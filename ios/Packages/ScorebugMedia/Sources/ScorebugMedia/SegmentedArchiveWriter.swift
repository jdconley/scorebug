@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum ArchiveWriterState: String, Codable, Sendable {
    case prepared, writing, finishing, finished, cancelled, failed
}

public enum ArchiveWriterError: Error, Equatable, Sendable {
    case invalidState, invalidTimestamp, invalidFormat, unsupportedSettings
    case encodingFailed, storageFailed, missingMedia
}

public struct ArchiveWriterSnapshot: Sendable {
    public let state: ArchiveWriterState
    public let videoFrames: Int
    public let audioSamples: Int
    public let acceptedDuration: Double
    public let segments: [ArchiveSegment]
    public let failure: ArchiveWriterError?
}

/// Owns the writer on one lock-protected lane. append never waits for encoder
/// readiness: a bounded upstream archive queue must retry the same sample before
/// accepting more. This object has no networking or scoring dependency.
public final class SegmentedArchiveWriter: @unchecked Sendable {
    public let directory: URL
    public let profile: ArchiveProfile
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let receiver: SegmentReceiver
    private var state: ArchiveWriterState = .prepared
    private var failure: ArchiveWriterError?
    private var origin = CMTime.invalid
    private var lastVideo = CMTime.invalid
    private var lastAudio = CMTime.invalid
    private var videoFrames = 0
    private var audioSamples = 0
    private var acceptedEnd = 0.0
    enum FinishCheckpoint { case beforeInitiation, beforeCompletion, afterCompletion }
    private var finishCheckpoint: (@Sendable (FinishCheckpoint) -> Void)?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    public init(directory: URL, profile: ArchiveProfile = ArchiveProfile(),
                reserveBytes: Int64 = 64 * 1024 * 1024,
                availableBytes: (@Sendable () -> Int64?)? = nil,
                storeFailureInjection: (@Sendable (ArchiveStoreFailurePoint) throws -> Void)? = nil) throws {
        try profile.validate()
        self.directory = directory
        self.profile = profile
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: profile.width, AVVideoHeightKey: profile.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: profile.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: profile.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: profile.segmentDuration,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: profile.audioSampleRate,
            AVNumberOfChannelsKey: profile.audioChannels,
            AVEncoderBitRateKey: profile.audioBitRate,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video),
              writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
            throw ArchiveWriterError.unsupportedSettings
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw ArchiveWriterError.unsupportedSettings
        }
        let store = try ArchiveSegmentStore(directory: directory, profile: profile,
                                             reserveBytes: reserveBytes, availableBytes: availableBytes,
                                             failureInjection: storeFailureInjection)
        receiver = SegmentReceiver(store: store)
        writer.add(videoInput)
        writer.add(audioInput)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: profile.segmentDuration, preferredTimescale: 60_000)
        writer.delegate = receiver
    }

    /// Internal synchronization seam for native lifecycle regression tests.
    convenience init(directory: URL, profile: ArchiveProfile,
                     finishCheckpoint: @escaping @Sendable (FinishCheckpoint) -> Void) throws {
        try self.init(directory: directory, profile: profile)
        self.finishCheckpoint = finishCheckpoint
    }

    #if DEBUG
    /// Attach once before startup; the receiver retains only this immutable owner reference.
    @discardableResult public func attachArchivePressureDiagnostics(_ owner: ArchivePressureDiagnostics) -> Bool {
        lock.withLock {
            guard state == .prepared else { return false }
            return receiver.attachArchivePressureDiagnostics(owner, profile: profile)
        }
    }
    #endif

    /// Accepted input duration, without querying segment storage. This shares the
    /// lifecycle lock and can still wait for an in-progress native writer call.
    public var acceptedDuration: Double { lock.withLock { acceptedEnd } }

    /// Scalars are captured before committed segments; this is not one atomic
    /// writer/store snapshot. Segments may include a later commit. A finished
    /// scalar state still includes all final segments, because durability precedes
    /// that state transition and the segment read follows it.
    public var snapshot: ArchiveWriterSnapshot {
        snapshot(readSegments: { receiver.store.segments })
    }

    /// Internal storage-read dependency used by the public snapshot path.
    func snapshot(readSegments: () -> [ArchiveSegment]) -> ArchiveWriterSnapshot {
        let scalar = lock.withLock {
            let storageFailed = receiver.failed
            return (state: storageFailed ? ArchiveWriterState.failed : state,
                    videoFrames: videoFrames, audioSamples: audioSamples,
                    acceptedDuration: acceptedEnd,
                    failure: storageFailed ? ArchiveWriterError.storageFailed : failure)
        }
        // Store reads can wait behind durable segment writes. Never hold the
        // append/finish/cancel lock during that wait.
        return ArchiveWriterSnapshot(state: scalar.state,
            videoFrames: scalar.videoFrames, audioSamples: scalar.audioSamples,
            acceptedDuration: scalar.acceptedDuration, segments: readSegments(),
            failure: scalar.failure)
    }

    /// Both input tracks use this one capture timestamp origin.
    public func start(at timestamp: CMTime) throws {
        try lock.withLock {
            guard state == .prepared else { throw ArchiveWriterError.invalidState }
            guard timestamp.isNumeric, timestamp.seconds.isFinite else { throw ArchiveWriterError.invalidTimestamp }
            writer.initialSegmentStartTime = timestamp
            guard writer.startWriting() else {
                state = .failed; failure = .encodingFailed
                throw ArchiveWriterError.encodingFailed
            }
            writer.startSession(atSourceTime: timestamp)
            origin = timestamp
            state = .writing
        }
    }

    /// false means temporary backpressure. The caller still owns this sample and
    /// must retry it or explicitly fail recording; silently skipping is not valid.
    public func append(_ sample: CMSampleBuffer, isVideo: Bool) throws -> Bool {
        try lock.withLock {
            guard state == .writing else { throw ArchiveWriterError.invalidState }
            if receiver.failed {
                state = .failed; failure = .storageFailed; writer.cancelWriting()
                throw ArchiveWriterError.storageFailed
            }
            guard writer.status == .writing else {
                state = .failed; failure = .encodingFailed
                throw ArchiveWriterError.encodingFailed
            }
            let timestamp = sample.presentationTimeStamp
            let previous = isVideo ? lastVideo : lastAudio
            guard CMSampleBufferDataIsReady(sample), timestamp.isNumeric,
                  timestamp.seconds.isFinite, timestamp >= origin,
                  !previous.isNumeric || timestamp > previous else {
                throw ArchiveWriterError.invalidTimestamp
            }
            try validate(sample, isVideo: isVideo)
            let input = isVideo ? videoInput : audioInput
            guard input.isReadyForMoreMediaData else { return false }
            guard input.append(sample) else {
                state = .failed; failure = .encodingFailed
                throw ArchiveWriterError.encodingFailed
            }
            let duration: Double
            if isVideo {
                lastVideo = timestamp; videoFrames += 1
                duration = sample.duration.isNumeric && sample.duration.seconds > 0
                    ? sample.duration.seconds : 1 / Double(profile.framesPerSecond)
            } else {
                lastAudio = timestamp; audioSamples += sample.numSamples
                duration = Double(sample.numSamples) / profile.audioSampleRate
            }
            acceptedEnd = max(acceptedEnd, timestamp.seconds - origin.seconds + duration)
            return true
        }
    }

    private func validate(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        if isVideo {
            guard let pixel = sample.imageBuffer,
                  CVPixelBufferGetWidth(pixel) == profile.width,
                  CVPixelBufferGetHeight(pixel) == profile.height,
                  [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                   kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(CVPixelBufferGetPixelFormatType(pixel)) else {
                throw ArchiveWriterError.invalidFormat
            }
        } else {
            guard let format = sample.formatDescription,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  description.pointee.mFormatID == kAudioFormatLinearPCM,
                  description.pointee.mSampleRate == profile.audioSampleRate,
                  Int(description.pointee.mChannelsPerFrame) == profile.audioChannels,
                  sample.numSamples > 0 else { throw ArchiveWriterError.invalidFormat }
        }
    }

    public func finish() async throws -> RecoveredArchive {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try lock.withLock {
                    guard state == .writing else { throw ArchiveWriterError.invalidState }
                    guard videoFrames > 0, audioSamples > 0 else {
                        writer.cancelWriting()
                        state = .failed; failure = .missingMedia
                        throw ArchiveWriterError.missingMedia
                    }
                    state = .finishing
                    videoInput.markAsFinished()
                    audioInput.markAsFinished()
                    finishCheckpoint?(.beforeInitiation)
                    // Initiation shares cancel's lock: AVAssetWriter must never
                    // receive finishWriting after cancelWriting has won the race.
                    finishContinuation = continuation
                    writer.finishWriting { [weak self] in
                        // Defer lock acquisition even if AVFoundation calls back
                        // inline while finishWriting still holds the lifecycle lock.
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            guard let self else { return }
                            finishCheckpoint?(.beforeCompletion)
                            completeFinish()
                            finishCheckpoint?(.afterCompletion)
                        }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return try ArchiveSegmentStore.recover(directory: directory)
    }

    private func completeFinish() {
        let completion: (CheckedContinuation<Void, Error>, Result<Void, Error>)? = lock.withLock {
            // Cancellation may have already resumed the waiter. AVFoundation's
            // callback is not guaranteed to arrive after cancelWriting.
            guard let continuation = finishContinuation else { return nil }
            finishContinuation = nil
            if receiver.failed {
                state = .failed; failure = .storageFailed
                return (continuation, .failure(ArchiveWriterError.storageFailed))
            }
            guard state != .cancelled, writer.status == .completed else {
                if state != .cancelled { state = .failed }
                failure = .encodingFailed
                return (continuation, .failure(ArchiveWriterError.encodingFailed))
            }
            state = .finished
            return (continuation, .success(()))
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }

    public func cancel() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard state != .finished && state != .cancelled else { return nil }
            writer.cancelWriting()
            state = .cancelled
            let pending = finishContinuation
            finishContinuation = nil
            if pending != nil { failure = .encodingFailed }
            return pending
        }
        continuation?.resume(throwing: ArchiveWriterError.encodingFailed)
    }
}

/// Callback payloads are persisted synchronously, avoiding an unbounded queue of
/// completed segment Data. AVAssetWriter retains its delegate weakly; the owner
/// above retains this receiver throughout append and asynchronous finalization.
private final class SegmentReceiver: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let store: ArchiveSegmentStore
    private let lock = NSLock()
    private var failure = false
    #if DEBUG
    private var diagnostics: ArchivePressureDiagnostics?
    func attachArchivePressureDiagnostics(_ owner: ArchivePressureDiagnostics, profile: ArchiveProfile) -> Bool {
        lock.withLock {
            guard diagnostics == nil, owner.attachPersistence(profile: profile) else { return false }
            diagnostics = owner
            return true
        }
    }
    #endif
    var failed: Bool { lock.withLock { failure } }
    init(store: ArchiveSegmentStore) { self.store = store }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        guard !failed else { return }
        do {
            switch segmentType {
            case .initialization:
                try persist(data: data, kind: .initialization)
            case .separable:
                let times = (segmentReport?.trackReports ?? []).compactMap { track -> (Double, Double)? in
                    let start = track.earliestPresentationTimeStamp
                    let duration = track.duration
                    guard start.isNumeric, duration.isNumeric, start.seconds.isFinite,
                          duration.seconds.isFinite, duration.seconds > 0 else { return nil }
                    return (start.seconds, start.seconds + duration.seconds)
                }
                let start = times.map(\.0).min()
                let duration = start.flatMap { first in times.map(\.1).max().map { $0 - first } }
                try persist(data: data, kind: .media, startTime: start, duration: duration)
            @unknown default:
                throw ArchiveWriterError.encodingFailed
            }
        } catch { lock.withLock { failure = true } }
    }

    private func persist(data: Data, kind: ArchiveSegmentKind, startTime: Double? = nil, duration: Double? = nil) throws {
        #if DEBUG
        let diagnostics = lock.withLock { self.diagnostics }
        let token = diagnostics?.persistenceStarted(kind: kind == .initialization ? .initialization : .media, bytes: data.count)
        do {
            try store.append(data: data, kind: kind, startTime: startTime, duration: duration)
            diagnostics?.persistenceFinished(token, result: .success)
        } catch {
            diagnostics?.persistenceFinished(token, result: .failure)
            throw error
        }
        #else
        try store.append(data: data, kind: kind, startTime: startTime, duration: duration)
        #endif
    }
}

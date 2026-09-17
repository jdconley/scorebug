import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

    private let encoderCompletionObserver: VideoEncoderCompletionObserver?
    private let encoderConfigurationObserver: VideoEncoderConfigurationObserver?
    private var recordedBitRateChange: VideoBitRateChange?
    private var lastSubmittedSourcePTS: CMTime?
    private var replacement: VideoEncoderReplacement?
    private var terminalCompletionCaptured = false

    private let sessionFactory: ((VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)?
    init(encoderCompletionObserver: VideoEncoderCompletionObserver? = nil,
         encoderConfigurationObserver: VideoEncoderConfigurationObserver? = nil,
         sessionFactory: ((VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)? = nil) {
        self.encoderCompletionObserver = encoderCompletionObserver
        self.encoderConfigurationObserver = encoderConfigurationObserver
        self.sessionFactory = sessionFactory
    }

    var lastBitRateChange: VideoBitRateChange? {
        guard isRunning, replacement == nil, failure.error == nil, let recordedBitRateChange,
              invalidation.isCurrent(recordedBitRateChange.configuration.encoderSessionID) else { return nil }
        return recordedBitRateChange
    }

    var lastSubmission: (sessionID: UUID, sourcePTS: CMTime)? {
        guard isRunning, failure.error == nil, sessionMode == .compression,
              let lastSubmittedSourcePTS else { return nil }
        let current = invalidation.snapshot
        guard !current.pending else { return nil }
        return (current.revision, lastSubmittedSourcePTS)
    }

    func requestSessionInvalidation() { invalidation.invalidate() }

    func prepareReplacement(_ settings: VideoCodecSettings) throws -> VideoEncoderReplacement {
        guard replacement == nil else { throw VideoEncoderReplacementError.busy }
        guard isRunning, !terminalCompletionCaptured, failure.error == nil, sessionMode == .compression, let session else {
            throw VideoEncoderReplacementError.notEncoding
        }
        let observed = invalidation.snapshot
        guard !observed.pending else { throw VideoEncoderReplacementError.obsolete }
        let operation = VideoEncoderReplacement(settings: settings, revision: observed.revision,
            session: session, failure: failure)
        replacement = operation
        return operation
    }

    /// Stages creation on the next raw input, not a receipt for the new encoder.
    /// The old output queue stays open and source timestamp ordering is retained.
    func commitReplacement(_ operation: VideoEncoderReplacement) throws {
        guard replacement === operation, operation.failure === failure,
              invalidation.isCurrent(operation.revision) else { throw VideoEncoderReplacementError.obsolete }
        guard isRunning, failure.error == nil else { throw VideoEncoderReplacementError.notEncoding }
        guard let status = operation.drainResult else { throw VideoEncoderReplacementError.notDrained }
        guard status == noErr else {
            failure.fail(.codecFailed(status: status))
            throw VideoEncoderReplacementError.drainFailed(status: status)
        }
        session = nil; sessionMode = nil
        storedSettings = operation.settings
        recordedBitRateChange = nil; lastSubmittedSourcePTS = nil
        requestSessionInvalidation()
        replacement = nil
    }


    func setVerifiedBitRate(_ bitRate: Int) throws -> VideoCodecSettings {
        guard isRunning, failure.error == nil, sessionMode == .compression, let session else {
            throw VideoBitRateUpdateError.notEncoding
        }
        let observed = invalidation.snapshot
        guard replacement == nil, !observed.pending else { throw VideoBitRateUpdateError.sessionInvalidated }
        let updated: VideoCodecSettings
        do { updated = try VerifiedVideoBitRate.apply(bitRate, to: settings, session: session) }
        catch let error as VideoBitRateUpdateError {
            // A failed attempted native mutation is not a successful rollback.
            switch error {
            case .writeFailed(_, let status), .readFailed(_, let status):
                failure.fail(.codecFailed(status: status))
            case .readbackMismatch:
                failure.fail(.codecFailed(status: -1))
            default: break // Preflight rejection made no native call.
            }
            throw error
        }
        guard failure.error == nil else { throw VideoBitRateUpdateError.notEncoding }
        guard invalidation.isCurrent(observed.revision) else {
            failure.fail(.codecFailed(status: -1))
            throw VideoBitRateUpdateError.sessionInvalidated
        }
        // This is accepted configuration at this point, not a frame boundary or
        // achieved output rate. Do not repeat settings' legacy unchecked apply.
        storedSettings = updated
        recordedBitRateChange = .init(settings: updated,
            configuration: .init(id: UUID(), encoderSessionID: observed.revision, bitRate: updated.bitRate),
            acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: lastSubmittedSourcePTS)
        return updated
    }


    private var storedSettings: VideoCodecSettings = .default
    var settings: VideoCodecSettings {
        get { storedSettings }
        set {
            guard replacement == nil else {
                failure.fail(.outputTerminated(boundary: "video replacement settings")); return
            }
            let previous = storedSettings
            recordedBitRateChange = nil
            storedSettings = newValue
            if newValue.invalidateSession(previous) { requestSessionInvalidation() }
            else { newValue.apply(self, rhs: previous) }
        }
    }
    var passthrough = true
    var failure = PublishingFailureLatch()
    var outputLimits = PublishingQueue<CMSampleBuffer>.Limits(count: 8, bytesPerItem: 2 * 1024 * 1024)
    var outputStream: AsyncStream<CMSampleBuffer> {
        continuation?.finish()
        let queue = PublishingQueue<CMSampleBuffer>(boundary: "video codec", limits: outputLimits, failure: failure)
        continuation = queue
        return queue.stream
    }
    var frameInterval = VideoCodec.frameInterval
    private var startedAt: CMTime = .zero
    private var continuation: PublishingQueue<CMSampleBuffer>?
    private let invalidation = VideoCodecInvalidation()
    private var sessionMode: VTSessionMode?
    private var presentationTimeStamp: CMTime?
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            requestSessionInvalidation()
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, failure.error == nil else {
            return
        }
        guard replacement == nil else {
            failure.fail(.outputTerminated(boundary: "video replacement input")); return
        }
        do {
            inputFormat = sampleBuffer.formatDescription
            let observed = invalidation.snapshot
            if observed.pending {
                let mode: VTSessionMode = sampleBuffer.formatDescription?.isCompressed == true ? .decompression : .compression
                session = try sessionFactory?(mode, self) ?? mode.makeSession(self)
                recordedBitRateChange = nil; lastSubmittedSourcePTS = nil
                sessionMode = mode
                invalidation.installed(observed.revision)
            }
            guard invalidation.isCurrent(observed.revision) else { return }
            guard let session, let continuation else {
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, continuation: continuation, encoderCompletionObserver: encoderCompletionObserver)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    let observer = submissionObserver(sessionID: observed.revision)
                    try session.convert(sampleBuffer, continuation: continuation, encoderCompletionObserver: observer)
                    if sampleBuffer.imageBuffer != nil { lastSubmittedSourcePTS = sampleBuffer.presentationTimeStamp }
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                }
            }
        } catch {
            failure.fail(.codecFailed(status: (error as? VTSessionError)?.status ?? -1))
            logger.warn(error)
        }
    }

    private func submissionObserver(sessionID: UUID) -> VideoEncoderCompletionObserver? {
        guard let configurationObserver = encoderConfigurationObserver else { return encoderCompletionObserver }
        let legacyObserver = encoderCompletionObserver
        let configuration = recordedBitRateChange?.configuration
        let submittedAt = ProcessInfo.processInfo.systemUptime
        return { source, output in
            let completedAt = ProcessInfo.processInfo.systemUptime
            legacyObserver?(source, output)
            configurationObserver(.init(sourcePTS: source, outputPTS: output,
                encoderSessionID: sessionID, configuration: configuration,
                submittedAt: submittedAt, completedAt: completedAt))
        }
    }

    /// Capture after raw input drains. The caller runs this off its stream actor
    /// so callbacks can be consumed concurrently within the existing queue bound.
    /// Only terminal invalidation may overlap the captured native session.
    func makeCompletion() -> @Sendable () -> Void {
        terminalCompletionCaptured = true
        if replacement != nil { failure.fail(.outputTerminated(boundary: "video replacement finish")) }
        let completion = VideoCompletion(session: replacement == nil ? session : nil,
            output: continuation, failure: failure)
        return { completion.run() }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = CMFormatDescriptionGetMediaSubType(inputFormat) as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        // A stream has no previous frame until its first accepted input. Zero is a
        // valid first PTS, including after restart and with a frame limiter enabled.
        guard let previousTimeStamp = self.presentationTimeStamp else {
            return true
        }
        guard previousTimeStamp < presentationTimeStamp else {
            return false
        }
        guard Self.frameInterval < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - previousTimeStamp.seconds
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        requestSessionInvalidation()
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            requestSessionInvalidation()
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        terminalCompletionCaptured = false
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        replacement = nil
        session = nil
        sessionMode = nil
        recordedBitRateChange = nil; lastSubmittedSourcePTS = nil
        requestSessionInvalidation()
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = nil
        continuation?.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}

/// Native VideoToolbox sessions support callback completion and invalidation;
/// this immutable owner transfers no mutable VideoCodec state off its actor.
private struct VideoCompletion: @unchecked Sendable {
    let session: (any VTSessionConvertible)?
    let output: PublishingQueue<CMSampleBuffer>?
    let failure: PublishingFailureLatch
    func run() {
        if let session {
            let status = session.completeFrames()
            if status != noErr { failure.fail(.codecFailed(status: status)) }
        }
        output?.finish()
    }
}

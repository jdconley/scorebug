import AVFoundation
import Foundation
import VideoToolbox

/// A single-use off-network candidate measurement using the publishing codec.
public final class VideoCandidateEncoder: @unchecked Sendable {
    public enum Outcome: String, Sendable { case completed, cancelled, failed }
    public struct Frame: Sendable {
        public let sourcePTS: CMTime
        public let outputPTS: CMTime
        public let encoderSessionID: UUID
        public let admittedAt: Double
        public let rawByteCount: Int
        public let submittedAt: Double
        public let completedAt: Double
        public let dequeuedAt: Double
        public let byteCount: Int
        public let width: Int32
        public let height: Int32
        public let isSync: Bool
    }
    public struct Result: Sendable {
        public let id: UUID
        /// The requested publishing recipe, not a native property-readback receipt.
        public let settings: VideoCodecSettings
        public let outcome: Outcome
        public let failure: String?
        public let nativeFailure: PublishingError?
        public let encoderSessionID: UUID?
        public let acceptedInputCount: Int
        public let outputCount: Int
        public let frames: [Frame]
    }
    public let id: UUID
    public let settings: VideoCodecSettings
    private let state: CandidateState
    private let owner: CandidateOwner
    public convenience init(settings: VideoCodecSettings, id: UUID = UUID()) throws {
        try self.init(settings: settings, id: id, sessionFactory: nil)
    }
    init(settings: VideoCodecSettings, id: UUID = UUID(),
         sessionFactory: (@Sendable (VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)?,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         deadlineWait: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(8)) },
         outputObserver: (@Sendable (Frame) -> Void)? = nil) throws {
        guard settings.format == .h264, settings.profileLevel.contains("H264"),
              [settings.videoSize.width, settings.videoSize.height].allSatisfy({
                  $0.isFinite && $0 >= 1 && $0 <= 4096 && $0.rounded() == $0
              }), settings.bitRate > 0, settings.bitRate <= Int(Int32.max),
              settings.frameInterval.isFinite, settings.frameInterval >= 0,
              settings.maxKeyFrameIntervalDuration > 0,
              settings.expectedFrameRate.map({ $0.isFinite && $0 > 0 }) ?? true,
              settings.dataRateLimits.map({ $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 } }) ?? true else {
            throw CandidateStartupError.invalidSettings
        }
        self.settings = settings; self.id = id
        let state = CandidateState(id: id, settings: settings, now: now)
        self.state = state
        owner = CandidateOwner(state: state, settings: settings, sessionFactory: sessionFactory,
                               deadlineWait: deadlineWait, outputObserver: outputObserver)
    }
    public func start() async throws {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await owner.start()
                try Task.checkCancellation()
            } onCancel: { state.cancel() }
        } catch {
            if Task.isCancelled || error is CancellationError {
                state.cancel()
                _ = await owner.result()
            }
            throw error
        }
    }
    /// Queues at most four raw frames, with at most sixteen unresolved inputs and
    /// 64 MiB of outstanding raw payload. Never waits for the encoder or schedules
    /// a per-frame task. A malformed/overflowing active offer fails the run.
    @discardableResult public func offer(_ sample: CMSampleBuffer) -> Bool { state.offer(sample) }
    /// Native completion may block beyond admission's deadline; it is always joined.
    public func finish() async -> Result {
        state.close()
        return await withTaskCancellationHandler { await owner.result() } onCancel: { state.cancel() }
    }
    public func cancel() async -> Result { state.cancel(); return await owner.result() }
}

private enum CandidateStartupError: Error { case invalidSettings, alreadyStarted, invalidClock }

/// Only bounded ingress and scalar accounting cross threads. Mutable VideoCodec
/// ownership never leaves CandidateOwner, except its immutable completion capture.
private final class CandidateState: @unchecked Sendable {
    private struct Record {
        let pts: CMTime
        let admittedAt: Double
        let rawByteCount: Int
        var submitted = false
        var callback: VideoEncoderFrame?
        var output: VideoCandidateEncoder.Frame?
    }
    private let lock = NSLock()
    private let id: UUID, settings: VideoCodecSettings
    let now: @Sendable () -> Double
    let input: AsyncStream<CMSampleBuffer>
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    private var startedAt: Double?
    private var closed = false, cancelled = false
    private var failure: String?
    private var records: [Record] = []
    private var unresolved = 0, outputCount = 0
    private var outstandingRawBytes = 0
    private var inputFormat: CMFormatDescription?
    private var sessionID: UUID?
    private var terminal: VideoCandidateEncoder.Result?

    init(id: UUID, settings: VideoCodecSettings, now: @escaping @Sendable () -> Double) {
        self.id = id; self.settings = settings; self.now = now
        (input, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(4))
    }
    func begin() throws {
        try lock.withLock {
            guard startedAt == nil, !closed, terminal == nil else { throw CandidateStartupError.alreadyStarted }
            let at = now()
            guard at.isFinite, at >= 0 else { throw CandidateStartupError.invalidClock }
            startedAt = at
        }
    }
    private func reject(_ reason: String) {
        failure = failure ?? reason; closed = true; continuation.finish()
    }
    func fail(_ reason: String) { lock.withLock { if terminal == nil { reject(reason) } } }
    func close() {
        lock.withLock {
            // A delayed timer must not let finish race an expired admission
            // window. Once closed on time, native completion may outlive it.
            if !closed, let startedAt {
                let at = now()
                if !at.isFinite || at < startedAt || at - startedAt >= 8 { reject("admissionDeadline") }
            }
            closed = true; continuation.finish()
        }
    }
    func cancel() {
        lock.withLock {
            guard terminal == nil else { return }
            cancelled = true; closed = true; continuation.finish()
        }
    }
    func expire() {
        lock.withLock {
            guard startedAt != nil, !closed, terminal == nil else { return }
            reject("admissionDeadline")
        }
    }
    var mayEncode: Bool { lock.withLock { !cancelled && failure == nil && terminal == nil } }
    private func valid(_ pts: CMTime) -> Bool {
        pts.isNumeric && pts.timescale > 0 && pts.epoch == 0 && pts.value >= 0
    }
    func offer(_ sample: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard let startedAt, !closed, terminal == nil else { return false }
            let at = now()
            guard at.isFinite, at >= startedAt, at - startedAt < 8 else { reject("admissionDeadline"); return false }
            guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
                  let format = sample.formatDescription, format.mediaType == .video, !format.isCompressed,
                  let image = sample.imageBuffer, sample.dataBuffer == nil,
                  CVPixelBufferGetDataSize(image) > 0, CVPixelBufferGetDataSize(image) <= 16 * 1024 * 1024,
                  CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: image),
                  valid(sample.presentationTimeStamp) else { reject("invalidRawInput"); return false }
            let pts = sample.presentationTimeStamp
            if let previous = records.last {
                guard CMTimeCompare(previous.pts, pts) < 0 else { reject("nonIncreasingSourcePTS"); return false }
            }
            if let first = records.first {
                let span = CMTimeSubtract(pts, first.pts)
                guard span.isNumeric, CMTimeCompare(span, CMTime(value: 17, timescale: 4)) <= 0 else {
                    reject("sourceSpanLimit"); return false
                }
            }
            if let inputFormat, !CFEqual(inputFormat, format) { reject("inputFormatChanged"); return false }
            guard records.count < 121 else { reject("frameLimit"); return false }
            let rawBytes = CVPixelBufferGetDataSize(image)
            guard unresolved < 16 else { reject("unresolvedInputLimit"); return false }
            guard rawBytes <= 64 * 1024 * 1024 - outstandingRawBytes else {
                reject("unresolvedRawByteLimit"); return false
            }
            inputFormat = format
            records.append(.init(pts: pts, admittedAt: at, rawByteCount: rawBytes))
            unresolved += 1; outstandingRawBytes += rawBytes
            switch continuation.yield(sample) {
            case .enqueued: return true
            default: reject("rawQueueFailure"); return false
            }
        }
    }
    func submitted(_ pts: CMTime, receipt: (sessionID: UUID, sourcePTS: CMTime)?) {
        lock.withLock {
            guard let index = records.firstIndex(where: { CMTimeCompare($0.pts, pts) == 0 }),
                  let receipt, CMTimeCompare(receipt.sourcePTS, pts) == 0, !records[index].submitted else {
                reject("missingNativeSubmission"); return
            }
            if let sessionID, sessionID != receipt.sessionID { reject("encoderSessionChanged"); return }
            sessionID = receipt.sessionID; records[index].submitted = true
        }
    }
    func callback(_ frame: VideoEncoderFrame) {
        lock.withLock {
            guard terminal == nil else { return }
            guard valid(frame.sourcePTS), valid(frame.outputPTS), CMTimeCompare(frame.sourcePTS, frame.outputPTS) == 0,
                  frame.submittedAt.isFinite, frame.completedAt.isFinite,
                  frame.submittedAt >= (startedAt ?? .infinity), frame.completedAt >= frame.submittedAt,
                  let index = records.firstIndex(where: { CMTimeCompare($0.pts, frame.sourcePTS) == 0 }),
                  frame.submittedAt >= records[index].admittedAt,
                  records[index].callback == nil else { reject("invalidNativeCallback"); return }
            if let sessionID, sessionID != frame.encoderSessionID { reject("encoderSessionChanged"); return }
            sessionID = frame.encoderSessionID; records[index].callback = frame
        }
    }
    func output(_ sample: CMSampleBuffer) -> VideoCandidateEncoder.Frame? {
        lock.withLock {
            outputCount += 1
            let pts = sample.presentationTimeStamp, at = now()
            guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
                  sample.imageBuffer == nil, valid(pts), let format = sample.formatDescription,
                  format.mediaType == .video, format.isCompressed,
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
                  let data = sample.dataBuffer,
                  data.dataLength > 0, data.dataLength <= 2 * 1024 * 1024,
                  CMSampleBufferGetTotalSampleSize(sample) == data.dataLength,
                  let index = records.firstIndex(where: { CMTimeCompare($0.pts, pts) == 0 }),
                  records[index].submitted, records[index].output == nil, let callback = records[index].callback,
                  at.isFinite, at >= callback.completedAt else { reject("invalidCompressedOutput"); return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width == Int32(settings.videoSize.width), dimensions.height == Int32(settings.videoSize.height) else {
                reject("unexpectedOutputDimensions"); return nil
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String]
            guard notSync == nil || notSync is Bool else { reject("invalidSyncMetadata"); return nil }
            let sync = !(notSync as? Bool ?? false)
            guard index != 0 || sync else { reject("missingInitialKeyframe"); return nil }
            let frame = VideoCandidateEncoder.Frame(sourcePTS: records[index].pts, outputPTS: pts,
                encoderSessionID: callback.encoderSessionID, admittedAt: records[index].admittedAt,
                rawByteCount: records[index].rawByteCount, submittedAt: callback.submittedAt,
                completedAt: callback.completedAt, dequeuedAt: at, byteCount: data.dataLength,
                width: dimensions.width, height: dimensions.height, isSync: sync)
            records[index].output = frame; unresolved -= 1
            outstandingRawBytes -= records[index].rawByteCount
            return frame
        }
    }
    func complete(nativeFailure: PublishingError?) -> VideoCandidateEncoder.Result {
        lock.withLock {
            if let terminal { return terminal }
            if startedAt == nil { failure = failure ?? "notStarted" }
            if records.isEmpty { failure = failure ?? "noFrames" }
            if nativeFailure != nil { failure = failure ?? "nativeFailure" }
            if unresolved != 0 || outstandingRawBytes != 0 || records.contains(where: { !$0.submitted || $0.callback == nil || $0.output == nil }) || outputCount != records.count {
                failure = failure ?? "incompleteJoin"
            }
            let result = VideoCandidateEncoder.Result(id: id, settings: settings,
                outcome: cancelled ? .cancelled : failure == nil ? .completed : .failed,
                failure: failure, nativeFailure: nativeFailure, encoderSessionID: sessionID,
                acceptedInputCount: records.count, outputCount: outputCount, frames: records.compactMap(\.output))
            closed = true; inputFormat = nil; terminal = result
            return result
        }
    }
}

private actor CandidateOwner {
    private let state: CandidateState
    private let settings: VideoCodecSettings
    private let sessionFactory: (@Sendable (VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)?
    private let deadlineWait: @Sendable () async -> Void
    private let outputObserver: (@Sendable (VideoCandidateEncoder.Frame) -> Void)?
    private var codec: VideoCodec?
    private var terminalTask: Task<VideoCandidateEncoder.Result, Never>?
    init(state: CandidateState, settings: VideoCodecSettings,
         sessionFactory: (@Sendable (VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)?,
         deadlineWait: @escaping @Sendable () async -> Void,
         outputObserver: (@Sendable (VideoCandidateEncoder.Frame) -> Void)?) {
        self.state = state; self.settings = settings; self.sessionFactory = sessionFactory
        self.deadlineWait = deadlineWait; self.outputObserver = outputObserver
    }
    func start() throws {
        try state.begin()
        let state = state
        let codec = VideoCodec(encoderConfigurationObserver: { state.callback($0) }, sessionFactory: sessionFactory)
        codec.settings = settings
        self.codec = codec
        let output = codec.outputStream, input = state.input, failure = codec.failure
        codec.startRunning()
        let inputTask = Task {
            for await sample in input {
                if state.mayEncode {
                    self.codec?.append(sample)
                    state.submitted(sample.presentationTimeStamp, receipt: self.codec?.lastSubmission)
                }
            }
        }
        let outputTask = Task {
            for await sample in output {
                if let frame = state.output(sample) { outputObserver?(frame) }
            }
        }
        let errorsTask = Task {
            for await _ in failure.events { state.fail("nativeFailure") }
        }
        let deadlineTask = Task {
            await deadlineWait()
            if !Task.isCancelled { state.expire() }
        }
        terminalTask = Task {
            await inputTask.value
            // All raw work has joined. Completion runs outside this actor so
            // the bounded compressed queue is consumed during native draining.
            if let completion = self.codec?.makeCompletion() {
                await Task.detached(priority: .utility) { completion() }.value
            }
            await outputTask.value
            self.codec?.stopRunning(); self.codec = nil
            failure.finish()
            await errorsTask.value
            deadlineTask.cancel(); await deadlineTask.value
            return state.complete(nativeFailure: failure.error)
        }
    }
    func result() async -> VideoCandidateEncoder.Result {
        if let terminalTask { return await terminalTask.value }
        return state.complete(nativeFailure: nil)
    }
}

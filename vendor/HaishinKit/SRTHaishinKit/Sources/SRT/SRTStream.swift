@preconcurrency import AVFoundation
import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a one-way channel over a SRTConnection.
public actor SRTStream {
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
    /// Scalar diagnostic of one FIFO payload's send call. Returned does not mean
    /// socket acceptance or receiver delivery. Observers must not wait or do I/O.
    public struct TransportSendObservation: Sendable {
        /// Outer phases execute on the transport worker; inner phases bracket the
        /// awaited socket.send on its connection actor, before error handling.
        /// Early connection guards may omit both inner phases.
        public enum Phase: String, Sendable { case started, socketStarted, socketReturned, returned }
        public let publishingGeneration: UInt64
        public let sequence: UInt64
        public let phase: Phase
        public let byteCount: Int
        public let pendingPacketCount: Int
        public let observedAt: Double
    }
    private let transportSendObserver: (@Sendable (TransportSendObservation) -> Void)?

    static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    /// A latched transport muxer failure. Cleared when the stream is closed/reset.
    public var muxerError: MuxerError? { writer.error }

    public enum MuxerError: Swift.Error, Equatable, Sendable {
        case payloadByteLimitExceeded
        case outputByteLimitExceeded
        case outputQueueLimitExceeded
        case invalidTimestamp
        case invalidPayload
        case startupPacketLimitExceeded
        case startupByteLimitExceeded
        case startupTimeLimitExceeded
        case incompleteStartup
    }

    /// First terminal publishing failure; retained through close and reset by publish.
    public var publishingError: PublishingError? { failure.error ?? writer.failure.error }
    private var failure = PublishingFailureLatch()
    private var generation: UInt64 = 0
    private var videoInputIsRaw = false
    private let pacesEncodedVideo: Bool
    private let pacingSleep: @Sendable (Double) async throws -> Void
    private var sourceCadenceClock = SourceCadenceClock()
    private let allowsBandwidthProbes: Bool
    private var bandwidthProbe: SRTBandwidthProbe?
    private let probeWakeRunner: @Sendable (SRTBandwidthProbe, TransportOutputAccounting) async -> Void
    private var probeWakeTask: Task<Void, Never>?
    private var probeStarting = false
    private var probeConfigurationRevision: UInt64 = 0
    private func invalidateProbeConfiguration() {
        probeConfigurationRevision &+= 1
        bandwidthProbe?.cancel(.replaced)
    }
    /// Last attempt survives close for diagnostics; a new publish clears it.
    public var bandwidthProbeSnapshot: SRTBandwidthProbeSnapshot? {
        bandwidthProbe?.snapshot(now: { ProcessInfo.processInfo.systemUptime })
    }
    public func beginBandwidthProbe(bitRate: Int, publishingGeneration expected: UInt64,
                                    staged: Bool = false, repeatable: Bool = false) async throws -> SRTBandwidthProbeSnapshot {
        try Task.checkCancellation()
        guard allowsBandwidthProbes else { throw SRTBandwidthProbeError.disabled }
        guard !repeatable || staged else { throw SRTBandwidthProbeError.invalidConfiguration }
        let maximumBitRate = staged ? 12_000_000 : 2_000_000
        guard (1...maximumBitRate).contains(bitRate) else { throw SRTBandwidthProbeError.invalidConfiguration }
        guard publishingGeneration == expected, writer.transportClock != nil, videoReplacement == nil, videoMutation == nil,
              let connection else { throw SRTBandwidthProbeError.notPublishing }
        guard bandwidthProbe == nil, !probeStarting else { throw SRTBandwidthProbeError.alreadyStarted }
        probeStarting = true
        let configuration = probeConfigurationRevision
        defer { probeStarting = false }
        let statistics = await connection.samplePerformanceData()
        try Task.checkCancellation()
        guard publishingGeneration == expected, videoReplacement == nil, videoMutation == nil,
              probeConfigurationRevision == configuration else { throw SRTBandwidthProbeError.obsolete }
        guard let statistics else { throw SRTBandwidthProbeError.unavailableStatistics }
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: bitRate, generation: expected, statistics: statistics, at: at,
            stage: staged ? 1 : nil, campaign: repeatable ? 1 : nil, campaignStartedAt: staged ? at : nil)
        return installBandwidthProbe(probe, at: at)
    }

    /// Replace only the current staged identity. Revocation joins any native send
    /// under the probe lock before its wake owner is cancelled and joined. Media
    /// keeps its single transport consumer; queued old opportunities are inert.
    public func replaceBandwidthProbe(id: UUID, publishingGeneration expected: UInt64,
                                      stage: UInt32, bitRate: Int) async throws -> SRTBandwidthProbeSnapshot {
        try Task.checkCancellation()
        guard allowsBandwidthProbes else { throw SRTBandwidthProbeError.disabled }
        guard (1...12_000_000).contains(bitRate) else { throw SRTBandwidthProbeError.invalidConfiguration }
        guard publishingGeneration == expected, writer.transportClock != nil, videoReplacement == nil, videoMutation == nil,
              let connection else { throw SRTBandwidthProbeError.notPublishing }
        guard let previous = bandwidthProbe, previous.id == id, previous.generation == expected,
              previous.snapshot(now: { ProcessInfo.processInfo.systemUptime }).stage == stage else {
            throw SRTBandwidthProbeError.obsolete
        }
        guard stage < 32 else { throw SRTBandwidthProbeError.invalidConfiguration }
        guard !probeStarting else { throw SRTBandwidthProbeError.alreadyStarted }
        probeStarting = true
        let configuration = probeConfigurationRevision
        defer { probeStarting = false }
        previous.cancel(.replaced)
        let oldWake = probeWakeTask
        oldWake?.cancel()
        await oldWake?.value
        try Task.checkCancellation()
        guard publishingGeneration == expected, bandwidthProbe === previous, videoReplacement == nil, videoMutation == nil,
              probeConfigurationRevision == configuration else { throw SRTBandwidthProbeError.obsolete }
        let retired = previous.snapshot(now: { ProcessInfo.processInfo.systemUptime })
        guard let origin = retired.campaignStartedAt, let accepted = retired.totalAcceptedPayloadBytes else {
            throw SRTBandwidthProbeError.invalidConfiguration
        }
        let statistics = await connection.samplePerformanceData()
        try Task.checkCancellation()
        guard publishingGeneration == expected, bandwidthProbe === previous, videoReplacement == nil, videoMutation == nil,
              probeConfigurationRevision == configuration else { throw SRTBandwidthProbeError.obsolete }
        guard let statistics else { throw SRTBandwidthProbeError.unavailableStatistics }
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: bitRate, generation: expected, statistics: statistics, at: at,
            stage: stage + 1, campaign: retired.campaign, campaignStartedAt: origin, previouslyAcceptedPayloadBytes: accepted)
        return installBandwidthProbe(probe, at: at)
    }

    /// Start a fresh campaign only from the current terminal staged identity.
    /// The retired attempt remains available for an explicit retry if admission
    /// fails. Its authority is never revived, and no campaign accounting carries.
    /// Only an explicitly repeatable v3 owner can advance its campaign ordinal.
    /// Legacy v1/v2 probes cannot restart within the same publication.
    public func restartBandwidthProbe(id: UUID, publishingGeneration expected: UInt64,
                                      stage: UInt32, bitRate: Int) async throws -> SRTBandwidthProbeSnapshot {
        try Task.checkCancellation()
        guard allowsBandwidthProbes else { throw SRTBandwidthProbeError.disabled }
        guard (1...12_000_000).contains(bitRate) else { throw SRTBandwidthProbeError.invalidConfiguration }
        guard publishingGeneration == expected, writer.transportClock != nil, videoReplacement == nil, videoMutation == nil,
              let connection else { throw SRTBandwidthProbeError.notPublishing }
        guard let previous = bandwidthProbe, previous.id == id, previous.generation == expected else {
            throw SRTBandwidthProbeError.obsolete
        }
        let retired = previous.snapshot(now: { ProcessInfo.processInfo.systemUptime })
        guard retired.stage == stage, retired.reason != nil else { throw SRTBandwidthProbeError.obsolete }
        let campaign = try previous.nextCampaign()
        guard !probeStarting else { throw SRTBandwidthProbeError.alreadyStarted }
        probeStarting = true
        let configuration = probeConfigurationRevision
        defer { probeStarting = false }
        let oldWake = probeWakeTask
        oldWake?.cancel()
        await oldWake?.value
        try Task.checkCancellation()
        guard publishingGeneration == expected, writer.transportClock != nil, bandwidthProbe === previous,
              videoReplacement == nil, videoMutation == nil, probeConfigurationRevision == configuration else {
            throw SRTBandwidthProbeError.obsolete
        }
        let statistics = await connection.samplePerformanceData()
        try Task.checkCancellation()
        guard publishingGeneration == expected, writer.transportClock != nil, bandwidthProbe === previous,
              videoReplacement == nil, videoMutation == nil, probeConfigurationRevision == configuration else {
            throw SRTBandwidthProbeError.obsolete
        }
        guard let statistics else { throw SRTBandwidthProbeError.unavailableStatistics }
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: bitRate, generation: expected, statistics: statistics, at: at,
            stage: 1, campaign: campaign, campaignStartedAt: at)
        return installBandwidthProbe(probe, at: at)
    }

    private func installBandwidthProbe(_ probe: SRTBandwidthProbe, at: Double) -> SRTBandwidthProbeSnapshot {
        // Once exposed, the independent pump may advance the probe clock.
        // Capture the initial receipt before publishing its pointer.
        let initial = probe.snapshot(now: { at })
        bandwidthProbe = probe
        let accounting = writer.outputAccounting
        accounting.probe = probe
        probeWakeTask = Task {
            await probeWakeRunner(probe, accounting)
        }
        return initial
    }
    public func renewBandwidthProbe(id: UUID, publishingGeneration expected: UInt64) throws -> SRTBandwidthProbeSnapshot {
        try Task.checkCancellation()
        guard publishingGeneration == expected, let probe = bandwidthProbe, probe.id == id,
              probe.generation == expected else { throw SRTBandwidthProbeError.obsolete }
        _ = probe.renew(now: { ProcessInfo.processInfo.systemUptime })
        return probe.snapshot(now: { ProcessInfo.processInfo.systemUptime })
    }
    public func cancelBandwidthProbe(id: UUID, publishingGeneration expected: UInt64) throws {
        guard publishingGeneration == expected, let probe = bandwidthProbe,
              probe.id == id, probe.generation == expected else { throw SRTBandwidthProbeError.obsolete }
        probeConfigurationRevision &+= 1
        probe.cancel(.cancelled)
        probeWakeTask?.cancel()
    }
    /// Scalar evidence that a PES reached the local mux output queue/sink.
    /// Transport timestamps are unwrapped 90 kHz integers, not wire-modulo values.
    /// This does not prove a socket write or receiver delivery.
    public struct MuxedPacketFrame: Sendable {
        public enum Media: String, Sendable { case audio, video }
        public let publishingGeneration: UInt64
        public let media: Media
        public let sourcePTS: CMTime
        public let sourceDTS: CMTime
        public let transportPTS: UInt64
        public let transportDTS: UInt64?
        public let observedAt: Double
    }
    private let muxedPacketObserver: (@Sendable (MuxedPacketFrame) -> Void)?
    private let compressedAudioObserver: (@Sendable (CompressedAudioFrame) -> Void)?
    private let compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)?
    /// Identity for an active publication, not proof that its encoder is ready.
    public var publishingGeneration: UInt64? {
        readyState == .publishing && finishingGeneration == nil && publishingError == nil && muxerError == nil
            ? generation : nil
    }
    public struct TransportClockSnapshot: Equatable, Sendable {
        public let publishingGeneration: UInt64
        public let clock: TransportClock
    }
    /// Muxer-selected mapping only; never a claim of transport receipt or frame loss.
    public var transportClockSnapshot: TransportClockSnapshot? {
        guard let generation = publishingGeneration, let clock = writer.transportClock else { return nil }
        return .init(publishingGeneration: generation, clock: clock)
    }

    /// Point-in-time native configuration acknowledgment. It is not a source-frame
    /// boundary, achieved output rate, or authorization to relabel queued frames.
    public func setVerifiedVideoBitRate(_ bitRate: Int, publishingGeneration expected: UInt64) async throws -> VideoCodecSettings {
        try await setVerifiedVideoBitRateWithReceipt(bitRate, publishingGeneration: expected).change.settings
    }
    public struct VideoBitRateReceipt: Sendable {
        public let publishingGeneration: UInt64
        public let change: VideoBitRateChange
    }
    public func setVerifiedVideoBitRateWithReceipt(_ bitRate: Int, publishingGeneration expected: UInt64) async throws -> VideoBitRateReceipt {
        try Task.checkCancellation()
        guard publishingGeneration == expected, videoInputIsRaw else { throw VideoBitRateUpdateError.notEncoding }
        guard videoReplacement == nil, videoMutation == nil, closeTask == nil, finishingGeneration == nil else {
            throw VideoBitRateUpdateError.sessionInvalidated
        }
        let mutation = reserveVideoMutation()
        defer { releaseVideoMutation(mutation) }
        invalidateProbeConfiguration()
        if let submission = videoSubmission { await commitVideoSubmission(submission) }
        try Task.checkCancellation()
        guard videoMutation == mutation, publishingGeneration == expected, closeTask == nil,
              finishingGeneration == nil else { throw VideoBitRateUpdateError.sessionInvalidated }
        guard videoInputIsRaw else { throw VideoBitRateUpdateError.notEncoding }
        _ = try outgoing.setVerifiedVideoBitRate(bitRate)
        guard let change = outgoing.lastVideoBitRateChange else { throw VideoBitRateUpdateError.sessionInvalidated }
        return .init(publishingGeneration: expected, change: change)
    }
    public enum VideoReplacementError: Swift.Error, Equatable, Sendable {
        case notEncoding, busy, invalidSettings, interrupted, deadline, invalidOutput
    }
    /// Pre-mux new-session evidence, not receiver delivery or achieved bitrate.
    public struct VideoReplacementReceipt: Sendable {
        public let publishingGeneration: UInt64
        public let encoderSessionID: UUID
        public let previousEncoderSessionID: UUID
        public let lastOldSourcePTS: CMTime
        public let firstNewSourcePTS: CMTime
        public let width: Int32
        public let height: Int32
        public let rawVideoFramesDropped: UInt64
    }
    /// Replaces a running raw H.264 encoder while audio and compressed consumers
    /// continue. Newest-frame raw buffering remains bounded; evictions are counted.
    /// Success requires a sync sample at the requested dimensions from the current
    /// new encoder. Cancellation/deadline/finish abort the change and join its native
    /// drain. A deadline requests invalidation; a wedged native call can delay join.
    public func replaceVideoSettings(_ settings: VideoCodecSettings,
        publishingGeneration expected: UInt64, timeout: Duration = .seconds(2)) async throws -> VideoReplacementReceipt {
        try Task.checkCancellation()
        guard videoReplacement == nil, videoMutation == nil, closeTask == nil, finishingGeneration == nil else {
            throw VideoReplacementError.busy
        }
        guard publishingGeneration == expected, videoInputIsRaw else { throw VideoReplacementError.notEncoding }
        let dimensions: [CGFloat] = [settings.videoSize.width, settings.videoSize.height]
        let validDimensions = dimensions.allSatisfy { value in
            guard value.isFinite, value >= 16, value <= 8192, value.rounded() == value else { return false }
            return Int(value) % 2 == 0
        }
        guard settings.format == .h264, settings.allowFrameReordering == false,
              validDimensions, settings.bitRate > 0 else { throw VideoReplacementError.invalidSettings }
        let mutation = reserveVideoMutation()
        defer { releaseVideoMutation(mutation) }
        invalidateProbeConfiguration()
        if let submission = videoSubmission { await commitVideoSubmission(submission) }
        try Task.checkCancellation()
        guard videoMutation == mutation, publishingGeneration == expected, closeTask == nil,
              finishingGeneration == nil, let previous = outgoing.lastVideoSubmission else {
            throw VideoReplacementError.interrupted
        }
        guard videoInputIsRaw else { throw VideoReplacementError.notEncoding }
        let operation = try outgoing.prepareVideoReplacement(settings)
        let state = VideoReplacement(generation: expected, operation: operation, settings: settings,
            oldPTS: previous.sourcePTS, dropped: outgoing.rawVideoFramesDropped)
        videoReplacement = state
        releaseVideoMutation(mutation) // Replacement now owns raw admission until its old drain commits.
        let task = Task { try await runVideoReplacement(state, timeout: timeout) }
        state.task = task
        let operationID = state.id
        return try await withTaskCancellationHandler {
            let receipt = try await task.value
            return try await acceptVideoReplacementReceipt(receipt)
        } onCancel: {
            Task { await self.abortVideoReplacement(id: operationID, error: .interrupted) }
        }
    }

    /// The owning task has joined. Recheck caller-side ownership at this final boundary.
    func acceptVideoReplacementReceipt(_ receipt: VideoReplacementReceipt) async throws -> VideoReplacementReceipt {
        if Task.isCancelled {
            if generation == receipt.publishingGeneration {
                failure.fail(.outputTerminated(boundary: "SRT video replacement cancelled return"))
                await close()
            }
            throw CancellationError()
        }
        guard publishingGeneration == receipt.publishingGeneration,
              outgoing.lastVideoSubmission?.sessionID == receipt.encoderSessionID else { throw VideoReplacementError.interrupted }
        return receipt
    }

    /// Only accessed on this stream actor. One raw consumer and one caller wait;
    /// no unbounded continuation list or extra retained media queue is introduced.
    private final class VideoReplacement {
        let id = UUID()
        let generation: UInt64
        let operation: VideoEncoderReplacement
        let settings: VideoCodecSettings
        let oldPTS: CMTime
        let dropped: UInt64
        let drain: Task<Void, Never>
        var task: Task<VideoReplacementReceipt, Swift.Error>?
        var committed = false
        var first: (sessionID: UUID, sourcePTS: CMTime)?
        var input: CheckedContinuation<Void, Never>?
        var output: CheckedContinuation<VideoReplacementReceipt, Swift.Error>?
        var error: VideoReplacementError?
        init(generation: UInt64, operation: VideoEncoderReplacement, settings: VideoCodecSettings,
             oldPTS: CMTime, dropped: UInt64) {
            self.generation = generation; self.operation = operation; self.settings = settings
            self.oldPTS = oldPTS; self.dropped = dropped
            drain = Task.detached(priority: .utility) { operation.drain() }
        }
        func interrupt(_ error: VideoReplacementError) {
            self.error = self.error ?? error
            input?.resume(); input = nil
            output?.resume(throwing: self.error!); output = nil
        }
    }
    private var videoReplacement: VideoReplacement?

    private func runVideoReplacement(_ state: VideoReplacement, timeout: Duration) async throws -> VideoReplacementReceipt {
        let deadline = Task {
            do { try await Task.sleep(for: max(.zero, timeout)) } catch { return }
            await abortVideoReplacement(id: state.id, error: .deadline)
        }
        let result: Result<VideoReplacementReceipt, Swift.Error>
        do {
            await state.drain.value
            guard state.error == nil, publishingGeneration == state.generation else {
                throw state.error ?? VideoReplacementError.interrupted
            }
            try outgoing.commitVideoReplacement(state.operation)
            state.committed = true
            state.input?.resume(); state.input = nil
            let receipt: VideoReplacementReceipt = try await withCheckedThrowingContinuation { state.output = $0 }
            result = .success(receipt)
        } catch {
            if generation == state.generation {
                failure.fail(.outputTerminated(boundary: "SRT video replacement"))
                await close()
            }
            result = .failure(error)
        }
        deadline.cancel(); await deadline.value
        // Close can interleave with deadline join. It cannot resurrect a receipt.
        if videoReplacement === state { videoReplacement = nil }
        if let error = state.error { throw error }
        guard publishingGeneration == state.generation else { throw VideoReplacementError.interrupted }
        return try result.get()
    }

    private func abortVideoReplacement(id: UUID, error: VideoReplacementError) async {
        guard let state = videoReplacement, state.id == id else { return }
        state.interrupt(error)
        guard generation == state.generation else { return }
        failure.fail(.outputTerminated(boundary: "SRT video replacement \(error)"))
        await close()
    }

    /// Actor-owned record; the native worker never calls back into this owner.
    private final class VideoSubmissionState {
        let generation: UInt64
        let operation: VideoSubmission
        let task: Task<Bool, Never>
        var committed = false
        init(generation: UInt64, operation: VideoSubmission) {
            self.generation = generation; self.operation = operation
            task = Task.detached { operation.run() }
        }
    }
    private var videoSubmission: VideoSubmissionState?
    var rawVideoFramesDropped: UInt64 { outgoing.rawVideoFramesDropped }
    var isVideoMutationPending: Bool { videoMutation != nil }
    private var videoMutation: UUID?
    private var videoMutationInput: CheckedContinuation<Void, Never>?
    private func reserveVideoMutation() -> UUID {
        let id = UUID(); videoMutation = id; return id
    }
    private func releaseVideoMutation(_ id: UUID) {
        guard videoMutation == id else { return }
        videoMutation = nil
        videoMutationInput?.resume(); videoMutationInput = nil
    }
    private func commitVideoSubmission(_ state: VideoSubmissionState) async {
        let succeeded = await state.task.value
        guard !state.committed else { return }
        state.committed = true
        guard generation == state.generation, videoSubmission === state else { return }
        videoSubmission = nil
        guard outgoing.commitVideoSubmission(state.operation, succeeded: succeeded) else { return }
        if let replacement = videoReplacement, replacement.committed, replacement.first == nil,
           let submitted = outgoing.lastVideoSubmission, submitted.sessionID != replacement.operation.revision {
            replacement.first = submitted
        }
    }

    private func consumeVideoInput(_ buffer: CMSampleBuffer, generation session: UInt64) async {
        while generation == session, !Task.isCancelled, failure.error == nil {
            if videoMutation != nil {
                await withCheckedContinuation { videoMutationInput = $0 }
            } else if let state = videoReplacement, !state.committed, state.error == nil {
                await withCheckedContinuation { state.input = $0 }
            } else { break }
        }
        guard generation == session, !Task.isCancelled, failure.error == nil,
              let operation = outgoing.prepareVideoSubmission(buffer) else { return }
        let state = VideoSubmissionState(generation: session, operation: operation)
        videoSubmission = state
        await commitVideoSubmission(state)
    }

    private func observeVideoReplacement(_ sample: CMSampleBuffer, wasEncoded: Bool) {
        guard let state = videoReplacement, state.committed, state.output != nil, let first = state.first,
              CMTimeCompare(sample.presentationTimeStamp, state.oldPTS) > 0 else { return }
        let frame = CompressedVideoFrame(sampleBuffer: sample, generation: generation, wasEncoded: wasEncoded)
        let valid = outgoing.lastVideoSubmission?.sessionID == first.sessionID &&
            frame.valid && wasEncoded && frame.codec == kCMVideoCodecType_H264 &&
            frame.width == Int32(state.settings.videoSize.width) && frame.height == Int32(state.settings.videoSize.height) &&
            CMTimeCompare(frame.sourcePTS, first.sourcePTS) == 0 && !sample.isNotSync
        guard valid else {
            state.interrupt(.invalidOutput)
            failure.fail(.outputTerminated(boundary: "SRT video replacement output"))
            return
        }
        let receipt = VideoReplacementReceipt(publishingGeneration: state.generation,
            encoderSessionID: first.sessionID, previousEncoderSessionID: state.operation.revision,
            lastOldSourcePTS: state.oldPTS, firstNewSourcePTS: first.sourcePTS,
            width: frame.width, height: frame.height,
            rawVideoFramesDropped: outgoing.rawVideoFramesDropped &- state.dropped)
        state.output?.resume(returning: receipt); state.output = nil
    }

    private struct PublishingTasks {
        let video, audio, input, transport, errors: Task<Void, Never>
        var all: [Task<Void, Never>] { [video, audio, input, transport, errors] }
    }
    private var publishingTasks: PublishingTasks?
    // close cannot join a worker that may be closing us through connection.send.
    // Re-publication owns that join before it can reuse the connection.
    private var retiredTransport: Task<Void, Never>?
    private var finishingGeneration: UInt64?
    private var finishTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    /// The expected medias for transport stream.
    public var expectedMedias: Set<AVMediaType> {
        writer.expectedMedias
    }

    @Published public private(set) var readyState: StreamReadyState = .idle
    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max
    package var outputs: [any StreamOutput] = []
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private lazy var writer = TSWriter()
    private lazy var reader = TSReader()
    package lazy var incoming = IncomingStream(self)
    package let outgoing: OutgoingStream
    private weak var connection: SRTConnection?

    /// The error domain codes.
    public enum Error: Swift.Error {
        // An unsupported codec.
        case unsupportedCodec
    }

    /// Creates a new stream object.
    /// - Parameter muxedPacketObserver: Synchronous scalar PES output admission,
    ///   including buffered startup and final drain. Must do bounded work without
    ///   I/O, waits, task creation or stream reentry. Nil avoids frame construction.
    /// - Parameter compressedAudioObserver: Synchronous copied AAC observation
    ///   after mux acceptance, including final drain. The callback must remain
    ///   bounded and perform no I/O, waits or task creation. Nil avoids snapshots.
    /// - Parameter encoderCompletionObserver: Immutable, synchronous native encoder
    ///   notification for this stream, including final drain. Compressed passthrough
    ///   does not notify. The callback must remain bounded and perform no I/O or waits.
    public init(connection: SRTConnection, encoderCompletionObserver: VideoEncoderCompletionObserver? = nil,
                encoderConfigurationObserver: VideoEncoderConfigurationObserver? = nil,
                compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)? = nil,
                compressedAudioObserver: (@Sendable (CompressedAudioFrame) -> Void)? = nil,
                muxedPacketObserver: (@Sendable (MuxedPacketFrame) -> Void)? = nil,
                pacesEncodedVideo: Bool = false, allowsBandwidthProbes: Bool = false,
                transportSendObserver: (@Sendable (TransportSendObservation) -> Void)? = nil,
                encoderSubmissionObserver: VideoEncoderSubmissionObserver? = nil) {
        self.transportSendObserver = transportSendObserver
        self.allowsBandwidthProbes = allowsBandwidthProbes
        probeWakeRunner = { probe, accounting in
            await SRTProbeWakeSchedule.run(probe: probe, wake: { accounting.wake() })
        }
        self.pacesEncodedVideo = pacesEncodedVideo
        pacingSleep = { try await Task.sleep(for: .seconds($0)) }
        outgoing = OutgoingStream(encoderCompletionObserver: encoderCompletionObserver,
                                  encoderConfigurationObserver: encoderConfigurationObserver,
                                  encoderSubmissionObserver: encoderSubmissionObserver)
        self.connection = connection
        self.compressedVideoObserver = compressedVideoObserver
        self.compressedAudioObserver = compressedAudioObserver
        self.muxedPacketObserver = muxedPacketObserver
        Task { await connection.addStream(self) }
    }

    init(connection: SRTConnection, outgoing: sending OutgoingStream,
         compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)? = nil,
         compressedAudioObserver: (@Sendable (CompressedAudioFrame) -> Void)? = nil,
         muxedPacketObserver: (@Sendable (MuxedPacketFrame) -> Void)? = nil,
         transportSendObserver: (@Sendable (TransportSendObservation) -> Void)? = nil,
         pacesEncodedVideo: Bool = false,
         allowsBandwidthProbes: Bool = false,
         probeWakeRunner: @escaping @Sendable (SRTBandwidthProbe, TransportOutputAccounting) async -> Void = { probe, accounting in
             await SRTProbeWakeSchedule.run(probe: probe, wake: { accounting.wake() })
         },
         pacingSleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transportSendObserver = transportSendObserver
        self.allowsBandwidthProbes = allowsBandwidthProbes
        self.probeWakeRunner = probeWakeRunner
        self.pacesEncodedVideo = pacesEncodedVideo; self.pacingSleep = pacingSleep
        self.outgoing = outgoing; self.connection = connection
        self.compressedVideoObserver = compressedVideoObserver
        self.compressedAudioObserver = compressedAudioObserver
        self.muxedPacketObserver = muxedPacketObserver
        Task { await connection.addStream(self) }
    }

    deinit {
        outputs.removeAll()
    }

    /// Sends streaming audio and video from client.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func publish(_ name: String? = "") async {
        let requestGeneration = generation
        guard let connection, await connection.publishingSession() != nil,
              generation == requestGeneration else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .publishing:
                await close()
            default:
                break
            }
            return
        }
        if let retiredTransport {
            await retiredTransport.value
            guard generation == requestGeneration else { return }
            self.retiredTransport = nil
        }
        guard readyState == .idle, closeTask == nil, finishingGeneration == nil, videoReplacement == nil, !probeStarting else { return }
        guard let connectionSession = await connection.publishingSession(),
              generation == requestGeneration, readyState == .idle, closeTask == nil,
              finishingGeneration == nil, videoReplacement == nil, !probeStarting else { return }
        generation &+= 1
        sourceCadenceClock = SourceCadenceClock()
        bandwidthProbe = nil
        videoInputIsRaw = false
        let session = generation
        failure = PublishingFailureLatch()
        writer.failure = failure
        if let observer = muxedPacketObserver {
            // Capture only the immutable callback and generation, never this actor.
            writer.muxedPacketObserver = { frame in
                observer(.init(publishingGeneration: session, media: frame.media,
                    sourcePTS: frame.sourcePTS, sourceDTS: frame.sourceDTS,
                    transportPTS: frame.transportPTS, transportDTS: frame.transportDTS,
                    observedAt: frame.observedAt))
            }
        }
        outgoing.setPublishingFailure(failure)
        // Raw video may skip stale frames before compression; compressed queues fail.
        if outgoing.videoInputBufferCounts <= 0 { outgoing.videoInputBufferCounts = 2 }
        // Install continuations before publishing becomes observable or accepting input.
        if pacesEncodedVideo, !outgoing.enablePacedVideoOutput() {
            failure.fail(.outputTerminated(boundary: "SRT pacing setup")); return
        }
        let videoOutput = outgoing.videoOutputStream
        let audioOutput = outgoing.audioOutputStream
        let videoInput = outgoing.videoInputStream
        let transportOutput = writer.output
        let transportAccounting = writer.outputAccounting
        outgoing.startRunning()
        readyState = .publishing
        if outgoing.videoInputFormat != nil {
            writer.expectedMedias.insert(.video)
        }
        if outgoing.audioInputFormat != nil {
            writer.expectedMedias.insert(.audio)
        }
        if writer.expectedMedias.isEmpty {
            logger.error("Please set expected media.")
        }
        publishingTasks = PublishingTasks(
            video: Task {
                for await buffer in videoOutput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    let dequeuedAt = ProcessInfo.processInfo.systemUptime
                    // A native callback may yield before convert returns. Join one
                    // snapshot, never chase later submissions; audio stays independent.
                    if let submission = videoSubmission { await commitVideoSubmission(submission) }
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    if pacesEncodedVideo {
                        do {
                            let delay = try sourceCadenceClock.delay(sourcePTS: buffer.presentationTimeStamp, now: ProcessInfo.processInfo.systemUptime)
                            if delay > 0 { try await pacingSleep(delay) }
                        } catch {
                            if generation == session, !Task.isCancelled {
                                failure.fail(.outputTerminated(boundary: "SRT source cadence pacing"))
                            }
                            return
                        }
                    }
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    appendCompressedVideo(buffer, wasEncoded: true, dequeuedAt: dequeuedAt)
                }
            },
            audio: Task {
                for await buffer in audioOutput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    appendCompressedAudio(buffer.0, when: buffer.1, wasEncoded: true)
                }
            },
            input: Task {
                for await buffer in videoInput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    await consumeVideoInput(buffer, generation: session)
                }
            },
            transport: Task.detached { [failure, transportSendObserver] in
                await SRTTransportPump.run(output: transportOutput, accounting: transportAccounting,
                    failure: failure, connection: connection, connectionSession: connectionSession,
                    publishingGeneration: session, observer: transportSendObserver)
            },
            errors: Task { [failure] in
                for await error in failure.events {
                    guard generation == session, !Task.isCancelled else { return }
                    await connection.failPublishing(error, generation: connectionSession)
                    return
                }
            }
        )
    }

    /// Playback streaming audio and video from server.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func play(_ name: String? = "") async {
        guard let connection, await connection.connected else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .playing:
                await close()
            default:
                break
            }
            return
        }
        await connection.recv()
        Task {
            await incoming.startRunning()
            for await buffer in reader.output {
                await incoming.append(buffer.1)
            }
        }
        readyState = .playing
    }

    /// Stops ingress and drains accepted publishing media through the codec,
    /// muxer and socket. Success means transport acceptance, not remote delivery.
    /// One owned deadline aborts a stalled drain; all finish callers join the same
    /// operation. Failure is latched in publishingError. Close revokes admission
    /// immediately, but may await native conversion before invalidating its session.
    /// Publication cannot restart until this operation has joined.
    public func finish(timeout: Duration = .seconds(2)) async {
        bandwidthProbe?.cancel(.finished)
        probeWakeTask?.cancel()
        if let state = videoReplacement {
            await abortVideoReplacement(id: state.id, error: .interrupted)
            _ = await state.task?.result
            return // A newer publication may start once the replacement owner joins.
        }
        if let finishTask { await finishTask.value; return }
        if let closeTask { await closeTask.value; return }
        guard readyState == .publishing, let tasks = publishingTasks else { return }
        let session = generation
        finishingGeneration = session
        outgoing.finishInput()
        let pending = Task {
            await drainPublishing(tasks, generation: session, timeout: timeout)
            // Every joining caller must observe a reusable stream at completion;
            // cleanup cannot depend on the original caller being rescheduled.
            if finishingGeneration == session {
                finishTask = nil
                finishingGeneration = nil
            }
        }
        finishTask = pending
        await pending.value
    }

    private func drainPublishing(_ tasks: PublishingTasks, generation session: UInt64, timeout: Duration) async {
        let deadline = Task {
            do { try await Task.sleep(for: max(.zero, timeout)) } catch { return }
            guard generation == session else { return }
            failure.fail(.outputTerminated(boundary: "SRT finish deadline"))
            await close()
        }
        await probeWakeTask?.value
        await tasks.input.value
        if generation == session, publishingError == nil {
            let completion = outgoing.makeVideoCompletion()
            // VideoToolbox completion can synchronously wait for callbacks. Let
            // the stream actor consume those callbacks within its bounded queue.
            await Task.detached(priority: .utility) { completion() }.value
        }
        await tasks.video.value
        await tasks.audio.value
        if generation == session, publishingError == nil { writer.finishOutput() }
        else { tasks.transport.cancel() }
        await tasks.transport.value
        if generation == session { await close() }
        deadline.cancel()
        await deadline.value
        await tasks.errors.value
    }

    /// Stops playing or publishing and makes available other uses.
    public func close() async {
        if let closeTask { await closeTask.value; return }
        bandwidthProbe?.cancel(.closed)
        let wakeTask = probeWakeTask
        wakeTask?.cancel()
        probeWakeTask = nil
        videoReplacement?.interrupt(.interrupted)
        generation &+= 1
        sourceCadenceClock = SourceCadenceClock()
        videoInputIsRaw = false
        let submission = videoSubmission
        videoSubmission = nil
        if let mutation = videoMutation { releaseVideoMutation(mutation) }
        for task in publishingTasks?.all ?? [] { task.cancel() }
        if let transport = publishingTasks?.transport { retiredTransport = transport }
        publishingTasks = nil
        outgoing.finishInput()
        failure.finish()
        writer.clear()
        reader.clear()
        readyState = .idle
        let closing = Task {
            // Only the independent call is joined. Consumers may themselves be
            // closing us, and session invalidation must not race conversion.
            _ = await submission?.task.value
            outgoing.stopRunning()
            await wakeTask?.value
            await incoming.stopRunning()
            // Clear inside the shared owner so every caller sees reusable state.
            closeTask = nil
        }
        closeTask = closing
        await closing.value
    }

    /// Sets the expected media.
    ///
    /// This sets whether the stream contains audio only, video only, or both. Normally, this is automatically set through the append method.
    /// If you cannot call the append method before publishing, please use this method to explicitly specify the contents of the stream.
    public func setExpectedMedias(_ expectedMedias: Set<AVMediaType>) {
        writer.expectedMedias = expectedMedias
    }

    func doInput(_ data: Data) {
        _ = reader.read(data)
    }
}

extension SRTStream: _Stream {
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        invalidateProbeConfiguration()
        outgoing.audioSettings = audioSettings
    }

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) async throws {
        try Task.checkCancellation()
        guard videoReplacement == nil, videoMutation == nil, closeTask == nil, finishingGeneration == nil else {
            throw VideoReplacementError.busy
        }
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        let expected = generation, mutation = reserveVideoMutation()
        defer { releaseVideoMutation(mutation) }
        invalidateProbeConfiguration()
        if let submission = videoSubmission { await commitVideoSubmission(submission) }
        try Task.checkCancellation()
        guard generation == expected, videoMutation == mutation, closeTask == nil, finishingGeneration == nil else {
            throw VideoReplacementError.interrupted
        }
        outgoing.videoSettings = videoSettings
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        guard publishingError == nil, finishingGeneration == nil else { return }
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                if let state = videoReplacement {
                    state.interrupt(.invalidOutput)
                    failure.fail(.outputTerminated(boundary: "SRT video replacement passthrough"))
                    return
                }
                videoInputIsRaw = false
                appendCompressedVideo(sampleBuffer, wasEncoded: false)
            } else {
                videoInputIsRaw = true
                outgoing.append(sampleBuffer)
                outputs.forEach { $0.stream(self, didOutput: sampleBuffer) }
            }
        default:
            break
        }
    }

    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard publishingError == nil, finishingGeneration == nil else { return }
        switch audioBuffer {
        case let audioBuffer as AVAudioPCMBuffer:
            outgoing.append(audioBuffer, when: when)
            outputs.forEach { $0.stream(self, didOutput: audioBuffer, when: when) }
        case let audioBuffer as AVAudioCompressedBuffer:
            appendCompressedAudio(audioBuffer, when: when, wasEncoded: false)
        default:
            break
        }
    }

    private func appendCompressedVideo(_ sampleBuffer: CMSampleBuffer, wasEncoded: Bool,
                                       dequeuedAt: Double = ProcessInfo.processInfo.systemUptime) {
        guard readyState == .publishing, publishingError == nil else { return }
        observeVideoReplacement(sampleBuffer, wasEncoded: wasEncoded)
        guard publishingError == nil else { return }
        compressedVideoObserver?(.init(sampleBuffer: sampleBuffer, generation: generation, wasEncoded: wasEncoded, dequeuedAt: dequeuedAt,
                                      sourceCadencePaced: wasEncoded && pacesEncodedVideo))
        writer.videoFormat = sampleBuffer.formatDescription
        writer.append(sampleBuffer)
    }

    private func appendCompressedAudio(_ audioBuffer: AVAudioBuffer, when: AVAudioTime, wasEncoded: Bool) {
        guard readyState == .publishing, publishingError == nil,
              let audioBuffer = audioBuffer as? AVAudioCompressedBuffer else { return }
        writer.audioFormat = audioBuffer.format
        writer.append(audioBuffer, when: when)
        guard writer.error == nil, publishingError == nil, let compressedAudioObserver else { return }
        compressedAudioObserver(.init(buffer: audioBuffer, when: when, generation: generation, wasEncoded: wasEncoded))
    }

    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension SRTStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { await append(sampleBuffer) }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        Task { await append(buffer, when: when) }
    }
}

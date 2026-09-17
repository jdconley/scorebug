@preconcurrency import AVFoundation
import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a one-way channel over a SRTConnection.
public actor SRTStream {
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
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
                                    staged: Bool = false) async throws -> SRTBandwidthProbeSnapshot {
        try Task.checkCancellation()
        guard allowsBandwidthProbes else { throw SRTBandwidthProbeError.disabled }
        let maximumBitRate = staged ? 12_000_000 : 2_000_000
        guard (1...maximumBitRate).contains(bitRate) else { throw SRTBandwidthProbeError.invalidConfiguration }
        guard publishingGeneration == expected, writer.transportClock != nil, videoReplacement == nil,
              let connection else { throw SRTBandwidthProbeError.notPublishing }
        guard bandwidthProbe == nil, !probeStarting else { throw SRTBandwidthProbeError.alreadyStarted }
        probeStarting = true
        let configuration = probeConfigurationRevision
        defer { probeStarting = false }
        let statistics = await connection.samplePerformanceData()
        try Task.checkCancellation()
        guard publishingGeneration == expected, videoReplacement == nil,
              probeConfigurationRevision == configuration else { throw SRTBandwidthProbeError.obsolete }
        guard let statistics else { throw SRTBandwidthProbeError.unavailableStatistics }
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: bitRate, generation: expected, statistics: statistics, at: at,
            stage: staged ? 1 : nil, campaignStartedAt: staged ? at : nil)
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
        guard publishingGeneration == expected, writer.transportClock != nil, videoReplacement == nil,
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
        guard publishingGeneration == expected, bandwidthProbe === previous, videoReplacement == nil,
              probeConfigurationRevision == configuration else { throw SRTBandwidthProbeError.obsolete }
        let retired = previous.snapshot(now: { ProcessInfo.processInfo.systemUptime })
        guard let origin = retired.campaignStartedAt, let accepted = retired.totalAcceptedPayloadBytes else {
            throw SRTBandwidthProbeError.invalidConfiguration
        }
        let statistics = await connection.samplePerformanceData()
        try Task.checkCancellation()
        guard publishingGeneration == expected, bandwidthProbe === previous, videoReplacement == nil,
              probeConfigurationRevision == configuration else { throw SRTBandwidthProbeError.obsolete }
        guard let statistics else { throw SRTBandwidthProbeError.unavailableStatistics }
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: bitRate, generation: expected, statistics: statistics, at: at,
            stage: stage + 1, campaignStartedAt: origin, previouslyAcceptedPayloadBytes: accepted)
        return installBandwidthProbe(probe, at: at)
    }

    private func installBandwidthProbe(_ probe: SRTBandwidthProbe, at: Double) -> SRTBandwidthProbeSnapshot {
        bandwidthProbe = probe
        let accounting = writer.outputAccounting
        probeWakeTask = Task {
            await probeWakeRunner(probe, accounting)
        }
        return probe.snapshot(now: { at })
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
    public func setVerifiedVideoBitRate(_ bitRate: Int, publishingGeneration expected: UInt64) throws -> VideoCodecSettings {
        try setVerifiedVideoBitRateWithReceipt(bitRate, publishingGeneration: expected).change.settings
    }
    public struct VideoBitRateReceipt: Sendable {
        public let publishingGeneration: UInt64
        public let change: VideoBitRateChange
    }
    public func setVerifiedVideoBitRateWithReceipt(_ bitRate: Int, publishingGeneration expected: UInt64) throws -> VideoBitRateReceipt {
        try Task.checkCancellation()
        guard publishingGeneration == expected, videoInputIsRaw else { throw VideoBitRateUpdateError.notEncoding }
        guard videoReplacement == nil else { throw VideoBitRateUpdateError.sessionInvalidated }
        invalidateProbeConfiguration()
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
        guard videoReplacement == nil else { throw VideoReplacementError.busy }
        guard publishingGeneration == expected, videoInputIsRaw,
              let previous = outgoing.lastVideoSubmission else { throw VideoReplacementError.notEncoding }
        let dimensions: [CGFloat] = [settings.videoSize.width, settings.videoSize.height]
        let validDimensions = dimensions.allSatisfy { value in
            guard value.isFinite, value >= 16, value <= 8192, value.rounded() == value else { return false }
            return Int(value) % 2 == 0
        }
        guard settings.format == .h264, settings.allowFrameReordering == false,
              validDimensions, settings.bitRate > 0 else { throw VideoReplacementError.invalidSettings }
        invalidateProbeConfiguration()
        let operation = try outgoing.prepareVideoReplacement(settings)
        let state = VideoReplacement(generation: expected, operation: operation, settings: settings,
            oldPTS: previous.sourcePTS, dropped: outgoing.rawVideoFramesDropped)
        videoReplacement = state
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

    private func consumeVideoInput(_ buffer: CMSampleBuffer, generation session: UInt64) async {
        if let state = videoReplacement, !state.committed, state.error == nil {
            await withCheckedContinuation { state.input = $0 }
        }
        guard generation == session, !Task.isCancelled, failure.error == nil else { return }
        outgoing.append(video: buffer)
        if let state = videoReplacement, state.committed, state.first == nil,
           let submitted = outgoing.lastVideoSubmission,
           submitted.sessionID != state.operation.revision,
           CMTimeCompare(submitted.sourcePTS, buffer.presentationTimeStamp) == 0 {
            state.first = submitted
        }
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
                pacesEncodedVideo: Bool = false, allowsBandwidthProbes: Bool = false) {
        self.allowsBandwidthProbes = allowsBandwidthProbes
        probeWakeRunner = { probe, accounting in
            await SRTProbeWakeSchedule.run(probe: probe, wake: { accounting.wake() })
        }
        self.pacesEncodedVideo = pacesEncodedVideo
        pacingSleep = { try await Task.sleep(for: .seconds($0)) }
        outgoing = OutgoingStream(encoderCompletionObserver: encoderCompletionObserver,
                                  encoderConfigurationObserver: encoderConfigurationObserver)
        self.connection = connection
        self.compressedVideoObserver = compressedVideoObserver
        self.compressedAudioObserver = compressedAudioObserver
        Task { await connection.addStream(self) }
    }

    init(connection: SRTConnection, outgoing: sending OutgoingStream,
         compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)? = nil,
         compressedAudioObserver: (@Sendable (CompressedAudioFrame) -> Void)? = nil,
         pacesEncodedVideo: Bool = false,
         allowsBandwidthProbes: Bool = false,
         probeWakeRunner: @escaping @Sendable (SRTBandwidthProbe, TransportOutputAccounting) async -> Void = { probe, accounting in
             await SRTProbeWakeSchedule.run(probe: probe, wake: { accounting.wake() })
         },
         pacingSleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.allowsBandwidthProbes = allowsBandwidthProbes
        self.probeWakeRunner = probeWakeRunner
        self.pacesEncodedVideo = pacesEncodedVideo; self.pacingSleep = pacingSleep
        self.outgoing = outgoing; self.connection = connection
        self.compressedVideoObserver = compressedVideoObserver
        self.compressedAudioObserver = compressedAudioObserver
        Task { await connection.addStream(self) }
    }

    deinit {
        outputs.removeAll()
    }

    /// Sends streaming audio and video from client.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func publish(_ name: String? = "") async {
        guard let connection, let connectionSession = await connection.publishingSession() else {
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
        guard readyState == .idle, closeTask == nil, finishingGeneration == nil, videoReplacement == nil, !probeStarting else { return }
        generation &+= 1
        sourceCadenceClock = SourceCadenceClock()
        bandwidthProbe = nil
        videoInputIsRaw = false
        let session = generation
        failure = PublishingFailureLatch()
        writer.failure = failure
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
                    if pacesEncodedVideo {
                        do {
                            let delay = try sourceCadenceClock.delay(sourcePTS: buffer.presentationTimeStamp, now: dequeuedAt)
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
            transport: Task {
                var iterator = transportOutput.makeAsyncIterator()
                for await _ in transportAccounting.wakes {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    // Exactly one consumer owns all media and optional sends.
                    // A wake may coalesce freely; data stays in the bounded queue.
                    while transportAccounting.pending > 0 {
                        guard let data = await iterator.next() else { return }
                        guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                        writer.didDequeueOutput()
                        await connection.send(data, generation: connectionSession)
                        guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    }
                    if publishingGeneration == session, let probe = bandwidthProbe {
                        await connection.sendPadding(probe, pendingMedia: transportAccounting, generation: connectionSession)
                    }
                }
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
    /// operation. Failure is latched in publishingError. close() remains immediate
    /// abort, and publication cannot restart until this operation has joined.
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
        for task in publishingTasks?.all ?? [] { task.cancel() }
        publishingTasks = nil
        outgoing.stopRunning()
        failure.finish()
        writer.clear()
        reader.clear()
        readyState = .idle
        let closing = Task {
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

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard videoReplacement == nil else { throw VideoReplacementError.busy }
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        invalidateProbeConfiguration()
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

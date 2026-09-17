@preconcurrency import AVFoundation
import VideoToolbox
import HaishinKit
import SRTHaishinKit
import ScorebugMedia

/// SRT encoding/transport adapter shared by the app and local qualification tools.
/// Its caller owns bounded raw-media admission and lifecycle serialization.
/// Construct a fresh adapter for every publishing attempt.
public actor SRTPublisher {
    public typealias CompressedAudioFrame = SRTStream.CompressedAudioFrame
    public typealias CompressedVideoFrame = SRTStream.CompressedVideoFrame
    public let videoCost: PublishingVideoCostOwner?
    private nonisolated let startupEvidence: PublishingVideoStartupOwner
    /// Historical evidence remains available after the terminal drain. Session
    /// admission separately requires this same publisher to still be running.
    public nonisolated var videoStartup: PublishingVideoStartup? { startupEvidence.snapshot.receipt }
    private let videoProfile: PublishingVideoProfile
    public struct EncoderConfiguration: Equatable, Sendable {
        public let id: UUID
        public let encoderSessionID: UUID
        public let bitRate: Int
        fileprivate init(_ value: VideoEncoderConfiguration) {
            id = value.id; encoderSessionID = value.encoderSessionID; bitRate = value.bitRate
        }
    }
    public struct EncoderFrame: Sendable {
        public let sourcePTS: CMTime
        public let outputPTS: CMTime
        public let encoderSessionID: UUID
        public let configuration: EncoderConfiguration?
        public let submittedAt: Double
        public let completedAt: Double
        fileprivate init(_ value: VideoEncoderFrame) {
            sourcePTS = value.sourcePTS; outputPTS = value.outputPTS; encoderSessionID = value.encoderSessionID
            configuration = value.configuration.map(EncoderConfiguration.init)
            submittedAt = value.submittedAt; completedAt = value.completedAt
        }
    }
    public typealias BitRateChangeReceipt = PublishingBitRateChange
    public enum PublisherError: Error { case notPublishing, mutationInProgress }
    private let connection = SRTConnection()
    private let stream: SRTStream
    private let stopPolicy: SRTStopPolicy
    private var activeGeneration: UInt64?
    private var stopping = false
    private var configuring = false
    private var probeOperation: Task<PublishingBandwidthProbeSnapshot, Error>?
    private var probeIdentity: PublishingBandwidthProbeSnapshot?
    private var probeRevision: UInt64 = 0
    private var encoderUpdating = false
    private var profileChange: Task<PublishingVideoProfileChange, Error>?
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?
    public private(set) var lastStopOutcome: SRTStopPolicy.Outcome?
    public init(stopPolicy: SRTStopPolicy = .init(), observations: VideoFrameObservationOwner? = nil,
                encoderConfigurationObserver: (@Sendable (EncoderFrame) -> Void)? = nil,
                videoProfile: PublishingVideoProfile = .hd1080,
                compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)? = nil,
                compressedAudioObserver: (@Sendable (CompressedAudioFrame) -> Void)? = nil,
                pacesEncodedVideo: Bool = false, allowsBandwidthProbes: Bool = false,
                videoCost: PublishingVideoCostOwner? = nil) {
        let startupEvidence = PublishingVideoStartupOwner(profile: videoProfile)
        self.startupEvidence = startupEvidence
        let cost = videoCost ?? observations.map { PublishingVideoCostOwner(scope: $0.snapshot.scope) }
        self.videoCost = cost
        self.stopPolicy = stopPolicy
        self.videoProfile = videoProfile
        // Immutable ownership prevents late native completions from reaching a
        // later publishing attempt. Observe synchronously without retaining media.
        let configurationObserver: VideoEncoderConfigurationObserver?
        configurationObserver = { frame in
                startupEvidence.recordEncoding(sourcePTS: frame.sourcePTS, outputPTS: frame.outputPTS,
                    encoderSessionID: frame.encoderSessionID, submittedAt: frame.submittedAt, completedAt: frame.completedAt)
                let configuration = frame.configuration.flatMap {
                    VideoEncodingConfiguration(id: $0.id, encoderSessionID: $0.encoderSessionID, bitRate: $0.bitRate)
                }
                // A failed conversion of a present configuration must remain
                // missing evidence, never become an unverified native submission.
                let encoding: VideoEncodingObservation?
                if frame.configuration != nil && configuration == nil { encoding = nil }
                else {
                    encoding = .init(encoderSessionID: frame.encoderSessionID, configuration: configuration,
                                     submittedAt: frame.submittedAt, completedAt: frame.completedAt)
                }
                observations?.observe(.encodedVideo, sourcePTS: frame.sourcePTS, encoding: encoding)
                cost?.observeEncoding(EncoderFrame(frame))
                encoderConfigurationObserver?(EncoderFrame(frame))
            }
        stream = SRTStream(connection: connection, encoderConfigurationObserver: configurationObserver,
                           compressedVideoObserver: { frame in
                               startupEvidence.recordCompressed(sourcePTS: frame.sourcePTS, publishingGeneration: frame.publishingGeneration,
                                   width: Int(frame.width), height: Int(frame.height),
                                   valid: frame.valid && frame.wasEncoded && frame.codec == kCMVideoCodecType_H264,
                                   isSync: frame.isSync == true, dequeuedAt: frame.dequeuedAt)
                               cost?.observeCompressed(frame)
                               compressedVideoObserver?(frame)
                           }, compressedAudioObserver: compressedAudioObserver, pacesEncodedVideo: pacesEncodedVideo,
                           allowsBandwidthProbes: allowsBandwidthProbes)
    }
    public func configure() async throws {
        try Task.checkCancellation()
        guard !stopping, !configuring, startup == nil, activeGeneration == nil else { throw PublisherError.notPublishing }
        configuring = true
        defer { configuring = false }
        try await stream.setVideoSettings(videoProfile.settings)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: 128_000))
        await stream.setExpectedMedias([.video, .audio])
        await stream.setVideoInputBufferCounts(4)
        try Task.checkCancellation()
        guard !stopping else { throw PublisherError.notPublishing }
    }
    public func start(_ url: URL) async throws {
        try Task.checkCancellation()
        guard !stopping, !configuring, startup == nil, activeGeneration == nil else { throw PublisherError.notPublishing }
        let pending = Task { try await performStart(url) }
        startup = pending
        defer { startup = nil }
        try await withTaskCancellationHandler {
            do {
                try await pending.value
                try Task.checkCancellation()
                guard !stopping else { throw PublisherError.notPublishing }
            } catch {
                // The owned operation has terminated, so joining it cannot self-wait.
                await stop()
                throw error
            }
        } onCancel: {
            pending.cancel()
            Task { await self.stop() }
        }
    }
    private func performStart(_ url: URL) async throws {
        try Task.checkCancellation()
        guard !stopping else { throw PublisherError.notPublishing }
        try await connection.connect(url)
        try Task.checkCancellation()
        guard !stopping else { throw PublisherError.notPublishing }
        await stream.publish()
        guard await connection.connected, await stream.readyState == .publishing,
              await stream.muxerError == nil, await stream.publishingError == nil,
              await connection.publishingError == nil else {
            throw PublisherError.notPublishing
        }
        guard let generation = await stream.publishingGeneration, !stopping, !Task.isCancelled else {
            throw PublisherError.notPublishing
        }
        activeGeneration = generation
    }
    public func video(_ sample: CMSampleBuffer) async { await stream.append(sample) }
    public func audio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) async { await stream.append(buffer, when: when) }
    public func setBitRate(_ bitRate: Int) async throws {
        _ = try await setBitRateWithReceipt(bitRate)
    }
    public func setBitRateWithReceipt(_ bitRate: Int) async throws -> BitRateChangeReceipt {
        try Task.checkCancellation()
        guard !stopping, let generation = activeGeneration else { throw PublisherError.notPublishing }
        guard !encoderUpdating else { throw PublisherError.mutationInProgress }
        encoderUpdating = true
        await invalidateBandwidthProbe()
        defer { encoderUpdating = false }
        let healthy = await isPublishing()
        try Task.checkCancellation()
        guard healthy, !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
        let receipt = try await stream.setVerifiedVideoBitRateWithReceipt(bitRate, publishingGeneration: generation)
        guard !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
        if Task.isCancelled {
            // Native settings were committed; retire the abandoned live attempt.
            await stop()
            throw CancellationError()
        }
        guard let configuration = VideoEncodingConfiguration(id: receipt.change.configuration.id,
            encoderSessionID: receipt.change.configuration.encoderSessionID, bitRate: receipt.change.configuration.bitRate),
              let change = PublishingBitRateChange(publishingGeneration: receipt.publishingGeneration,
                configuration: configuration, acceptedAt: receipt.change.acceptedAt,
                lastSubmittedSourcePTS: receipt.change.lastSubmittedSourcePTS) else {
            await stop()
            throw PublisherError.notPublishing
        }
        return change
    }
    public func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        try Task.checkCancellation()
        guard !stopping, let generation = activeGeneration else { throw PublisherError.notPublishing }
        guard !encoderUpdating else { throw PublisherError.mutationInProgress }
        encoderUpdating = true
        await invalidateBandwidthProbe()
        guard !stopping, activeGeneration == generation, !Task.isCancelled else { encoderUpdating = false; throw PublisherError.notPublishing }
        let pending = Task { try await performProfileChange(profile, generation: generation) }
        profileChange = pending
        defer { profileChange = nil; encoderUpdating = false }
        return try await withTaskCancellationHandler {
            do {
                let receipt = try await pending.value
                guard !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
                try Task.checkCancellation()
                return receipt
            } catch {
                await stop()
                throw error
            }
        } onCancel: {
            pending.cancel()
            Task { await self.stop() }
        }
    }
    private func performProfileChange(_ profile: PublishingVideoProfile, generation: UInt64) async throws -> PublishingVideoProfileChange {
        try Task.checkCancellation()
        let healthy = await isPublishing()
        try Task.checkCancellation()
        guard healthy, !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
        let native = try await stream.replaceVideoSettings(profile.settings, publishingGeneration: generation)
        let acknowledgedAt = ProcessInfo.processInfo.systemUptime
        let stillHealthy = await isPublishing()
        try Task.checkCancellation()
        guard stillHealthy, !stopping, activeGeneration == generation,
              native.publishingGeneration == generation,
              let receipt = PublishingVideoProfileChange(profile: profile,
                publishingGeneration: native.publishingGeneration,
                previousEncoderSessionID: native.previousEncoderSessionID, encoderSessionID: native.encoderSessionID,
                lastOldSourcePTS: native.lastOldSourcePTS, firstNewSourcePTS: native.firstNewSourcePTS,
                width: Int(native.width), height: Int(native.height), rawVideoFramesDropped: native.rawVideoFramesDropped,
                acknowledgedAt: acknowledgedAt) else { throw PublisherError.notPublishing }
        return receipt
    }

    public func beginBandwidthProbe(bitRate: Int, staged: Bool = false) async throws -> PublishingBandwidthProbeSnapshot {
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, probeIdentity == nil, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) {
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.beginBandwidthProbe(
                    bitRate: bitRate, publishingGeneration: generation, staged: staged))
                guard value.publishingGeneration == generation, value.isValidStart(staged: staged, bitRate: bitRate) else {
                    try? await self.stream.cancelBandwidthProbe(id: value.id, publishingGeneration: value.publishingGeneration)
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    public func renewBandwidthProbe(id: UUID, publishingGeneration: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard generation == publishingGeneration, let prior = probeIdentity, prior.id == id,
              prior.publishingGeneration == generation else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) {
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.renewBandwidthProbe(id: id, publishingGeneration: generation))
                guard value.isValidRenewal(of: prior) else {
                    try? await self.stream.cancelBandwidthProbe(id: value.id, publishingGeneration: value.publishingGeneration)
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    public func replaceBandwidthProbe(id: UUID, publishingGeneration: UInt64, stage: UInt32,
                                      bitRate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard generation == publishingGeneration, let prior = probeIdentity, prior.id == id,
              prior.publishingGeneration == generation, prior.stage == stage else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) {
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.replaceBandwidthProbe(
                    id: id, publishingGeneration: generation, stage: stage, bitRate: bitRate))
                guard value.isValidReplacement(of: prior, bitRate: bitRate) else {
                    try? await self.stream.cancelBandwidthProbe(id: value.id, publishingGeneration: value.publishingGeneration)
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    public func cancelBandwidthProbe(id: UUID, publishingGeneration: UInt64) async {
        guard probeIdentity?.id == id, probeIdentity?.publishingGeneration == publishingGeneration else { return }
        probeRevision &+= 1
        probeOperation?.cancel()
        try? await stream.cancelBandwidthProbe(id: id, publishingGeneration: publishingGeneration)
    }

    public func bandwidthProbeSnapshot() async -> PublishingBandwidthProbeSnapshot? {
        await stream.bandwidthProbeSnapshot.map(PublishingBandwidthProbeSnapshot.init)
    }

    private func invalidateBandwidthProbe() async {
        probeRevision &+= 1
        if let probe = probeIdentity {
            try? await stream.cancelBandwidthProbe(id: probe.id, publishingGeneration: probe.publishingGeneration)
        }
    }

    private func performProbeOperation(generation: UInt64, revision: UInt64,
        operation: @Sendable () async throws -> PublishingBandwidthProbeSnapshot) async throws -> PublishingBandwidthProbeSnapshot {
        let healthy = await isPublishing()
        guard healthy, !stopping, activeGeneration == generation else { throw PublishingBandwidthProbeError.notPublishing }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeRevision == revision, !encoderUpdating else { throw PublishingBandwidthProbeError.obsolete }
        let value = try await operation()
        let stillHealthy = await isPublishing()
        guard stillHealthy, !stopping, activeGeneration == generation,
              !Task.isCancelled, probeRevision == revision, !encoderUpdating else {
            try? await stream.cancelBandwidthProbe(id: value.id, publishingGeneration: value.publishingGeneration)
            throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
        }
        probeIdentity = value
        return value
    }

    private func runProbeOperation(generation: UInt64, revision: UInt64,
        _ operation: @escaping @Sendable () async throws -> PublishingBandwidthProbeSnapshot) async throws -> PublishingBandwidthProbeSnapshot {
        let pending = Task {
            do { return try await operation() }
            catch {
                // Revocation belongs to the joined operation, including a renewal
                // that throws before returning its updated snapshot.
                await self.invalidateBandwidthProbe()
                throw error
            }
        }
        probeOperation = pending
        defer { probeOperation = nil }
        return try await withTaskCancellationHandler {
            do {
                let value = try await pending.value
                guard !Task.isCancelled, !stopping, activeGeneration == generation,
                      probeRevision == revision, !encoderUpdating else {
                    try? await stream.cancelBandwidthProbe(id: value.id, publishingGeneration: value.publishingGeneration)
                    throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
                }
                return value
            } catch { throw publishingProbeError(error) }
        } onCancel: { pending.cancel() }
    }

    public func transportClock() async -> PublishingTransportClock? {
        guard !stopping, !Task.isCancelled, let generation = activeGeneration else { return nil }
        let healthy = await isPublishing()
        guard healthy, !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let snapshot = await stream.transportClockSnapshot
        guard !stopping, !Task.isCancelled, activeGeneration == generation,
              let snapshot, snapshot.publishingGeneration == generation else { return nil }
        return PublishingTransportClock(sourceOrigin: snapshot.clock.origin,
                                        publishingGeneration: snapshot.publishingGeneration)
    }

    public func transportStatistics() async -> PublishingTransportStatistics? {
        guard !stopping, !Task.isCancelled, let generation = activeGeneration else { return nil }
        let healthy = await isPublishing()
        guard healthy, !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let stats = await connection.samplePerformanceData()
        guard !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let stillHealthy = await isPublishing()
        guard stillHealthy, !stopping, !Task.isCancelled, activeGeneration == generation,
              let stats, let sampledAt = stats.sampledAt else { return nil }
        return .init(publishingGeneration: generation, sampledAt: sampledAt,
            elapsedMilliseconds: stats.msTimeStamp, sentBytes: stats.byteSentTotal,
            retransmittedBytes: stats.byteRetransTotal, droppedPackets: stats.pktSndDropTotal,
            rttMilliseconds: stats.msRTT, estimatedBandwidthMbps: stats.mbpsBandwidth,
            senderBufferedBytes: stats.byteSndBuf, senderBufferMilliseconds: stats.msSndBuf,
            availableSenderBytes: stats.byteAvailSndBuf, senderDeliveryDelayMilliseconds: stats.msSndTsbPdDelay,
            senderMaximumBandwidthMbps: stats.mbpsMaxBW, packetSendPeriodMicroseconds: stats.usPktSndPeriod)
    }

    public func metrics() async -> (Double, Int32, UInt64)? {
        guard let stats = await connection.performanceData else { return nil }
        return (stats.msRTT, stats.pktSndDropTotal, stats.byteSentTotal)
    }
    public func isPublishing() async -> Bool {
        let connected = await connection.connected
        let publishing = await stream.readyState == .publishing
        let muxerHealthy = await stream.muxerError == nil
        let streamHealthy = await stream.publishingError == nil
        let transportHealthy = await connection.publishingError == nil
        return connected && publishing && muxerHealthy && streamHealthy && transportHealthy
    }
    public func stop() async {
        stopping = true
        activeGeneration = nil
        if let shutdown { await shutdown.value; return }
        let changing = profileChange
        let starting = startup
        let probing = probeOperation
        probing?.cancel()
        changing?.cancel()
        starting?.cancel()
        let pending = Task {
            // Keep the raw health predicate available to the drain policy after
            // admission closes. Join native replacement even when health failed.
            lastStopOutcome = await stopPolicy.run(operations: .init(
                isPublishing: { await self.isPublishing() },
                finish: { await self.stream.finish(timeout: $0) },
                snapshot: { await self.stopSnapshot() },
                close: {
                    await self.stream.close()
                    await self.connection.close()
                }))
            _ = await changing?.result
            _ = await starting?.result
            _ = await probing?.result
            if starting != nil || changing != nil || probing != nil {
                // A native actor call admitted before shutdown can complete after
                // the first close. Its owner must finish before this final close.
                await stream.close()
                await connection.close()
            }
            videoCost?.close()
            startupEvidence.close()
        }
        shutdown = pending
        await pending.value
    }

    private func stopSnapshot() async -> SRTStopPolicy.Snapshot? {
        // finish() normally leaves the stream idle. Its terminal errors and the
        // connection remain meaningful; isPublishing() would be false here.
        guard await connection.connected, await stream.muxerError == nil,
              await stream.publishingError == nil, await connection.publishingError == nil else {
            return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0)
        }
        do {
            // Fresh socket options directly measure the drain boundary.
            guard let packets = try await connection.getSocketOption(.snddata),
                  let latency = try await connection.getSocketOption(.peerlatency) else { return nil }
            // Socket reads suspend this actor. A close may have replaced the
            // socket since the first health check, so recheck before accepting it.
            guard await connection.connected, await stream.muxerError == nil,
                  await stream.publishingError == nil, await connection.publishingError == nil else {
                return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0)
            }
            return .init(healthy: true, unacknowledgedPackets: packets.intValue,
                         peerLatencyMilliseconds: latency.intValue)
        } catch { return nil }
    }
}

public func copyPCM(_ sample: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioTime)? {
    guard let description = sample.formatDescription,
          CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM,
          sample.numSamples > 0, sample.numSamples <= Int32.max else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    let pts = sample.presentationTimeStamp
    guard pts.isNumeric, pts.epoch == 0, pts.seconds.isFinite, pts.seconds >= 0,
          pts.seconds < AVAudioTime.seconds(forHostTime: UInt64.max),
          format.sampleRate.isFinite, format.sampleRate > 0,
          format.sampleRate <= Double(Int32.max), format.sampleRate.rounded() == format.sampleRate else { return nil }
    let sampleTime = CMTimeConvertScale(pts, timescale: Int32(format.sampleRate), method: .default)
    guard sampleTime.isNumeric, sampleTime.value >= 0 else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(sample.numSamples)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else { return nil }
    // The SDK anchors encoded audio to hostTime and interprets sampleTime at the
    // PCM format's rate. Preserve both clocks even when capture uses another scale.
    return (buffer, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds),
        sampleTime: sampleTime.value, atRate: format.sampleRate))
}

@preconcurrency import AVFoundation
import HaishinKit
import SRTHaishinKit
import ScorebugMedia

/// SRT publisher for one connection attempt: H.264 + AAC at a ladder profile,
/// live profile replacement, and sender statistics. Construct one per attempt.
public actor SRTStreamPublisher: MediaPublisher {
    public static let audioBitRate = 128_000
    public enum PublisherError: Error, Equatable, Sendable {
        case invalidState, notPublishing, cancelled, startFailed, appendFailed, invalidSample, profileUpdateFailed
    }

    /// Seam for unit tests; production wires these to SRTConnection/SRTStream.
    struct Operations: Sendable {
        var configure: @Sendable (PublishingVideoProfile) async throws -> Void
        var start: @Sendable () async throws -> Void
        var append: @Sendable (CapturedMediaSample) async throws -> Void
        var isPublishing: @Sendable () async -> Bool
        var stop: @Sendable () async -> Void
        var setProfile: @Sendable (PublishingVideoProfile) async throws -> Void
        var statistics: @Sendable () async -> PublishingTransportStatistics?
    }

    private enum State { case prepared, starting, publishing, stopped }
    private let operations: Operations
    private let initialProfile: PublishingVideoProfile
    private var state = State.prepared
    private var startup: Task<Void, Error>?
    private var profileChange: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?

    public init(url: URL, profile: PublishingVideoProfile, stopPolicy: SRTStopPolicy = .init()) {
        let native = NativeSRT(stopPolicy: stopPolicy)
        self.init(operations: Operations(
            configure: { try await native.configure($0) },
            start: { try await native.start(url) },
            append: { try await native.append($0) },
            isPublishing: { await native.isPublishing() },
            stop: { await native.stop() },
            setProfile: { try await native.setProfile($0) },
            statistics: { await native.statistics() }), profile: profile)
    }

    init(operations: Operations, profile: PublishingVideoProfile) {
        self.operations = operations
        initialProfile = profile
    }

    public func start() async throws {
        guard state == .prepared else { throw PublisherError.invalidState }
        state = .starting
        let operations = self.operations, profile = initialProfile
        let attempt = Task {
            try await operations.configure(profile)
            try Task.checkCancellation()
            try await operations.start()
        }
        startup = attempt
        do {
            try await attempt.value
            startup = nil
            guard state == .starting, !Task.isCancelled else { throw PublisherError.cancelled }
            state = .publishing
        } catch {
            startup = nil
            let reason: PublisherError = state == .stopped || error is CancellationError ? .cancelled : .startFailed
            await stop()
            throw reason
        }
    }

    public func append(_ sample: CapturedMediaSample) async throws {
        guard state == .publishing else { throw PublisherError.notPublishing }
        do {
            try Task.checkCancellation()
            try await operations.append(sample)
            guard state == .publishing else { throw PublisherError.cancelled }
        } catch is CancellationError { throw PublisherError.cancelled }
        catch let error as PublisherError { throw error }
        catch { throw PublisherError.appendFailed }
    }

    public var isPublishing: Bool {
        get async {
            guard state == .publishing else { return false }
            let healthy = await operations.isPublishing()
            return state == .publishing && healthy
        }
    }

    public func transportStatistics() async -> PublishingTransportStatistics? {
        guard state == .publishing else { return nil }
        return await operations.statistics()
    }

    public func setVideoProfile(_ profile: PublishingVideoProfile) async throws {
        guard state == .publishing else { throw PublisherError.notPublishing }
        guard profileChange == nil else { throw PublisherError.invalidState }
        let change = operations.setProfile
        let pending = Task { try await change(profile) }
        profileChange = pending
        defer { profileChange = nil }
        do {
            try await pending.value
            guard state == .publishing else { throw PublisherError.cancelled }
        } catch {
            let reason: PublisherError = state == .stopped ? .cancelled : .profileUpdateFailed
            await stop()
            throw reason
        }
    }

    public func stop() async {
        state = .stopped
        if let shutdown { await shutdown.value; return }
        let close = operations.stop
        let starting = startup, changing = profileChange
        starting?.cancel(); changing?.cancel()
        let pending = Task.detached {
            // Close first so a blocked connect/replace can finish, then join it and
            // close again: the SDK can reopen on a late actor hop.
            await close()
            _ = await starting?.result
            _ = await changing?.result
            if starting != nil || changing != nil { await close() }
        }
        shutdown = pending
        await pending.value
    }
}

/// Owns the vendored SRT connection and stream for one attempt.
private actor NativeSRT {
    private let connection = SRTConnection()
    private let stream: SRTStream
    private let stopPolicy: SRTStopPolicy
    private var generation: UInt64?
    private var stopping = false

    init(stopPolicy: SRTStopPolicy) {
        self.stopPolicy = stopPolicy
        stream = SRTStream(connection: connection)
    }

    func configure(_ profile: PublishingVideoProfile) async throws {
        try await stream.setVideoSettings(profile.settings)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: SRTStreamPublisher.audioBitRate))
        await stream.setExpectedMedias([.video, .audio])
        await stream.setVideoInputBufferCounts(4)
    }

    func start(_ url: URL) async throws {
        guard !stopping else { throw SRTStreamPublisher.PublisherError.notPublishing }
        try await connection.connect(url)
        guard !stopping else { throw SRTStreamPublisher.PublisherError.notPublishing }
        await stream.publish()
        guard await isPublishing(), let current = await stream.publishingGeneration, !stopping else {
            throw SRTStreamPublisher.PublisherError.notPublishing
        }
        generation = current
    }

    func append(_ sample: CapturedMediaSample) async throws {
        switch sample.kind {
        case .video: await stream.append(sample.sampleBuffer)
        case .audio:
            guard let (pcm, when) = copyPCM(sample.sampleBuffer) else { throw SRTStreamPublisher.PublisherError.invalidSample }
            await stream.append(pcm, when: when)
        }
    }

    func isPublishing() async -> Bool {
        guard await connection.connected, await stream.readyState == .publishing else { return false }
        let muxer = await stream.muxerError, streamError = await stream.publishingError
        let transport = await connection.publishingError
        return muxer == nil && streamError == nil && transport == nil
    }

    func setProfile(_ profile: PublishingVideoProfile) async throws {
        guard !stopping, let generation else { throw SRTStreamPublisher.PublisherError.notPublishing }
        _ = try await stream.replaceVideoSettings(profile.settings, publishingGeneration: generation)
    }

    func statistics() async -> PublishingTransportStatistics? {
        guard !stopping, let stats = await connection.samplePerformanceData() else { return nil }
        return .init(sampledAt: stats.sampledAt ?? ProcessInfo.processInfo.systemUptime,
                     sentPackets: stats.pktSentTotal, retransmittedPackets: Int64(stats.pktRetransTotal),
                     droppedPackets: Int64(stats.pktSndDropTotal), senderBufferMilliseconds: Int(stats.msSndBuf),
                     rttMilliseconds: stats.msRTT, sendRateMbps: stats.mbpsSendRate)
    }

    func stop() async {
        let first = !stopping
        stopping = true
        generation = nil
        guard first else {
            await stream.close(); await connection.close(); return
        }
        _ = await stopPolicy.run(operations: .init(
            isPublishing: { await self.isPublishing() },
            finish: { await self.stream.finish(timeout: $0) },
            snapshot: { await self.stopSnapshot() },
            close: {
                await self.stream.close()
                await self.connection.close()
            }))
    }

    private func stopSnapshot() async -> SRTStopPolicy.Snapshot? {
        // finish() normally leaves the stream idle; its errors and the connection still matter.
        func healthy() async -> Bool {
            let connected = await connection.connected
            let muxer = await stream.muxerError, streamError = await stream.publishingError
            let transport = await connection.publishingError
            return connected && muxer == nil && streamError == nil && transport == nil
        }
        guard await healthy() else { return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0) }
        do {
            guard let packets = try await connection.getSocketOption(.snddata),
                  let latency = try await connection.getSocketOption(.peerlatency) else { return nil }
            guard await healthy() else { return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0) }
            return .init(healthy: true, unacknowledgedPackets: packets.intValue, peerLatencyMilliseconds: latency.intValue)
        } catch { return nil }
    }
}

/// Copies one LPCM capture sample into an AVAudioPCMBuffer for the AAC encoder.
func copyPCM(_ sample: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioTime)? {
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

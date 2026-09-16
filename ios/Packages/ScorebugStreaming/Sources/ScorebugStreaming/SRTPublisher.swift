@preconcurrency import AVFoundation
import VideoToolbox
import HaishinKit
import SRTHaishinKit
import ScorebugMedia

/// SRT encoding/transport adapter shared by the app and local qualification tools.
/// Its caller owns bounded raw-media admission and lifecycle serialization.
/// Construct a fresh adapter for every publishing attempt.
public actor SRTPublisher {
    public typealias CompressedVideoFrame = SRTStream.CompressedVideoFrame
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
    public enum PublisherError: Error { case notPublishing }
    private let connection = SRTConnection()
    private let stream: SRTStream
    private let stopPolicy: SRTStopPolicy
    private var activeGeneration: UInt64?
    private var stopping = false
    public private(set) var lastStopOutcome: SRTStopPolicy.Outcome?
    public init(stopPolicy: SRTStopPolicy = .init(), observations: VideoFrameObservationOwner? = nil,
                encoderConfigurationObserver: (@Sendable (EncoderFrame) -> Void)? = nil,
                videoProfile: PublishingVideoProfile = .hd1080,
                compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)? = nil) {
        self.stopPolicy = stopPolicy
        self.videoProfile = videoProfile
        // Immutable ownership prevents late native completions from reaching a
        // later publishing attempt. Observe synchronously without retaining media.
        let configurationObserver: VideoEncoderConfigurationObserver?
        if observations != nil || encoderConfigurationObserver != nil {
            configurationObserver = { frame in
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
                encoderConfigurationObserver?(EncoderFrame(frame))
            }
        } else { configurationObserver = nil }
        stream = SRTStream(connection: connection, encoderConfigurationObserver: configurationObserver,
                           compressedVideoObserver: compressedVideoObserver)
    }
    public func configure() async throws {
        try await stream.setVideoSettings(videoProfile.settings)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: 128_000))
        await stream.setExpectedMedias([.video, .audio])
        await stream.setVideoInputBufferCounts(4)
    }
    public func start(_ url: URL) async throws {
        try await connection.connect(url)
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
        let stats = await connection.performanceData
        guard !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let stillHealthy = await isPublishing()
        guard stillHealthy, !stopping, !Task.isCancelled, activeGeneration == generation,
              let stats, let sampledAt = stats.sampledAt else { return nil }
        return .init(publishingGeneration: generation, sampledAt: sampledAt,
            elapsedMilliseconds: stats.msTimeStamp, sentBytes: stats.byteSentTotal,
            retransmittedBytes: stats.byteRetransTotal, droppedPackets: stats.pktSndDropTotal,
            rttMilliseconds: stats.msRTT, estimatedBandwidthMbps: stats.mbpsBandwidth,
            senderBufferedBytes: stats.byteSndBuf, senderBufferMilliseconds: stats.msSndBuf,
            availableSenderBytes: stats.byteAvailSndBuf)
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
        // isPublishing remains a raw health predicate so the stop policy can drain
        // this now-stopping stream rather than treating it as already closed.
        lastStopOutcome = await stopPolicy.run(operations: .init(
            isPublishing: { await self.isPublishing() },
            finish: { await self.stream.finish(timeout: $0) },
            snapshot: { await self.stopSnapshot() },
            close: {
                await self.stream.close()
                await self.connection.close()
            }))
    }

    private func stopSnapshot() async -> SRTStopPolicy.Snapshot? {
        // finish() normally leaves the stream idle. Its terminal errors and the
        // connection remain meaningful; isPublishing() would be false here.
        guard await connection.connected, await stream.muxerError == nil,
              await stream.publishingError == nil, await connection.publishingError == nil else {
            return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0)
        }
        do {
            // Fresh socket options; performanceData is only refreshed once a second.
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

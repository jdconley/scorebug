@preconcurrency import AVFoundation
import VideoToolbox
import HaishinKit
import SRTHaishinKit

/// SRT encoding/transport adapter shared by the app and local qualification tools.
/// Its caller owns bounded raw-media admission and lifecycle serialization.
/// Construct a fresh adapter for every publishing attempt.
public actor SRTPublisher {
    public enum PublisherError: Error { case notPublishing }
    private let connection = SRTConnection()
    private let stream: SRTStream
    private let stopPolicy: SRTStopPolicy
    public private(set) var lastStopOutcome: SRTStopPolicy.Outcome?
    public init(stopPolicy: SRTStopPolicy = .init()) {
        self.stopPolicy = stopPolicy
        stream = SRTStream(connection: connection)
    }
    public func configure() async throws {
        try await stream.setVideoSettings(VideoCodecSettings(
            videoSize: CGSize(width: 1920, height: 1080), bitRate: 6_000_000,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2, allowFrameReordering: false,
            expectedFrameRate: 30))
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
    }
    public func video(_ sample: CMSampleBuffer) async { await stream.append(sample) }
    public func audio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) async { await stream.append(buffer, when: when) }
    public func setBitRate(_ bitRate: Int) async throws {
        var settings = await stream.videoSettings
        settings.bitRate = bitRate
        try await stream.setVideoSettings(settings)
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

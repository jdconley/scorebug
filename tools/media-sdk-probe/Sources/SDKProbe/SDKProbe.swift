@preconcurrency import AVFoundation
import VideoToolbox
import HaishinKit
import SRTHaishinKit

public actor SDKProbe {
    private let connection = SRTConnection()
    private let stream: SRTStream
    public init() { stream = SRTStream(connection: connection) }
    public func configure() async throws {
        try await stream.setVideoSettings(VideoCodecSettings(
            videoSize: CGSize(width: 1920, height: 1080), bitRate: 6_000_000,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2, allowFrameReordering: false,
            expectedFrameRate: 30))
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: 128_000))
        await stream.setExpectedMedias([.video, .audio])
    }
    public func start(_ url: URL) async throws {
        try await connection.connect(url)
        await stream.publish()
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
    public func stop() async { await stream.close(); await connection.close() }
}

public func copyPCM(_ sample: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioTime)? {
    guard let description = sample.formatDescription,
          CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM,
          sample.numSamples > 0 else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(sample.numSamples)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else { return nil }
    let pts = sample.presentationTimeStamp
    guard pts.isNumeric, pts.timescale > 0 else { return nil }
    return (buffer, AVAudioTime(sampleTime: pts.value, atRate: Double(pts.timescale)))
}

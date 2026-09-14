import AVFoundation
import CoreMedia
import Testing
import VideoToolbox
@testable import HaishinKit

@Suite(.serialized) struct VideoCodecStartupTests {
    private func frame(_ timestamp: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let image = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let bytes = CVPixelBufferGetBaseAddress(image) {
            memset(bytes, 0, CVPixelBufferGetDataSize(image))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func encode(_ codec: VideoCodec, timestamps: [CMTime]) async throws -> [CMTime] {
        let output = codec.outputStream
        codec.startRunning()
        for timestamp in timestamps { codec.append(try frame(timestamp)) }
        let session = try #require(codec.session) as! VTCompressionSession
        #expect(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr)
        codec.stopRunning()
        var timestamps: [CMTime] = []
        for await sample in output { timestamps.append(sample.presentationTimeStamp) }
        return timestamps
    }

    @Test(arguments: [0.0, VideoCodecSettings.frameInterval30])
    func encodesFirstZeroTimestampAndRestart(interval: Double) async throws {
        let codec = VideoCodec()
        codec.settings = VideoCodecSettings(videoSize: CGSize(width: 64, height: 64),
            allowFrameReordering: false)
        codec.settings.frameInterval = interval
        let source: [CMTime] = [.zero, CMTime(value: 1, timescale: 30)]
        let first = try await encode(codec, timestamps: source)
        #expect(first == source)
        let restarted = try await encode(codec, timestamps: source)
        #expect(restarted == source)
    }

    @Test func stillRejectsDuplicateOutOfOrderAndOverRateFrames() async throws {
        let codec = VideoCodec()
        codec.settings = VideoCodecSettings(videoSize: CGSize(width: 64, height: 64),
            allowFrameReordering: false)
        codec.settings.frameInterval = VideoCodecSettings.frameInterval30
        let frameTime = CMTime(value: 1, timescale: 30)
        let output = try await encode(codec, timestamps: [.zero, .zero, CMTime(value: -1, timescale: 30),
            CMTime(value: 1, timescale: 60), frameTime, frameTime, CMTime(value: 1, timescale: 60)])
        #expect(output == [.zero, frameTime])
    }
}

import AVFoundation
import Testing
import VideoToolbox
@testable import HaishinKit

struct VideoInputPixelFormatTests {
    @Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                      kCVPixelFormatType_32BGRA])
    func compressionSessionReceivesActualPixelFormat(pixelFormat: OSType) throws {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, pixelFormat,
            nil, &pixel) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: try #require(pixel), formatDescriptionOut: &format) == noErr)
        let description = try #require(format)
        #expect(CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video)
        #expect(CMFormatDescriptionGetMediaSubType(description) == pixelFormat)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: try #require(pixel), formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        var received: OSType?
        let codec = VideoCodec(sessionFactory: { mode, codec in
            let attributes = codec.makeImageBufferAttributes(mode)
            received = (attributes?[kCVPixelBufferPixelFormatTypeKey] as? NSNumber)?.uint32Value
            // Stop at the real factory boundary; this test needs no native encoder.
            throw VTSessionError.failedToCreate(status: kVTParameterErr)
        })
        codec.startRunning()
        defer { codec.stopRunning() }
        codec.append(try #require(sample))
        #expect(received == pixelFormat)
        #expect(received != kCMMediaType_Video)
    }

    @Test func absentInputFormatDoesNotInventPixelFormat() {
        #expect(VideoCodec().makeImageBufferAttributes(.compression) == nil)
    }
}

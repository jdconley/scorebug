import CoreMedia
import Testing
@testable import SRTHaishinKit

@Suite struct CompressedVideoFrameTests {
    @Test func actualSampleDimensionsAreCopiedIndependentlyOfAnyRequestedProfile() throws {
        for width: Int32 in [960, 1920] {
            let sample = try makeSample(width: width)
            let frame = SRTStream.CompressedVideoFrame(sampleBuffer: sample, generation: 3, wasEncoded: true)
            #expect(frame.valid && frame.wasEncoded)
            #expect(frame.width == width && frame.height == 540)
            #expect(frame.codec == kCMVideoCodecType_H264)
            #expect(frame.publishingGeneration == 3 && frame.sourcePTS == CMTime(value: 7, timescale: 30))
        }
    }
    @Test func invalidPayloadIsVisibleAndPassthroughIsNotRelabeledAsEncoding() throws {
        let invalid = SRTStream.CompressedVideoFrame(sampleBuffer: try makeSample(width: 960, bytes: 0), generation: 1, wasEncoded: true)
        #expect(!invalid.valid)
        let passthrough = SRTStream.CompressedVideoFrame(sampleBuffer: try makeSample(width: 960), generation: 1, wasEncoded: false)
        #expect(passthrough.valid && !passthrough.wasEncoded)
    }
    private func makeSample(width: Int32, bytes: Int = 8) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: width, height: 540, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        if bytes > 0 {
            #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale:30), presentationTimeStamp: CMTime(value:7,timescale:30),decodeTimeStamp:.invalid)
        var size = bytes
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator:kCFAllocatorDefault,dataBuffer:block,dataReady:true,
            makeDataReadyCallback:nil,refcon:nil,formatDescription:format,sampleCount:1,
            sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample) == noErr)
        return try #require(sample)
    }
}

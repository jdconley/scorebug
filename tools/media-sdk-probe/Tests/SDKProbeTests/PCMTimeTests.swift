@preconcurrency import AVFoundation
import XCTest
@testable import SDKProbe

final class PCMTimeTests: XCTestCase {
    func testCopyPreservesNonzeroSourceTimeInHostAndPCMSampleClocks() throws {
        let sample = try makeSample(at: CMTime(value: 123_250, timescale: 1000))
        let (pcm, when) = try XCTUnwrap(copyPCM(sample))
        XCTAssertEqual(pcm.frameLength, 1024)
        XCTAssertTrue(when.isHostTimeValid)
        XCTAssertTrue(when.isSampleTimeValid)
        XCTAssertEqual(AVAudioTime.seconds(forHostTime: when.hostTime), 123.25, accuracy: 0.000001)
        XCTAssertEqual(when.sampleRate, 48_000)
        XCTAssertEqual(when.sampleTime, 5_916_000)
    }

    func testZeroOriginHasValidHostClock() throws {
        let (_, when) = try XCTUnwrap(copyPCM(makeSample(at: .zero)))
        XCTAssertTrue(when.isHostTimeValid)
        XCTAssertEqual(when.hostTime, 0)
        XCTAssertEqual(when.sampleTime, 0)
        XCTAssertEqual(when.sampleRate, 48_000)
    }

    func testNegativeSourceTimeIsRejectedInsteadOfUnsignedHostConversion() throws {
        XCTAssertNil(copyPCM(try makeSample(at: CMTime(value: -1, timescale: 1000))))
    }

    private func makeSample(at timestamp: CMTime) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 48_000, channels: 1, interleaved: true))
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 2048, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 2048,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block), formatDescription: format.formatDescription,
            sampleCount: 1024, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

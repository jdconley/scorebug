import AVFoundation
import Testing
import VideoToolbox
@testable import HaishinKit

@Suite(.serialized) struct EncoderCompletionObservationTests {
    @Test func delayedCompletionUsesCapturedObserverAndEquivalentRationalPTS() async throws {
        let old = CompletionRecorder()
        let replacement = CompletionRecorder()
        let failure = PublishingFailureLatch()
        let queue = PublishingQueue<CMSampleBuffer>(boundary: "test", limits: .init(count: 2, bytesPerItem: 100), failure: failure)
        let source = CMTime(value: 1, timescale: 30)
        let delayed = VideoEncoderCompletion(sourcePTS: source, observer: old.record, continuation: queue)
        let fresh = VideoEncoderCompletion(sourcePTS: .zero, observer: replacement.record, continuation: nil)
        #expect(old.pairs.isEmpty && replacement.pairs.isEmpty)
        let sample = try compressed(CMTime(value: 2, timescale: 60))
        delayed.complete(status: noErr, flags: [], sampleBuffer: sample)
        #expect(old.pairs.count == 1 && replacement.pairs.isEmpty)
        #expect(old.pairs.first?.0 == source)
        #expect(old.pairs.first?.1.timescale == 60)
        fresh.complete(status: noErr, flags: [], sampleBuffer: try compressed(.zero))
        #expect(old.pairs.count == 1 && replacement.pairs.count == 1)
        queue.finish()
        var received = 0
        for await output in queue.stream { #expect(output === sample); received += 1 }
        #expect(received == 1 && failure.error == nil)
    }

    @Test func rejectionDoesNotChangeSuccessfulMediaDelivery() async throws {
        let valid = CMTime(value: 1, timescale: 30)
        let cases: [(CMTime, CMSampleBuffer, VTEncodeInfoFlags)] = [
            (valid, try compressed(valid), .frameDropped),
            (.invalid, try compressed(valid), []),
            (.positiveInfinity, try compressed(valid), []),
            (CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0), try compressed(valid), []),
            (valid, try compressed(.invalid), []),
            (valid, try compressed(.indefinite), []),
            (valid, try compressed(CMTime(value: 2, timescale: 30)), []),
            (valid, try compressed(CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1)), []),
            (valid, try compressed(valid, count: 0, bytes: 0), []),
            (valid, try compressed(valid, bytes: 0), []),
            (valid, try compressed(valid, count: 2), []),
            (valid, try compressed(valid, ready: false), []),
            (valid, try image(valid), [])
        ]
        for (source, sample, flags) in cases {
            let recorder = CompletionRecorder()
            let failure = PublishingFailureLatch()
            let queue = PublishingQueue<CMSampleBuffer>(boundary: "test", limits: .init(count: 2, bytesPerItem: 100_000), failure: failure)
            VideoEncoderCompletion(sourcePTS: source, observer: recorder.record, continuation: queue)
                .complete(status: noErr, flags: flags, sampleBuffer: sample)
            queue.finish()
            var delivered = 0
            for await output in queue.stream { #expect(output === sample); delivered += 1 }
            #expect(recorder.pairs.isEmpty)
            #expect(delivered == 1 && failure.error == nil)
        }
    }

    @Test func nilAndErrorKeepExistingTerminalFailure() throws {
        for (status, sample) in [(noErr, nil), (OSStatus(-123), try compressed(.zero))] {
            let recorder = CompletionRecorder()
            let failure = PublishingFailureLatch()
            let queue = PublishingQueue<CMSampleBuffer>(boundary: "test", limits: .init(count: 1, bytesPerItem: 100), failure: failure)
            VideoEncoderCompletion(sourcePTS: .zero, observer: recorder.record, continuation: queue)
                .complete(status: status, flags: [], sampleBuffer: sample)
            #expect(recorder.pairs.isEmpty)
            #expect(failure.error == .codecFailed(status: status == noErr ? -1 : status))
        }
    }

    @Test(arguments: [true, false]) func completionNotifiesBeforeQueueRejection(byteLimit: Bool) throws {
        let recorder = CompletionRecorder()
        let failure = PublishingFailureLatch()
        let queue = PublishingQueue<CMSampleBuffer>(boundary: "test", limits: .init(count: 1, bytesPerItem: byteLimit ? 1 : 100), failure: failure)
        if !byteLimit { queue.yield(try compressed(.zero), byteCount: 8) }
        let completion = VideoEncoderCompletion(sourcePTS: .zero, observer: { source, output in
            #expect(failure.error == nil, "Observer must precede queue rejection")
            recorder.record(source, output)
        }, continuation: queue)
        completion.complete(status: noErr, flags: [], sampleBuffer: try compressed(.zero))
        #expect(recorder.pairs.count == 1)
        if byteLimit { #expect(failure.error == .itemSizeExceeded(boundary: "test", bytes: 8, limit: 1)) }
        else { #expect(failure.error == .queueCapacityExceeded(boundary: "test")) }
    }

    @Test func realEncoderNotifiesMatchingPTSAndDecompressionDoesNotNotify() async throws {
        let recorder = CompletionRecorder()
        let encoder = VideoCodec(encoderCompletionObserver: recorder.record)
        encoder.settings = VideoCodecSettings(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false)
        let output = encoder.outputStream
        encoder.startRunning()
        let expected: [CMTime] = [.zero, CMTime(value: 2, timescale: 60)]
        for pts in expected { encoder.append(try image(pts)) }
        encoder.makeCompletion()()
        #expect(encoder.failure.error == nil)
        #expect(recorder.pairs.count == 2)
        #expect(recorder.pairs.map(\.0) == expected)
        #expect(recorder.pairs.allSatisfy { CMTimeCompare($0.0, $0.1) == 0 })
        let decoderRecorder = CompletionRecorder()
        let decoder = VideoCodec(encoderCompletionObserver: decoderRecorder.record)
        let decoded = decoder.outputStream
        decoder.startRunning()
        for await sample in output { decoder.append(sample) }
        decoder.makeCompletion()()
        var decodedCount = 0
        for await _ in decoded { decodedCount += 1 }
        #expect(decodedCount == 2 && decoder.failure.error == nil)
        #expect(decoderRecorder.pairs.isEmpty)
        encoder.stopRunning()
        decoder.stopRunning()
    }

    private func compressed(_ pts: CMTime, count: Int = 1, bytes: Int = 8, ready: Bool = true) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 64, height: 64, extensions: nil, formatDescriptionOut: &format) == noErr)
        let description = try #require(format)
        var block: CMBlockBuffer?
        if bytes > 0 {
            #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = count > 0 ? bytes / count : 0
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: ready,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: count > 0 ? 1 : 0,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func image(_ pts: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let pixelBuffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(CMTime, CMTime)] = []
    var pairs: [(CMTime, CMTime)] { lock.withLock { stored } }
    func record(_ source: CMTime, _ output: CMTime) { lock.withLock { stored.append((source, output)) } }
}

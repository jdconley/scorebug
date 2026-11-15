import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import HaishinKit

@Suite(.serialized) struct EncoderConfigurationTests {
    private final class Session: VTSessionConvertible {
        var options: [String: AnyObject] = [:]
        var pending: [(CMTime, VideoEncoderCompletionObserver?)] = []
        var writeStatus: OSStatus = noErr
        var conversionFails = false
        func setOption(_ option: VTSessionOption) -> OSStatus { options[option.key.rawValue] = option.value; return writeStatus }
        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
        func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, options[key.rawValue]) }
        func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
            if conversionFails { throw VTSessionError.failedToConvert(status: -70) }
            if sampleBuffer.imageBuffer != nil { pending.append((sampleBuffer.presentationTimeStamp, encoderCompletionObserver)) }
        }
        func completeFrames() -> OSStatus { noErr }
        func invalidate() {}
        func complete(_ index: Int) { let item = pending[index]; item.1?(item.0, item.0) }
    }
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [VideoEncoderFrame] = []
        private var oldCount = 0
        var frames: [VideoEncoderFrame] { lock.withLock { stored } }
        var legacyCount: Int { lock.withLock { oldCount } }
        func record(_ frame: VideoEncoderFrame) { lock.withLock { stored.append(frame) } }
        func old(_ source: CMTime, _ output: CMTime) { lock.withLock { oldCount += 1 } }
    }
    private func ready(_ session: Session, _ recorder: Recorder) throws -> VideoCodec {
        let codec = VideoCodec(encoderCompletionObserver: recorder.old,
            encoderConfigurationObserver: recorder.record, sessionFactory: { _, _ in session })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        return codec
    }
    @Test func delayedCallbacksKeepSubmissionIdentityAcrossMultipleWrites() throws {
        let session = Session(), recorder = Recorder(), codec = try ready(session, recorder)
        _ = try codec.setVerifiedBitRate(3_000_000)
        let first = try #require(codec.lastBitRateChange)
        #expect(first.lastSubmittedSourcePTS == .zero)
        codec.append(try frame(1))
        _ = try codec.setVerifiedBitRate(2_000_000)
        let second = try #require(codec.lastBitRateChange)
        #expect(second.lastSubmittedSourcePTS == CMTime(value: 1, timescale: 30))
        #expect(first.configuration.id != second.configuration.id)
        #expect(first.configuration.encoderSessionID == second.configuration.encoderSessionID)
        codec.append(try frame(2))
        session.complete(2); session.complete(0); session.complete(1)
        #expect(recorder.frames.count == 3 && recorder.legacyCount == 3)
        #expect(recorder.frames[0].configuration == second.configuration)
        #expect(recorder.frames[1].configuration == nil)
        #expect(recorder.frames[2].configuration == first.configuration)
        #expect(recorder.frames[2].submittedAt >= first.acceptedAt)
        #expect(recorder.frames.allSatisfy { $0.completedAt >= $0.submittedAt })
        codec.stopRunning()
    }
    @Test func sameRateGetsFreshIdentityAndLegacyWritesClearVerifiedState() throws {
        let session = Session(), recorder = Recorder(), codec = try ready(session, recorder)
        _ = try codec.setVerifiedBitRate(3_000_000)
        let first = try #require(codec.lastBitRateChange)
        codec.append(try frame(1))
        _ = try codec.setVerifiedBitRate(3_000_000)
        #expect(codec.lastBitRateChange?.configuration.id != first.configuration.id)
        var settings = codec.settings; settings.bitRate = 2_000_000; codec.settings = settings
        #expect(codec.lastBitRateChange == nil)
        codec.append(try frame(2))
        session.complete(1); session.complete(2)
        #expect(recorder.frames.first?.configuration == first.configuration)
        #expect(recorder.frames.last?.configuration == nil)
        codec.stopRunning()
    }
    @Test func recreationAndStopCannotRelabelOldCallbacks() throws {
        let first = Session(), second = Session(), recorder = Recorder()
        var creations = 0
        let codec = VideoCodec(encoderConfigurationObserver: recorder.record, sessionFactory: { _, _ in
            creations += 1; return creations == 1 ? first : second
        })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        _ = try codec.setVerifiedBitRate(3_000_000); let old = try #require(codec.lastBitRateChange)
        codec.append(try frame(1)); codec.requestSessionInvalidation()
        #expect(codec.lastBitRateChange == nil)
        codec.append(try frame(2)); #expect(codec.lastBitRateChange == nil)
        _ = try codec.setVerifiedBitRate(2_000_000); let next = try #require(codec.lastBitRateChange)
        #expect(old.configuration.encoderSessionID != next.configuration.encoderSessionID)
        #expect(next.lastSubmittedSourcePTS == CMTime(value: 2, timescale: 30))
        codec.append(try frame(3)); codec.stopRunning()
        #expect(codec.lastBitRateChange == nil)
        first.complete(1); second.complete(1)
        #expect(recorder.frames.map { $0.configuration?.id } == [old.configuration.id, next.configuration.id])
    }
    @Test func failedWriteAndFailedConversionNeverProduceNewReceipt() throws {
        let session = Session(), recorder = Recorder(), codec = try ready(session, recorder)
        session.writeStatus = -50
        #expect(throws: VideoBitRateUpdateError.writeFailed(property: "AverageBitRate", status: -50)) {
            try codec.setVerifiedBitRate(3_000_000)
        }
        #expect(codec.lastBitRateChange == nil)
        session.complete(0); #expect(recorder.frames.first?.configuration == nil)
        codec.stopRunning()
        let bad = Session(), other = try ready(bad, recorder)
        bad.conversionFails = true; other.append(try frame(1))
        #expect(other.failure.error != nil)
        #expect(throws: VideoBitRateUpdateError.notEncoding) { try other.setVerifiedBitRate(2_000_000) }
        #expect(other.lastBitRateChange == nil); other.stopRunning()
    }
    @Test func failedLaterWriteClearsCurrentReceiptButPreservesPendingHistory() throws {
        let session = Session(), recorder = Recorder(), codec = try ready(session, recorder)
        _ = try codec.setVerifiedBitRate(3_000_000)
        let accepted = try #require(codec.lastBitRateChange)
        codec.append(try frame(1))
        session.writeStatus = -50
        #expect(throws: VideoBitRateUpdateError.writeFailed(property: "AverageBitRate", status: -50)) {
            try codec.setVerifiedBitRate(2_000_000)
        }
        #expect(codec.lastBitRateChange == nil)
        session.complete(1)
        #expect(recorder.frames.first?.configuration == accepted.configuration)
        codec.stopRunning()
    }
    @Test func rawMarkerWithoutImageCannotAdvanceNativeBoundary() throws {
        let session = Session(), recorder = Recorder(), codec = try ready(session, recorder)
        let actual = try frame(1)
        var marker: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
            formatDescription: actual.formatDescription, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &marker) == noErr)
        codec.append(try #require(marker))
        _ = try codec.setVerifiedBitRate(2_000_000)
        #expect(codec.lastBitRateChange?.lastSubmittedSourcePTS == .zero)
        codec.stopRunning()
    }
    private func frame(_ index: Int) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let image = try #require(pixel)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}

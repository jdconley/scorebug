import AVFoundation
import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import HaishinKit

@Suite(.serialized) struct VideoEncoderReplacementTests {
    private final class Session: VTSessionConvertible, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(CMSampleBuffer, PublishingQueue<CMSampleBuffer>?, VideoEncoderCompletionObserver?)] = []
        private var events: [String] = []
        let status: OSStatus
        let gate: Gate?
        init(status: OSStatus = noErr, gate: Gate? = nil) { self.status = status; self.gate = gate }
        var log: [String] { lock.withLock { events } }
        func setOption(_ option: VTSessionOption) -> OSStatus { lock.withLock { events.append("write") }; return noErr }
        func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, nil) }
        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
        func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
            lock.withLock { events.append("submit"); pending.append((sampleBuffer, continuation, encoderCompletionObserver)) }
        }
        func completeFrames() -> OSStatus {
            let work = lock.withLock { events.append("complete"); let work = pending; pending.removeAll(); return work }
            if let gate, !gate.pause() { return -999 }
            for (sample, output, observer) in work {
                observer?(sample.presentationTimeStamp, sample.presentationTimeStamp)
                _ = output?.yield(sample, byteCount: 1)
            }
            return status
        }
        func invalidate() { lock.withLock { events.append("invalidate"); pending.removeAll() } }
    }
    private func frame(_ index: Int) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        let buffer = try #require(image)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
    private var reduced: VideoCodecSettings { .init(videoSize: CGSize(width: 32, height: 32), bitRate: 1_500_000, allowFrameReordering: false) }

    @Test @MainActor func completesPendingFramesBeforeInvalidationAndKeepsOutputOpen() async throws {
        let first = Session(), second = Session()
        var creations = 0
        let codec = VideoCodec(sessionFactory: { _, _ in creations += 1; return creations == 1 ? first : second })
        let output = codec.outputStream
        codec.startRunning(); codec.append(try frame(0)); codec.append(try frame(1))
        let oldSize = codec.settings.videoSize
        let operation = try codec.prepareReplacement(reduced)
        #expect(codec.settings.videoSize == oldSize)
        #expect(first.log == ["submit", "submit"])
        #expect(throws: VideoEncoderReplacementError.notDrained) { try codec.commitReplacement(operation) }
        await Task.detached { operation.drain(); operation.drain() }.value
        #expect(first.log == ["submit", "submit", "complete"])
        try codec.commitReplacement(operation)
        #expect(first.log == ["submit", "submit", "complete", "invalidate"])
        #expect(codec.settings.videoSize == reduced.videoSize)
        codec.append(try frame(2)); #expect(creations == 2)
        let complete = codec.makeCompletion(); await Task.detached { complete() }.value
        codec.stopRunning()
        var ids: [Int64] = []
        for await sample in output { ids.append(sample.presentationTimeStamp.value) }
        #expect(ids == [0, 1, 2]); #expect(codec.failure.error == nil)
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let release = DispatchSemaphore(value: 0)
        func pause() -> Bool {
            lock.withLock { entered = true }
            return release.wait(timeout: .now() + 3) == .success
        }
        func open() { release.signal() }
        func waitForEntry() async throws -> Bool {
            for _ in 0..<1000 {
                if lock.withLock({ entered }) { return true }
                try await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
    }
    @MainActor private func ready(_ session: Session) throws -> VideoCodec {
        let codec = VideoCodec(sessionFactory: { _, _ in session })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        return codec
    }

    @Test @MainActor func rejectsMissingSessionAndConcurrentChangesWithoutNativeMutation() async throws {
        let session = Session(), empty = VideoCodec(sessionFactory: { _, _ in session })
        #expect(throws: VideoEncoderReplacementError.notEncoding) { try empty.prepareReplacement(reduced) }
        empty.startRunning()
        #expect(throws: VideoEncoderReplacementError.notEncoding) { try empty.prepareReplacement(reduced) }
        empty.stopRunning()
        let codec = try ready(session), operation = try codec.prepareReplacement(reduced)
        #expect(throws: VideoEncoderReplacementError.busy) { try codec.prepareReplacement(reduced) }
        #expect(throws: VideoBitRateUpdateError.sessionInvalidated) { try codec.setVerifiedBitRate(2_000_000) }
        #expect(codec.lastBitRateChange == nil); #expect(session.log == ["submit"])
        await Task.detached { operation.drain() }.value
        try codec.commitReplacement(operation)
        #expect(throws: VideoEncoderReplacementError.obsolete) { try codec.commitReplacement(operation) }
        codec.stopRunning()
    }

    @Test @MainActor func nativeCompletionFailureCannotInvalidateOrCommit() async throws {
        let session = Session(status: -77), codec = try ready(session)
        let before = codec.settings.videoSize, operation = try codec.prepareReplacement(reduced)
        await Task.detached { operation.drain() }.value
        #expect(throws: VideoEncoderReplacementError.drainFailed(status: -77)) { try codec.commitReplacement(operation) }
        #expect(codec.failure.error == .codecFailed(status: -77))
        #expect(codec.settings.videoSize == before)
        #expect(session.log == ["submit", "complete"])
        codec.stopRunning(); #expect(session.log.last == "invalidate")
    }

    @Test(arguments: ["input", "settings", "finish"])
    @MainActor func refusesAmbiguousWorkDuringReplacement(action: String) async throws {
        let session = Session(), codec = try ready(session)
        let before = codec.settings.videoSize, operation = try codec.prepareReplacement(reduced)
        switch action {
        case "input": codec.append(try frame(1))
        case "settings": codec.settings = reduced
        default: let finish = codec.makeCompletion(); await Task.detached { finish() }.value
        }
        #expect(codec.failure.error == .outputTerminated(boundary: "video replacement " + action))
        #expect(codec.settings.videoSize == before); #expect(session.log == ["submit"])
        await Task.detached { operation.drain() }.value
        #expect(throws: VideoEncoderReplacementError.notEncoding) { try codec.commitReplacement(operation) }
        codec.stopRunning()
    }

    @Test @MainActor func notificationOrWrongHandleCannotCommit() async throws {
        let first = try ready(Session()), second = try ready(Session())
        let operation = try first.prepareReplacement(reduced), foreign = try second.prepareReplacement(reduced)
        await Task.detached { operation.drain(); foreign.drain() }.value
        #expect(throws: VideoEncoderReplacementError.obsolete) { try first.commitReplacement(foreign) }
        first.requestSessionInvalidation()
        #expect(throws: VideoEncoderReplacementError.obsolete) { try first.commitReplacement(operation) }
        #expect(first.settings.videoSize != reduced.videoSize)
        first.stopRunning(); second.stopRunning()
    }

    @Test @MainActor func repeatedDrainCannotCommitBeforeTheFirstDrainCompletes() async throws {
        let gate = Gate(), session = Session(gate: gate), codec = try ready(session)
        defer { gate.open(); codec.stopRunning() }
        let operation = try codec.prepareReplacement(reduced)
        let drain = Task.detached { operation.drain() }
        #expect(try await gate.waitForEntry())
        await Task.detached { operation.drain() }.value
        #expect(throws: VideoEncoderReplacementError.notDrained) { try codec.commitReplacement(operation) }
        gate.open(); await drain.value
        try codec.commitReplacement(operation)
        #expect(session.log == ["submit", "complete", "invalidate"])
    }

    @Test @MainActor func stopAndRestartRejectLateCompletionWithoutPoisoningNewOutput() async throws {
        let gate = Gate(), first = Session(status: -88, gate: gate), second = Session()
        var creations = 0
        let codec = VideoCodec(sessionFactory: { _, _ in creations += 1; return creations == 1 ? first : second })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        let operation = try codec.prepareReplacement(reduced), oldFailure = codec.failure
        let drain = Task.detached { operation.drain() }
        defer { gate.open(); codec.stopRunning() }
        #expect(try await gate.waitForEntry())
        drain.cancel() // Native completion must still be joined after cancellation.
        codec.stopRunning()
        #expect(first.log == ["submit", "complete", "invalidate"])
        codec.failure = PublishingFailureLatch()
        let output = codec.outputStream
        codec.startRunning(); codec.append(try frame(1))
        let liveSize = codec.settings.videoSize
        gate.open(); await drain.value
        #expect(throws: VideoEncoderReplacementError.obsolete) { try codec.commitReplacement(operation) }
        #expect(codec.isRunning); #expect(codec.settings.videoSize == liveSize)
        #expect(codec.failure.error == nil); #expect(oldFailure.error == nil)
        let complete = codec.makeCompletion(); await Task.detached { complete() }.value
        codec.stopRunning()
        var ids: [Int64] = []; for await sample in output { ids.append(sample.presentationTimeStamp.value) }
        #expect(ids == [1]); #expect(second.log == ["submit", "complete", "invalidate"])
    }

    @Test @MainActor func replacementCreationFailureCannotResumeTheOldEncoder() async throws {
        let first = Session(); var creations = 0
        let codec = VideoCodec(sessionFactory: { _, _ in
            creations += 1
            if creations == 1 { return first }
            throw VTSessionError.failedToCreate(status: -91)
        })
        let output = codec.outputStream
        codec.startRunning(); codec.append(try frame(0))
        let operation = try codec.prepareReplacement(reduced)
        await Task.detached { operation.drain() }.value
        try codec.commitReplacement(operation); codec.append(try frame(1))
        #expect(codec.failure.error == .codecFailed(status: -91)); #expect(codec.session == nil)
        #expect(first.log == ["submit", "complete", "invalidate"])
        let complete = codec.makeCompletion(); await Task.detached { complete() }.value
        codec.stopRunning()
        var ids: [Int64] = []; for await sample in output { ids.append(sample.presentationTimeStamp.value) }
        #expect(ids == [0])
    }

    @Test @MainActor func realEncoderDrainsBothFormatsThroughTheSameBoundedOutput() async throws {
        let codec = VideoCodec()
        codec.settings = .init(videoSize: CGSize(width: 64, height: 64),
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String, allowFrameReordering: false)
        let output = codec.outputStream
        let consumer = Task.detached { () -> [(Int64, Int32)] in
            var values: [(Int64, Int32)] = []
            for await sample in output {
                let width = sample.formatDescription.map { CMVideoFormatDescriptionGetDimensions($0).width } ?? 0
                values.append((sample.presentationTimeStamp.value, width))
            }
            return values
        }
        codec.startRunning()
        for i in 0..<20 { codec.append(try frame(i)) }
        let operation = try codec.prepareReplacement(reduced)
        await Task.detached { operation.drain() }.value
        try codec.commitReplacement(operation)
        for i in 20..<40 { codec.append(try frame(i)) }
        let complete = codec.makeCompletion(); await Task.detached { complete() }.value
        codec.stopRunning()
        let values = await consumer.value
        #expect(values.map(\.0) == (0..<40).map(Int64.init))
        #expect(values.map(\.1) == Array(repeating: Int32(64), count: 20) + Array(repeating: Int32(32), count: 20))
        #expect(codec.failure.error == nil); #expect(codec.outputLimits.count == 8)
    }

    @Test(arguments: [false, true])
    @MainActor func terminalCompletionExcludesReplacement(started: Bool) async throws {
        let gate = Gate(), session = Session(gate: gate), codec = try ready(session)
        defer { gate.open(); codec.stopRunning() }
        let complete = codec.makeCompletion()
        let running: Task<Void, Never>?
        if started {
            running = Task.detached { complete() }
            #expect(try await gate.waitForEntry())
        } else { running = nil }
        #expect(throws: VideoEncoderReplacementError.notEncoding) { try codec.prepareReplacement(reduced) }
        gate.open()
        if let running { await running.value }
        else { await Task.detached { complete() }.value }
        #expect(session.log == ["submit", "complete"])
    }

}

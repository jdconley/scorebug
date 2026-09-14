@preconcurrency import AVFoundation
import XCTest
@testable import ScorebugMedia

@MainActor final class RecordingSessionTests: XCTestCase {
    #if DEBUG
    func testDiagnosticsFreezeExactOverflowWithBlockedAppendAndIgnoreLaterCompletion() async throws {
        let gate = RecordingGate()
        let sink = RecordingTestSink(appendGate: gate)
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "overflow", now: clock.now)
        let sample = try audio(0)
        let session = try RecordingSession(sink: sink, maxItems: 2, maxBytes: sample.retainedByteCount * 2)
        XCTAssertTrue(session.attachArchivePressureDiagnostics(owner))
        XCTAssertFalse(session.attachArchivePressureDiagnostics(owner))
        try await session.start(at: .zero)
        XCTAssertFalse(session.attachArchivePressureDiagnostics(ArchivePressureDiagnostics(recordingID: "late")))
        XCTAssertTrue(session.offer(sample))
        await gate.waitUntilEntered()
        clock.advance(3)
        XCTAssertTrue(session.offer(try audio(1)))
        XCTAssertTrue(session.offer(try audio(2)))
        XCTAssertFalse(session.offer(try audio(3)))
        let frozen = try XCTUnwrap(owner.snapshot.firstFailure)
        XCTAssertEqual(frozen.queue?.currentItems, "2")
        XCTAssertEqual(frozen.queue?.currentBytes, "6400")
        XCTAssertEqual(frozen.queue?.rejectedCount, "1")
        XCTAssertEqual(frozen.queue?.droppedCount, "0")
        XCTAssertEqual(frozen.rejection, "full")
        XCTAssertEqual(frozen.sample?.pts.value, "3")
        XCTAssertEqual(frozen.writtenSamples, "0")
        XCTAssertEqual(frozen.observations.activeConsumer?.phase, .append)
        XCTAssertEqual(frozen.observations.activeConsumer?.appendElapsed, 3)
        XCTAssertEqual(frozen.observations.activeConsumer?.falseCount, "0")
        XCTAssertNil(frozen.observations.activeConsumer?.readinessSince)
        XCTAssertFalse(frozen.coverage.persistence)
        clock.advance(4)
        gate.release()
        await assertFailure(session, .overflow)
        let final = owner.close(snapshot: session.snapshot)
        XCTAssertEqual(final.firstFailure, frozen)
        XCTAssertEqual(final.terminal?.queue.currentItems, "0")
        XCTAssertEqual(final.terminal?.queue.droppedCount, "2")
        XCTAssertEqual(final.queueLimits?.maxItems, "2")
        XCTAssertEqual(final.observations.audioAccepted, "3")
        XCTAssertEqual(final.observations.audioRejected, "1")
    }

    func testDiagnosticsMeasureControlledRetryCallsAndWaitWithoutChangingOrder() async throws {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "retry", now: clock.now)
        let sink = RecordingTestSink(rejections: 2, appendAction: { clock.advance(1) })
        let retry = RecordingRetryClock(now: { clock.origin.duration(to: clock.now()) }, sleep: { _ in clock.advance(2.5) })
        let session = try RecordingSession(sink: sink, backpressureLimit: .seconds(20),
            retryInterval: .seconds(2), retryClock: retry)
        XCTAssertTrue(session.attachArchivePressureDiagnostics(owner))
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        XCTAssertTrue(session.offer(try audio(1)))
        _ = try await session.stop()
        let complete = owner.close(snapshot: session.snapshot).observations.consumers.completed
        XCTAssertEqual(sink.attempts, [0, 0, 0, 1])
        XCTAssertEqual(sink.values, [0, 1])
        XCTAssertEqual(complete[0].appendElapsed, 3)
        XCTAssertEqual(complete[0].appendMaximum, 1)
        XCTAssertEqual(complete[0].retryWaitElapsed, 5)
        XCTAssertEqual(complete[0].readinessElapsed, 7)
        XCTAssertEqual(complete[0].attemptCount, "3")
    }

    func testDiagnosticsKeepOversleepPendingWaitAndAppendThrow() async throws {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "oversleep", now: clock.now)
        let sink = RecordingTestSink(rejections: 1)
        let retry = RecordingRetryClock(now: { clock.origin.duration(to: clock.now()) }, sleep: { _ in clock.advance(3) })
        let session = try RecordingSession(sink: sink, retryClock: retry)
        XCTAssertTrue(session.attachArchivePressureDiagnostics(owner))
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        await assertFailure(session, .backpressureTimedOut)
        let active = owner.snapshot.firstFailure?.observations.activeConsumer
        XCTAssertEqual(sink.attempts, [0])
        XCTAssertEqual(active?.phase, .retryWait)
        XCTAssertEqual(active?.retryWaitElapsed, 3)
        XCTAssertEqual(active?.appendElapsed, 0)
        let failedOwner = ArchivePressureDiagnostics(recordingID: "throw", now: clock.now)
        let throwing = try RecordingSession(sink: RecordingTestSink(failure: .append, appendAction: { clock.advance(2) }))
        XCTAssertTrue(throwing.attachArchivePressureDiagnostics(failedOwner))
        try await throwing.start(at: .zero)
        XCTAssertTrue(throwing.offer(try audio(0)))
        await assertFailure(throwing, .sinkFailed)
        XCTAssertEqual(failedOwner.snapshot.firstFailure?.observations.activeConsumer?.appendElapsed, 2)
        XCTAssertEqual(failedOwner.snapshot.firstFailure?.observations.activeConsumer?.lastAppendResult, .failure)
    }

    func testUnattachedDiagnosticsClockIsNeverReadBySession() async throws {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "unused", now: clock.now)
        let initial = clock.reads
        let session = try RecordingSession(sink: RecordingTestSink())
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        _ = try await session.stop()
        XCTAssertEqual(clock.reads, initial)
        XCTAssertFalse(owner.snapshot.coverage.session)
    }
    #endif

    func testOfflineStartDrainsInOrderAndStopIsIdempotent() async throws {
        let sink = RecordingTestSink()
        let session = try RecordingSession(sink: sink)
        XCTAssertFalse(session.offer(try audio(0)))
        try await session.start(at: CMTime(value: 5, timescale: 1))
        for i in 0..<12 { XCTAssertTrue(session.offer(try audio(i))) }
        async let first = session.stop()
        async let second = session.stop()
        _ = try await (first, second)
        XCTAssertEqual(sink.values, Array(0..<12))
        XCTAssertEqual(sink.startTime, CMTime(value: 5, timescale: 1))
        XCTAssertEqual(sink.finishCount, 1)
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertEqual(session.snapshot.writtenSamples, 12)
        XCTAssertFalse(session.offer(try audio(13)))
        do { try await session.start(at: .zero); XCTFail("One use") } catch {}
    }

    func testTemporaryBackpressureRetriesSameSampleWithoutReordering() async throws {
        let sink = RecordingTestSink(rejections: 3)
        let clock = RecordingTestClock()
        let session = try RecordingSession(sink: sink, retryClock: clock.clock)
        try await session.start(at: .zero)
        for i in 0..<10 { XCTAssertTrue(session.offer(try audio(i))) }
        _ = try await session.stop()
        XCTAssertEqual(sink.values, Array(0..<10))
        XCTAssertEqual(sink.attempts, [0, 0, 0, 0] + Array(1..<10))
        XCTAssertEqual(clock.sleeps, 3)
    }

    func testBackpressureHasFiniteDeadline() async throws {
        let sink = RecordingTestSink(rejections: .max)
        let clock = RecordingTestClock()
        let session = try RecordingSession(sink: sink, backpressureLimit: .milliseconds(6),
                                           retryInterval: .milliseconds(2), retryClock: clock.clock)
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        await assertFailure(session, .backpressureTimedOut)
        XCTAssertEqual(clock.sleeps, 3)
        XCTAssertEqual(sink.finishCount, 0)
        XCTAssertEqual(sink.cancelCount, 1)
    }

    func testSchedulerOversleepCannotAcceptSampleAfterRetryDeadline() async throws {
        let sink = RecordingTestSink(rejections: 1)
        let clock = RecordingTestClock().clock
        let oversleep = RecordingRetryClock(now: clock.now, sleep: { _ in try await clock.sleep(.seconds(3)) })
        let session = try RecordingSession(sink: sink, retryClock: oversleep)
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        await assertFailure(session, .backpressureTimedOut)
        XCTAssertEqual(sink.attempts, [0], "Do not try a now-ready sink after the finite deadline")
        XCTAssertTrue(sink.values.isEmpty)
    }

    func testOverflowLatchesFailureAndBoundsQueuedMemory() async throws {
        let gate = RecordingGate()
        let sink = RecordingTestSink(appendGate: gate)
        let sample = try audio(0)
        let session = try RecordingSession(sink: sink, maxItems: 2, maxBytes: sample.retainedByteCount * 2)
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(sample))
        await gate.waitUntilEntered()
        XCTAssertTrue(session.offer(try audio(1)))
        XCTAssertTrue(session.offer(try audio(2)))
        XCTAssertEqual(session.snapshot.queue.currentItems, 2)
        XCTAssertEqual(session.snapshot.queue.currentBytes, sample.retainedByteCount * 2)
        XCTAssertFalse(session.offer(try audio(3)))
        XCTAssertEqual(session.snapshot.state, .failed)
        XCTAssertLessThanOrEqual(session.snapshot.queue.peakBytes, sample.retainedByteCount * 2)
        gate.release()
        await assertFailure(session, .overflow)
        XCTAssertEqual(sink.finishCount, 0)
    }

    func testCaptureFailureDuringFinishCannotBecomeSuccess() async throws {
        let gate = RecordingAsyncGate()
        let sink = RecordingTestSink(finishGate: gate)
        let session = try RecordingSession(sink: sink)
        try await session.start(at: .zero)
        let stop = Task { try await session.stop() }
        await gate.waitUntilEntered()
        session.failCapture(reason: "Capture interrupted")
        let deadline = ContinuousClock.now + .milliseconds(200)
        while sink.cancelCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(sink.cancelCount, 1, "Source failure must cancel pending finalization")
        // Safety release only on a broken implementation, so a red run terminates.
        if sink.cancelCount == 0 { gate.release() }
        do { _ = try await stop.value; XCTFail("Failure must win") }
        catch { XCTAssertEqual(error as? RecordingSessionError, .captureFailed("Capture interrupted")) }
        await assertFailure(session, .captureFailed("Capture interrupted"))
    }

    func testSinkStartAppendAndFinishErrorsLatchFailure() async throws {
        for point in RecordingTestSink.Failure.allCases {
            let sink = RecordingTestSink(failure: point)
            let session = try RecordingSession(sink: sink)
            if point == .start {
                do { try await session.start(at: .zero); XCTFail("Start should fail") } catch {}
            } else {
                try await session.start(at: .zero)
                XCTAssertTrue(session.offer(try audio(0)))
            }
            await assertFailure(session, .sinkFailed)
            XCTAssertEqual(sink.cancelCount, 1)
        }
    }

    func testCancelledStopWaiterStillJoinsGracefulDrain() async throws {
        let gate = RecordingAsyncGate()
        let sink = RecordingTestSink(finishGate: gate)
        let session = try RecordingSession(sink: sink)
        try await session.start(at: .zero)
        let stop = Task { try await session.stop() }
        await gate.waitUntilEntered()
        stop.cancel()
        gate.release()
        _ = try await stop.value
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertEqual(sink.cancelCount, 0)
    }

    func testExplicitCancelUnblocksPendingFinishAndAllStopWaitersFail() async throws {
        let gate = RecordingAsyncGate()
        let sink = RecordingTestSink(finishGate: gate)
        let session = try RecordingSession(sink: sink)
        try await session.start(at: .zero)
        let first = Task { try await session.stop() }
        let second = Task { try await session.stop() }
        await gate.waitUntilEntered()
        session.cancel()
        for result in [await first.result, await second.result] {
            switch result {
            case .success: XCTFail("Cancellation must not finish")
            case .failure(let error): XCTAssertEqual(error as? RecordingSessionError, .cancelled)
            }
        }
        XCTAssertEqual(session.snapshot.state, .failed)
        XCTAssertEqual(sink.finishCount, 1)
        XCTAssertEqual(sink.cancelCount, 1)
    }

    func testFailedStopJoinsCancellationAlreadyRunningOffWorker() async throws {
        let appendGate = RecordingGate()
        let cancelGate = RecordingGate()
        let sink = RecordingTestSink(failure: .append, appendGate: appendGate, cancelGate: cancelGate)
        let session = try RecordingSession(sink: sink)
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        await appendGate.waitUntilEntered()
        session.failCapture(reason: "Capture interrupted")
        await cancelGate.waitUntilEntered()
        let completion = RecordingCompletionFlag()
        let stopped = Task {
            let result = await Task { try await session.stop() }.result
            completion.set()
            return result
        }
        appendGate.release()
        let deadline = ContinuousClock.now + .milliseconds(200)
        while !completion.value && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(completion.value, "Failed stop must join sink teardown before returning")
        XCTAssertEqual(sink.cancelCount, 1)
        cancelGate.release()
        switch await stopped.value {
        case .success: XCTFail("Failure must stay latched")
        case .failure(let error): XCTAssertEqual(error as? RecordingSessionError, .captureFailed("Capture interrupted"))
        }
        XCTAssertTrue(completion.value)
        XCTAssertEqual(sink.cancelCount, 1)
    }

    func testReleasingIdleOwnerReleasesCoreAndSink() async throws {
        var sink: RecordingTestSink? = RecordingTestSink()
        weak let releasedSink = sink
        var session: RecordingSession? = try RecordingSession(sink: sink!)
        try await session!.start(at: .zero)
        sink = nil
        session = nil
        let deadline = ContinuousClock.now + .seconds(1)
        while releasedSink != nil && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNil(releasedSink, "The worker and core must release each other after owner teardown")
    }

    func testExplicitCancelFailsAndDroppingSessionReleasesWorker() async throws {
        let sink = RecordingTestSink()
        var session: RecordingSession? = try RecordingSession(sink: sink)
        weak let weakSession = session
        try await session!.start(at: .zero)
        session!.cancel()
        await assertFailure(session!, .cancelled)
        session = nil
        XCTAssertNil(weakSession)
        XCTAssertEqual(sink.cancelCount, 1)
        let idleSink = RecordingTestSink()
        var idle: RecordingSession? = try RecordingSession(sink: idleSink)
        try await idle!.start(at: .zero)
        idle = nil
        for _ in 0..<1_000 where idleSink.cancelCount == 0 { await Task.yield() }
        XCTAssertEqual(idleSink.cancelCount, 1)
    }

    func testStopBeforeStartDoesNotPoisonFutureStart() async throws {
        let sink = RecordingTestSink()
        let session = try RecordingSession(sink: sink)
        await assertInvalidStop(session)
        try await session.start(at: .zero)
        XCTAssertTrue(session.offer(try audio(0)))
        _ = try await session.stop()
        XCTAssertEqual(sink.values, [0])
    }

    func testConcurrentStopDuringStartClosesIngressAndJoinsWorker() async throws {
        let gate = RecordingGate()
        let sink = RecordingTestSink(startGate: gate)
        let session = try RecordingSession(sink: sink)
        let start = Task { try await session.start(at: .zero) }
        await gate.waitUntilEntered()
        XCTAssertEqual(session.snapshot.state, .starting)
        XCTAssertFalse(session.offer(try audio(0)))
        let stop = Task { try await session.stop() }
        while session.snapshot.state == .starting { await Task.yield() }
        gate.release()
        try await start.value
        _ = try await stop.value
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertEqual(sink.finishCount, 1)
        XCTAssertTrue(sink.values.isEmpty)
    }

    func testCaptureFailureDuringStartCannotBecomeRecording() async throws {
        let gate = RecordingGate()
        let sink = RecordingTestSink(startGate: gate)
        let session = try RecordingSession(sink: sink)
        let start = Task { try await session.start(at: .zero) }
        await gate.waitUntilEntered()
        session.failCapture(reason: "Dropped sample")
        gate.release()
        do { try await start.value; XCTFail("Startup cannot erase source failure") } catch {}
        await assertFailure(session, .captureFailed("Dropped sample"))
    }

    func testByteBudgetRejectsOversizedSingleSample() async throws {
        let sink = RecordingTestSink()
        let sample = try audio(0)
        let session = try RecordingSession(sink: sink, maxBytes: sample.retainedByteCount - 1)
        try await session.start(at: .zero)
        XCTAssertFalse(session.offer(sample))
        await assertFailure(session, .overflow)
        XCTAssertEqual(session.snapshot.queue.peakBytes, 0)
        XCTAssertTrue(sink.values.isEmpty)
    }

    func testNativeSinkEncodesOfflineAudioAndVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let writer = try SegmentedArchiveWriter(directory: directory, profile: profile)
        let session = try RecordingSession(sink: SegmentedArchiveSink(writer: writer))
        try await session.start(at: .zero)
        for index in 0..<2 {
            let sample = try video(index)
            let pixel = try XCTUnwrap(sample.sampleBuffer.imageBuffer)
            XCTAssertEqual(sample.retainedByteCount, CVPixelBufferGetDataSize(pixel))
            XCTAssertTrue(session.offer(sample))
            XCTAssertTrue(session.offer(try audio(index)))
        }
        let archive = try await session.stop()
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertEqual(writer.snapshot.videoFrames, 2)
        XCTAssertEqual(writer.snapshot.audioSamples, 3200)
        XCTAssertTrue(archive.segments.contains { $0.kind == .media })
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: directory).segments, archive.segments)
        session.failCapture(reason: "Late callback")
        session.cancel()
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertNil(session.snapshot.failure)
    }

    private func assertInvalidStop(_ session: RecordingSession) async {
        do { _ = try await session.stop(); XCTFail("Not started") }
        catch { XCTAssertEqual(error as? RecordingSessionError, .invalidState) }
        XCTAssertEqual(session.snapshot.state, .prepared)
    }

    func testSampleCountsPayloadAndRejectsMismatchedKind() throws {
        let sample = try audio(0)
        XCTAssertEqual(sample.retainedByteCount, 3200)
        XCTAssertEqual(sample.kind, .audio)
        XCTAssertThrowsError(try CapturedMediaSample(sampleBuffer: sample.sampleBuffer, kind: .video))
    }

    private func assertFailure(_ session: RecordingSession, _ expected: RecordingSessionError) async {
        do { _ = try await session.stop(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? RecordingSessionError, expected) }
        XCTAssertEqual(session.snapshot.state, .failed)
        XCTAssertEqual(session.snapshot.failure, expected)
    }
}

private final class RecordingTestSink: RecordingArchiveSink, @unchecked Sendable {
    enum Failure: CaseIterable { case start, append, finish }
    let lock = NSLock()
    private var storedValues: [Int] = []
    private var storedAttempts: [Int] = []
    private var storedFinishCount = 0
    private var storedCancelCount = 0
    private var storedStartTime: CMTime?
    private var rejections: Int
    let failure: Failure?
    let appendAction: (@Sendable () -> Void)?
    let startGate: RecordingGate?
    let appendGate: RecordingGate?
    let finishGate: RecordingAsyncGate?
    let cancelGate: RecordingGate?
    var values: [Int] { lock.withLock { storedValues } }
    var attempts: [Int] { lock.withLock { storedAttempts } }
    var finishCount: Int { lock.withLock { storedFinishCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var startTime: CMTime? { lock.withLock { storedStartTime } }
    init(rejections: Int = 0, failure: Failure? = nil, startGate: RecordingGate? = nil, appendGate: RecordingGate? = nil,
         finishGate: RecordingAsyncGate? = nil, cancelGate: RecordingGate? = nil,
         appendAction: (@Sendable () -> Void)? = nil) {
        self.appendAction = appendAction
        self.rejections = rejections; self.failure = failure
        self.startGate = startGate; self.appendGate = appendGate; self.finishGate = finishGate
        self.cancelGate = cancelGate
    }
    func start(at timestamp: CMTime) throws {
        startGate?.block()
        if failure == .start { throw ArchiveWriterError.encodingFailed }
        lock.withLock { storedStartTime = timestamp }
    }
    func append(_ sample: CapturedMediaSample) throws -> Bool {
        appendGate?.block()
        appendAction?()
        if failure == .append { throw ArchiveWriterError.encodingFailed }
        return lock.withLock {
            let value = Int(sample.sampleBuffer.presentationTimeStamp.value)
            storedAttempts.append(value)
            if rejections > 0 { rejections -= 1; return false }
            storedValues.append(value)
            return true
        }
    }
    func finish() async throws -> RecoveredArchive {
        lock.withLock { storedFinishCount += 1 }
        await finishGate?.block()
        if failure == .finish { throw ArchiveWriterError.storageFailed }
        return RecoveredArchive(directory: URL(fileURLWithPath: "/unused"), profile: ArchiveProfile(), segments: [])
    }
    func cancel() {
        lock.withLock { storedCancelCount += 1 }
        cancelGate?.block()
        finishGate?.release()
    }
}

private final class RecordingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private var count = 0
    var sleeps: Int { lock.withLock { count } }
    var clock: RecordingRetryClock {
        RecordingRetryClock(now: { self.lock.withLock { self.time } }, sleep: { duration in
            self.lock.withLock { self.time += duration; self.count += 1 }
        })
    }
}

private final class RecordingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    func block() {
        let first = lock.withLock { let first = !entered; entered = true; return first }
        if first { XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success) }
    }
    func waitUntilEntered() async { while !lock.withLock({ entered }) { await Task.yield() } }
    func release() { semaphore.signal() }
}

private final class RecordingAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() async {
        await withCheckedContinuation { pending in
            let immediate = lock.withLock {
                entered = true
                if released { return true }
                continuation = pending
                return false
            }
            if immediate { pending.resume() }
        }
    }
    func waitUntilEntered() async { while !lock.withLock({ entered }) { await Task.yield() } }
    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}

private func audio(_ index: Int) throws -> CapturedMediaSample {
    var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
        mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format), noErr)
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: 3200, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: 3200, flags: 0, blockBufferOut: &block), noErr)
    let data = try XCTUnwrap(block)
    XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: 3200), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
    var sampleSize = 2
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
        formatDescription: try XCTUnwrap(format), sampleCount: 1600, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .audio)
}

private func video(_ index: Int) throws -> CapturedMediaSample {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 32 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
}

private final class RecordingCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.withLock { completed } }
    func set() { lock.withLock { completed = true } }
}

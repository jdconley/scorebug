@preconcurrency import AVFoundation
import XCTest
@testable import ScorebugMedia

@MainActor final class PublishingSessionTests: XCTestCase {
    func testReadinessRejectsSamplesUntilStartCompletesAndCannotRestart() async throws {
        let gate = PublishingGate()
        let publisher = PublisherFixture(startGate: gate)
        let session = try PublishingSession(publisher: publisher)
        let sample = try publishingAudio(1)
        XCTAssertFalse(session.offer(sample))
        let start = Task { try await session.start() }
        await gate.waitUntilEntered()
        XCTAssertEqual(session.snapshot.state, .starting)
        XCTAssertFalse(session.offer(sample))
        gate.release()
        try await start.value
        XCTAssertEqual(session.snapshot.state, .publishing)
        XCTAssertTrue(session.offer(sample))
        await eventually { publisher.seconds == [1] }
        await session.stop()
        XCTAssertEqual(session.snapshot.state, .stopped)
        XCTAssertFalse(session.offer(sample))
        do { try await session.start(); XCTFail("Sessions are one-use") }
        catch { XCTAssertEqual(error as? PublishingSessionError, .invalidState) }
        XCTAssertEqual(publisher.starts, 1)
        XCTAssertEqual(publisher.stops, 1)
    }

    func testStartFailureJoinsPublisherCleanupAndLatchesSanitizedFailure() async throws {
        let publisher = PublisherFixture(startFails: true)
        let session = try PublishingSession(publisher: publisher)
        do { try await session.start(); XCTFail("Expected startup failure") }
        catch { XCTAssertEqual(error as? PublishingSessionError, .startFailed) }
        XCTAssertEqual(session.snapshot.failure, .startFailed)
        XCTAssertEqual(session.snapshot.state, .failed)
        XCTAssertEqual(publisher.stops, 1)
        await session.stop()
        XCTAssertEqual(publisher.stops, 1)
    }

    func testAppendFailureClosesIngressAndAutomaticallyStopsPublisher() async throws {
        let publisher = PublisherFixture(appendFails: true)
        let session = try PublishingSession(publisher: publisher)
        try await session.start()
        XCTAssertTrue(session.offer(try publishingAudio(1)))
        await eventually { session.snapshot.failure == .appendFailed }
        await session.stop()
        XCTAssertFalse(session.offer(try publishingAudio(2)))
        XCTAssertEqual(session.snapshot.sentSamples, 0)
        XCTAssertEqual(publisher.stops, 1)
    }

    func testHealthMonitorDetectsIdleFailureWithoutSamples() async throws {
        let publisher = PublisherFixture()
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        try await session.start()
        publisher.markUnhealthy()
        await eventually { session.snapshot.failure == .publisherUnhealthy }
        await session.stop()
        XCTAssertEqual(session.snapshot.sentSamples, 0)
        XCTAssertEqual(publisher.stops, 1)
    }

    func testStopUnblocksSuspendedHealthAndJoinsMonitorBeforeReturning() async throws {
        let publisher = SuspendedHealthPublisher()
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        try await session.start()
        await eventually { publisher.healthGate.hasEntered }
        let stop = Task { await session.stop() }
        await eventually { publisher.healthCompletionGate.hasEntered }
        XCTAssertEqual(publisher.stops, 1, "Publisher stop must unblock the suspended health query")
        XCTAssertFalse(publisher.healthReturned)
        XCTAssertEqual(session.snapshot.state, .stopping, "Stop must join the monitor after publisher.stop returns")
        publisher.healthCompletionGate.release()
        await stop.value
        XCTAssertTrue(publisher.healthReturned)
        XCTAssertEqual(session.snapshot.state, .stopped)
        XCTAssertNil(session.snapshot.failure)
    }

    func testQueueDropsOldestByCountAndBytesAndRejectsOversizeWithoutEviction() async throws {
        for limits in [(2, 100), (8, 4)] {
            let gate = PublishingGate()
            let publisher = PublisherFixture(appendGate: gate)
            let session = try PublishingSession(publisher: publisher, maxItems: limits.0, maxBytes: limits.1)
            try await session.start()
            XCTAssertTrue(session.offer(try publishingAudio(0)))
            await gate.waitUntilEntered()
            for second in 1...4 { XCTAssertTrue(session.offer(try publishingAudio(Int64(second)))) }
            XCTAssertEqual(session.snapshot.queue.currentItems, 2)
            XCTAssertEqual(session.snapshot.queue.currentBytes, 4)
            XCTAssertEqual(session.snapshot.queue.droppedCount, 2)
            XCTAssertFalse(session.offer(try publishingAudio(99, bytes: 102)))
            XCTAssertEqual(session.snapshot.queue.rejectedCount, 1)
            XCTAssertEqual(session.snapshot.queue.currentItems, 2)
            XCTAssertNil(session.snapshot.failure)
            gate.release()
            await eventually { publisher.seconds.count == 3 }
            XCTAssertEqual(publisher.seconds, [0, 3, 4], "Stale queued media is evicted")
            await session.stop()
            XCTAssertEqual(session.snapshot.sentSamples, 3)
        }
    }

    func testStopDuringStartupUnblocksStartAndCannotResurrect() async throws {
        let gate = PublishingGate()
        let publisher = PublisherFixture(startGate: gate)
        let session = try PublishingSession(publisher: publisher)
        let start = Task { try await session.start() }
        await gate.waitUntilEntered()
        await session.stop()
        do { try await start.value; XCTFail("Stopped startup cannot succeed") }
        catch { XCTAssertEqual(error as? PublishingSessionError, .cancelled) }
        XCTAssertEqual(session.snapshot.state, .stopped)
        XCTAssertFalse(session.offer(try publishingAudio(1)))
        XCTAssertEqual(publisher.stops, 1)
    }

    func testStopUnblocksAppendDiscardsQueueAndJoinsCancelledConcurrentWaiters() async throws {
        let appendGate = PublishingGate()
        let stopGate = PublishingGate()
        let publisher = PublisherFixture(appendGate: appendGate, stopGate: stopGate)
        let session = try PublishingSession(publisher: publisher)
        try await session.start()
        XCTAssertTrue(session.offer(try publishingAudio(0)))
        await appendGate.waitUntilEntered()
        XCTAssertTrue(session.offer(try publishingAudio(1)))
        let first = Task { await session.stop() }
        await stopGate.waitUntilEntered()
        let second = Task { await session.stop() }
        first.cancel(); second.cancel()
        XCTAssertEqual(session.snapshot.state, .stopping)
        XCTAssertEqual(session.snapshot.queue.currentItems, 0)
        XCTAssertEqual(session.snapshot.queue.droppedCount, 1)
        XCTAssertFalse(session.offer(try publishingAudio(2)))
        stopGate.release()
        await first.value; await second.value
        XCTAssertEqual(session.snapshot.state, .stopped)
        XCTAssertEqual(publisher.stops, 1)
        XCTAssertTrue(publisher.appendReturned)
    }

    func testExplicitCancelIsLatchedAndCleanupIsJoined() async throws {
        let publisher = PublisherFixture()
        let session = try PublishingSession(publisher: publisher)
        try await session.start()
        session.cancel()
        await session.stop()
        XCTAssertEqual(session.snapshot.failure, .cancelled)
        XCTAssertEqual(session.snapshot.state, .failed)
        XCTAssertEqual(publisher.stops, 1)
    }

    func testOwnerDeinitSchedulesCleanupWithoutIdleWorkerRetainingOwner() async throws {
        let publisher = PublisherFixture()
        var session: PublishingSession? = try PublishingSession(publisher: publisher)
        weak let owner = session
        try await session!.start()
        session = nil
        XCTAssertNil(owner)
        await eventually { publisher.stops == 1 }
    }

    func testTapAttachesLateReplacesSessionAndGuardsStaleDetach() async throws {
        let tap = PublishingTap()
        let one = PublisherFixture(), two = PublisherFixture()
        let first = try PublishingSession(publisher: one), second = try PublishingSession(publisher: two)
        try await first.start(); try await second.start()
        XCTAssertFalse(tap.offer(try publishingAudio(0)))
        XCTAssertTrue(tap.attach(first))
        XCTAssertTrue(tap.offer(try publishingAudio(1)))
        await eventually { one.seconds == [1] }
        XCTAssertTrue(tap.attach(second))
        tap.detach(first)
        XCTAssertTrue(tap.offer(try publishingAudio(2)))
        await eventually { two.seconds == [2] }
        tap.detach(second)
        XCTAssertFalse(tap.offer(try publishingAudio(3)))
        XCTAssertEqual(first.snapshot.state, .publishing, "Tap does not own stop policy")
        await first.stop(); await second.stop()
    }

    func testDefaultLimitsBoundEightItemsAndTwelveMiBIndependently() async throws {
        for bytes in [2, 2 * 1024 * 1024] {
            let gate = PublishingGate()
            let publisher = PublisherFixture(appendGate: gate)
            let session = try PublishingSession(publisher: publisher)
            try await session.start()
            session.offer(try publishingAudio(0))
            await gate.waitUntilEntered()
            let sample = try publishingAudio(1, bytes: bytes)
            for _ in 0..<10 { XCTAssertTrue(session.offer(sample)) }
            let expectedItems = bytes == 2 ? 8 : 6
            XCTAssertEqual(session.snapshot.queue.currentItems, expectedItems)
            XCTAssertEqual(session.snapshot.queue.currentBytes, expectedItems * bytes)
            XCTAssertEqual(session.snapshot.queue.droppedCount, 10 - expectedItems)
            await session.stop()
        }
    }

    func testCancelledStartWaiterDoesNotAbandonReadiness() async throws {
        let gate = PublishingGate()
        let publisher = PublisherFixture(startGate: gate)
        let session = try PublishingSession(publisher: publisher)
        let start = Task { try await session.start() }
        await gate.waitUntilEntered()
        start.cancel()
        gate.release()
        try await start.value
        XCTAssertEqual(session.snapshot.state, .publishing)
        await session.stop()
    }

    func testUnhealthyReadinessNeverAdmitsSamples() async throws {
        let publisher = PublisherFixture(unhealthyAtStart: true)
        let session = try PublishingSession(publisher: publisher)
        do { try await session.start(); XCTFail("Readiness must be healthy") }
        catch { XCTAssertEqual(error as? PublishingSessionError, .publisherUnhealthy) }
        XCTAssertFalse(session.offer(try publishingAudio(1)))
        XCTAssertEqual(publisher.stops, 1)
    }

    func testStopBeforeStartIsTerminalAndReleasesPublisherOnce() async throws {
        let publisher = PublisherFixture()
        let session = try PublishingSession(publisher: publisher)
        await session.stop()
        await session.stop()
        XCTAssertEqual(session.snapshot.state, .stopped)
        do { try await session.start(); XCTFail("Stopped instances are not reusable") }
        catch { XCTAssertEqual(error as? PublishingSessionError, .invalidState) }
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertEqual(publisher.stops, 1)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }
}

private final class PublisherFixture: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var ended = false
    private var startCount = 0, stopCount = 0
    private var timestamps: [Int64] = []
    private var didReturnAppend = false
    let startGate: PublishingGate?, appendGate: PublishingGate?, stopGate: PublishingGate?
    let startFails: Bool, appendFails: Bool, unhealthyAtStart: Bool
    init(startGate: PublishingGate? = nil, appendGate: PublishingGate? = nil,
         stopGate: PublishingGate? = nil, startFails: Bool = false, appendFails: Bool = false, unhealthyAtStart: Bool = false) {
        self.startGate = startGate; self.appendGate = appendGate; self.stopGate = stopGate
        self.startFails = startFails; self.appendFails = appendFails; self.unhealthyAtStart = unhealthyAtStart
    }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var seconds: [Int64] { lock.withLock { timestamps } }
    var appendReturned: Bool { lock.withLock { didReturnAppend } }
    var isPublishing: Bool { get async { lock.withLock { active } } }
    func start() async throws {
        lock.withLock { startCount += 1 }
        await startGate?.block()
        if startFails { throw FixtureError.sensitiveTransportDetail }
        try lock.withLock {
            if ended { throw CancellationError() }
            active = !unhealthyAtStart
        }
    }
    func append(_ sample: CapturedMediaSample) async throws {
        await appendGate?.block()
        lock.withLock { didReturnAppend = true }
        if appendFails { throw FixtureError.sensitiveTransportDetail }
        try lock.withLock {
            if ended { throw CancellationError() }
            timestamps.append(Int64(sample.sampleBuffer.presentationTimeStamp.seconds))
        }
    }
    func stop() async {
        lock.withLock { stopCount += 1; ended = true; active = false }
        startGate?.release(); appendGate?.release()
        await stopGate?.block()
    }
    func markUnhealthy() { lock.withLock { active = false } }
    private enum FixtureError: Error { case sensitiveTransportDetail }
}

private final class SuspendedHealthPublisher: MediaPublisher, @unchecked Sendable {
    let healthGate = PublishingGate()
    let healthCompletionGate = PublishingGate()
    private let lock = NSLock()
    private var healthReads = 0, stopCount = 0
    private var active = false, didReturnHealth = false
    var stops: Int { lock.withLock { stopCount } }
    var healthReturned: Bool { lock.withLock { didReturnHealth } }
    var isPublishing: Bool {
        get async {
            let shouldSuspend = lock.withLock { healthReads += 1; return healthReads > 1 }
            if shouldSuspend {
                // Deliberately ignores task cancellation. Publisher.stop must
                // unblock this query, then the session must join its return.
                await healthGate.block()
                await healthCompletionGate.block()
                lock.withLock { didReturnHealth = true }
            }
            return lock.withLock { active }
        }
    }
    func start() async throws { lock.withLock { active = true } }
    func append(_ sample: CapturedMediaSample) async throws {}
    func stop() async {
        lock.withLock { stopCount += 1; active = false }
        healthGate.release()
    }
}

private final class PublishingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() async {
        await withCheckedContinuation { pending in
            let immediate = lock.withLock {
                entered = true
                if released { return true }
                continuation = pending; return false
            }
            if immediate { pending.resume() }
        }
    }
    var hasEntered: Bool { lock.withLock { entered } }
    func waitUntilEntered() async { while !hasEntered { await Task.yield() } }
    func release() {
        let pending = lock.withLock { released = true; let result = continuation; continuation = nil; return result }
        pending?.resume()
    }
}

private func publishingAudio(_ second: Int64, bytes: Int = 2) throws -> CapturedMediaSample {
    var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
        mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format), noErr)
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: second, timescale: 1), decodeTimeStamp: .invalid)
    var sampleSize = 2
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: try XCTUnwrap(format), sampleCount: bytes / 2, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .audio)
}

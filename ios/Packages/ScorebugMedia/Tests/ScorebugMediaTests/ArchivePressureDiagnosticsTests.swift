#if DEBUG
import AVFoundation
import XCTest
@testable import ScorebugMedia

final class ArchivePressureDiagnosticsTests: XCTestCase {
    func testRejectedAdmissionRetainsAtomicStatisticsAfterCancel() throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 2, maxBytes: 4, overflowPolicy: .rejectNew)
        mailbox.offer(1, bytes: 2)
        mailbox.offer(2, bytes: 2)
        let admission = mailbox.offer(3, bytes: 2)
        mailbox.cancel()
        XCTAssertEqual(admission.rejectionStatistics?.currentItems, 2)
        XCTAssertEqual(admission.rejectionStatistics?.currentBytes, 4)
        XCTAssertEqual(admission.rejectionStatistics?.rejectedCount, 1)
        XCTAssertEqual(admission.rejectionStatistics?.droppedCount, 0)
        XCTAssertEqual(mailbox.statistics.droppedCount, 2)
    }
    func testProducerSeparatesDeadlineLatenessGenerationAndCallbackPair() {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "recording", now: clock.now)
        XCTAssertTrue(owner.attachProducer())
        clock.advance(3)
        owner.beginFrame(index: 7, deadline: clock.origin.advanced(by: .seconds(1)),
                         nominalDeadline: clock.origin.advanced(by: .seconds(0.5)))
        clock.advance(0.25)
        owner.generationFinished()
        owner.callbacksStarted()
        let active = owner.snapshot.observations.activeProducer
        XCTAssertEqual(active?.frameIndex, "7")
        XCTAssertEqual(active?.deadline, 1)
        XCTAssertEqual(active?.nominalDeadline, 0.5)
        XCTAssertEqual(active?.generationStart, 3)
        XCTAssertEqual(active?.generationEnd, 3.25)
        XCTAssertEqual(active?.callbackStart, 3.25)
        XCTAssertNil(active?.callbackEnd)
        owner.freezeFailure(.overflow, rejection: nil, sample: nil, queue: nil, writtenSamples: 0)
        let frozenProducer = owner.snapshot.firstFailure?.observations.activeProducer
        XCTAssertEqual(frozenProducer, active)
        owner.callbacksFinished()
        clock.advance(0.75)
        owner.beginFrame(index: 8, deadline: clock.origin.advanced(by: .seconds(4)))
        clock.advance(2)
        owner.generationFinished()
        owner.callbacksStarted()
        owner.callbacksFinished()
        XCTAssertEqual(owner.snapshot.observations.producers.completed.last?.generationEnd, 6)
        XCTAssertEqual(owner.snapshot.observations.producers.completed.first?.generationEnd, 3.25)
        XCTAssertEqual(owner.snapshot.firstFailure?.observations.activeProducer, frozenProducer)
        XCTAssertNil(owner.snapshot.firstFailure?.observations.activeProducer?.callbackEnd)
    }

    func testCompletedStallSurvivesFastCallsUntilCountEviction() {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "ring", now: clock.now)
        let sample = ArchivePressureDiagnostics.Sample(kind: .audio, pts: .zero, bytes: 4)
        for index in 0..<65 {
            owner.consumerStarted(sample)
            owner.appendStarted()
            clock.advance(index == 0 ? 4 : 0.001)
            owner.appendFinished(.accepted)
            owner.consumerWritten()
            if index == 63 {
                XCTAssertEqual(owner.snapshot.observations.consumers.completed.first?.appendElapsed, 4)
                XCTAssertEqual(owner.snapshot.observations.consumers.omittedCount, "0")
            }
        }
        let history = owner.snapshot.observations.consumers
        XCTAssertEqual(history.completed.count, 64)
        XCTAssertEqual(history.omittedCount, "1")
        XCTAssertEqual(history.oldestRetainedTime, 4)
        for index in 0..<40 {
            owner.beginFrame(index: Int64(index), deadline: clock.origin)
            owner.generationFinished(); owner.callbacksStarted(); owner.callbacksFinished()
            let token = owner.persistenceStarted(kind: .media, bytes: 5)
            owner.persistenceFinished(token, result: .success)
        }
        XCTAssertEqual(owner.snapshot.observations.producers.completed.count, 32)
        XCTAssertEqual(owner.snapshot.observations.producers.omittedCount, "8")
        XCTAssertEqual(owner.snapshot.observations.persistences.completed.count, 32)
        XCTAssertEqual(owner.snapshot.observations.persistences.omittedCount, "8")
    }

    func testRetryWaitAndAppendCallsAreSeparateWhileReadinessOverlaps() {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "retry", now: clock.now)
        owner.consumerStarted(.init(kind: .video, pts: CMTime(value: .max, timescale: 30, flags: .valid, epoch: .max), bytes: 8))
        owner.appendStarted(); clock.advance(2); owner.appendFinished(.notReady)
        clock.advance(3)
        var active = owner.snapshot.observations.activeConsumer
        XCTAssertEqual(active?.phase, .retryWait)
        XCTAssertEqual(active?.retryWaitElapsed, 3)
        XCTAssertEqual(active?.readinessElapsed, 3)
        owner.appendStarted(); clock.advance(4)
        active = owner.snapshot.observations.activeConsumer
        XCTAssertEqual(active?.appendElapsed, 6)
        XCTAssertEqual(active?.appendMaximum, 4)
        XCTAssertEqual(active?.retryWaitElapsed, 3)
        XCTAssertEqual(active?.readinessElapsed, 7)
        XCTAssertEqual(active?.attemptCount, "2")
        XCTAssertEqual(active?.falseCount, "1")
        XCTAssertEqual(active?.sample.pts.value, String(Int64.max))
        owner.appendFinished(.accepted); owner.consumerWritten()
        let complete = owner.snapshot.observations.consumers.completed[0]
        XCTAssertEqual(complete.appendElapsed, 6)
        XCTAssertEqual(complete.retryWaitElapsed, 3)
        XCTAssertEqual(complete.readinessElapsed, 7)
    }

    func testPersistenceTokensBoundConcurrencyAndDoNotConfuseReusedSlots() {
        let owner = ArchivePressureDiagnostics(recordingID: "tokens")
        let tokens = (0..<4).map { _ in owner.persistenceStarted(kind: .media, bytes: 1) }
        XCTAssertNil(owner.persistenceStarted(kind: .media, bytes: 1))
        XCTAssertEqual(owner.snapshot.observations.activePersistences.count, 4)
        XCTAssertEqual(owner.snapshot.observations.omittedActivePersistences, "1")
        XCTAssertFalse(owner.snapshot.coverage.persistenceComplete)
        owner.persistenceFinished(tokens[2], result: .success)
        let replacement = owner.persistenceStarted(kind: .initialization, bytes: 2)
        XCTAssertNotEqual(replacement, tokens[2])
        owner.persistenceFinished(tokens[2], result: .success)
        XCTAssertTrue(owner.snapshot.validity.invalidToken)
        XCTAssertEqual(owner.snapshot.observations.activePersistences.count, 4)
        owner.persistenceFinished(replacement, result: .failure)
        for index in [3, 0, 1] { owner.persistenceFinished(tokens[index], result: .success) }
        owner.persistenceFinished(nil, result: .success)
        XCTAssertTrue(owner.snapshot.observations.activePersistences.isEmpty)
        XCTAssertEqual(owner.snapshot.observations.persistences.completed.count, 5)
        let untouched = ArchivePressureDiagnostics(recordingID: "unknown-token")
        untouched.persistenceFinished(tokens[0], result: .success)
        XCTAssertTrue(untouched.snapshot.validity.invalidToken)
        XCTAssertTrue(untouched.snapshot.observations.persistences.completed.isEmpty)
    }

    func testClockInvalidityStillCapturesFailureAndCloseIgnoresLateCalls() throws {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "close", now: clock.now)
        let token = owner.persistenceStarted(kind: .media, bytes: 5)
        clock.advance(-1)
        owner.freezeFailure(.captureFailed("sensitive"), rejection: nil, sample: nil, queue: nil, writtenSamples: 0)
        XCTAssertFalse(owner.snapshot.validity.timingValid)
        XCTAssertNil(owner.snapshot.firstFailure?.detectedAt)
        let mailbox = try BoundedMailbox<CapturedMediaSample>(maxItems: 1, maxBytes: 1, overflowPolicy: .rejectNew)
        let terminal = RecordingSessionSnapshot(state: .failed, failure: .captureFailed("sensitive"), writtenSamples: 0, queue: mailbox.statistics)
        let closed = owner.close(snapshot: terminal)
        let reads = clock.reads
        clock.advance(5)
        owner.persistenceFinished(token, result: .success)
        owner.beginFrame(index: 9, deadline: clock.origin)
        XCTAssertEqual(owner.close(snapshot: terminal), closed)
        XCTAssertEqual(owner.snapshot, closed)
        XCTAssertEqual(clock.reads, reads)
        XCTAssertEqual(closed.observations.activePersistences.count, 1)
        XCTAssertNil(closed.observations.activePersistences[0].ended)
        let json = String(decoding: try JSONEncoder().encode(closed), as: UTF8.self)
        XCTAssertFalse(json.contains("sensitive"))
        XCTAssertTrue(json.contains("captureFailed"))
    }

    func testCounterSaturationNeverWrapsAndReportsOverflow() {
        let last = ArchivePressureDiagnostics.saturatedIncrement(UInt64.max - 1)
        XCTAssertEqual(last.value, UInt64.max)
        XCTAssertFalse(last.overflow)
        let overflow = ArchivePressureDiagnostics.saturatedIncrement(last.value)
        XCTAssertEqual(overflow.value, UInt64.max)
        XCTAssertTrue(overflow.overflow)
    }

    func testConcurrentArrivalCannotReadSecondStampBeforeFirstEventFinishes() async {
        let reader = SerialStampProbe()
        let owner = ArchivePressureDiagnostics(recordingID: "serialized", now: reader.now)
        let firstDone = expectation(description: "first event stamped")
        let secondDone = expectation(description: "second event stamped")
        DispatchQueue.global().async { owner.observeOffer(kind: .audio, accepted: true); firstDone.fulfill() }
        XCTAssertEqual(reader.firstEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { owner.observeOffer(kind: .video, accepted: true); secondDone.fulfill() }
        XCTAssertEqual(reader.secondEntered.wait(timeout: .now() + 0.1), .timedOut,
            "Clock reads must serialize inside the diagnostics lock")
        reader.release.signal()
        await fulfillment(of: [firstDone, secondDone], timeout: 2)
        XCTAssertTrue(owner.snapshot.validity.timingValid)
    }

    func testRepeatedStampsValidAndConcurrentStampsAreReadInsideOwnerLock() {
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "clock", now: clock.now)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            owner.observeOffer(kind: .audio, accepted: true)
        }
        XCTAssertTrue(owner.snapshot.validity.timingValid)
        XCTAssertEqual(owner.snapshot.observations.audioAccepted, "100")
        clock.advance(1_000_000_000_001)
        owner.observeOffer(kind: .video, accepted: true)
        XCTAssertFalse(owner.snapshot.validity.timingValid)
    }
}

private final class SerialStampProbe: @unchecked Sendable {
    let origin = ContinuousClock.now
    let firstEntered = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func now() -> ContinuousClock.Instant {
        let number = lock.withLock { count += 1; return count }
        if number == 2 {
            firstEntered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        } else if number == 3 { secondEntered.signal() }
        return origin.advanced(by: .seconds(number))
    }
}

final class PressureClock: @unchecked Sendable {
    let origin = ContinuousClock.now
    private let lock = NSLock()
    private var elapsed = 0.0
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func now() -> ContinuousClock.Instant { lock.withLock { count += 1; return origin.advanced(by: .seconds(elapsed)) } }
    func advance(_ seconds: Double) { lock.withLock { elapsed += seconds } }
}
#endif

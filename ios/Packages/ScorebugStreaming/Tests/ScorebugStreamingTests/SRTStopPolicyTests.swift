import Foundation
import XCTest
@testable import ScorebugStreaming

final class SRTStopPolicyTests: XCTestCase {
    func testCancellationRequestAfterJoinCannotScheduleLateClose() async {
        let fixture = StopFixture()
        let cancellation = StopCancellation(close: fixture.operations.close)
        await cancellation.join()
        cancellation.request()
        await cancellation.join()
        XCTAssertEqual(fixture.closes, 0, "Once join closes the gate, a late callback cannot launch cleanup")
    }

    func testWaitsForFreshAcknowledgmentsThenPeerLatencyAndDeploymentAllowance() async {
        let fixture = StopFixture(packets: [2, 1, 0])
        let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
        XCTAssertEqual(outcome, .allowanceElapsed)
        XCTAssertEqual(fixture.time, .milliseconds(660)) // 40 ms ACK + 120 ms peer + 500 ms deployment.
        XCTAssertEqual(fixture.finishBudgets, [.seconds(3)])
        XCTAssertEqual(fixture.closes, 1)
        XCTAssertGreaterThan(fixture.snapshots, 3, "Health/statistics remain live during the allowance")
    }

    func testCodecFinishAndTransportShareOneDeadline() async {
        let fixture = StopFixture(finishCost: .milliseconds(2_500))
        let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
        XCTAssertEqual(outcome, .deadlineExceeded)
        XCTAssertEqual(fixture.time, .seconds(3))
        XCTAssertEqual(fixture.closes, 1)
    }

    func testUnacknowledgedPeerCannotWaitBeyondBudget() async {
        let fixture = StopFixture(packets: [1])
        let policy = SRTStopPolicy(totalBudget: .milliseconds(70))
        let outcome = await policy.run(clock: fixture.clock, operations: fixture.operations)
        XCTAssertEqual(outcome, .deadlineExceeded)
        XCTAssertEqual(fixture.time, .milliseconds(70))
        XCTAssertEqual(fixture.closes, 1)
    }

    func testFailureDuringAllowanceAbortsAtNextPoll() async {
        let fixture = StopFixture(failureAt: .milliseconds(60))
        let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fixture.time, .milliseconds(60))
        XCTAssertEqual(fixture.closes, 1)
    }

    func testMissingAndMalformedStatisticsFailClosed() async {
        for snapshot in [nil, SRTStopPolicy.Snapshot(healthy: true, unacknowledgedPackets: -1, peerLatencyMilliseconds: 120),
                         SRTStopPolicy.Snapshot(healthy: true, unacknowledgedPackets: 0, peerLatencyMilliseconds: -1)] {
            let fixture = StopFixture(snapshotOverride: .some(snapshot))
            let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
            XCTAssertEqual(outcome, .statisticsUnavailable)
            XCTAssertEqual(fixture.time, .zero)
            XCTAssertEqual(fixture.closes, 1)
        }
    }

    func testCancellationDuringSleepAbortsAndCloses() async {
        let fixture = StopFixture(cancelSleep: true)
        let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.closes, 1)
    }

    func testCancellationDuringShieldedCodecFinishClosesAndJoinsCleanup() async {
        let fixture = StopFixture(gatedFinish: true)
        let task = Task { await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations) }
        while fixture.finishBudgets.isEmpty { await Task.yield() }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertGreaterThanOrEqual(fixture.closes, 1)
        XCTAssertFalse(fixture.finishing)
    }

    func testFailedPublisherSkipsFinishButEveryStopStillCloses() async {
        let fixture = StopFixture(publishing: false)
        for _ in 0..<2 {
            let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
            XCTAssertEqual(outcome, .notPublishing)
        }
        XCTAssertEqual(fixture.finishBudgets, [])
        XCTAssertEqual(fixture.closes, 2, "A later stop must close a late SDK startup")
    }

    func testOversleptDeadlineCannotReportAllowanceElapsed() async {
        let fixture = StopFixture(sleepOvershoot: .seconds(4))
        let outcome = await SRTStopPolicy().run(clock: fixture.clock, operations: fixture.operations)
        XCTAssertEqual(outcome, .deadlineExceeded)
        XCTAssertEqual(fixture.closes, 1)
    }
}

private final class StopFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var packetValues: [Int]
    private let finishCost: Duration
    private let failureAt: Duration?
    private let override: SRTStopPolicy.Snapshot??
    private let cancelSleep: Bool
    private let publishing: Bool
    private let sleepOvershoot: Duration
    private let gatedFinish: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var closeCount = 0
    private var snapshotCount = 0
    private var budgets: [Duration] = []
    private var finishActive = false

    init(packets: [Int] = [0], finishCost: Duration = .zero, failureAt: Duration? = nil,
         snapshotOverride: SRTStopPolicy.Snapshot?? = nil, cancelSleep: Bool = false,
         publishing: Bool = true, sleepOvershoot: Duration = .zero, gatedFinish: Bool = false) {
        packetValues = packets; self.finishCost = finishCost; self.failureAt = failureAt
        override = snapshotOverride; self.cancelSleep = cancelSleep; self.publishing = publishing
        self.sleepOvershoot = sleepOvershoot; self.gatedFinish = gatedFinish
    }
    var time: Duration { lock.withLock { elapsed } }
    var closes: Int { lock.withLock { closeCount } }
    var snapshots: Int { lock.withLock { snapshotCount } }
    var finishBudgets: [Duration] { lock.withLock { budgets } }
    var finishing: Bool { lock.withLock { finishActive } }
    var clock: SRTStopPolicy.Clock {
        .init(now: { self.time }, sleep: { duration in
            if self.cancelSleep { throw CancellationError() }
            self.lock.withLock { self.elapsed += duration + self.sleepOvershoot }
        })
    }
    var operations: SRTStopPolicy.Operations {
        .init(isPublishing: { self.publishing }, finish: { budget in
            if self.gatedFinish {
                await withCheckedContinuation { continuation in
                    self.lock.withLock {
                        self.finishActive = true; self.gate = continuation; self.budgets.append(budget)
                    }
                }
                self.lock.withLock { self.finishActive = false }
            } else {
                self.lock.withLock { self.budgets.append(budget); self.elapsed += self.finishCost }
            }
        }, snapshot: {
            self.lock.withLock {
                self.snapshotCount += 1
                if let override = self.override { return override }
                let packets = self.packetValues.count > 1 ? self.packetValues.removeFirst() : self.packetValues[0]
                return .init(healthy: self.failureAt.map { self.elapsed < $0 } ?? true,
                             unacknowledgedPackets: packets, peerLatencyMilliseconds: 120)
            }
        }, close: {
            let continuation = self.lock.withLock {
                self.closeCount += 1
                let result = self.gate; self.gate = nil
                return result
            }
            continuation?.resume()
        })
    }
}

import Foundation
import ScorebugCore
import XCTest

final class WorkerReceiverProbeTrackerTests: XCTestCase {
    private let anchor = ContinuousClock.now
    private func evidence(seconds: Double, messages: Int, pending: Int = 0,
                          change: (inout WorkerMediaStatusResponse) -> Void = { _ in }) throws -> WorkerReceiverProbeFreshness {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "receiver-probe-status-v1", withExtension: "json", subdirectory: "Fixtures"))
        var response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
        var p = response.status.receiverProbe!.snapshot
        p.publishingGeneration = "1"; p.deliveredMessages = String(messages)
        p.deliveredPayloadBytes = String(messages * 1316); p.nextSequence = String(messages); p.pendingPackets = pending
        p.observedAtNanoseconds = String(Int64(seconds * 1e9))
        p.firstDeliveredAtNanoseconds = messages == 0 ? nil : "100000000"
        p.lastDeliveredAtNanoseconds = messages == 0 ? nil : String(Int64((seconds - 0.01) * 1e9))
        response.status.receiverProbe = .init(snapshot: p, ageUpperBoundMs: 10)
        change(&response)
        return try XCTUnwrap(WorkerReceiverProbeFreshness(response: response,
            expected: .init(gameId: "match", generation: 2, workerId: "mac",
                publishingAttemptId: response.status.publication!.publishingAttemptId,
                probeId: p.id, publishingGeneration: 1, bitRate: 1_000_000),
            receivedAt: anchor + .seconds(seconds), requestDuration: .milliseconds(10)))
    }
    @discardableResult private func observe(_ tracker: inout WorkerReceiverProbeTracker, seconds: Double, messages: Int,
                                           pending: Int = 0, accepted: UInt64? = nil, active: Bool = true,
                                           change: (inout WorkerMediaStatusResponse) -> Void = { _ in }) throws -> WorkerReceiverProbeInterval? {
        tracker.observe(try evidence(seconds: seconds, messages: messages, pending: pending, change: change),
            acceptedPayloadBytes: accepted ?? UInt64((messages + (pending > 0 ? 1 : 0)) * 1316),
            senderActive: active, at: anchor + .seconds(seconds))
    }
    func testIntervalSubtractsAlreadyReceivedPartialPacketsAndUsesReceiverElapsedTime() throws {
        var tracker = WorkerReceiverProbeTracker()
        XCTAssertNil(try observe(&tracker, seconds: 1, messages: 90, pending: 3))
        let interval = try XCTUnwrap(observe(&tracker, seconds: 3, messages: 270, pending: 6))
        XCTAssertEqual(interval.duration, .seconds(2))
        XCTAssertEqual(interval.deliveredMessages, 180)
        XCTAssertEqual(interval.deliveredPayloadBytesLowerBound, 180 * 1316 - 3 * 188)
        XCTAssertEqual(interval.payloadBitsPerSecondLowerBound, Double(180 * 1316 - 3 * 188) * 4)
        XCTAssertEqual(interval.start.deliveredMessages, "90")
        XCTAssertEqual(interval.end.snapshot.deliveredMessages, "270")
    }
    func testSubsecondReportsAccumulateAndDoNotRefreshPriorInterval() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        XCTAssertNil(try observe(&tracker, seconds: 1.5, messages: 135))
        let first = try XCTUnwrap(observe(&tracker, seconds: 2, messages: 180))
        let later = try XCTUnwrap(observe(&tracker, seconds: 2.5, messages: 225))
        XCTAssertEqual(later.end.snapshot, first.end.snapshot)
        XCTAssertEqual(later.end.snapshotAgeUpperBound(at: anchor + .seconds(2.5)), .milliseconds(520))
        let next = try XCTUnwrap(observe(&tracker, seconds: 3, messages: 270))
        XCTAssertEqual(next.start.deliveredMessages, "180")
    }
    func testSenderAcceptanceMustCoverEvenPendingReceiverPackets() throws {
        for pending in [0, 1, 6] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90)
            XCTAssertNil(try observe(&tracker, seconds: 2, messages: 180, pending: pending, accepted: UInt64(180 * 1316 - (pending == 0 ? 1 : 0))))
            XCTAssertTrue(tracker.isQuarantined)
            XCTAssertNil(try observe(&tracker, seconds: 3, messages: 270))
        }
    }
    func testContradictionsRemainQuarantinedAcrossMissingEvidence() throws {
        let faults: [(inout WorkerMediaStatusResponse) -> Void] = [
            { $0.status.receiverProbe?.snapshot.deliveredMessages = "80"; $0.status.receiverProbe?.snapshot.deliveredPayloadBytes = "105280"; $0.status.receiverProbe?.snapshot.nextSequence = "80" },
            { $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "999999999"; $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "999999998" },
            { $0.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = "100000001" },
            { $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "999999999" },
            { $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "4000000000"; $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "3990000000" },
        ]
        for fault in faults {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90)
            XCTAssertNil(try observe(&tracker, seconds: 2, messages: 180, change: fault))
            XCTAssertTrue(tracker.isQuarantined)
            XCTAssertNil(tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(2.1)))
            XCTAssertNil(try observe(&tracker, seconds: 3, messages: 270))
            XCTAssertTrue(tracker.isQuarantined)
        }
    }
    func testPartialProgressCannotReverseOrAdvanceDeliveryTimeWithoutNewMessage() throws {
        for (pending, last) in [(2, "990000000"), (3, "1000000000")] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90, pending: 3)
            XCTAssertNil(try observe(&tracker, seconds: 2, messages: 90, pending: pending) {
                $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = last
            })
            XCTAssertTrue(tracker.isQuarantined)
        }
    }
    func testReceiverClockMustFitEveryRequestEnvelopeAndRequestsMustBeSerial() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        let cached = try evidence(seconds: 2, messages: 90) {
            $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "1000000000"
            $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "990000000"
        }
        XCTAssertNil(tracker.observe(cached, acceptedPayloadBytes: 118440, senderActive: true, at: anchor + .seconds(2)))
        XCTAssertTrue(tracker.isQuarantined)
        tracker.reset()
        try observe(&tracker, seconds: 1, messages: 90)
        XCTAssertNil(try observe(&tracker, seconds: 1.005, messages: 90) {
            $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "990000000"
        })
        XCTAssertTrue(tracker.isQuarantined)
    }
    func testMissingEvidenceBreaksIntervalButPreservesCounterHighWater() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(1.1))
        XCTAssertNil(try observe(&tracker, seconds: 2, messages: 180))
        XCTAssertNotNil(try observe(&tracker, seconds: 3, messages: 270))
        tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(3.1))
        XCTAssertNil(try observe(&tracker, seconds: 4, messages: 200))
        XCTAssertTrue(tracker.isQuarantined)
    }
    func testScopeReplacementReacquiresAndExplicitResetDropsQuarantine() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        try observe(&tracker, seconds: 2, messages: 80)
        XCTAssertTrue(tracker.isQuarantined)
        XCTAssertNil(try observe(&tracker, seconds: 3, messages: 270) { $0.status.workerEpoch = "11111111-1111-4111-8111-111111111111" })
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNotNil(try observe(&tracker, seconds: 4, messages: 360) { $0.status.workerEpoch = "11111111-1111-4111-8111-111111111111" })
        tracker.reset(); XCTAssertNil(tracker.latest); XCTAssertFalse(tracker.isQuarantined)
    }
    func testExpiredInactiveOverlongAndZeroProgressAreUnavailable() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        XCTAssertNotNil(try observe(&tracker, seconds: 2, messages: 180))
        tracker.expire(at: anchor + .seconds(3.5))
        XCTAssertNil(tracker.latest)
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNil(try observe(&tracker, seconds: 4, messages: 360, active: false))
        XCTAssertNil(try observe(&tracker, seconds: 5, messages: 450))
        XCTAssertNil(try observe(&tracker, seconds: 11, messages: 990))
        tracker.reset()
        try observe(&tracker, seconds: 1, messages: 90)
        XCTAssertNil(try observe(&tracker, seconds: 2, messages: 90) {
            $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "990000000"
        })
        XCTAssertFalse(tracker.isQuarantined)
    }
    func testEmptyBaselineRequiresFirstDeliveryAfterItsObservation() throws {
        for valid in [true, false] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 0)
            let result = try observe(&tracker, seconds: 2, messages: 90) {
                $0.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = valid ? "1000000000" : "999999999"
            }
            XCTAssertEqual(result != nil, valid)
            XCTAssertEqual(tracker.isQuarantined, !valid)
        }
    }
}

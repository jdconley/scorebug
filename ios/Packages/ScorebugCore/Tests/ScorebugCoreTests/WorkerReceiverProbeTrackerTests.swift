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
                probeId: response.status.receiverProbe!.snapshot.id, publishingGeneration: UInt64(response.status.receiverProbe!.snapshot.publishingGeneration)!,
                bitRate: response.status.receiverProbe!.snapshot.bitRate, stage: response.status.receiverProbe!.snapshot.stage),
            receivedAt: anchor + .seconds(seconds), requestDuration: .milliseconds(10)))
    }
    @discardableResult private func observe(_ tracker: inout WorkerReceiverProbeTracker, seconds: Double, messages: Int,
                                           pending: Int = 0, accepted: UInt64? = nil, active: Bool = true,
                                           change: (inout WorkerMediaStatusResponse) -> Void = { _ in }) throws -> WorkerReceiverProbeInterval? {
        tracker.observe(try evidence(seconds: seconds, messages: messages, pending: pending, change: change),
            acceptedPayloadBytes: accepted ?? UInt64((messages + (pending > 0 ? 1 : 0)) * 1316),
            senderActive: active, at: anchor + .seconds(seconds))
    }
    @discardableResult private func stage(_ tracker: inout WorkerReceiverProbeTracker,
        _ number: Int, seconds: Double, messages: Int, totalMessages: Int, pending: Int = 0,
        first: Double = 0.1, id: Int? = nil, accepted: UInt64? = nil,
        change: (inout WorkerMediaStatusResponse) -> Void = { _ in }) throws -> WorkerReceiverProbeInterval? {
        try observe(&tracker, seconds: seconds, messages: messages, pending: pending, accepted: accepted) {
            $0.status.receiverProbe?.snapshot.convention = "mpegts-null-probe-v2"
            $0.status.receiverProbe?.snapshot.stage = number
            $0.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = String(totalMessages * 1316)
            $0.status.receiverProbe?.snapshot.id = String(format: "60000000-0000-4000-8000-%012d", id ?? number)
            $0.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = messages == 0 ? nil : String(Int64(first * 1e9))
            change(&$0)
        }
    }

    func testV2AdvancingStagesResetOnlyStageWindowAndPermitSkippedStagesAndHistoricalUUID() throws {
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90)
        XCTAssertNotNil(try stage(&tracker, 1, seconds: 2, messages: 180, totalMessages: 180))
        XCTAssertNil(try stage(&tracker, 3, seconds: 3, messages: 20, totalMessages: 220, first: 2))
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNil(tracker.latest)
        XCTAssertNotNil(try stage(&tracker, 3, seconds: 4, messages: 110, totalMessages: 310, first: 2))
        XCTAssertNil(try stage(&tracker, 4, seconds: 5, messages: 20, totalMessages: 330, first: 4, id: 1))
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNotNil(try stage(&tracker, 4, seconds: 6, messages: 110, totalMessages: 420, first: 4, id: 1))
    }

    func testV2StageAndIdentitySubstitutionsQuarantineSamePublication() throws {
        let faults: [(inout WorkerMediaStatusResponse) -> Void] = [
            { $0.status.receiverProbe?.snapshot.stage = 1 },
            { $0.status.receiverProbe?.snapshot.stage = 2 },
            { $0.status.receiverProbe?.snapshot.id = "60000000-0000-4000-8000-000000000002" },
            { $0.status.receiverProbe?.snapshot.convention = "mpegts-null-probe-v1"; $0.status.receiverProbe?.snapshot.stage = nil; $0.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = nil },
        ]
        for fault in faults {
            var tracker = WorkerReceiverProbeTracker()
            try stage(&tracker, 2, seconds: 1, messages: 90, totalMessages: 180)
            XCTAssertNil(try stage(&tracker, 3, seconds: 2, messages: 20, totalMessages: 220, first: 1, change: fault))
            XCTAssertTrue(tracker.isQuarantined)
        }
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 2, seconds: 1, messages: 90, totalMessages: 180)
        XCTAssertNil(try stage(&tracker, 2, seconds: 2, messages: 180, totalMessages: 270) {
            $0.status.receiverProbe?.snapshot.bitRate = 500_000
        })
        XCTAssertTrue(tracker.isQuarantined)
        tracker.reset()
        try observe(&tracker, seconds: 1, messages: 90)
        XCTAssertNil(try stage(&tracker, 2, seconds: 2, messages: 20, totalMessages: 110, first: 1))
        XCTAssertTrue(tracker.isQuarantined)
    }

    func testV2StageCannotWashCounterClockSerialOrPendingContradictions() throws {
        let faults: [(inout WorkerMediaStatusResponse) -> Void] = [
            { $0.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = String(110 * 1316) },
            { $0.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = String(20 * 1316) },
            { $0.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = "999999999" },
            { $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "4000000000"; $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "3990000000" },
            { $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "999999999"; $0.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = "900000000"; $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "990000000" },
        ]
        for fault in faults {
            var tracker = WorkerReceiverProbeTracker()
            try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90, pending: 1)
            tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(1.1))
            XCTAssertNil(try stage(&tracker, 2, seconds: 2, messages: 20, totalMessages: 111, first: 1, change: fault))
            XCTAssertTrue(tracker.isQuarantined)
            XCTAssertNil(try stage(&tracker, 3, seconds: 3, messages: 20, totalMessages: 200, first: 2))
            XCTAssertTrue(tracker.isQuarantined)
        }
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90)
        XCTAssertNil(try stage(&tracker, 2, seconds: 1.005, messages: 0, totalMessages: 90))
        XCTAssertTrue(tracker.isQuarantined)
    }

    func testV2SameStageTotalDeltaMustMatchStageBytes() throws {
        for total in [99, 101, 80] {
            var tracker = WorkerReceiverProbeTracker()
            try stage(&tracker, 1, seconds: 1, messages: 20, totalMessages: 90)
            XCTAssertNil(try stage(&tracker, 1, seconds: 2, messages: 30, totalMessages: total))
            XCTAssertTrue(tracker.isQuarantined)
        }
    }

    func testV2SameStageUUIDSwapAndSenderRegressionFailClosed() throws {
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 2, seconds: 1, messages: 90, totalMessages: 180)
        XCTAssertNil(try stage(&tracker, 2, seconds: 2, messages: 180, totalMessages: 270, id: 3))
        XCTAssertTrue(tracker.isQuarantined)
        tracker.reset()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90, accepted: 200 * 1316)
        XCTAssertNil(try stage(&tracker, 1, seconds: 2, messages: 180, totalMessages: 180))
        XCTAssertTrue(tracker.isQuarantined)
    }

    func testV2StaleStageSuppliesNoCreditAndCannotEraseCumulativeHighWater() throws {
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90, pending: 1)
        XCTAssertNil(try stage(&tracker, 2, seconds: 3, messages: 20, totalMessages: 111, first: 1) {
            $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "1000000000"
        })
        XCTAssertNil(tracker.latest)
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNil(try stage(&tracker, 3, seconds: 4, messages: 20, totalMessages: 110, first: 3))
        XCTAssertTrue(tracker.isQuarantined)
    }

    func testV2NativeGenerationReplacementResetsQuarantineAndV1ScopeBehaviorIsPreserved() throws {
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90)
        try stage(&tracker, 1, seconds: 2, messages: 80, totalMessages: 90)
        XCTAssertTrue(tracker.isQuarantined)
        XCTAssertNil(try stage(&tracker, 1, seconds: 3, messages: 20, totalMessages: 20) {
            $0.status.receiverProbe?.snapshot.publishingGeneration = "2"
        })
        XCTAssertFalse(tracker.isQuarantined)
        tracker.reset()
        try observe(&tracker, seconds: 1, messages: 90)
        try observe(&tracker, seconds: 2, messages: 80)
        XCTAssertTrue(tracker.isQuarantined)
        XCTAssertNil(try observe(&tracker, seconds: 3, messages: 20) {
            $0.status.receiverProbe?.snapshot.id = "70000000-0000-4000-8000-000000000001"
        })
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNotNil(try observe(&tracker, seconds: 4, messages: 110) {
            $0.status.receiverProbe?.snapshot.id = "70000000-0000-4000-8000-000000000001"
        })
    }

    func testV2PendingReservationAndEmptyStageBaseline() throws {
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90, pending: 6)
        XCTAssertNil(try stage(&tracker, 2, seconds: 2, messages: 0, totalMessages: 91))
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNotNil(try stage(&tracker, 2, seconds: 3, messages: 20, totalMessages: 111, first: 2))
        XCTAssertFalse(tracker.isQuarantined)
    }

    func testV2QuarantineSurvivesStageReplacementButNewPublicationCanReset() throws {
        var tracker = WorkerReceiverProbeTracker()
        try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90)
        try stage(&tracker, 1, seconds: 2, messages: 80, totalMessages: 90)
        XCTAssertTrue(tracker.isQuarantined)
        XCTAssertNil(try stage(&tracker, 2, seconds: 3, messages: 20, totalMessages: 110, first: 2))
        XCTAssertTrue(tracker.isQuarantined)
        XCTAssertNil(try stage(&tracker, 1, seconds: 4, messages: 20, totalMessages: 20) {
            $0.status.publication?.publisherId = "50000000-0000-4000-8000-000000000005"
        })
        XCTAssertFalse(tracker.isQuarantined)
        XCTAssertNotNil(try stage(&tracker, 1, seconds: 5, messages: 110, totalMessages: 110) {
            $0.status.publication?.publisherId = "50000000-0000-4000-8000-000000000005"
        })
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
    func testIntervalExposesReconciledConservativeImmutableClockBounds() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 0.5, messages: 45)
        let interval = try XCTUnwrap(observe(&tracker, seconds: 2, messages: 180) {
            $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "1990000000"
            $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "1980000000"
        })
        // Exact integer receipt times keep this assertion independent of Double
        // conversion rounding. The request envelopes intersect at [-10ms, 0].
        XCTAssertEqual(interval.receiverClockOffsetBounds, (anchor - .milliseconds(10))...anchor)
        XCTAssertEqual(interval.startBounds, (anchor + .milliseconds(490))...(anchor + .milliseconds(500)))
        XCTAssertEqual(interval.endBounds, (anchor + .milliseconds(1980))...(anchor + .milliseconds(1990)))
        try observe(&tracker, seconds: 3, messages: 270) {
            $0.status.receiverProbe?.snapshot.observedAtNanoseconds = "2985000000"
            $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "2975000000"
        }
        XCTAssertEqual(interval.receiverClockOffsetBounds, (anchor - .milliseconds(10))...anchor,
                       "Previously issued interval bounds remain immutable conservative values")
    }
    func testLatestPairContainsOnlyTwoNewestDistinctContiguousIntervals() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        XCTAssertNil(tracker.latestPair)
        let first = try XCTUnwrap(observe(&tracker, seconds: 2, messages: 180))
        XCTAssertNil(tracker.latestPair)
        let second = try XCTUnwrap(observe(&tracker, seconds: 3, messages: 270))
        let pair = try XCTUnwrap(tracker.latestPair)
        XCTAssertEqual(pair.older.start, first.start)
        XCTAssertEqual(pair.older.end.snapshot, second.start)
        XCTAssertEqual(pair.newer.end.snapshot, second.end.snapshot)
        try observe(&tracker, seconds: 3.25, messages: 290)
        XCTAssertEqual(tracker.latestPair?.older.start, pair.older.start)
        XCTAssertEqual(tracker.latestPair?.newer.end.snapshot, pair.newer.end.snapshot)
        try observe(&tracker, seconds: 4, messages: 360)
        XCTAssertEqual(tracker.latestPair?.older.start, second.start)
        XCTAssertEqual(tracker.latestPair?.newer.start, second.end.snapshot)
        XCTAssertEqual(tracker.latestPair?.newer.end.snapshot.observedAtNanoseconds, "4000000000")
    }
    func testMissingInactiveAndExpiryBreakPairCoverageWithoutErasingHistory() throws {
        for interruption in 0..<3 {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90)
            try observe(&tracker, seconds: 2, messages: 180)
            try observe(&tracker, seconds: 3, messages: 270)
            XCTAssertNotNil(tracker.latestPair)
            if interruption == 0 {
                tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(3.1))
            } else if interruption == 1 {
                try observe(&tracker, seconds: 3.1, messages: 279, active: false)
            } else {
                tracker.expire(at: anchor + .seconds(4.5))
            }
            XCTAssertNil(tracker.latestPair)
            try observe(&tracker, seconds: 5, messages: 450)
            if interruption == 2 { XCTAssertNotNil(tracker.latestPair) }
            else { XCTAssertNil(tracker.latestPair) }
            try observe(&tracker, seconds: 6, messages: 540)
            if interruption != 2 { XCTAssertNil(tracker.latestPair) }
            try observe(&tracker, seconds: 7, messages: 630)
            XCTAssertNotNil(tracker.latestPair)
            tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(7.1))
            try observe(&tracker, seconds: 8, messages: 600)
            XCTAssertTrue(tracker.isQuarantined)
            XCTAssertNil(tracker.latestPair)
        }
    }
    func testStageProbePublicationAndRateCannotSplicePair() throws {
        for replacement in 0..<4 {
            var tracker = WorkerReceiverProbeTracker()
            try stage(&tracker, 1, seconds: 1, messages: 90, totalMessages: 90)
            try stage(&tracker, 1, seconds: 2, messages: 180, totalMessages: 180)
            try stage(&tracker, 1, seconds: 3, messages: 270, totalMessages: 270)
            XCTAssertNotNil(tracker.latestPair)
            if replacement == 0 {
                try stage(&tracker, 2, seconds: 4, messages: 90, totalMessages: 360, first: 3)
            } else {
                try stage(&tracker, 1, seconds: 4, messages: 360, totalMessages: 360) {
                    if replacement == 1 { $0.status.receiverProbe?.snapshot.id = "60000000-0000-4000-8000-000000000002" }
                    if replacement == 2 { $0.status.publication?.publisherId = "50000000-0000-4000-8000-000000000005" }
                    if replacement == 3 { $0.status.receiverProbe?.snapshot.bitRate = 500_000 }
                }
            }
            XCTAssertNil(tracker.latestPair)
            XCTAssertEqual(tracker.isQuarantined, replacement == 1 || replacement == 3)
        }
    }
    func testZeroProgressAndOverlongIntervalsBreakPair() throws {
        for overlong in [false, true] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90)
            try observe(&tracker, seconds: 2, messages: 180)
            try observe(&tracker, seconds: 3, messages: 270)
            XCTAssertNotNil(tracker.latestPair)
            if overlong {
                try observe(&tracker, seconds: 8.1, messages: 729)
            } else {
                try observe(&tracker, seconds: 4, messages: 270) {
                    $0.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "2990000000"
                }
            }
            XCTAssertNil(tracker.latestPair)
            XCTAssertFalse(tracker.isQuarantined)
        }
    }

    func testTwoSecondIntervalsRecoverPairFromBoundedHistoryAfterExpiryPolls() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        let older = try XCTUnwrap(observe(&tracker, seconds: 3, messages: 270))
        tracker.expire(at: anchor + .seconds(4.5))
        XCTAssertNil(tracker.latest)
        XCTAssertNil(tracker.latestPair)
        let newer = try XCTUnwrap(observe(&tracker, seconds: 5, messages: 450))
        let pair = try XCTUnwrap(tracker.latestPair)
        XCTAssertEqual(pair.older.start, older.start)
        XCTAssertEqual(pair.older.end.snapshot, newer.start)
        XCTAssertEqual(pair.newer.end.snapshot, newer.end.snapshot)
        XCTAssertFalse(tracker.isQuarantined)
        tracker.expire(at: anchor + .seconds(6.5))
        XCTAssertNil(tracker.latestPair)
        try observe(&tracker, seconds: 7, messages: 630)
        XCTAssertEqual(tracker.latestPair?.older.start, newer.start)
    }

}

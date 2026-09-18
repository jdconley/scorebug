import Foundation
@testable import ScorebugCore
import XCTest

final class WorkerReceiverProbeCampaignTests: XCTestCase {
    private let anchor = ContinuousClock.now
    private func fixture() throws -> WorkerMediaStatusResponse {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "receiver-probe-status-v3", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
    }
    private func expected(_ response: WorkerMediaStatusResponse) -> WorkerReceiverProbeExpectation {
        let p = response.status.receiverProbe!.snapshot
        return .init(gameId: "match", generation: 2, workerId: "mac",
            publishingAttemptId: response.status.publication!.publishingAttemptId,
            probeId: p.id, publishingGeneration: UInt64(p.publishingGeneration)!, bitRate: p.bitRate,
            stage: p.stage, campaign: p.campaign.flatMap(UInt32.init))
    }
    private func freshness(_ response: WorkerMediaStatusResponse, seconds: Double = 1,
                           expectation: WorkerReceiverProbeExpectation? = nil) -> WorkerReceiverProbeFreshness? {
        .init(response: response, expected: expectation ?? expected(response),
              receivedAt: anchor + .seconds(seconds), requestDuration: .milliseconds(10))
    }
    @discardableResult private func observe(_ tracker: inout WorkerReceiverProbeTracker,
        campaign: UInt32 = 1, stage: Int = 1, seconds: Double, messages: Int,
        campaignMessages: Int? = nil, totalMessages: Int? = nil, pending: Int = 0,
        first: Double = 0.1, id: Int = 1,
        change: (inout ReceiverProbeSnapshot) -> Void = { _ in }) throws -> WorkerReceiverProbeInterval? {
        var response = try fixture()
        var p = response.status.receiverProbe!.snapshot
        p.campaign = String(campaign); p.stage = stage
        p.id = String(format: "60000000-0000-4000-8000-%012d", id)
        p.deliveredMessages = String(messages); p.deliveredPayloadBytes = String(messages * 1316)
        p.nextSequence = String(messages); p.pendingPackets = pending
        p.campaignDeliveredPayloadBytes = String((campaignMessages ?? messages) * 1316)
        p.totalDeliveredPayloadBytes = String((totalMessages ?? campaignMessages ?? messages) * 1316)
        p.observedAtNanoseconds = String(Int64(seconds * 1e9))
        p.firstDeliveredAtNanoseconds = messages == 0 ? nil : String(Int64(first * 1e9))
        p.lastDeliveredAtNanoseconds = messages == 0 ? nil : String(Int64((seconds - 0.01) * 1e9))
        change(&p)
        response.status.receiverProbe = .init(snapshot: p, ageUpperBoundMs: 10)
        return tracker.observe(try XCTUnwrap(freshness(response, seconds: seconds)),
            acceptedPayloadBytes: UInt64(messages + (pending > 0 ? 1 : 0)) * 1316,
            senderActive: true, at: anchor + .seconds(seconds))
    }

    func testV3CanonicalCampaignBoundsAndExactExpectationIncludingWatchUInt32Maximum() throws {
        var response = try fixture()
        XCTAssertNotNil(freshness(response))
        for campaign: UInt32 in [1, UInt32.max] {
            response.status.receiverProbe?.snapshot.campaign = String(campaign)
            response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = "5264"
            let e = expected(response)
            XCTAssertEqual(e.campaign, campaign)
            XCTAssertNotNil(freshness(response, expectation: e))
            var mismatch = e; mismatch.campaign = nil
            XCTAssertNil(freshness(response, expectation: mismatch))
            mismatch.campaign = campaign == 1 ? 2 : 1
            XCTAssertNil(freshness(response, expectation: mismatch))
        }
        for value in ["0", "4294967296", "01", "+1", "1\n", "١", "1.0", "18446744073709551616"] {
            response.status.receiverProbe?.snapshot.campaign = value
            XCTAssertNil(response.status.receiverProbe?.snapshot.validated, value)
        }
    }

    func testV3PayloadCapsReserveAWholePendingMessageAndNeverNarrowPublicationTotal() throws {
        var p = try XCTUnwrap(fixture().status.receiverProbe?.snapshot)
        let maximum = UInt64(UInt32.max) * 16 * 1024 * 1024
        let aligned = maximum / 1316 * 1316
        p.campaign = String(UInt32.max); p.totalDeliveredPayloadBytes = String(aligned - 1316)
        p.campaignDeliveredPayloadBytes = "16776368"
        p.pendingPackets = 0; p.bitRate = 12_000_000
        XCTAssertNotNil(p.validated)
        p.pendingPackets = 1
        XCTAssertNil(p.validated)
        p.campaignDeliveredPayloadBytes = "16775052"
        p.totalDeliveredPayloadBytes = String(aligned - 2632)
        XCTAssertNotNil(p.validated)
        p.campaignDeliveredPayloadBytes = "16776368"
        XCTAssertNil(p.validated)
        p.pendingPackets = 0
        XCTAssertNotNil(p.validated)
        let faults: [(inout ReceiverProbeSnapshot) -> Void] = [
            { $0.campaign = nil }, { $0.campaignDeliveredPayloadBytes = nil },
            { $0.campaignDeliveredPayloadBytes = "16777684" },
            { $0.campaignDeliveredPayloadBytes = "2631" },
            { $0.campaignDeliveredPayloadBytes = "1316" },
            { $0.campaignDeliveredPayloadBytes = "02632" },
            { $0.campaignDeliveredPayloadBytes = "2632\n" },
            { $0.campaignDeliveredPayloadBytes = "18446744073709551616" },
            { $0.totalDeliveredPayloadBytes = "2632" },
            { $0.totalDeliveredPayloadBytes = String(aligned + 1316) },
            { $0.totalDeliveredPayloadBytes = "18446744073709551616" },
            { $0.totalDeliveredPayloadBytes = "016776368" },
            { $0.stage = 0 }, { $0.stage = 33 }, { $0.stage = nil },
            { $0.bitRate = 0 }, { $0.bitRate = 12_000_001 },
        ]
        for (index, fault) in faults.enumerated() {
            var malformed = p; fault(&malformed)
            XCTAssertNil(malformed.validated, "fault \(index)")
        }
    }

    func testV3RejectsImpossiblePriorCampaignCarryAndStageOneCarry() throws {
        var p = try XCTUnwrap(fixture().status.receiverProbe?.snapshot)
        p.campaign = "1"
        XCTAssertNil(p.validated, "First campaign must own the full publication total")
        p.totalDeliveredPayloadBytes = p.campaignDeliveredPayloadBytes
        XCTAssertNotNil(p.validated)
        p.stage = 1
        XCTAssertNil(p.validated, "First stage must own the full campaign counter")
        p.campaignDeliveredPayloadBytes = p.deliveredPayloadBytes
        p.totalDeliveredPayloadBytes = p.deliveredPayloadBytes
        XCTAssertNotNil(p.validated)
        p.campaign = "2"
        let priorCap: UInt64 = 16 * 1024 * 1024
        let impossibleCarry = (priorCap + 2632) / 1316 * 1316 + 1316
        p.totalDeliveredPayloadBytes = String(impossibleCarry)
        XCTAssertNil(p.validated, "Prior campaign carry cannot exceed its cap")
    }

    func testV3OptionalCampaignFieldsRejectNullAndWrongTypes() throws {
        let original = try XCTUnwrap(fixture().status.receiverProbe?.snapshot)
        for key in ["campaign", "campaignDeliveredPayloadBytes"] {
            for value: Any in [NSNull(), 2, [], true] {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
                object[key] = value
                XCTAssertThrowsError(try JSONDecoder().decode(ReceiverProbeSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
            }
        }
    }

    func testV3EveryStageAndCampaignBoundaryDropsPairUntilTwoNewIntervals() throws {
        var tracker = WorkerReceiverProbeTracker()
        for time in 1...3 { try observe(&tracker, seconds: Double(time), messages: time * 90) }
        XCTAssertNotNil(tracker.latestPair)
        XCTAssertNil(try observe(&tracker, stage: 3, seconds: 4, messages: 20, campaignMessages: 290, first: 3, id: 2))
        XCTAssertNil(tracker.latestPair)
        XCTAssertNotNil(try observe(&tracker, stage: 3, seconds: 5, messages: 110, campaignMessages: 380, first: 3, id: 2))
        XCTAssertNil(tracker.latestPair)
        try observe(&tracker, stage: 3, seconds: 6, messages: 200, campaignMessages: 470, first: 3, id: 2)
        XCTAssertNotNil(tracker.latestPair)
        XCTAssertNil(try observe(&tracker, campaign: 2, seconds: 7, messages: 20, totalMessages: 490, first: 6, id: 3))
        XCTAssertNil(tracker.latestPair)
        XCTAssertNotNil(try observe(&tracker, campaign: 2, seconds: 8, messages: 110, totalMessages: 580, first: 6, id: 3))
        XCTAssertNil(tracker.latestPair)
        try observe(&tracker, campaign: 2, seconds: 9, messages: 200, totalMessages: 670, first: 6, id: 3)
        let pair = try XCTUnwrap(tracker.latestPair)
        XCTAssertEqual(pair.older.start.campaign, "2")
        XCTAssertEqual(pair.older.start.stage, 1)
        XCTAssertEqual(pair.older.end.snapshot, pair.newer.start)
        XCTAssertFalse(tracker.isQuarantined)
    }

    func testV3LexicographicOrderAllowsUnseenCampaignsStagesAndUInt32Maximum() throws {
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, campaign: 2, stage: 32, seconds: 1, messages: 90)
        XCTAssertNil(try observe(&tracker, campaign: UInt32.max, stage: 7, seconds: 2, messages: 20, campaignMessages: 50, totalMessages: 140, first: 1, id: 2))
        XCTAssertNotNil(try observe(&tracker, campaign: UInt32.max, stage: 7, seconds: 3, messages: 110, campaignMessages: 140, totalMessages: 230, first: 1, id: 2))
        XCTAssertFalse(tracker.isQuarantined)
    }

    func testV3ReplayedTuplesChangedCurrentUUIDAndMixedVersionsQuarantine() throws {
        let faults: [(inout ReceiverProbeSnapshot) -> Void] = [
            { $0.campaign = "1" },
            { $0.stage = 1 },
            { $0.id = "60000000-0000-4000-8000-000000000002" },
            { $0.bitRate = 500_000 },
            { $0.convention = "mpegts-null-probe-v2"; $0.campaign = nil; $0.campaignDeliveredPayloadBytes = nil },
            { $0.convention = "mpegts-null-probe-v1"; $0.campaign = nil; $0.campaignDeliveredPayloadBytes = nil; $0.stage = nil; $0.totalDeliveredPayloadBytes = nil },
        ]
        for fault in faults {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, campaign: 2, stage: 2, seconds: 1, messages: 90)
            XCTAssertNil(try observe(&tracker, campaign: 2, stage: 2, seconds: 2, messages: 180, change: fault))
            XCTAssertTrue(tracker.isQuarantined)
            tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(2.1))
            XCTAssertNil(try observe(&tracker, campaign: 3, seconds: 3, messages: 20, totalMessages: 200, first: 2, id: 3))
            XCTAssertTrue(tracker.isQuarantined)
        }
        for newCampaign: UInt32 in [1, 2] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90)
            try observe(&tracker, campaign: newCampaign, stage: 2, seconds: 2, messages: 20,
                        campaignMessages: newCampaign == 1 ? 110 : 20, totalMessages: 110, first: 1)
            XCTAssertTrue(tracker.isQuarantined, "Boundary must replace current UUID")
        }
    }

    func testV3SameCampaignPublicationDeltaAlwaysEqualsCampaignDelta() throws {
        for newStage in [2, 3] {
            for wrongTotal in [111, 140, 180] {
                var tracker = WorkerReceiverProbeTracker()
                try observe(&tracker, campaign: 2, stage: 2, seconds: 1, messages: 20, campaignMessages: 90, id: 2)
                try observe(&tracker, campaign: 2, stage: newStage, seconds: 2, messages: newStage == 2 ? 40 : 20,
                            campaignMessages: 110, totalMessages: wrongTotal, first: newStage == 2 ? 0.1 : 1,
                            id: newStage)
                XCTAssertTrue(tracker.isQuarantined)
            }
        }
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, stage: 2, seconds: 1, messages: 20, campaignMessages: 90)
        try observe(&tracker, stage: 2, seconds: 2, messages: 30, campaignMessages: 110)
        XCTAssertTrue(tracker.isQuarantined, "Same-stage campaign delta must equal stage delta")
    }

    func testV3CampaignCarryRequiresFullNewCampaignAndOldPendingReservation() throws {
        for newTotal in [50, 110, 140, 141] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90, pending: 1)
            tracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: anchor + .seconds(1.1))
            try observe(&tracker, campaign: 2, stage: 3, seconds: 2, messages: 20,
                        campaignMessages: 50, totalMessages: newTotal, first: 1, id: 2)
            XCTAssertEqual(tracker.isQuarantined, newTotal < 141)
            XCTAssertNil(tracker.latestPair)
        }
        for newTotal in [110, 111] {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90, pending: 1)
            try observe(&tracker, stage: 2, seconds: 2, messages: 20,
                        campaignMessages: newTotal, first: 1, id: 2)
            XCTAssertEqual(tracker.isQuarantined, newTotal < 111)
        }
    }

    func testV3CampaignBoundaryKeepsClockMonotonicityRequestChainAndFirstDelivery() throws {
        let faults: [(inout ReceiverProbeSnapshot) -> Void] = [
            { $0.observedAtNanoseconds = "999999999"; $0.firstDeliveredAtNanoseconds = "900000000"; $0.lastDeliveredAtNanoseconds = "990000000" },
            { $0.observedAtNanoseconds = "4000000000"; $0.lastDeliveredAtNanoseconds = "3990000000" },
            { $0.firstDeliveredAtNanoseconds = "999999999" },
        ]
        for fault in faults {
            var tracker = WorkerReceiverProbeTracker()
            try observe(&tracker, seconds: 1, messages: 90)
            try observe(&tracker, campaign: 2, seconds: 2, messages: 20, totalMessages: 110, first: 1, id: 2, change: fault)
            XCTAssertTrue(tracker.isQuarantined)
        }
        var tracker = WorkerReceiverProbeTracker()
        try observe(&tracker, seconds: 1, messages: 90)
        try observe(&tracker, campaign: 2, seconds: 1.005, messages: 0, totalMessages: 90, id: 2)
        XCTAssertTrue(tracker.isQuarantined)
    }
}

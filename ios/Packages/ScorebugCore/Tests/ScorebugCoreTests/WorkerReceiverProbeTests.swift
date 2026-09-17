import Foundation
@testable import ScorebugCore
import XCTest

final class WorkerReceiverProbeTests: XCTestCase {
    private func data() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "receiver-probe-status-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func fixture() throws -> WorkerMediaStatusResponse {
        try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: data())
    }
    private func expectation() -> WorkerReceiverProbeExpectation {
        .init(gameId: "match", generation: 2, workerId: "mac",
              publishingAttemptId: "30000000-0000-0000-0000-00000000000c",
              probeId: "60000000-0000-4000-8000-00000000000d",
              publishingGeneration: UInt64.max, bitRate: 1_000_000)
    }
    private func helper(_ response: WorkerMediaStatusResponse, at: ContinuousClock.Instant = .now,
                        duration: Duration = .zero, expected: WorkerReceiverProbeExpectation? = nil) -> WorkerReceiverProbeFreshness? {
        .init(response: response, expected: expected ?? expectation(), receivedAt: at, requestDuration: duration)
    }

    func testRateCeilingDependsOnWireVersionAndStillRequiresBoundedStage() throws {
        var snapshot = try XCTUnwrap(fixture().status.receiverProbe?.snapshot)
        snapshot.bitRate = 2_000_000
        XCTAssertNotNil(snapshot.validated)
        snapshot.bitRate = 2_000_001
        XCTAssertNil(snapshot.validated)
        snapshot.convention = "mpegts-null-probe-v2"
        snapshot.stage = 1
        snapshot.totalDeliveredPayloadBytes = snapshot.deliveredPayloadBytes
        for rate in [2_000_001, 12_000_000] {
            snapshot.bitRate = rate
            XCTAssertNotNil(snapshot.validated)
        }
        snapshot.bitRate = 12_000_001
        XCTAssertNil(snapshot.validated)
        snapshot.bitRate = 12_000_000
        snapshot.stage = nil
        XCTAssertNil(snapshot.validated)
        snapshot.stage = 33
        XCTAssertNil(snapshot.validated)
        snapshot.stage = 1
        snapshot.convention = "mpegts-null-probe-v1"
        XCTAssertNil(snapshot.validated)
    }

    func testV2GoldenIsValidatedAndRoundTrips() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "receiver-probe-status-v2", withExtension: "json", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: bytes)
        XCTAssertNotNil(response.status.receiverProbe?.snapshot.validated)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
    }

    func testV2RequiresCanonicalBoundedStageAndCumulativeBytes() throws {
        var response = try fixture()
        response.status.receiverProbe?.snapshot.convention = "mpegts-null-probe-v2"
        response.status.receiverProbe?.snapshot.stage = 3
        response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = "5264"
        var expected = expectation(); expected.stage = 3
        XCTAssertNotNil(helper(response, expected: expected))
        XCTAssertNil(helper(response))
        expected.stage = 2
        XCTAssertNil(helper(response, expected: expected))
        XCTAssertNil(helper(try fixture(), expected: expected))
        expected.stage = 3
        let changes: [(inout ReceiverProbeSnapshot) -> Void] = [
            { $0.stage = nil }, { $0.stage = 0 }, { $0.stage = 33 }, { $0.stage = Int.max },
            { $0.totalDeliveredPayloadBytes = nil }, { $0.totalDeliveredPayloadBytes = "05264" },
            { $0.totalDeliveredPayloadBytes = "5264\n" }, { $0.totalDeliveredPayloadBytes = "+5264" },
            { $0.totalDeliveredPayloadBytes = "٥٢٦٤" }, { $0.totalDeliveredPayloadBytes = "5265" },
            { $0.totalDeliveredPayloadBytes = "1316" }, { $0.totalDeliveredPayloadBytes = "16777684" },
            { $0.totalDeliveredPayloadBytes = "18446744073709551616" },
            { $0.totalDeliveredPayloadBytes = "16776368"; $0.pendingPackets = 1 },
            { $0.totalDeliveredPayloadBytes = "16776368"; $0.pendingPackets = 6 },
        ]
        for (index, change) in changes.enumerated() {
            var malformed = response; change(&malformed.status.receiverProbe!.snapshot)
            XCTAssertNil(helper(malformed, expected: expected), "fault \(index)")
        }
        response.status.receiverProbe?.snapshot.pendingPackets = 0
        response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = "16776368"
        XCTAssertNotNil(helper(response, expected: expected))
        // UInt64 parsing must also work when Int is only 32 bits (arm64_32 Watch).
        response.status.receiverProbe?.snapshot.observedAtNanoseconds = "86400000000000"
        XCTAssertNotNil(helper(response, expected: expected))
        let original = try XCTUnwrap(response.status.receiverProbe?.snapshot)
        for (key, values) in [("stage", [NSNull(), "3", 1.5, []] as [Any]),
                              ("totalDeliveredPayloadBytes", [NSNull(), 5264, []] as [Any])] {
            for value in values {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
                object[key] = value
                XCTAssertThrowsError(try JSONDecoder().decode(ReceiverProbeSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
            }
        }
    }

    func testV1CannotCarryStageOrCumulativeCountersEvenAsNull() throws {
        let original = try XCTUnwrap(fixture().status.receiverProbe?.snapshot)
        for key in ["stage", "totalDeliveredPayloadBytes"] {
            for value: Any in [NSNull(), 3, "5264", []] {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
                object[key] = value
                let bytes = try JSONSerialization.data(withJSONObject: object)
                let decoded = try? JSONDecoder().decode(ReceiverProbeSnapshot.self, from: bytes)
                XCTAssertNil(decoded?.validated, key)
            }
        }
    }

    func testSharedGoldenRoundTripsWithoutContaminatingPublicationIdentity() throws {
        let response = try fixture()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data()) as? NSDictionary)
        var next = response
        next.status.receiverProbe?.snapshot.deliveredMessages = "3"
        XCTAssertEqual(response.status.publication, next.status.publication)
        XCTAssertNotEqual(response.status.receiverProbe, next.status.receiverProbe)
        next.status.receiverProbe = nil
        let decoded = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONEncoder().encode(next))
        XCTAssertNil(decoded.status.receiverProbe)
        XCTAssertNil(helper(decoded))
    }

    func testMalformedAdditiveFieldLeavesOrdinaryStatusUsable() throws {
        for field: Any in [NSNull(), 42, [], "bad", ["snapshot": 2, "ageUpperBoundMs": 0]] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
            var status = try XCTUnwrap(object["status"] as? [String: Any])
            status["receiverProbe"] = field; object["status"] = status
            let decoded = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.status.state, .producingOutput)
            XCTAssertEqual(decoded.status.publication, try fixture().status.publication)
            XCTAssertNil(decoded.status.receiverProbe)
        }
    }

    func testNativeWorkerStatusBypassesLocalAndRemoteCaches() async throws {
        let body = try data()
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { request in
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let response = try await client.workerStatus(credential: .init(gameId: "match", deviceId: "phone", role: .capture, token: "test"))
        XCTAssertEqual(response, try fixture())
    }

    func testExplicitNullAndWrongTypedOptionalSnapshotFieldsCannotEraseInvalidity() throws {
        for key in ["invalidReason", "firstDeliveredAtNanoseconds", "lastDeliveredAtNanoseconds"] {
            for value: Any in [NSNull(), 42, []] {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
                var status = try XCTUnwrap(object["status"] as? [String: Any])
                var report = try XCTUnwrap(status["receiverProbe"] as? [String: Any])
                var snapshot = try XCTUnwrap(report["snapshot"] as? [String: Any])
                snapshot[key] = value; report["snapshot"] = snapshot; status["receiverProbe"] = report; object["status"] = status
                let decoded = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
                XCTAssertNil(decoded.status.receiverProbe, key)
                XCTAssertEqual(decoded.status.state, .producingOutput)
            }
        }
    }

    func testSnapshotAndLastDeliveryAgeIncludeRequestAndResidence() throws {
        let now = ContinuousClock.now
        let evidence = try XCTUnwrap(helper(fixture(), at: now, duration: .milliseconds(200)))
        XCTAssertEqual(evidence.snapshotAgeUpperBound(at: now), .milliseconds(251))
        XCTAssertEqual(evidence.lastDeliveryAgeUpperBound(at: now), .milliseconds(351))
        XCTAssertEqual(evidence.snapshotAgeUpperBound(at: now + .milliseconds(300)), .milliseconds(551))
        XCTAssertEqual(evidence.lastDeliveryAgeUpperBound(at: now + .milliseconds(300)), .milliseconds(651))
        XCTAssertNil(evidence.snapshotAgeUpperBound(at: now - .nanoseconds(1)))
        XCTAssertNil(evidence.lastDeliveryAgeUpperBound(at: now - .nanoseconds(1)))
    }

    func testPollingUnchangedCountersCannotRefreshLastDelivery() throws {
        let now = ContinuousClock.now
        var response = try fixture()
        let first = try XCTUnwrap(helper(response, at: now))
        response.status.receiverProbe?.snapshot.observedAtNanoseconds = "2000000000"
        let later = try XCTUnwrap(helper(response, at: now + .seconds(1)))
        XCTAssertEqual(first.lastDeliveryAgeUpperBound(at: now + .seconds(1)), later.lastDeliveryAgeUpperBound(at: now + .seconds(1)))
    }

    func testExplicitLocalExpectationRejectsEveryWrongOwner() throws {
        let changes: [(inout WorkerReceiverProbeExpectation) -> Void] = [
            { $0.gameId = "other" }, { $0.generation = 3 }, { $0.workerId = "other" },
            { $0.publishingAttemptId = "40000000-0000-0000-0000-00000000000e" },
            { $0.probeId = "70000000-0000-0000-0000-00000000000e" },
            { $0.publishingGeneration = 1 }, { $0.bitRate = 2_000_000 },
        ]
        for change in changes {
            var expected = expectation(); change(&expected)
            XCTAssertNil(helper(try fixture(), expected: expected))
        }
    }

    func testImmutableEvidenceRetainsFullWorkerAndPublicationScope() throws {
        var response = try fixture()
        let evidence = try XCTUnwrap(helper(response))
        response.status.workerEpoch = "other"; response.status.observation?.attempt = 3
        response.status.publication?.publisherId = "other"
        response.status.receiverProbe?.snapshot.id = "other"
        XCTAssertEqual(evidence.workerEpoch, "d6c217a3-27c5-44ea-a55e-3b951c67981f")
        XCTAssertEqual(evidence.workerAttempt, 1)
        XCTAssertEqual(evidence.publication, try fixture().status.publication)
        XCTAssertEqual(evidence.expected, expectation())
        XCTAssertEqual(evidence.snapshot, try fixture().status.receiverProbe?.snapshot)
    }

    func testExpiryConsumesRequestBudgetAndRejectsInvalidClockInputs() throws {
        let now = ContinuousClock.now
        let evidence = try XCTUnwrap(helper(fixture(), at: now, duration: .milliseconds(200)))
        XCTAssertNotNil(evidence.snapshotAgeUpperBound(at: now + .milliseconds(3799)))
        XCTAssertNil(evidence.snapshotAgeUpperBound(at: now + .milliseconds(3800)))
        XCTAssertNil(evidence.lastDeliveryAgeUpperBound(at: now + .milliseconds(3800)))
        for duration: Duration in [.seconds(4), .seconds(5), .nanoseconds(-1), .seconds(Int64.max)] {
            XCTAssertNil(helper(try fixture(), duration: duration))
        }
        for expiry in [nil, "bad", "2040-01-01T00:00:01.000Z"] {
            var response = try fixture(); response.status.expiresAt = expiry
            XCTAssertNil(helper(response))
        }
    }

    func testRejectsMalformedNumericAndCrossFieldEvidence() throws {
        let changes: [(inout ReceiverProbeSnapshot) -> Void] = [
            { $0.convention = "other" }, { $0.id = $0.id.uppercased() },
            { $0.id += "\n" }, { $0.id = "00000000-0000-0000-0000-000000000000" },
            { $0.publishingGeneration = "0" }, { $0.publishingGeneration = "18446744073709551616" },
            { $0.publishingGeneration = "01" }, { $0.publishingGeneration = "+1" },
            { $0.publishingGeneration = "1\n" }, { $0.publishingGeneration = "١" },
            { $0.bitRate = 0 }, { $0.bitRate = 2_000_001 },
            { $0.deliveredMessages = "-1" }, { $0.deliveredMessages = "02" },
            { $0.deliveredMessages = "3" }, { $0.deliveredPayloadBytes = "2633" },
            { $0.nextSequence = "3" }, { $0.pendingPackets = -1 }, { $0.pendingPackets = 7 },
            { $0.observedAtNanoseconds = "86400000000001" },
            { $0.observedAtNanoseconds = "1e9" }, { $0.observedAtNanoseconds = "1000000000\n" },
            { $0.firstDeliveredAtNanoseconds = nil }, { $0.lastDeliveredAtNanoseconds = nil },
            { $0.firstDeliveredAtNanoseconds = "900000001" },
            { $0.lastDeliveredAtNanoseconds = "1000000001" },
            { $0.invalidReason = "sequence" }, { $0.invalidReason = "future-unknown" },
            { $0.deliveredMessages = "0"; $0.deliveredPayloadBytes = "0"; $0.nextSequence = "0" },
            { $0.deliveredMessages = "1"; $0.deliveredPayloadBytes = "1316"; $0.nextSequence = "1" },
            { $0.deliveredMessages = "12748"; $0.deliveredPayloadBytes = "16776368"; $0.nextSequence = "12748"; $0.pendingPackets = 1 },
            { $0.deliveredMessages = "12748"; $0.deliveredPayloadBytes = "16776368"; $0.nextSequence = "12748"; $0.pendingPackets = 6 },
            { $0.deliveredMessages = "12749"; $0.deliveredPayloadBytes = "16777684"; $0.nextSequence = "12749" },
        ]
        for (index, change) in changes.enumerated() {
            var response = try fixture(); change(&response.status.receiverProbe!.snapshot)
            XCTAssertNil(helper(response), "fault \(index)")
        }
    }

    func testRejectsInvalidStatusScopeAndAge() throws {
        let changes: [(inout WorkerMediaStatus) -> Void] = [
            { $0.gameId = "other" }, { $0.generation = 3 }, { $0.workerId = nil },
            { $0.workerEpoch = nil }, { $0.workerEpoch = "invalid" },
            { $0.state = .stale }, { $0.observation = nil }, { $0.observation?.attempt = 0 },
            { $0.observation?.gameId = "other" }, { $0.observation?.generation = 3 },
            { $0.observation?.state = .starting }, { $0.publication = nil },
            { let publisher = $0.publication!.publisherId; $0.publication?.readerId = publisher },
            { $0.receiverProbe = nil },
        ]
        for change in changes {
            var response = try fixture(); change(&response.status); XCTAssertNil(helper(response))
        }
        for age in [-1.0, 0.5, .nan, .infinity, -.infinity, 9_007_199_254_740_992] {
            var response = try fixture(); response.status.receiverProbe?.ageUpperBoundMs = age
            XCTAssertNil(helper(response))
        }
    }

    func testEmptyAndSingleMessageCountersDoNotInventLastDelivery() throws {
        var response = try fixture()
        response.status.receiverProbe?.snapshot.deliveredMessages = "0"
        response.status.receiverProbe?.snapshot.deliveredPayloadBytes = "0"
        response.status.receiverProbe?.snapshot.nextSequence = "0"
        response.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = nil
        response.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = nil
        let now = ContinuousClock.now
        let empty = try XCTUnwrap(helper(response, at: now))
        XCTAssertEqual(empty.snapshotAgeUpperBound(at: now), .milliseconds(51))
        XCTAssertNil(empty.lastDeliveryAgeUpperBound(at: now))
        response.status.receiverProbe?.snapshot.deliveredMessages = "1"
        response.status.receiverProbe?.snapshot.deliveredPayloadBytes = "1316"
        response.status.receiverProbe?.snapshot.nextSequence = "1"
        response.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = "0"
        response.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = "0"
        XCTAssertEqual(try XCTUnwrap(helper(response, at: now)).lastDeliveryAgeUpperBound(at: now), .milliseconds(1051))
    }

    func testExactArithmeticAtSafeMillisecondBoundaryDoesNotOverflowWatch() throws {
        let maximum: Int64 = 9_007_199_254_740_991
        let now = ContinuousClock.now
        var response = try fixture()
        response.status.receiverProbe?.ageUpperBoundMs = Double(maximum)
        XCTAssertNil(helper(response, duration: .nanoseconds(1)))
        let evidence = try XCTUnwrap(helper(response, at: now))
        XCTAssertEqual(evidence.snapshotAgeUpperBound(at: now), .milliseconds(maximum))
        XCTAssertNil(evidence.snapshotAgeUpperBound(at: now + .nanoseconds(1)))
        XCTAssertNil(evidence.lastDeliveryAgeUpperBound(at: now))
        response.status.receiverProbe?.ageUpperBoundMs = Double(maximum - 101)
        let edge = try XCTUnwrap(helper(response, at: now, duration: .microseconds(500)))
        XCTAssertEqual(edge.lastDeliveryAgeUpperBound(at: now + .microseconds(500)), .milliseconds(maximum))
        XCTAssertNil(edge.lastDeliveryAgeUpperBound(at: now + .microseconds(501)))
    }
}

import Foundation
import ScorebugCore
import XCTest

final class WorkerStatusTests: XCTestCase {
    private let wire = #"{"status":{"gameId":"match","generation":2,"workerId":"mac","state":"producing_output","observation":{"gameId":"match","generation":2,"state":"producing_output","reason":null,"attempt":1,"frame":12,"outTimeUs":400000,"scoreRevision":null},"observedAt":"2040-01-01T00:00:00.000Z","expiresAt":"2040-01-01T00:00:05.000Z"},"serverTime":"2040-01-01T00:00:01.000Z"}"#

    func testSharedCanonicalFixtureRoundTripsEveryResponse() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-status-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: data)
        XCTAssertEqual(Set(fixture.keys), Set(["unknown", "current", "stale", "stopped"]))
        XCTAssertEqual(fixture["current"]?.status.observation?.scoreRevision, 1)
        XCTAssertEqual(fixture["unknown"]?.status.state, .unknown)
        XCTAssertEqual(fixture["stale"]?.status.state, .stale)
        XCTAssertEqual(fixture["stopped"]?.status.state, .notRequested)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testSharedWorkerEpochFixtureRoundTripsEveryResponse() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-epoch-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: data)
        XCTAssertEqual(Set(fixture.keys), Set(["current", "stale", "replacement", "legacy"]))
        let current = try XCTUnwrap(fixture["current"]?.status)
        let stale = try XCTUnwrap(fixture["stale"]?.status)
        let replacement = try XCTUnwrap(fixture["replacement"]?.status)
        let legacy = try XCTUnwrap(fixture["legacy"]?.status)
        XCTAssertEqual(current.workerEpoch, "d6c217a3-27c5-44ea-a55e-3b951c67981f")
        XCTAssertEqual(stale.workerEpoch, current.workerEpoch)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(replacement.workerEpoch, "d1e71c84-e637-4215-b5d2-3840e5a6fe40")
        XCTAssertNotEqual(replacement.workerEpoch, current.workerEpoch)
        XCTAssertEqual(replacement.workerId, current.workerId)
        XCTAssertEqual(replacement.observation?.attempt, current.observation?.attempt)
        XCTAssertNil(legacy.workerEpoch)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testWorkerEpochIsAnOpaqueOptionalString() throws {
        for epoch in ["", "opaque epoch / β"] {
            let status = WorkerMediaStatus(gameId: "match", generation: 2, workerId: "mac", state: .unknown,
                                           observation: nil, observedAt: nil, expiresAt: nil, workerEpoch: epoch)
            let decoded = try JSONDecoder().decode(WorkerMediaStatus.self, from: JSONEncoder().encode(status))
            XCTAssertEqual(decoded.workerEpoch, epoch)
            XCTAssertEqual(decoded.state, .unknown)
            XCTAssertNil(decoded.observation)
        }
    }

    func testWorkerEpochRejectsNonStringJSONValues() throws {
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
        var status = try XCTUnwrap(response["status"] as? [String: Any])
        for epoch: Any in [42, true, ["epoch"], ["id": "epoch"]] {
            status["workerEpoch"] = epoch
            response["status"] = status
            let data = try JSONSerialization.data(withJSONObject: response)
            XCTAssertThrowsError(try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: data)) { error in
                guard case DecodingError.typeMismatch = error else {
                    return XCTFail("Expected a type mismatch, got \(error)")
                }
            }
        }
    }

    func testStatusHTTPClientPreservesWorkerEpochFixtureValues() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-epoch-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        for name in ["current", "stale", "replacement", "legacy"] {
            let response = try XCTUnwrap(fixture[name])
            let status = try XCTUnwrap(response["status"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: response)
            let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let result = try await client.workerStatus(credential: MatchCredential(gameId: "match", deviceId: "phone", role: .score, token: "scoped"))
            XCTAssertEqual(result.status.workerEpoch, status["workerEpoch"] as? String, name)
        }
    }

    func testWireRoundTripPreservesNullsAndAllStateAndReasonValues() throws {
        let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(wire.utf8))
        XCTAssertEqual(response.status.state, .producingOutput)
        XCTAssertNil(response.status.observation?.reason)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? NSDictionary)
        XCTAssertEqual(WorkerState.allCases.map(\.rawValue), ["idle", "waiting_source", "starting", "producing_output", "stopping", "retrying", "failed", "closed"])
        XCTAssertEqual(WorkerReason.allCases.map(\.rawValue), ["assignment_changed", "source_unavailable", "output_mismatch", "control_unavailable", "control_timeout", "output_timeout", "process_exited", "score_write_failed", "start_failed", "retry_budget", "retry_delay", "shutdown"])
        for state in WorkerMediaState.allCases {
            let status = WorkerMediaStatus(gameId: "match", generation: 2, workerId: nil, state: state, observation: nil, observedAt: nil, expiresAt: nil)
            let data = try JSONEncoder().encode(status)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            XCTAssertTrue(object["workerId"] is NSNull)
            XCTAssertTrue(object["observation"] is NSNull)
            XCTAssertTrue(object["observedAt"] is NSNull)
            XCTAssertTrue(object["expiresAt"] is NSNull)
            XCTAssertNil(status.workerEpoch)
            XCTAssertNil(object["workerEpoch"])
            XCTAssertEqual(try JSONDecoder().decode(WorkerMediaStatus.self, from: data), status)
        }
    }

    func testMonotonicFreshnessIgnoresDeviceWallClockAndSubtractsRequestElapsed() throws {
        let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(wire.utf8))
        let receipt = ContinuousClock.now
        let freshness = WorkerStatusFreshness(response: response, receivedAt: receipt, requestDuration: .seconds(1))
        XCTAssertTrue(freshness.isFresh(at: receipt.advanced(by: .seconds(2))))
        XCTAssertFalse(freshness.isFresh(at: receipt.advanced(by: .seconds(3))))
    }

    func testMalformedExpiredAndOverlongTTLFailConservatively() throws {
        var response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(wire.utf8))
        let receipt = ContinuousClock.now
        for expiry in [nil, "malformed", "2040-01-01T00:00:00Z"] as [String?] {
            response.status.expiresAt = expiry
            XCTAssertFalse(WorkerStatusFreshness(response: response, receivedAt: receipt, requestDuration: .zero).isFresh(at: receipt))
        }
        response.status.expiresAt = "2040-01-01T00:10:00Z"
        let capped = WorkerStatusFreshness(response: response, receivedAt: receipt, requestDuration: .seconds(1))
        XCTAssertTrue(capped.isFresh(at: receipt.advanced(by: .seconds(3))))
        XCTAssertFalse(capped.isFresh(at: receipt.advanced(by: .seconds(4))))
        response.serverTime = "bad"
        XCTAssertFalse(WorkerStatusFreshness(response: response, receivedAt: receipt, requestDuration: .zero).isFresh(at: receipt))
    }

    func testStatusRouteUsesScopedCredentialAndRejectsAuthorizationErrors() async throws {
        for role in [MatchRole.score, .capture] {
            let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control"), transport: { [wire] request in
                XCTAssertEqual(request.url?.path, "/control/v1/matches/match/media/status")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped")
                XCTAssertNil(request.httpBody)
                return (Data(wire.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let result = try await client.workerStatus(credential: MatchCredential(gameId: "match", deviceId: "phone", role: role, token: "scoped"))
            XCTAssertEqual(result.status.state, .producingOutput)
        }
        for (status, expected) in [(401, MatchClientError.unauthorized), (403, .forbidden)] {
            let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do {
                _ = try await client.workerStatus(credential: MatchCredential(gameId: "match", deviceId: "phone", role: .score, token: "scoped"))
                XCTFail("Expected rejection")
            } catch let error as MatchClientError { XCTAssertEqual(error, expected) }
        }
    }
}

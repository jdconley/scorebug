import Foundation
import XCTest
@testable import ScorebugCore

final class MatchClientTests: XCTestCase {
    private let snapshotJSON = ##"{"id":"match-1","createdAt":"2026-09-14T01:00:00.123Z","revision":2,"teams":{"home":{"name":"Home","shortName":"HOM","color":"#112233"},"away":{"name":"Away","shortName":"AWY","color":"#445566"}},"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":1,"away":0,"set":2,"homeSets":1,"awaySets":0},"completedSets":[{"set":1,"home":25,"away":23,"winner":"home","overrideReason":null}],"status":"active","endReason":null,"canUndo":true,"scorer":{"deviceId":"phone-1","epoch":1},"broadcast":{"desired":"stopped","generation":0}}"##
    private let credential = MatchCredential(gameId: "match-1", deviceId: "phone-1", role: .score, token: "scoped-secret")

    func testSnapshotRoundTripPreservesWireNullsAndMillisecondDates() throws {
        let data = Data(snapshotJSON.utf8)
        let snapshot = try JSONDecoder().decode(MatchSnapshot.self, from: data)
        XCTAssertEqual(snapshot.createdAt, "2026-09-14T01:00:00.123Z")
        XCTAssertEqual(snapshot.completedSets.first?.winner, .home)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testEveryOperationUsesTheCanonicalDiscriminatorAndFlatPayload() throws {
        let cases: [(MatchOperation, String)] = [
            (.awardPoint(side: .away), #"{"type":"award_point","side":"away"}"#),
            (.undo, #"{"type":"undo"}"#),
            (.endSet(winner: nil, overrideReason: nil), #"{"type":"end_set"}"#),
            (.endSet(winner: .home, overrideReason: "Forfeit"), #"{"type":"end_set","winner":"home","overrideReason":"Forfeit"}"#),
            (.endMatch(reason: "Finished"), #"{"type":"end_match","reason":"Finished"}"#),
            (.takeOver, #"{"type":"take_over"}"#),
        ]
        for (operation, expected) in cases {
            let encoded = try JSONEncoder().encode(operation)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
            XCTAssertEqual(try JSONDecoder().decode(MatchOperation.self, from: encoded), operation)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(MatchOperation.self, from: Data(#"{"type":"future"}"#.utf8)))
    }

    func testCreatePreservesEndpointBasePathAndUsesInstallationCredential() async throws {
        let snapshot = try JSONDecoder().decode(MatchSnapshot.self, from: Data(snapshotJSON.utf8))
        let body = "{\"snapshot\":\(snapshotJSON),\"credential\":{\"gameId\":\"match-1\",\"deviceId\":\"phone-1\",\"role\":\"score\",\"token\":\"scoped-secret\"},\"serverTime\":\"2026-09-14T01:00:00.123Z\"}"
        let client = try client(status: 201, body: body) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/control/v1/matches")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer install-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertGreaterThan(request.timeoutInterval, 0)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 30)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(payload.keys), Set(["id", "deviceId", "teams", "rules"]))
            XCTAssertEqual(payload["id"] as? String, "match-1")
            XCTAssertTrue((payload["rules"] as? [String: Any])?["pointCap"] is NSNull)
        }
        let result = try await client.create(id: "match-1", deviceId: "phone-1", teams: snapshot.teams, rules: snapshot.rules, installationToken: "install-secret")
        XCTAssertEqual(result.credential, credential)
        XCTAssertEqual(result.snapshot, snapshot)
    }

    func testActiveJoinAndSnapshotReadTheirEnvelopes() async throws {
        let active = try client(status: 200, body: #"{"snapshot":null,"serverTime":"2026-09-14T01:00:00Z"}"#) { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/active")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation")
        }
        let activeResponse = try await active.active(installationToken: "installation")
        XCTAssertNil(activeResponse.snapshot)
        let joinBody = "{\"snapshot\":\(snapshotJSON),\"credential\":{\"gameId\":\"match-1\",\"deviceId\":\"phone-1\",\"role\":\"score\",\"token\":\"scoped-secret\"},\"serverTime\":\"now\"}"
        let join = try client(status: 200, body: joinBody) { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/match-1/join")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation")
            let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
            XCTAssertEqual(payload, ["deviceId": "phone-1", "role": "score"])
        }
        let joined = try await join.join(gameId: "match-1", deviceId: "phone-1", role: .score, installationToken: "installation")
        XCTAssertEqual(joined.credential, credential)
        let reader = try client(status: 200, body: "{\"snapshot\":\(snapshotJSON),\"serverTime\":\"now\"}") { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/match-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-secret")
        }
        let read = try await reader.snapshot(credential: credential)
        XCTAssertEqual(read.snapshot.id, "match-1")
    }

    func testExecuteReturnsAcceptedAndConflictOutcomesWithExactCommandBody() async throws {
        let command = MatchCommand(commandId: "cmd-1", gameId: "match-1", deviceId: "phone-1", expectedRevision: 1, scorerEpoch: 1, issuedAt: "2026-09-14T01:00:00.123Z", operation: .awardPoint(side: .home))
        for (status, accepted, error) in [(200, true, "null"), (409, false, "\"stale_revision\"")] {
            let body = "{\"commandId\":\"cmd-1\",\"accepted\":\(accepted),\"error\":\(error),\"snapshot\":\(snapshotJSON)}"
            let client = try client(status: status, body: body) { request in
                XCTAssertEqual(request.url?.path, "/control/v1/matches/match-1/commands")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-secret")
                XCTAssertEqual(try JSONDecoder().decode(MatchCommand.self, from: XCTUnwrap(request.httpBody)), command)
            }
            let outcome = try await client.execute(command, credential: credential)
            XCTAssertEqual(outcome.accepted, accepted)
            XCTAssertEqual(outcome.snapshot.revision, 2)
        }
    }

    func testReceiptReturnsNilOnlyForCommandNotFound() async throws {
        let missing = try client(status: 404, body: #"{"error":"command_not_found"}"#) { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/match-1/commands/cmd-1")
            XCTAssertEqual(request.httpMethod, "GET")
        }
        let missingReceipt = try await missing.receipt(commandId: "cmd-1", credential: credential)
        XCTAssertNil(missingReceipt)
        for (status, body) in [(500, #"{"error":"command_not_found"}"#), (404, #"{"error":"match_not_found"}"#)] {
            let failing = try client(status: status, body: body)
            do { _ = try await failing.receipt(commandId: "cmd-1", credential: credential); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, .http(status: status, code: status == 500 ? "command_not_found" : "match_not_found")) }
        }
        let found = try client(status: 200, body: "{\"commandId\":\"cmd-1\",\"accepted\":false,\"error\":\"stale_revision\",\"snapshot\":\(snapshotJSON)}")
        let receipt = try await found.receipt(commandId: "cmd-1", credential: credential)
        XCTAssertEqual(receipt?.accepted, false)
    }

    func testAuthenticationAndMalformedResponsesAreErrors() async throws {
        for (status, expected) in [(401, MatchClientError.unauthorized), (403, .forbidden)] {
            let client = try client(status: status, body: #"{"error":"unauthorized"}"#)
            do { _ = try await client.snapshot(credential: credential); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, expected) }
        }
        let malformed = try client(status: 200, body: "not json")
        do { _ = try await malformed.snapshot(credential: credential); XCTFail("Should throw") }
        catch is DecodingError { }
    }

    func testCanonicalTypeScriptFixtureRoundTripsWithoutWireChanges() throws {
        struct Fixture: Codable {
            let creation: MatchCreation
            let command: MatchCommand
            let snapshot: MatchSnapshot
            let outcome: CommandOutcome
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertEqual(fixture.command.expectedRevision, fixture.snapshot.revision)
        XCTAssertEqual(fixture.outcome.snapshot.revision, fixture.snapshot.revision + 1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testMalformedConflictIsNotTreatedAsAnAcknowledgement() async throws {
        let command = MatchCommand(commandId: "cmd-1", gameId: "match-1", deviceId: "phone-1", expectedRevision: 1, scorerEpoch: 1, issuedAt: "2026-09-14T01:00:00Z", operation: .undo)
        let client = try client(status: 409, body: #"{"error":"conflict"}"#)
        do { _ = try await client.execute(command, credential: credential); XCTFail("Should throw") }
        catch is DecodingError { }
    }

    func testReceiptRejectsMalformedNotFoundBody() async throws {
        let client = try client(status: 404, body: "not json")
        do { _ = try await client.receipt(commandId: "cmd-1", credential: credential); XCTFail("Should throw") }
        catch let error as MatchClientError { XCTAssertEqual(error, .http(status: 404, code: nil)) }
    }

    func testTransportFailurePropagatesWithoutInventingAReceipt() async throws {
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:3000"), transport: { _ in
            throw URLError(.timedOut)
        })
        do { _ = try await client.receipt(commandId: "cmd-1", credential: credential); XCTFail("Should throw") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testRejectsIdentifiersThatCouldEscapeTheScopedPath() async throws {
        let client = try client(status: 200, body: "{}") { _ in XCTFail("Must not send request") }
        for commandId in ["../other", "foo/bar", "%2f", "", String(repeating: "x", count: 129)] {
            do { _ = try await client.receipt(commandId: commandId, credential: credential); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, .invalidIdentifier) }
        }
    }

    func testNonHTTPResponseCannotBeDecodedAsSuccess() async throws {
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:3000"), transport: { request in
            (Data("{}".utf8), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 2, textEncodingName: nil))
        })
        do { _ = try await client.active(installationToken: "installation"); XCTFail("Should throw") }
        catch let error as MatchClientError { XCTAssertEqual(error, .invalidResponse) }
    }

    private func client(status: Int, body: String, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control/"), transport: { request in
            try inspect(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

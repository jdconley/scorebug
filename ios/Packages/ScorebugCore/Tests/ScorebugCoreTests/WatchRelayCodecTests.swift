import Foundation
import XCTest
@testable import ScorebugCore

final class WatchRelayCodecTests: XCTestCase {
    private let device = "00000000-0000-4000-8000-000000000014"
    private let pairing = "00000000-0000-4000-8000-000000000015"
    private let requestID = "00000000-0000-4000-8000-000000000016"
    private let date = "2026-09-14T01:00:00.123Z"
    private var scope: WatchRelayScope {
        WatchRelayScope(endpoint: "https://example.com/control", gameId: "fixture-game", watchDeviceId: device, pairingId: pairing)
    }
    private var credential: MatchCredential {
        MatchCredential(gameId: scope.gameId, deviceId: device, role: .score, token: String(repeating: "a", count: 43))
    }
    private func command(_ operation: MatchOperation = .awardPoint(side: .home)) -> MatchCommand {
        MatchCommand(commandId: "durable-command", gameId: scope.gameId, deviceId: device,
            expectedRevision: 0, scorerEpoch: 1, issuedAt: date, operation: operation)
    }
    private func request(_ operation: WatchRelayOperation = .snapshot) -> WatchRelayRequest {
        WatchRelayRequest(requestId: requestID, scope: scope, credential: credential, operation: operation)
    }
    private func snapshot() throws -> MatchSnapshot {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot
    }
    private func outcome(accepted: Bool = true) throws -> CommandOutcome {
        CommandOutcome(commandId: command().commandId, accepted: accepted,
            error: accepted ? nil : "revision_conflict", snapshot: try snapshot())
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func rejectRequest(_ patch: (inout [String: Any]) -> Void) throws {
        var value = try object(request(.execute(command())))
        patch(&value)
        XCTAssertThrowsError(try WatchRelayCodec.decodeRequest(data(value))) {
            XCTAssertEqual($0 as? WatchRelayCodecError, .invalidMessage)
        }
    }
    private func rejectReply(_ patch: (inout [String: Any]) -> Void) throws {
        let expected = request(.execute(command()))
        var value = try object(WatchRelayReply(request: expected, result: .outcome(try outcome())))
        patch(&value)
        XCTAssertThrowsError(try WatchRelayCodec.decodeReply(data(value), for: expected))
    }

    func testRoundTripsEveryScoringOperationPreservingExactDurableValues() throws {
        let operations: [MatchOperation] = [.awardPoint(side: .away), .undo, .endSet(winner: nil, overrideReason: nil),
            .endSet(winner: .away, overrideReason: "  Referee awarded set  "), .endSet(winner: .home, overrideReason: nil),
            .endMatch(reason: "  Weather \n"), .takeOver]
        for operation in operations {
            let value = request(.execute(command(operation)))
            XCTAssertEqual(try WatchRelayCodec.decodeRequest(WatchRelayCodec.encodeRequest(value)), value)
        }
        for value in [request(), request(.receipt(commandId: "original-id"))] {
            XCTAssertEqual(try WatchRelayCodec.decodeRequest(WatchRelayCodec.encodeRequest(value)), value)
        }
    }

    func testRoundTripsTypedRepliesWithoutRequiringCurrentScorerToBeTheWatch() throws {
        let pairs: [(WatchRelayRequest, WatchRelayResult)] = [
            (request(), .snapshot(MatchSnapshotResponse(snapshot: try snapshot(), serverTime: date))),
            (request(.execute(command())), .outcome(try outcome())),
            (request(.execute(command())), .outcome(try outcome(accepted: false))),
            (request(.receipt(commandId: command().commandId)), .receiptFound(try outcome())),
            (request(.receipt(commandId: command().commandId)), .receiptAbsent),
        ]
        for (expected, result) in pairs {
            let reply = WatchRelayReply(request: expected, result: result)
            XCTAssertEqual(try WatchRelayCodec.decodeReply(WatchRelayCodec.encodeReply(reply, for: expected), for: expected), reply)
        }
    }

    func testFailuresRemainDistinctFromAuthoritativeReceiptAbsence() throws {
        let failures: [WatchRelayFailure] = [.unauthorized, .forbidden, .http(status: 503, code: "server_unavailable"),
            .http(status: 404, code: nil), .invalidResponse, .invalidRequest, .scopeMismatch, .unavailable, .cancelled, .busy]
        let expected = request(.receipt(commandId: "original-id"))
        for failure in failures {
            let reply = WatchRelayReply(request: expected, result: .failure(failure))
            let decoded = try WatchRelayCodec.decodeReply(WatchRelayCodec.encodeReply(reply, for: expected), for: expected)
            XCTAssertEqual(decoded.result, .failure(failure))
            XCTAssertNotEqual(decoded.result, .receiptAbsent)
        }
    }

    func testMaximalEscapedSnapshotAndLargeScoresFitReplyBudget() throws {
        var value = try snapshot()
        let reason = String(repeating: "\u{0001}", count: 500)
        let team = MatchTeam(name: String(repeating: "\u{0001}", count: 80), shortName: String(repeating: "\u{0001}", count: 8), color: "#ABCDEF")
        value.teams = MatchTeams(home: team, away: team)
        value.rules.bestOf = 5
        value.score = MatchScore(home: 1000, away: 998, set: 5, homeSets: 3, awaySets: 2)
        value.completedSets = (1...5).map {
            MatchSetResult(set: $0, home: $0.isMultiple(of: 2) ? 998 : 1000,
                away: $0.isMultiple(of: 2) ? 1000 : 998,
                winner: $0.isMultiple(of: 2) ? .away : .home, overrideReason: reason)
        }
        value.status = .ended; value.endReason = reason
        let expected = request()
        let reply = WatchRelayReply(request: expected, result: .snapshot(MatchSnapshotResponse(snapshot: value, serverTime: date)))
        let encoded = try WatchRelayCodec.encodeReply(reply, for: expected)
        XCTAssertGreaterThan(encoded.count, 18000)
        XCTAssertLessThan(encoded.count, WatchRelayCodec.maximumReplyBytes)
        XCTAssertEqual(try WatchRelayCodec.decodeReply(encoded, for: expected), reply)
        value.completedSets.append(value.completedSets[0])
        XCTAssertThrowsError(try WatchRelayCodec.encodeReply(WatchRelayReply(request: expected,
            result: .snapshot(MatchSnapshotResponse(snapshot: value, serverTime: date))), for: expected))
    }

    func testStringLimitsUseUTF16AndDoNotRewriteCommandWhitespace() throws {
        let legal = String(repeating: "😀", count: 250)
        let value = request(.execute(command(.endMatch(reason: " \u{FEFF}" + legal + "\u{FEFF} "))))
        XCTAssertEqual(try WatchRelayCodec.decodeRequest(WatchRelayCodec.encodeRequest(value)), value)
        XCTAssertThrowsError(try WatchRelayCodec.encodeRequest(request(.execute(command(.endMatch(reason: legal + "a"))))))
        XCTAssertThrowsError(try WatchRelayCodec.encodeRequest(request(.execute(command(.endMatch(reason: "\u{FEFF}"))))))
        // NEXT LINE is Foundation whitespace but not ECMAScript TrimString.
        XCTAssertNoThrow(try WatchRelayCodec.encodeRequest(request(.execute(command(.endMatch(reason: "\u{0085}"))))))
        var snapshot = try snapshot()
        snapshot.teams.home.name = String(repeating: "😀", count: 40)
        let expected = request()
        func reply() -> WatchRelayReply { WatchRelayReply(request: expected, result: .snapshot(MatchSnapshotResponse(snapshot: snapshot, serverTime: date))) }
        XCTAssertNoThrow(try WatchRelayCodec.encodeReply(reply(), for: expected))
        snapshot.teams.home.name += "a"
        XCTAssertThrowsError(try WatchRelayCodec.encodeReply(reply(), for: expected))
    }

    func testByteCeilingsAreCheckedBeforeParsingIncludingWhitespace() throws {
        let original = try WatchRelayCodec.encodeRequest(request())
        let boundary = original + Data(repeating: 32, count: WatchRelayCodec.maximumRequestBytes - original.count)
        XCTAssertEqual(try WatchRelayCodec.decodeRequest(boundary), request())
        XCTAssertThrowsError(try WatchRelayCodec.decodeRequest(boundary + Data([32])))
        let expected = request(.receipt(commandId: "original-id"))
        let reply = WatchRelayReply(request: expected, result: .receiptAbsent)
        let encoded = try WatchRelayCodec.encodeReply(reply, for: expected)
        let replyBoundary = encoded + Data(repeating: 32, count: WatchRelayCodec.maximumReplyBytes - encoded.count)
        XCTAssertEqual(try WatchRelayCodec.decodeReply(replyBoundary, for: expected), reply)
        XCTAssertThrowsError(try WatchRelayCodec.decodeReply(replyBoundary + Data([32]), for: expected))
    }

    func testCanonicalScopeRequiresValidIdentityAndSyntaxButDoesNotAuthorizeAnEndpoint() throws {
        XCTAssertNoThrow(try WatchRelayCodec.validateScope(scope))
        for endpoint in ["https://EXAMPLE.com/control", "https://example.com/control/", "https://example.com:443/control", "http://public.example", "https://a:b@example.com", "https://example.com?token=x"] {
            XCTAssertThrowsError(try WatchRelayCodec.validateScope(WatchRelayScope(endpoint: endpoint, gameId: scope.gameId, watchDeviceId: device, pairingId: pairing)))
        }
        XCTAssertNoThrow(try WatchRelayCodec.validateScope(WatchRelayScope(endpoint: "http://192.168.1.2:8080", gameId: scope.gameId, watchDeviceId: device, pairingId: pairing)))
        for field in ["gameId", "watchDeviceId", "pairingId"] {
            try rejectRequest { object in
                var nested = object["scope"] as! [String: Any]; nested[field] = "../invalid"; object["scope"] = nested
            }
        }
    }

    func testRequestsRejectMismatchedCredentialCommandAndForbiddenOperations() throws {
        for patch in [["role": "capture"], ["gameId": "other"], ["deviceId": pairing], ["token": "secret\r\nheader"], ["token": String(repeating: "a", count: 44)]] {
            try rejectRequest { object in
                var nested = object["credential"] as! [String: Any]; nested.merge(patch) { _, new in new }; object["credential"] = nested
            }
        }
        for field in ["gameId", "deviceId"] {
            try rejectRequest { object in
                var operation = object["operation"] as! [String: Any]
                var command = operation["command"] as! [String: Any]; command[field] = "other"
                operation["command"] = command; object["operation"] = operation
            }
        }
        for type in ["create", "join", "publish", "execute_broadcast", "redeem", "http"] {
            try rejectRequest { $0["operation"] = ["type": type] }
        }
    }

    func testUnknownNestedKeysAndNullRequiredFieldsFailClosed() throws {
        try rejectRequest { $0["installationToken"] = "never-forward" }
        for field in ["scope", "credential", "operation"] {
            try rejectRequest { object in
                var nested = object[field] as! [String: Any]; nested["url"] = "https://arbitrary.example"; object[field] = nested
            }
            try rejectRequest { $0[field] = NSNull() }
        }
        try rejectRequest { object in
            var operation = object["operation"] as! [String: Any]
            var command = operation["command"] as! [String: Any]
            command["operation"] = ["type": "undo", "installationToken": "never-forward"]
            operation["command"] = command; object["operation"] = operation
        }
        try rejectReply { object in
            var result = object["result"] as! [String: Any]
            var outcome = result["value"] as! [String: Any]
            var snapshot = outcome["snapshot"] as! [String: Any]
            var teams = snapshot["teams"] as! [String: Any]
            var home = teams["home"] as! [String: Any]; home["extra"] = true
            teams["home"] = home; snapshot["teams"] = teams; outcome["snapshot"] = snapshot
            result["value"] = outcome; object["result"] = result
        }
    }

    func testDuplicateEscapedKeysMalformedJSONAndExcessiveDepthAreRejected() throws {
        let encoded = try WatchRelayCodec.encodeRequest(request(.execute(command())))
        let text = String(decoding: encoded, as: UTF8.self)
        let duplicateRoot = "{\"version\":1," + String(text.dropFirst())
        let duplicateNested = text.replacingOccurrences(of: "\"gameId\":", with: "\"gameId\":\"fixture-game\",\"game\\u0049d\":")
        let deep = String(repeating: "[", count: 13) + "0" + String(repeating: "]", count: 13)
        let malformed = [duplicateRoot, duplicateNested, "[" + text + "]", text + "true", "{", deep]
        for bad in malformed {
            XCTAssertThrowsError(try WatchRelayCodec.decodeRequest(Data(bad.utf8)))
        }
        XCTAssertThrowsError(try WatchRelayCodec.decodeRequest(Data([0x7B, 0xFF, 0x7D])))
    }

    func testExactSafeIntegerBoundsAndBooleanDistinction() throws {
        var command = command(); command.expectedRevision = 9_007_199_254_740_991; command.scorerEpoch = 9_007_199_254_740_991
        let good = request(.execute(command))
        XCTAssertEqual(try WatchRelayCodec.decodeRequest(WatchRelayCodec.encodeRequest(good)), good)
        let text = String(decoding: try WatchRelayCodec.encodeRequest(request(.execute(self.command()))), as: UTF8.self)
        for number in ["true", "-1", "9007199254740992", "9007199254740991.1", "0.5", "1e2", "01", "NaN", "1.0"] {
            XCTAssertThrowsError(try WatchRelayCodec.decodeRequest(Data(text.replacingOccurrences(of: "\"expectedRevision\":0", with: "\"expectedRevision\":" + number).utf8)), number)
        }
        try rejectRequest { $0["version"] = true }
    }

    func testReplyCorrelationRejectsEveryRequestScopeOperationAndOutcomeMismatch() throws {
        try rejectReply { $0["requestId"] = self.pairing }
        try rejectReply { $0["operation"] = "receipt" }
        for (key, replacement) in [("endpoint", "https://other.example"), ("gameId", "other"), ("watchDeviceId", pairing), ("pairingId", requestID)] {
            try rejectReply { object in
                var scope = object["scope"] as! [String: Any]; scope[key] = replacement; object["scope"] = scope
            }
        }
        try rejectReply { object in
            var result = object["result"] as! [String: Any]
            var outcome = result["value"] as! [String: Any]; outcome["commandId"] = "different-command"
            result["value"] = outcome; object["result"] = result
        }
        try rejectReply { $0["result"] = ["type": "receipt_absent"] }
        let expected = request()
        XCTAssertThrowsError(try WatchRelayCodec.encodeReply(WatchRelayReply(request: expected, result: .outcome(try outcome())), for: expected))
    }

    func testContradictoryOutcomesInvalidSnapshotsAndFailureDetailsAreRejected() throws {
        for accepted in [true, false] {
            var value = try outcome(accepted: accepted); value.error = accepted ? "contradictory" : nil
            let expected = request(.execute(command()))
            XCTAssertThrowsError(try WatchRelayCodec.encodeReply(WatchRelayReply(request: expected, result: .outcome(value)), for: expected))
        }
        var value = try snapshot(); value.id = "wrong-game"
        let expected = request()
        XCTAssertThrowsError(try WatchRelayCodec.encodeReply(WatchRelayReply(request: expected, result: .snapshot(MatchSnapshotResponse(snapshot: value, serverTime: date))), for: expected))
        for failure in [WatchRelayFailure.http(status: 99, code: nil), .http(status: 600, code: nil), .http(status: 500, code: "raw body\nsecret")] {
            XCTAssertThrowsError(try WatchRelayCodec.encodeReply(WatchRelayReply(request: expected, result: .failure(failure)), for: expected))
        }
        for serverTime in ["yesterday", "2026-99-99T00:00:00Z", String(repeating: "0", count: 129)] {
            XCTAssertThrowsError(try WatchRelayCodec.encodeReply(WatchRelayReply(request: expected,
                result: .snapshot(MatchSnapshotResponse(snapshot: try snapshot(), serverTime: serverTime))), for: expected))
        }
    }
}

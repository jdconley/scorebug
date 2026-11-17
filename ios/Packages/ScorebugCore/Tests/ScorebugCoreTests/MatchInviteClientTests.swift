import XCTest
@testable import ScorebugCore

final class MatchInviteClientTests: XCTestCase {
    private var snapshotJSON: String {
        let url = Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures")!
        let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object["snapshot"]!), as: UTF8.self)
    }

    func testInviteCreateAndRedeem() async throws {
        let issued = #"{"invite":{"id":"i1","gameId":"fixture-game","createdAt":"t","expiresAt":"t","revokedAt":null,"redemptions":0},"code":"K7P-4QX","link":"https://scorebug.live/join/K7P4QX","expiresAt":"t"}"#
        let create = try client(status: 201, body: issued) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/teams/team-1/matches/fixture-game/invites")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session")
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
        }
        let invite = try await create.team("team-1").createInvite(gameId: "fixture-game", token: "session")
        do { _ = try await create.createInvite(gameId: "fixture-game", token: "session"); XCTFail("invites need a team") }
        catch let error as MatchClientError { XCTAssertEqual(error, .invalidIdentifier) }
        XCTAssertEqual(invite.code, "K7P-4QX")
        XCTAssertEqual(ScorebugLink(string: invite.link), .matchJoin(code: "K7P4QX"))

        let redeemBody = #"{"credential":{"gameId":"fixture-game","deviceId":"mom","role":"score","token":"s"},"snapshot":\#(snapshotJSON),"serverTime":"2026-11-15T10:00:00.000Z"}"#
        let redeem = try client(status: 200, body: redeemBody) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/invites/redeem")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
            XCTAssertEqual(body, ["code": "K7P4QX", "deviceId": "mom"])
        }
        let joined = try await redeem.redeemInvite(code: "K7P4QX", deviceId: "mom")
        XCTAssertEqual(joined.credential.role, .score)
        XCTAssertEqual(joined.snapshot.id, "fixture-game")
        XCTAssertNil(joined.snapshot.pendingSetEnd)
    }

    func testCreateSendsStyle() async throws {
        let response = #"{"snapshot":\#(snapshotJSON),"credential":{"gameId":"fixture-game","deviceId":"p","role":"score","token":"s"},"serverTime":"t"}"#
        let client = try client(status: 201, body: response) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/teams/team-1/matches")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(body?["scorebugStyle"] as? String, "lowerThird")
            XCTAssertNil(body?["recordOnly"])
        }
        let creation = MatchCreation(id: "fixture-game", deviceId: "p",
                                     teams: MatchTeams(home: MatchTeam(name: "A", shortName: "A", color: "#000000"),
                                                       away: MatchTeam(name: "B", shortName: "B", color: "#ffffff")),
                                     rules: MatchFormat.bestOf3.rules, scorebugStyle: .lowerThird)
        _ = try await client.team("team-1").create(creation, token: "session")
    }

    func testSnapshotDecodesSetPointAndOutput() throws {
        var object = try JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)) as! [String: Any]
        object["pendingSetEnd"] = ["winner": "away"]
        object["output"] = ["recordOnly": true]
        object["scorebugStyle"] = "setCard"
        let snapshot = try JSONDecoder().decode(MatchSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(snapshot.pendingSetEnd, PendingSetEnd(winner: .away))
        XCTAssertTrue(snapshot.output.recordOnly)
        XCTAssertEqual(snapshot.scorebugStyle, .setCard)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        XCTAssertEqual(encoded?["output"] as? [String: Bool], ["recordOnly": true])

        for key in ["output", "scorebugStyle"] {
            var missing = object
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(MatchSnapshot.self, from: JSONSerialization.data(withJSONObject: missing)), key)
        }
    }

    private func client(status: Int, body: String, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/base"), transport: { request in
            try inspect(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

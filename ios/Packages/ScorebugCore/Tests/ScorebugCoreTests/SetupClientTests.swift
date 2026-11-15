import XCTest
@testable import ScorebugCore

final class SetupClientTests: XCTestCase {
    private let device = #"{"id":"d1","name":"JD's iPhone","role":"owner","createdAt":"2026-11-15T10:00:00.000Z","lastSeenAt":null,"revokedAt":null}"#
    private var snapshotJSON: String {
        let url = Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures")!
        let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object["snapshot"]!), as: UTF8.self)
    }

    func testRedeemSetupIsUnauthenticatedAndReturnsOwnerToken() async throws {
        let client = try client(status: 200, body: #"{"device":\#(device),"token":"owner-token","serverTime":"2026-11-15T10:00:00.000Z"}"#) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/base/v1/setup/redeem")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
            XCTAssertEqual(body, ["code": "abc", "deviceId": "uuid", "deviceName": "JD's iPhone"])
        }
        let redeemed = try await client.redeemSetup(code: "abc", deviceId: "uuid", deviceName: "JD's iPhone")
        XCTAssertEqual(redeemed.token, "owner-token")
        XCTAssertEqual(redeemed.device.name, "JD's iPhone")
    }

    func testRedeemErrorsKeepTheServerCode() async throws {
        let client = try client(status: 409, body: #"{"error":"setup_code_used"}"#)
        do { _ = try await client.redeemSetup(code: "abc", deviceId: "u", deviceName: "n"); XCTFail("Should throw") }
        catch let error as MatchClientError { XCTAssertEqual(error, .http(status: 409, code: "setup_code_used")) }
    }

    func testDevicesMeAndDestinationsUseOwnerToken() async throws {
        let me = try client(status: 200, body: #"{"role":"owner","legacy":false,"device":\#(device)}"#) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/devices/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner")
        }
        let current = try await me.currentDevice(ownerToken: "owner")
        XCTAssertEqual(current.device?.id, "d1")

        let list = try client(status: 200, body: #"{"destinations":[{"id":"y1","name":"YouTube","rtmpUrl":"rtmps://a.rtmp.youtube.com/live2","streamKeyLast4":"qrst","isDefault":true,"createdAt":"t","updatedAt":"t"}],"serverTime":"t"}"#) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/destinations")
            XCTAssertEqual(request.httpMethod, "GET")
        }
        let destinations = try await list.destinations(ownerToken: "owner")
        XCTAssertEqual(destinations.map(\.name), ["YouTube"])
        XCTAssertTrue(destinations[0].isDefault)
    }

    func testInviteCreateAndRedeem() async throws {
        let issued = #"{"invite":{"id":"i1","gameId":"fixture-game","createdAt":"t","expiresAt":"t","revokedAt":null,"redemptions":0},"code":"K7P-4QX","link":"scorebug://join?server=https%3A%2F%2Fa.example&code=K7P4QX","expiresAt":"t"}"#
        let create = try client(status: 201, body: issued) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/matches/fixture-game/invites")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capture-token")
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
        }
        let invite = try await create.createInvite(gameId: "fixture-game", token: "capture-token")
        XCTAssertEqual(invite.code, "K7P-4QX")
        XCTAssertEqual(ScorebugLink(string: invite.link)?.code, "K7P4QX")

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

    func testCreateSendsDestinationAndStyle() async throws {
        let response = #"{"snapshot":\#(snapshotJSON),"credential":{"gameId":"fixture-game","deviceId":"p","role":"score","token":"s"},"serverTime":"t"}"#
        let client = try client(status: 201, body: response) { request in
            XCTAssertEqual(request.url?.path, "/base/v1/matches")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(body?["destinationId"] as? String, "dest")
            XCTAssertEqual(body?["scorebugStyle"] as? String, "lowerThird")
            XCTAssertNil(body?["recordOnly"])
        }
        let creation = MatchCreation(id: "fixture-game", deviceId: "p",
                                     teams: MatchTeams(home: MatchTeam(name: "A", shortName: "A", color: "#000000"),
                                                       away: MatchTeam(name: "B", shortName: "B", color: "#ffffff")),
                                     rules: MatchFormat.bestOf3.rules, scorebugStyle: .lowerThird, destinationId: "dest")
        _ = try await client.create(creation, ownerToken: "owner")
    }

    func testSnapshotDecodesSetPointAndOutput() throws {
        var object = try JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)) as! [String: Any]
        object["pendingSetEnd"] = ["winner": "away"]
        object["output"] = ["destinationId": "d", "recordOnly": false]
        object["scorebugStyle"] = "setCard"
        let snapshot = try JSONDecoder().decode(MatchSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(snapshot.pendingSetEnd, PendingSetEnd(winner: .away))
        XCTAssertEqual(snapshot.output.destinationId, "d")
        XCTAssertEqual(snapshot.scorebugStyle, .setCard)

        object.removeValue(forKey: "pendingSetEnd"); object.removeValue(forKey: "output"); object.removeValue(forKey: "scorebugStyle")
        let older = try JSONDecoder().decode(MatchSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.scorebugStyle, .bar)
        XCTAssertFalse(older.output.recordOnly)
    }

    private func client(status: Int, body: String, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/base"), transport: { request in
            try inspect(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

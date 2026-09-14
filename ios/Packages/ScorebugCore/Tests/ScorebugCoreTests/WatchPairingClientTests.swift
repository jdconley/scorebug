import Foundation
import XCTest
@testable import ScorebugCore

final class WatchPairingClientTests: XCTestCase {
    func testSharedPairingFixtureRoundTripsExactly() throws {
        struct Fixture: Codable { let issued: WatchPairingIssued; let redeemed: WatchPairingRedeemed }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "watch-pairing-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertEqual(value.issued.watchDeviceId, value.redeemed.credential.deviceId)
        XCTAssertEqual(value.issued.pairingId, value.redeemed.pairingId)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    static let pairingId = "10000000-0000-4000-8000-000000000001"
    static let deviceId = "20000000-0000-4000-8000-000000000002"
    static let redemptionId = "30000000-0000-4000-8000-000000000003"
    static let secret = String(repeating: "A", count: 43)
    static let offer = WatchPairingIssued(pairingId: pairingId, gameId: "fixture-game", watchDeviceId: deviceId,
        pairingToken: secret, expiresAt: "2026-09-14T10:05:00.000Z", serverTime: "2026-09-14T10:00:00.000Z")

    static func response(deviceId: String = deviceId, role: MatchRole = .score,
                         pairingId: String = pairingId, redemptionId: String = redemptionId) throws -> WatchPairingRedeemed {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        // Use the same native score fixture, preserving complete rules/snapshot fields.
        let snapshot = try JSONDecoder().decode(MatchSnapshot.self, from: JSONSerialization.data(withJSONObject: value["snapshot"]!))
        return WatchPairingRedeemed(pairingId: pairingId, redemptionId: redemptionId,
            credential: MatchCredential(gameId: snapshot.id, deviceId: deviceId, role: role, token: "scoped-watch-secret"),
            snapshot: snapshot, serverTime: "2026-09-14T10:00:01.000Z")
    }

    func testIssueUsesInstallationAuthAndRedeemUsesOnlyCapabilityAndRecoveryKey() async throws {
        let issued = Self.offer
        let issuer = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control"), transport: { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/fixture-game/watch-pairings")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer phone-install")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"))
            XCTAssertEqual(try JSONDecoder().decode(WatchPairingIssueRequest.self, from: XCTUnwrap(request.httpBody)),
                WatchPairingIssueRequest(pairingId: Self.pairingId, watchDeviceId: Self.deviceId))
            return (try JSONEncoder().encode(issued), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        do {
            let actual = try await issuer.issueWatchPairing(gameId: issued.gameId,
                request: WatchPairingIssueRequest(pairingId: Self.pairingId, watchDeviceId: Self.deviceId), installationToken: "phone-install")
            XCTAssertEqual(actual, issued)
        } catch { XCTFail("Issue must send the pairing request: \(error)") }
        let redeemed = try Self.response()
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control"), transport: { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/fixture-game/watch-pairings/\(Self.pairingId)/redeem")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.secret)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"), Self.secret)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 20)
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertEqual(try JSONDecoder().decode(WatchPairingRedeemRequest.self, from: body),
                WatchPairingRedeemRequest(redemptionId: Self.redemptionId, deviceId: Self.deviceId))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(Self.secret))
            return (try JSONEncoder().encode(redeemed), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            let actual = try await client.redeemWatchPairing(gameId: "fixture-game", pairingId: Self.pairingId,
                pairingToken: Self.secret, recoveryKey: Self.secret,
                request: WatchPairingRedeemRequest(redemptionId: Self.redemptionId, deviceId: Self.deviceId))
            XCTAssertEqual(actual, redeemed)
        } catch { XCTFail("Redeem must send the capability request: \(error)") }
    }

    func testRedemptionPayloadBytesStayStableAcrossRepeatedEncodes() async throws {
        let response = try Self.response()
        let expected = Data("{\"deviceId\":\"\(Self.deviceId)\",\"redemptionId\":\"\(Self.redemptionId)\"}".utf8)
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { request in
            XCTAssertEqual(request.httpBody, expected)
            return (try JSONEncoder().encode(response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for _ in 0..<32 {
            _ = try await client.redeemWatchPairing(gameId: "fixture-game", pairingId: Self.pairingId,
                pairingToken: Self.secret, recoveryKey: Self.secret,
                request: WatchPairingRedeemRequest(redemptionId: Self.redemptionId, deviceId: Self.deviceId))
        }
    }
}

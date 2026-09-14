import Foundation
import XCTest
import ScorebugCore

final class PublishAccessTests: XCTestCase {
    private let credential = MatchCredential(gameId: "match", deviceId: "phone", role: .capture, token: "capture-secret")
    private let valid: [String: Any] = [
        "gameId": "match", "generation": 3, "recordingId": "recording-1",
        "publishUrl": "srt://localhost:8890?streamid=publish:scorebug-path&passphrase=private-secret&pkt_size=1316",
        "serverTime": "2026-09-14T03:00:00.123Z"
    ]

    func testRequestsSelectedRecordingWithScopedAuthorizationAndDecodesAccess() async throws {
        let client = try client(body: valid) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/control/v1/matches/match/media/publish")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capture-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary,
                           ["recordingId": "recording-1", "generation": 3] as NSDictionary)
        }
        let access = try await client.publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
        XCTAssertEqual(access.gameId, "match")
        XCTAssertEqual(access.recordingId, "recording-1")
        XCTAssertEqual(access.generation, 3)
        XCTAssertEqual(access.publishUrl.absoluteString, valid["publishUrl"] as? String)
        XCTAssertEqual(access.serverTime, valid["serverTime"] as? String)
        var dumpOutput = ""
        dump(access, to: &dumpOutput)
        for description in [String(describing: access), String(reflecting: access), dumpOutput] {
            XCTAssertFalse(description.contains("private-secret"))
            XCTAssertFalse(description.contains("srt://"))
        }
    }

    func testAcceptsIPv6DestinationAndRejectsMalformedSuccess() async throws {
        var ipv6 = valid
        ipv6["publishUrl"] = "srt://[::1]:8890?streamid=publish:scorebug-path&passphrase=private-secret"
        let access = try await client(body: ipv6).publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
        XCTAssertEqual(access.publishUrl.host, "::1")
        for key in ["gameId", "recordingId", "generation", "publishUrl", "serverTime"] {
            var malformed = valid
            malformed.removeValue(forKey: key)
            do {
                _ = try await client(body: malformed).publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
                XCTFail("Must reject missing field")
            } catch is DecodingError {}
        }
    }

    func testRejectsAccessForAnotherMatchRecordingOrGeneration() async throws {
        for (key, value) in [("gameId", "other" as Any), ("recordingId", "other" as Any), ("generation", 4 as Any)] {
            var body = valid
            body[key] = value
            let client = try client(body: body)
            do {
                _ = try await client.publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
                XCTFail("Must reject mismatched \(key)")
            } catch let error as MatchClientError { XCTAssertEqual(error, .invalidResponse) }
        }
    }

    func testRejectsInvalidPublishingDestinations() async throws {
        for url in ["https://localhost:8890", "srt:///", "srt://localhost", "srt://localhost:0", "srt://localhost:65536",
                    "srt://user:password@localhost:8890", "srt://localhost:8890#fragment"] {
            var body = valid
            body["publishUrl"] = url
            let client = try client(body: body)
            do {
                _ = try await client.publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
                XCTFail("Must reject invalid destination")
            } catch let error as MatchClientError { XCTAssertEqual(error, .invalidResponse) }
        }
    }

    func testAuthorizationConflictsAndUnavailableRelayNeverReturnAccess() async throws {
        for (status, code, expected) in [
            (401, "unauthorized", MatchClientError.unauthorized),
            (403, "forbidden", .forbidden),
            (409, "broadcast_changed", .http(status: 409, code: "broadcast_changed")),
            (503, "relay_unavailable", .http(status: 503, code: "relay_unavailable"))
        ] {
            let client = try client(body: ["error": code], status: status)
            do {
                _ = try await client.publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
                XCTFail("Must reject HTTP \(status)")
            } catch let error as MatchClientError { XCTAssertEqual(error, expected) }
        }
        let failed = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:3000"), transport: { _ in throw URLError(.timedOut) })
        do {
            _ = try await failed.publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
            XCTFail("Must propagate timeout")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    private func client(body: [String: Any], status: Int = 200, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        let data = try JSONSerialization.data(withJSONObject: body)
        return MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control/"), transport: { request in
            try inspect(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

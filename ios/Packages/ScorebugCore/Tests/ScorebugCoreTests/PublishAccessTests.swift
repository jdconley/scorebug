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

    func testAttemptGrantUsesCanonicalRequestAndReturnsBoundIdentity() async throws {
        let attempt = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let body = attemptBody(attempt)
        let client = try client(body: body) { request in
            let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(payload?["publishingAttemptId"] as? String, attempt.uuidString.lowercased())
            XCTAssertEqual(payload?["recordingId"] as? String, "recording-1")
            XCTAssertEqual(payload?["generation"] as? Int, 3)
        }
        let access = try await client.publishAccess(recordingId: "recording-1", generation: 3,
                                                   publishingAttemptId: attempt, credential: credential)
        XCTAssertEqual(access.publishingAttemptId, attempt)
        XCTAssertEqual(access.publishUrl.absoluteString, body["publishUrl"] as? String)
        var dumpOutput = ""
        dump(access, to: &dumpOutput)
        for description in [String(describing: access), String(reflecting: access), dumpOutput] {
            XCTAssertFalse(description.contains(attempt.uuidString.lowercased()))
            XCTAssertFalse(description.contains("sbp1"))
            XCTAssertFalse(description.contains("srt://"))
        }
    }

    func testAttemptGrantRequiresExactCanonicalEcho() async throws {
        let attempt = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        for echo in [nil, "", "not-a-uuid", UUID().uuidString.lowercased(), attempt.uuidString] as [String?] {
            var body = attemptBody(attempt)
            body["publishingAttemptId"] = echo
            await assertInvalidAttempt(body, attempt: attempt)
        }
    }

    func testAttemptGrantRequiresOneCompleteStreamIDWithMatchingIdentityAndProofSyntax() async throws {
        let attempt = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let stream = attemptStreamID(attempt)
        let other = UUID().uuidString.lowercased()
        let invalidQueries = [
            "", "streamid", "streamid=", "streamid=publish:scorebug-path",
            "streamid=\(stream)&streamid=\(stream)", "streamid=\(stream)&streamid=",
            "streamid=\(stream)extra", "streamid=\(stream)%0A", "streamid=\(stream)%00",
            "streamid=prefix\(stream)", "streamid=\(stream.replacingOccurrences(of: attempt.uuidString.lowercased(), with: other))",
            "streamid=\(stream.replacingOccurrences(of: attempt.uuidString.lowercased(), with: attempt.uuidString))",
            "streamid=\(stream.replacingOccurrences(of: "sbp1=", with: "sbp2="))",
            "streamid=\(stream.dropLast())", "streamid=\(stream.dropLast())g",
            "streamid=\(stream.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "A", count: 64)))",
            "streamid=\(stream.replacingOccurrences(of: "0123456789abcdef-", with: "0123456789abcde-"))",
            "streamid=\(stream.replacingOccurrences(of: "0123456789abcdef0123456789abcdef:", with: "0123456789abcdef0123456789abcde:"))",
            "streamid=\(stream.replacingOccurrences(of: "scorebug-", with: "scorebug-A"))"
        ]
        for query in invalidQueries {
            var body = attemptBody(attempt)
            body["publishUrl"] = "srt://localhost:8890?\(query)"
            await assertInvalidAttempt(body, attempt: attempt)
        }
    }

    func testAttemptGrantUsesDecodedQueryValueAndKeepsDestinationValidation() async throws {
        let attempt = UUID()
        var body = attemptBody(attempt)
        body["publishUrl"] = "srt://[::1]:8890?pkt_size=1316&streamid=" + attemptStreamID(attempt).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "=", with: "%3D")
        let access = try await client(body: body).publishAccess(recordingId: "recording-1", generation: 3,
            publishingAttemptId: attempt, credential: credential)
        XCTAssertEqual(access.publishingAttemptId, attempt)
        for destination in ["https://localhost:8890", "srt:///", "srt://localhost", "srt://localhost:0",
                            "srt://localhost:65536", "srt://user:password@localhost:8890"] {
            body["publishUrl"] = destination + "?streamid=" + attemptStreamID(attempt)
            await assertInvalidAttempt(body, attempt: attempt)
        }
    }

    func testLegacyAccessIgnoresUnrequestedAttemptAndNeedsNoProof() async throws {
        var body = valid
        body["publishingAttemptId"] = "not-an-attempt"
        let access = try await client(body: body).publishAccess(recordingId: "recording-1", generation: 3, credential: credential)
        XCTAssertNil(access.publishingAttemptId)
    }

    private func attemptStreamID(_ attempt: UUID) -> String {
        "publish:scorebug-0123456789abcdef-0123456789abcdef0123456789abcdef:sbp1=\(attempt.uuidString.lowercased())." + String(repeating: "a", count: 64)
    }

    private func attemptBody(_ attempt: UUID) -> [String: Any] {
        var body = valid
        body["publishingAttemptId"] = attempt.uuidString.lowercased()
        body["publishUrl"] = "srt://localhost:8890?streamid=" + attemptStreamID(attempt) + "&pkt_size=1316"
        return body
    }

    private func assertInvalidAttempt(_ body: [String: Any], attempt: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client(body: body).publishAccess(recordingId: "recording-1", generation: 3,
                publishingAttemptId: attempt, credential: credential)
            XCTFail("Must reject invalid attempt grant", file: file, line: line)
        } catch let error as MatchClientError { XCTAssertEqual(error, .invalidResponse, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func client(body: [String: Any], status: Int = 200, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        let data = try JSONSerialization.data(withJSONObject: body)
        return MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control/"), transport: { request in
            try inspect(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

import Foundation
import XCTest
import ScorebugCore

final class PublishAccessTests: XCTestCase {
    private let credential = MatchCredential(gameId: "match", deviceId: "phone", role: .capture, token: "capture-secret")
    private let attempt = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
    /// Cloudflare Stream's SRT URL: its passphrase and its own stream ID.
    private let streamURL = "srt://live.cloudflare.com:778?passphrase=0123456789abcdef0123&streamid=f256e6ea9341d51eea64c9454659e576"
    private var valid: [String: Any] {
        ["gameId": "match", "generation": 3, "recordingId": "recording-1", "publishUrl": streamURL,
         "serverTime": "2026-09-14T03:00:00.123Z", "publishingAttemptId": attempt.uuidString.lowercased()]
    }

    func testRequestsTheAttemptWithScopedAuthorizationAndDecodesAccess() async throws {
        let client = try client(body: valid) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/control/v1/matches/match/media/publish")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capture-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary,
                           ["recordingId": "recording-1", "generation": 3,
                            "publishingAttemptId": "abcdef01-2345-6789-abcd-ef0123456789"] as NSDictionary)
        }
        let access = try await publish(client)
        XCTAssertEqual(access.gameId, "match")
        XCTAssertEqual(access.recordingId, "recording-1")
        XCTAssertEqual(access.generation, 3)
        XCTAssertEqual(access.publishingAttemptId, attempt)
        XCTAssertEqual(access.publishUrl.absoluteString, streamURL)
        XCTAssertEqual(access.publishUrl.host, "live.cloudflare.com")
        XCTAssertEqual(access.publishUrl.port, 778)
        XCTAssertEqual(access.serverTime, valid["serverTime"] as? String)
        var dumpOutput = ""
        dump(access, to: &dumpOutput)
        for description in [String(describing: access), String(reflecting: access), dumpOutput] {
            XCTAssertFalse(description.contains("0123456789abcdef0123"))
            XCTAssertFalse(description.contains(attempt.uuidString.lowercased()))
            XCTAssertFalse(description.contains("srt://"))
        }
    }

    func testAcceptsIPv6AndDecodedQueryValuesAndRejectsMissingFields() async throws {
        var body = valid
        body["publishUrl"] = "srt://[::1]:8890?pkt_size=1316&streamid=publish%3Ascorebug%3Dx"
        let access = try await publish(client(body: body))
        XCTAssertEqual(access.publishUrl.host, "::1")
        for key in ["gameId", "recordingId", "generation", "publishUrl", "serverTime", "publishingAttemptId"] {
            var malformed = valid
            malformed.removeValue(forKey: key)
            do {
                _ = try await publish(client(body: malformed))
                XCTFail("Must reject missing \(key)")
            } catch is DecodingError {}
        }
    }

    func testRejectsAccessForAnotherMatchRecordingOrGeneration() async throws {
        for (key, value) in [("gameId", "other" as Any), ("recordingId", "other" as Any), ("generation", 4 as Any)] {
            var body = valid
            body[key] = value
            await assertInvalid(body)
        }
    }

    func testRejectsInvalidPublishingDestinations() async throws {
        for url in ["https://localhost:8890", "srt:///", "srt://localhost", "srt://localhost:0", "srt://localhost:65536",
                    "srt://user:password@localhost:8890", "srt://localhost:8890#fragment"] {
            var body = valid
            body["publishUrl"] = url + "?streamid=abc"
            await assertInvalid(body)
        }
    }

    func testAuthorizationConflictsAndUnavailableStreamNeverReturnAccess() async throws {
        for (status, code, expected) in [
            (401, "unauthorized", MatchClientError.unauthorized),
            (403, "forbidden", .forbidden),
            (409, "broadcast_changed", .http(status: 409, code: "broadcast_changed")),
            (503, "stream_unavailable", .http(status: 503, code: "stream_unavailable"))
        ] {
            do {
                _ = try await publish(client(body: ["error": code], status: status))
                XCTFail("Must reject HTTP \(status)")
            } catch let error as MatchClientError { XCTAssertEqual(error, expected) }
        }
        let failed = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:3000"), transport: { _ in throw URLError(.timedOut) })
        do {
            _ = try await publish(failed)
            XCTFail("Must propagate timeout")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testRequiresTheExactCanonicalAttemptEcho() async throws {
        for echo in ["", "not-a-uuid", UUID().uuidString.lowercased(), attempt.uuidString] {
            var body = valid
            body["publishingAttemptId"] = echo
            await assertInvalid(body)
        }
    }

    func testRequiresOneIntactStreamID() async throws {
        let stream = "f256e6ea9341d51eea64c9454659e576"
        let invalidQueries = [
            "", "streamid", "streamid=", "streamid=\(stream)&streamid=\(stream)", "streamid=\(stream)&streamid=",
            "streamid=\(stream)%0A", "streamid=\(stream)%00", "streamid=a%20b", "streamid=" + String(repeating: "a", count: 513),
        ]
        for query in invalidQueries {
            var body = valid
            body["publishUrl"] = "srt://live.cloudflare.com:778?\(query)"
            await assertInvalid(body)
        }
    }

    private func publish(_ client: MatchHTTPClient) async throws -> PublishAccess {
        try await client.publishAccess(recordingId: "recording-1", generation: 3, publishingAttemptId: attempt, credential: credential)
    }

    private func assertInvalid(_ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await publish(client(body: body))
            XCTFail("Must reject the grant", file: file, line: line)
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

import Foundation
import XCTest
import ScorebugCore

final class MediaClientTests: XCTestCase {
    private struct Fixture: Codable {
        let snapshotResponse: MediaSnapshotResponse
        let recordingReport: RecordingReport
        let recordingResponse: RecordingReportResponse
        let command: BroadcastCommand
        let outcome: BroadcastOutcome
    }

    private let credential = MatchCredential(gameId: "match", deviceId: "phone", role: .capture, token: "capture-secret")

    private func fixtureData() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "media-v1", withExtension: "json", subdirectory: "Fixtures")))
    }

    private func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: fixtureData()) }

    func testRealAPIFixtureRoundTripsWithWireNullsAndFractionalDates() throws {
        let data = try fixtureData()
        let fixture = try fixture()
        XCTAssertEqual(fixture.snapshotResponse.serverTime, "2026-09-14T03:00:00.000Z")
        XCTAssertEqual(fixture.recordingResponse.recording.startedAt, fixture.recordingReport.startedAt)
        XCTAssertNil(fixture.snapshotResponse.snapshot.broadcast.selection)
        XCTAssertNil(fixture.outcome.error)
        XCTAssertEqual(fixture.outcome.snapshot.broadcast.generation, 1)
        XCTAssertEqual(try object(JSONEncoder().encode(fixture)), try object(data))
    }

    func testRecordingStatusesAndReportEncodeCanonicalFields() throws {
        for status in [RecordingStatus.recording, .stopped, .interrupted] {
            let report = RecordingReport(recordingId: "archive", sequence: 3, status: status, startedAt: "2026-09-14T03:00:00.123Z")
            let data = try JSONEncoder().encode(report)
            XCTAssertEqual(try object(data), ["recordingId": "archive", "sequence": 3, "status": status.rawValue, "startedAt": "2026-09-14T03:00:00.123Z"] as NSDictionary)
            XCTAssertEqual(try JSONDecoder().decode(RecordingReport.self, from: data), report)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(RecordingStatus.self, from: Data(#""unknown""#.utf8)))
    }

    func testStartAndStopUseFlatDiscriminatedWireShape() throws {
        let selection = BroadcastSelection(workerId: "mac", outputId: "local-sink", captureDeviceId: "phone", recordingId: "archive-1")
        let cases: [(BroadcastOperation, String)] = [
            (.start(selection: selection), #"{"type":"start","selection":{"workerId":"mac","outputId":"local-sink","captureDeviceId":"phone","recordingId":"archive-1"}}"#),
            (.stop, #"{"type":"stop"}"#),
        ]
        for (operation, expected) in cases {
            let data = try JSONEncoder().encode(operation)
            XCTAssertEqual(try object(data), try object(Data(expected.utf8)))
            XCTAssertEqual(try JSONDecoder().decode(BroadcastOperation.self, from: data), operation)
        }
        for invalid in [#"{"type":"future"}"#, #"{"type":"start"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(BroadcastOperation.self, from: Data(invalid.utf8)))
        }
    }

    func testPublicModelInitializersPreserveValues() throws {
        let fixture = try fixture()
        let report = fixture.recordingReport
        let recording = RecordingAssociation(gameId: "match", recordingId: report.recordingId, deviceId: "phone", startedAt: report.startedAt, updatedAt: report.startedAt, status: report.status, sequence: report.sequence)
        let snapshot = MediaSnapshot(gameId: "match", recordings: [recording], broadcast: MediaBroadcast(desired: .stopped, generation: 0, selection: nil))
        XCTAssertEqual(MediaSnapshotResponse(snapshot: snapshot, serverTime: report.startedAt), fixture.snapshotResponse)
        XCTAssertEqual(RecordingReportResponse(recording: recording, serverTime: report.startedAt), fixture.recordingResponse)
        XCTAssertEqual(BroadcastOutcome(commandId: fixture.command.commandId, accepted: true, error: nil, snapshot: fixture.outcome.snapshot), fixture.outcome)
        XCTAssertEqual(BroadcastCommand(commandId: "start-1", gameId: "match", expectedGeneration: 0, issuedAt: report.startedAt, operation: fixture.command.operation), fixture.command)
    }

    func testSnapshotUsesScopedCredentialBasePathAndBoundedTimeout() async throws {
        let fixture = try fixture()
        let client = try client(status: 200, body: JSONEncoder().encode(fixture.snapshotResponse)) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/control/v1/matches/match/media")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capture-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertNil(request.httpBody)
        }
        let response = try await client.mediaSnapshot(credential: credential)
        XCTAssertEqual(response, fixture.snapshotResponse)
    }

    func testRecordingReportUsesScopedCredentialAndExactBody() async throws {
        let fixture = try fixture()
        let client = try client(status: 200, body: JSONEncoder().encode(fixture.recordingResponse)) { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/match/media/recordings")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capture-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(try JSONDecoder().decode(RecordingReport.self, from: XCTUnwrap(request.httpBody)), fixture.recordingReport)
        }
        let response = try await client.reportRecording(fixture.recordingReport, credential: credential)
        XCTAssertEqual(response, fixture.recordingResponse)
    }

    func testBroadcastUsesInstallationCredentialAndReturnsNormalConflictOutcome() async throws {
        let fixture = try fixture()
        for status in [200, 409] {
            let expected = BroadcastOutcome(commandId: fixture.command.commandId, accepted: status == 200, error: status == 409 ? "stale_generation" : nil, snapshot: fixture.outcome.snapshot)
            let client = try client(status: status, body: JSONEncoder().encode(expected)) { request in
                XCTAssertEqual(request.url?.path, "/control/v1/matches/match/media/commands")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(try JSONDecoder().decode(BroadcastCommand.self, from: XCTUnwrap(request.httpBody)), fixture.command)
            }
            let outcome = try await client.executeBroadcast(fixture.command, installationToken: "installation-secret")
            XCTAssertEqual(outcome, expected)
        }
    }

    func testBroadcastReceiptUsesInstallationCredentialAndDecodesFoundOutcome() async throws {
        let fixture = try fixture()
        let client = try client(status: 200, body: JSONEncoder().encode(fixture.outcome)) { request in
            XCTAssertEqual(request.url?.path, "/control/v1/matches/match/media/commands/start-1")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
        }
        let receipt = try await client.broadcastReceipt(gameId: "match", commandId: "start-1", installationToken: "installation-secret")
        XCTAssertEqual(receipt, fixture.outcome)
    }

    func testBroadcastReceiptReturnsNilOnlyForExactCommandNotFound() async throws {
        let missing = try client(status: 404, body: Data(#"{"error":"command_not_found"}"#.utf8))
        let receipt = try await missing.broadcastReceipt(gameId: "match", commandId: "start-1", installationToken: "installation-secret")
        XCTAssertNil(receipt)
        let cases: [(Int, String, MatchClientError)] = [
            (404, #"{"error":"match_not_found"}"#, .http(status: 404, code: "match_not_found")),
            (500, #"{"error":"command_not_found"}"#, .http(status: 500, code: "command_not_found")),
            (401, #"{"error":"command_not_found"}"#, .unauthorized),
            (403, #"{"error":"forbidden"}"#, .forbidden),
            (404, "invalid json", .http(status: 404, code: nil)),
        ]
        for (status, body, expected) in cases {
            let client = try client(status: status, body: Data(body.utf8))
            do { _ = try await client.broadcastReceipt(gameId: "match", commandId: "start-1", installationToken: "installation-secret"); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, expected) }
        }
    }

    func testMalformedConflictAndTransportFailureAreNotAcknowledgements() async throws {
        let command = try fixture().command
        let malformed = try client(status: 409, body: Data(#"{"error":"conflict"}"#.utf8))
        do { _ = try await malformed.executeBroadcast(command, installationToken: "installation"); XCTFail("Should throw") }
        catch is DecodingError { }
        let failed = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:3000"), transport: { _ in throw URLError(.timedOut) })
        do { _ = try await failed.broadcastReceipt(gameId: "match", commandId: "start-1", installationToken: "installation"); XCTFail("Should throw") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testMediaPathsRejectInvalidIdentifiersBeforeSending() async throws {
        let client = try client(status: 200, body: Data("{}".utf8)) { _ in XCTFail("Must not send") }
        for invalid in ["../other", "foo/bar", "%2f", "", String(repeating: "x", count: 129)] {
            do { _ = try await client.broadcastReceipt(gameId: "match", commandId: invalid, installationToken: "installation"); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, .invalidIdentifier) }
            var command = try fixture().command
            command.gameId = invalid
            do { _ = try await client.executeBroadcast(command, installationToken: "installation"); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, .invalidIdentifier) }
        }
    }

    private func object(_ data: Data) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary) }

    private func client(status: Int, body: Data, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/control/"), transport: { request in
            try inspect(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

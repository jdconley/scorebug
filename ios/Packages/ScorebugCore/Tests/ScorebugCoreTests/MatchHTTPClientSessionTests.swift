import Foundation
import XCTest
@testable import ScorebugCore

final class MatchHTTPClientSessionTests: XCTestCase {
    func testDefaultSessionWaitsForPermissionWithinRequestBudgetAndIsReused() {
        let session = MatchHTTPClient.defaultSession
        XCTAssertTrue(session === MatchHTTPClient.defaultSession)
        XCTAssertFalse(session === URLSession.shared)
        let configuration = session.configuration
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
    }

    func testExplicitSessionIsUsedWithoutChangingItsConfiguration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 7
        configuration.protocolClasses = [SessionInjectionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://session-injection.invalid"), session: session)

        let response = try await client.active(installationToken: "test-installation-token")

        XCTAssertNil(response.snapshot)
        XCTAssertEqual(response.serverTime, "injected-session")
        XCTAssertFalse(session.configuration.waitsForConnectivity)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 7)
    }

    func testInjectedTransportFailureDoesNotRetryMutation() async throws {
        let calls = SessionTransportCalls()
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("http://192.168.1.2:3000"), transport: { request in
            await calls.record()
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 20)
            throw URLError(.notConnectedToInternet)
        })
        let credential = MatchCredential(gameId: "match-1", deviceId: "phone-1", role: .score, token: "test-device-token")
        let command = MatchCommand(commandId: "command-1", gameId: "match-1", deviceId: "phone-1",
                                   expectedRevision: 1, scorerEpoch: 1, issuedAt: "2026-09-25T17:00:00Z", operation: .undo)
        do {
            _ = try await client.execute(command, credential: credential)
            XCTFail("Expected injected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }
}

private actor SessionTransportCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class SessionInjectionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "session-injection.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"snapshot":null,"serverTime":"injected-session"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

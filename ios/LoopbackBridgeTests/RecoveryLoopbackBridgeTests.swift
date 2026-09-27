import Foundation
import Network
import XCTest
@testable import RecoveryBridge

final class RecoveryLoopbackBridgeTests: XCTestCase {
    func environment(port: Int = 49173) -> [String: String] {
        ["SCOREBUG_RECOVERY_RUNNER_TRANSPORT": "app-loopback",
         "SCOREBUG_RECOVERY_BRIDGE_PORT": String(port),
         "SCOREBUG_RECOVERY_CONTROL_URL": "http://192.168.1.130:8123/",
         "SCOREBUG_DEVICE_API_URL": "http://192.168.1.130:8124",
         "SCOREBUG_RECOVERY_CONTROL_TOKEN": String(repeating: "a", count: 64),
         "SCOREBUG_RECOVERY_RUN_ID": "11111111-2222-4333-8444-555555555555"]
    }
    func testExplicitCompleteCanonicalConfiguration() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment())
        XCTAssertEqual(c.port, 49173)
        XCTAssertEqual(c.api.absoluteString, "http://192.168.1.130:8124/")
        for key in environment().keys {
            var e = environment(); e.removeValue(forKey: key)
            XCTAssertThrowsError(try RecoveryLoopbackConfiguration(environment: e), key)
        }
        for (key, values) in [
            ("SCOREBUG_RECOVERY_BRIDGE_PORT", ["80", "65536", "049173", "0"]),
            ("SCOREBUG_RECOVERY_CONTROL_TOKEN", ["", String(repeating: "A", count: 64)]),
            ("SCOREBUG_RECOVERY_RUN_ID", ["bad"]),
            ("SCOREBUG_DEVICE_API_URL", ["http://192.168.1.131:8124", "http://192.168.1.130:8124/a", "http://%31%39%32.168.1.130:8124", "http://3232235906:8124", "http://192.168.001.130:8124"]),
            ("SCOREBUG_RECOVERY_CONTROL_URL", ["http://8.8.8.8:8123", "http://user@192.168.1.130:8123", "http://192.168.1.130:8123/?x=1", "https://192.168.1.130:8123"])
        ] {
            for value in values { var e = environment(); e[key] = value
                XCTAssertThrowsError(try RecoveryLoopbackConfiguration(environment: e), value)
            }
        }
    }
    func request(_ first: String = "GET / HTTP/1.1", extra: String = "", body: String = "", token: String = String(repeating: "a", count: 64)) -> Data {
        Data("\(first)\r\nHost: 127.0.0.1:49173\r\nAuthorization: Bearer \(token)\r\n\(extra)\r\n\(body)".utf8)
    }
    func testParserAuthenticationFramingAndRoutes() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment())
        XCTAssertEqual(try RecoveryLoopbackRequest.parse(request(), configuration: c)?.path, "/")
        let payload = "{\"sequence\":1}"
        let parsed = try RecoveryLoopbackRequest.parse(request("POST /constrain HTTP/1.1", extra: "Content-Length: \(payload.utf8.count)\r\n", body: payload), configuration: c)
        XCTAssertEqual(parsed?.body, Data(payload.utf8))
        XCTAssertEqual(try RecoveryLoopbackRequest.parse(request("POST /restore HTTP/1.1", extra: "Content-Length: 8192\r\n", body: String(repeating: "x", count: 8192)), configuration: c)?.body.count, 8192)
        XCTAssertNil(try RecoveryLoopbackRequest.parse(request("POST /restore HTTP/1.1", extra: "Content-Length: 5\r\n", body: "123"), configuration: c))
        for bytes in [request(token: "bad"), request("CONNECT / HTTP/1.1"), request("GET http://192.168.1.130:8123/ HTTP/1.1"), request("GET /unknown HTTP/1.1"), request("GET /?x=1 HTTP/1.1"), request(extra: "Authorization: Bearer a\r\n"), request(extra: "Transfer-Encoding: chunked\r\n"), request(extra: "Content-Length: 8193\r\n"), request(extra: "Content-Length: 0\r\nContent-Length: 0\r\n"), request(body: "GET / HTTP/1.1\r\n\r\n"), request(extra: "X-Large: \(String(repeating: "x", count: 8192))\r\n")] {
            XCTAssertThrowsError(try RecoveryLoopbackRequest.parse(bytes, configuration: c))
        }
    }
    func testListenerAuthenticatesAndStopClosesWithoutUpstream() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment())
        let bridge = try RecoveryLoopbackBridge(configuration: c, lifetime: 10)
        let ready = expectation(description: "listening")
        bridge.start { ok in XCTAssertTrue(ok); ready.fulfill() }
        wait(for: [ready], timeout: 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); bridge.stop() }
        func send(_ token: String, method: String, path: String, status: Int) {
            let done = expectation(description: path)
            var r = URLRequest(url: URL(string: "http://127.0.0.1:49173\(path)")!)
            r.httpMethod = method; r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            session.dataTask(with: r) { data, response, error in
                XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
                if status == 200 { XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "{\"stopped\":true}") }
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 3)
        }
        send("bad", method: "POST", path: "/stop", status: 400)
        send(c.token, method: "POST", path: "/stop", status: 200)
        let closed = expectation(description: "refused after shutdown")
        session.dataTask(with: URL(string: "http://127.0.0.1:49173/")!) { _, response, error in
            XCTAssertNotNil(error); XCTAssertNil(response); closed.fulfill()
        }.resume()
        wait(for: [closed], timeout: 3)
    }
    func testUpstreamPreservesFixedTargetBodyAndStatusAndRejectsOversizeAndRedirect() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment(port: 49174))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeFixtureProtocol.self]
        let bridge = try RecoveryLoopbackBridge(configuration: c, upstreamConfiguration: config)
        let ready = expectation(description: "ready")
        bridge.start { ok in XCTAssertTrue(ok); ready.fulfill() }
        wait(for: [ready], timeout: 3)
        defer { bridge.stop() }
        for (payload, upstreamStatus, expectedStatus) in [(Data("unchanged".utf8), 418, 418), (Data(repeating: 97, count: 4096), 200, 200), (Data(repeating: 97, count: 4097), 200, 502), (Data(), 302, 502)] {
            let hit = expectation(description: "one upstream")
            hit.assertForOverFulfill = true
            BridgeFixtureProtocol.handle = { fixture in
                XCTAssertEqual(fixture.request.url, c.controller.appendingPathComponent("constrain"))
                XCTAssertEqual(fixture.request.httpMethod, "POST")
                XCTAssertEqual(fixture.request.value(forHTTPHeaderField: "Authorization"), "Bearer " + c.token)
                var received = fixture.request.httpBody
                if let stream = fixture.request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count >= 0 { received = Data(buffer.prefix(count)) }
                }
                XCTAssertEqual(received, Data("original-body".utf8))
                hit.fulfill()
                fixture.reply(status: upstreamStatus, body: payload)
            }
            let done = expectation(description: "response")
            var request = URLRequest(url: c.endpoint.appendingPathComponent("constrain"))
            request.httpMethod = "POST"; request.httpBody = Data("original-body".utf8)
            request.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { data, response, error in
                XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
                XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Scorebug-Loopback-Upstream"), expectedStatus == 502 ? "0" : "1")
                if expectedStatus != 502 { XCTAssertEqual(data, payload) }
                done.fulfill()
            }.resume()
            wait(for: [hit, done], timeout: 4)
        }
    }

    func testStopJoinsInFlightUpstreamAndClosesIdleConnections() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment(port: 49175))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BridgeFixtureProtocol.self]
        let bridge = try RecoveryLoopbackBridge(configuration: c, upstreamConfiguration: config)
        let ready = expectation(description: "ready")
        bridge.start { ok in XCTAssertTrue(ok); ready.fulfill() }; wait(for: [ready], timeout: 3)
        defer { bridge.stop() }
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: c.port)!, using: .tcp)
        let idleReady = expectation(description: "idle client ready")
        idle.stateUpdateHandler = { state in if case .ready = state { idleReady.fulfill() } }
        idle.start(queue: DispatchQueue(label: "bridge-idle-test"))
        wait(for: [idleReady], timeout: 3)
        let idleClosed = expectation(description: "idle client closed")
        idle.receive(minimumIncompleteLength: 1, maximumLength: 10) { _, _, complete, error in
            XCTAssertTrue(complete || error != nil); idleClosed.fulfill()
        }
        defer { idle.cancel() }
        let hit = expectation(description: "forwarding")
        let cancelled = expectation(description: "upstream cancelled")
        BridgeFixtureProtocol.handle = { fixture in fixture.onStop = { cancelled.fulfill() }; hit.fulfill() }
        var request = URLRequest(url: c.endpoint); request.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
        let failed = expectation(description: "client closed")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request) { _, _, error in XCTAssertNotNil(error); failed.fulfill() }.resume()
        wait(for: [hit], timeout: 3)
        request.url = c.endpoint.appendingPathComponent("stop"); request.httpMethod = "POST"
        let stopped = expectation(description: "shutdown")
        session.dataTask(with: request) { data, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, Data("{\"stopped\":true}".utf8)); stopped.fulfill()
        }.resume()
        wait(for: [cancelled, failed, idleClosed, stopped], timeout: 4)
    }


    func testBindCollisionFailsWithoutTakingOverExistingListener() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment(port: 49177))
        let first = try RecoveryLoopbackBridge(configuration: c)
        let ready = expectation(description: "first ready")
        first.start { ok in XCTAssertTrue(ok); ready.fulfill() }; wait(for: [ready], timeout: 3)
        defer { first.stop() }
        let second = try RecoveryLoopbackBridge(configuration: c)
        let rejected = expectation(description: "collision rejected")
        second.start { ok in XCTAssertFalse(ok); rejected.fulfill() }
        wait(for: [rejected], timeout: 3)
        second.stop()
    }

    func testAPIUsesFixedRootWithoutControllerCredentialsAndTimesOutOnce() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment(port: 49178))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BridgeFixtureProtocol.self]
        let bridge = try RecoveryLoopbackBridge(configuration: c, upstreamConfiguration: config)
        let ready = expectation(description: "ready")
        bridge.start { ok in XCTAssertTrue(ok); ready.fulfill() }; wait(for: [ready], timeout: 3)
        defer { bridge.stop() }
        let hit = expectation(description: "one request, no retry"); hit.assertForOverFulfill = true
        BridgeFixtureProtocol.handle = { fixture in
            XCTAssertEqual(fixture.request.url, c.api)
            XCTAssertNil(fixture.request.value(forHTTPHeaderField: "Authorization"))
            hit.fulfill()
        }
        var request = URLRequest(url: c.endpoint.appendingPathComponent("api-health"))
        request.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
        let done = expectation(description: "bounded timeout")
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Scorebug-Loopback-Upstream"), "0")
            done.fulfill()
        }.resume()
        wait(for: [hit, done], timeout: 5)
    }

    func testLifetimeClosesListenerAndRejectsOverlongLifetime() throws {
        let c = try RecoveryLoopbackConfiguration(environment: environment(port: 49176))
        XCTAssertThrowsError(try RecoveryLoopbackBridge(configuration: c, lifetime: 901))
        let bridge = try RecoveryLoopbackBridge(configuration: c, lifetime: 0.1)
        let ready = expectation(description: "ready")
        bridge.start { ok in XCTAssertTrue(ok); ready.fulfill() }; wait(for: [ready], timeout: 3)
        let expired = expectation(description: "expired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            URLSession.shared.dataTask(with: c.endpoint) { _, response, error in
                XCTAssertNil(response); XCTAssertNotNil(error); expired.fulfill()
            }.resume()
        }
        wait(for: [expired], timeout: 3)
    }

}


private final class BridgeFixtureProtocol: URLProtocol {
    static var handle: (BridgeFixtureProtocol) -> Void = { _ in }
    var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle(self) }
    override func stopLoading() { onStop?(); onStop = nil }
    func reply(status: Int, body: Data) {
        // No Content-Length deliberately tests the incremental response cap.
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        if status == 302 {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "http://8.8.8.8/forbidden")!), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

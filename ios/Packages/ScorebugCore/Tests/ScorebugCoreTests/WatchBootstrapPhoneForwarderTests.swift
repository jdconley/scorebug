import Foundation
import XCTest
@testable import ScorebugCore

@MainActor final class WatchBootstrapPhoneForwarderTests: XCTestCase {
    private typealias F = WatchPairingClientTests
    private var authority: WatchBootstrapAuthority {
        WatchBootstrapAuthority(scope: WatchRelayScope(endpoint: "https://example.com/control",
            gameId: "fixture-game", watchDeviceId: F.deviceId, pairingId: F.pairingId), pairingToken: F.secret)
    }
    private func request(_ authority: WatchBootstrapAuthority? = nil) -> WatchBootstrapRequest {
        let value = authority ?? self.authority
        return WatchBootstrapRequest(requestId: UUID().uuidString, authority: value,
            redemption: WatchPairingRedeemRequest(redemptionId: F.redemptionId, deviceId: value.scope.watchDeviceId),
            recoveryKey: String(repeating: "B", count: 42) + "A")
    }
    private func response() throws -> WatchPairingRedeemed {
        let old = try F.response()
        return WatchPairingRedeemed(pairingId: old.pairingId, redemptionId: old.redemptionId,
            credential: MatchCredential(gameId: old.credential.gameId, deviceId: old.credential.deviceId,
                role: .score, token: String(repeating: "C", count: 42) + "A"),
            snapshot: old.snapshot, serverTime: "2026-09-14T12:00:00.000Z")
    }
    private func setup() throws -> (WatchBootstrapPhoneForwarder, BootstrapHTTP, BootstrapClock, BootstrapFactories) {
        let http = BootstrapHTTP(response: try response()), clock = BootstrapClock(), factories = BootstrapFactories()
        let owner = WatchBootstrapPhoneForwarder(now: { clock.time },
            schedule: { delay, fire in clock.schedule(delay, fire) }, clientFactory: { endpoint in
                factories.record(endpoint.canonicalAddress)
                return MatchHTTPClient(endpoint: endpoint, transport: { try await http.send($0) })
            })
        try owner.updateAuthority(authority)
        return (owner, http, clock, factories)
    }
    private func result(_ data: Data, _ request: WatchBootstrapRequest) throws -> WatchBootstrapResult {
        try WatchBootstrapCodec.decodeReply(data, for: request).result
    }

    func testAuthorizedRedemptionUsesExactCapabilityRecoveryKeyAndBody() async throws {
        let (owner, http, _, factories) = try setup(), input = request()
        let data = await owner.forward(try WatchBootstrapCodec.encodeRequest(input))
        XCTAssertEqual(try result(data, input), .redeemed(try response()))
        let requests = await http.requests
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(factories.endpoints, [authority.scope.endpoint])
        XCTAssertEqual(sent.url?.absoluteString,
            "https://example.com/control/v1/matches/fixture-game/watch-pairings/\(F.pairingId)/redeem")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(input.authority.pairingToken)")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"), input.recoveryKey)
        let body = try XCTUnwrap(sent.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(WatchPairingRedeemRequest.self, from: body), input.redemption)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(input.recoveryKey))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(input.recoveryKey))
        // Repeated redemption remains allowed. HTTP success does not remove phone
        // authority or activate a scoring binding; the phone model owns that.
        let again = await owner.forward(try WatchBootstrapCodec.encodeRequest(input))
        XCTAssertEqual(try result(again, input), .redeemed(try response()))
    }

    func testMissingAndEveryMismatchedAuthorityRejectBeforeClientFactory() async throws {
        let alternatives = [
            WatchRelayScope(endpoint: "https://other.example", gameId: "fixture-game", watchDeviceId: F.deviceId, pairingId: F.pairingId),
            WatchRelayScope(endpoint: authority.scope.endpoint, gameId: "different-game", watchDeviceId: F.deviceId, pairingId: F.pairingId),
            WatchRelayScope(endpoint: authority.scope.endpoint, gameId: "fixture-game", watchDeviceId: UUID().uuidString, pairingId: F.pairingId),
            WatchRelayScope(endpoint: authority.scope.endpoint, gameId: "fixture-game", watchDeviceId: F.deviceId, pairingId: UUID().uuidString)
        ].map { WatchBootstrapAuthority(scope: $0, pairingToken: F.secret) }
            + [WatchBootstrapAuthority(scope: authority.scope, pairingToken: String(repeating: "D", count: 42) + "A")]
        let (owner, http, _, factories) = try setup()
        for changed in alternatives {
            let input = request(changed)
            let data = await owner.forward(try WatchBootstrapCodec.encodeRequest(input))
            XCTAssertEqual(try result(data, input), .failure(.scopeMismatch))
        }
        try owner.updateAuthority(nil)
        let input = request(), data = await owner.forward(try WatchBootstrapCodec.encodeRequest(input))
        XCTAssertEqual(try result(data, input), .failure(.scopeMismatch))
        XCTAssertTrue(factories.endpoints.isEmpty)
        let calls = await http.requests; XCTAssertTrue(calls.isEmpty)
    }

    func testMalformedBytesAndInvalidAuthorityNeverDispatch() async throws {
        let (owner, http, _, factories) = try setup()
        for bytes in [Data(), Data("not-json".utf8), Data(repeating: 32, count: WatchBootstrapCodec.maximumRequestBytes + 1)] {
            let reply = await owner.forward(bytes); XCTAssertTrue(reply.isEmpty)
        }
        let invalid = WatchBootstrapAuthority(scope: authority.scope, pairingToken: "invalid")
        XCTAssertThrowsError(try owner.updateAuthority(invalid))
        let input = request(), data = await owner.forward(try WatchBootstrapCodec.encodeRequest(input))
        XCTAssertEqual(try result(data, input), .failure(.scopeMismatch))
        XCTAssertTrue(factories.endpoints.isEmpty)
        let calls = await http.requests; XCTAssertTrue(calls.isEmpty)
    }

    func testCancelledHTTPKeepsBusyUntilJoinAndSuppressesLateCredential() async throws {
        let (owner, http, _, factories) = try setup(), input = request()
        await http.holdNext()
        let bytes = try WatchBootstrapCodec.encodeRequest(input)
        let attempt = Task { await owner.forward(bytes) }
        await http.waitUntilHeld(); attempt.cancel()
        let busy = await owner.forward(bytes)
        XCTAssertEqual(try result(busy, input), .failure(.busy))
        await http.release()
        let completed = await attempt.value
        XCTAssertEqual(try result(completed, input), .failure(.cancelled))
        let next = await owner.forward(bytes)
        XCTAssertEqual(try result(next, input), .redeemed(try response()))
        XCTAssertEqual(factories.endpoints.count, 2)
        let flags = await http.cancelledAtReturn; XCTAssertEqual(flags, [true, false])
    }

    func testSameAuthorityPeerPublicationInvalidatesBeforeLateReplyAndRetainsBusy() async throws {
        let (owner, http, _, _) = try setup(), input = request()
        await http.holdNext()
        let bytes = try WatchBootstrapCodec.encodeRequest(input)
        let attempt = Task { await owner.forward(bytes) }
        await http.waitUntilHeld()
        try owner.updateAuthority(authority)
        let busy = await owner.forward(bytes)
        XCTAssertEqual(try result(busy, input), .failure(.busy))
        await http.release()
        let completed = await attempt.value
        XCTAssertEqual(try result(completed, input), .failure(.scopeMismatch))
        let flags = await http.cancelledAtReturn; XCTAssertEqual(flags, [true])
    }

    func testTimeoutCancelsAndJoinsInsteadOfAdmittingOverlappingRedemption() async throws {
        let (owner, http, clock, _) = try setup(), input = request()
        await http.holdNext()
        let bytes = try WatchBootstrapCodec.encodeRequest(input)
        let attempt = Task { await owner.forward(bytes) }
        await http.waitUntilHeld()
        clock.time += 3; clock.fire(0)
        let busy = await owner.forward(bytes)
        XCTAssertEqual(try result(busy, input), .failure(.busy))
        await http.release()
        let completed = await attempt.value
        XCTAssertEqual(try result(completed, input), .failure(.unavailable))
        let flags = await http.cancelledAtReturn; XCTAssertEqual(flags, [true])
    }

    func testAbsoluteDeadlineRejectsSuccessWithoutTimerExecution() async throws {
        for elapsed in [2.999, 3.0] {
            let (owner, http, clock, _) = try setup(), input = request()
            await http.holdNext()
            let bytes = try WatchBootstrapCodec.encodeRequest(input)
            let attempt = Task { await owner.forward(bytes) }
            await http.waitUntilHeld(); clock.time += elapsed; await http.release()
            let value = try result(await attempt.value, input)
            XCTAssertEqual(value, elapsed < 3 ? .redeemed(try response()) : .failure(.unavailable))
        }
    }

    func testActualHTTPFailureTaxonomyAndMalformedResponsesStayTerminal() async throws {
        let cases: [(BootstrapHTTP.Mode, WatchRelayFailure)] = [
            (.failure(URLError(.notConnectedToInternet)), .unavailable),
            (.failure(URLError(.timedOut)), .unavailable),
            (.failure(URLError(.cancelled)), .cancelled),
            (.failure(CancellationError()), .cancelled),
            (.failure(URLError(.serverCertificateUntrusted)), .invalidResponse),
            (.failure(URLError(.secureConnectionFailed)), .invalidResponse),
            (.failure(BootstrapError.unexpected), .invalidResponse),
            (.body(Data("not-json".utf8), 200), .invalidResponse),
            (.body(Data("{}".utf8), 200), .invalidResponse),
            (.body(Data("{}".utf8), 401), .unauthorized),
            (.body(Data("{}".utf8), 403), .forbidden),
            (.body(Data("{\"error\":\"pairing_expired\"}".utf8), 409), .http(status: 409, code: "pairing_expired"))
        ]
        for (mode, expected) in cases {
            let (owner, http, _, _) = try setup(), input = request()
            await http.setMode(mode)
            let bytes = await owner.forward(try WatchBootstrapCodec.encodeRequest(input))
            XCTAssertEqual(try result(bytes, input), .failure(expected))
        }
    }

    func testRealCoordinatorRecoversExactCommittedRedemptionAfterLostReplyAndExpiry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BootstrapFileStore(url: root.appendingPathComponent("setup.json"))
        let (owner, http, _, _) = try setup()
        let loss = BootstrapLoss()
        let redeem: @Sendable (PendingWatchPairing) async throws -> WatchPairingRedeemed = { pending in
            XCTAssertEqual(try store.load()?.pending, pending)
            let authority = WatchBootstrapAuthority(scope: WatchRelayScope(endpoint: pending.endpoint,
                gameId: pending.offer.gameId, watchDeviceId: pending.request.deviceId,
                pairingId: pending.offer.pairingId), pairingToken: pending.offer.pairingToken)
            let request = WatchBootstrapRequest(requestId: UUID().uuidString, authority: authority,
                redemption: pending.request, recoveryKey: pending.recoveryKey)
            let reply = await owner.forward(try WatchBootstrapCodec.encodeRequest(request))
            if await loss.dropOnce() { throw URLError(.networkConnectionLost) }
            switch try WatchBootstrapCodec.decodeReply(reply, for: request).result {
            case .redeemed(let response): return response
            case .failure(let error): throw error
            }
        }
        let first = WatchSetupCoordinator(storage: store,
            scoringOutbox: JSONFilePendingCommandStore(url: root.appendingPathComponent("score.json")),
            redemption: redeem, newDeviceId: { F.deviceId }, newRedemptionId: { F.redemptionId },
            newRecoveryKey: { String(repeating: "B", count: 42) + "A" })
        do { _ = try await first.accept(endpoint: authority.scope.endpoint, offer: F.offer); XCTFail("Expected lost response") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let original = try XCTUnwrap(store.load()?.pending)
        let second = WatchSetupCoordinator(storage: BootstrapFileStore(url: store.url),
            scoringOutbox: JSONFilePendingCommandStore(url: root.appendingPathComponent("score.json")), redemption: redeem)
        let recovered = try await second.recover()
        XCTAssertNil(recovered.record?.pending)
        XCTAssertEqual(recovered.record?.paired?.credential, try response().credential)
        let calls = await http.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].httpBody, calls[1].httpBody)
        XCTAssertEqual(calls[0].url, calls[1].url)
        XCTAssertEqual(calls[0].value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"), original.recoveryKey)
        XCTAssertEqual(calls[0].allHTTPHeaderFields, calls[1].allHTTPHeaderFields)
        let applications = await http.applications; XCTAssertEqual(applications, 1)
    }
}

private enum BootstrapError: Error { case unexpected, changedIdentity }
private actor BootstrapLoss {
    private var dropped = false
    func dropOnce() -> Bool { defer { dropped = true }; return !dropped }
}
private struct BootstrapFileStore: WatchSetupStorage {
    let url: URL
    func load() throws -> WatchSetupRecord? {
        do { return try JSONDecoder().decode(WatchSetupRecord.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ record: WatchSetupRecord) throws { try JSONEncoder().encode(record).write(to: url, options: .atomic) }
}
@MainActor private final class BootstrapClock {
    var time: TimeInterval = 100
    var timers: [(@MainActor @Sendable () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> WatchRelayMessageTransport.ScheduledCancellation {
        timers.append(fire)
        return {} // Tests deliberately retain callbacks to model stale scheduling.
    }
    func fire(_ index: Int) { timers[index]() }
}
private final class BootstrapFactories: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var endpoints: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
}
private actor BootstrapHTTP {
    enum Mode: Sendable { case success, body(Data, Int), failure(any Error) }
    let response: WatchPairingRedeemed
    private var mode: Mode = .success
    private var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var committed: (Data, String, String)?
    private(set) var requests: [URLRequest] = []
    private(set) var cancelledAtReturn: [Bool] = []
    private(set) var applications = 0
    init(response: WatchPairingRedeemed) { self.response = response }
    func setMode(_ value: Mode) { mode = value }
    func holdNext() { hold = true }
    func waitUntilHeld() async { if held == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { held?.resume(); held = nil }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body: Data, status: Int
        switch mode {
        case .failure(let error): throw error
        case .body(let value, let code): body = value; status = code
        case .success:
            let payload = try XCTUnwrap(request.httpBody)
            let key = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"))
            let token = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            if let committed {
                guard committed.0 == payload, committed.1 == key, committed.2 == token else { throw BootstrapError.changedIdentity }
            } else { committed = (payload, key, token); applications += 1 }
            body = try JSONEncoder().encode(response); status = 200
        }
        if hold {
            hold = false
            await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
        }
        cancelledAtReturn.append(Task.isCancelled)
        return (body, try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

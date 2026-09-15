import Foundation
import XCTest
@testable import ScorebugCore

@MainActor
final class WatchRelayPhoneForwarderTests: XCTestCase {
    private let scope = WatchRelayScope(endpoint: "https://example.com/control", gameId: "fixture-game",
        watchDeviceId: "00000000-0000-4000-8000-000000000014", pairingId: "00000000-0000-4000-8000-000000000015")
    private let date = Date(timeIntervalSince1970: 1_789_347_600)
    private var credential: MatchCredential {
        MatchCredential(gameId: scope.gameId, deviceId: scope.watchDeviceId, role: .score, token: String(repeating: "a", count: 43))
    }
    private func request(_ operation: WatchRelayOperation = .snapshot, scope: WatchRelayScope? = nil) -> WatchRelayRequest {
        let scope = scope ?? self.scope
        var credential = credential; credential.gameId = scope.gameId; credential.deviceId = scope.watchDeviceId
        return WatchRelayRequest(requestId: UUID().uuidString, scope: scope, credential: credential, operation: operation)
    }
    private func command() -> MatchCommand {
        MatchCommand(commandId: "durable-command", gameId: scope.gameId, deviceId: scope.watchDeviceId,
            expectedRevision: 0, scorerEpoch: 1, issuedAt: forwarderDate(date), operation: .awardPoint(side: .home))
    }
    private func snapshot() throws -> MatchSnapshot {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        var snapshot = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot
        snapshot.scorer.deviceId = credential.deviceId
        return snapshot
    }
    private func setup(timeout: TimeInterval = 3, snapshot: MatchSnapshot? = nil,
                       store: (any PendingCommandStore)? = nil) throws -> (WatchRelayPhoneForwarder, ForwardHarness, ForwardHTTP, ForwardFactory) {
        let http = ForwardHTTP(snapshot: try snapshot ?? self.snapshot(), serverTime: forwarderDate(date), store: store)
        let factory = ForwardFactory(http), harness = ForwardHarness()
        let forwarder = WatchRelayPhoneForwarder(timeout: timeout, now: { harness.time },
            schedule: { delay, fire in harness.schedule(delay, fire: fire) }, clientFactory: { factory.make($0) })
        try forwarder.updateBinding(scope)
        return (forwarder, harness, http, factory)
    }
    private func result(_ bytes: Data, for request: WatchRelayRequest) throws -> WatchRelayResult {
        try WatchRelayCodec.decodeReply(bytes, for: request).result
    }

    func testAllowedOperationsForwardCanonicalEndpointExactWatchCredentialAndCommand() async throws {
        let (forwarder, _, http, factory) = try setup()
        let requests = [request(), request(.execute(command())), request(.receipt(commandId: command().commandId)), request(.receipt(commandId: "absent"))]
        var results: [WatchRelayResult] = []
        for request in requests { results.append(try result(await forwarder.forward(WatchRelayCodec.encodeRequest(request)), for: request)) }
        guard case .snapshot = results[0], case .outcome(let outcome) = results[1], case .receiptFound(let receipt) = results[2] else {
            return XCTFail("Expected typed results")
        }
        XCTAssertTrue(outcome.accepted); XCTAssertEqual(outcome, receipt)
        XCTAssertEqual(results[3], .receiptAbsent)
        let calls = await http.calls
        XCTAssertEqual(calls.map(\.operation), [.snapshot, .execute(command()), .receipt(commandId: command().commandId), .receipt(commandId: "absent")])
        XCTAssertTrue(calls.allSatisfy { $0.credential == credential })
        XCTAssertEqual(factory.endpoints, Array(repeating: scope.endpoint, count: 4))
    }

    func testMalformedAndEveryScopeMismatchFailBeforeFactoryOrHTTP() async throws {
        let (forwarder, _, http, factory) = try setup()
        for data in [Data(), Data("not-json".utf8), Data(repeating: 65, count: WatchRelayCodec.maximumRequestBytes + 1)] {
            let reply = await forwarder.forward(data)
            XCTAssertTrue(reply.isEmpty)
        }
        let scopes = [
            WatchRelayScope(endpoint: "https://other.example", gameId: scope.gameId, watchDeviceId: scope.watchDeviceId, pairingId: scope.pairingId),
            WatchRelayScope(endpoint: scope.endpoint, gameId: "another-game", watchDeviceId: scope.watchDeviceId, pairingId: scope.pairingId),
            WatchRelayScope(endpoint: scope.endpoint, gameId: scope.gameId, watchDeviceId: scope.pairingId, pairingId: scope.pairingId),
            WatchRelayScope(endpoint: scope.endpoint, gameId: scope.gameId, watchDeviceId: scope.watchDeviceId, pairingId: scope.watchDeviceId),
        ]
        for scope in scopes {
            let request = request(scope: scope)
            let reply = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
            XCTAssertEqual(try result(reply, for: request), .failure(.scopeMismatch))
        }
        XCTAssertTrue(factory.endpoints.isEmpty)
        let calls = await http.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testInvalidAndClearedBindingsFailClosed() async throws {
        let (forwarder, _, _, factory) = try setup()
        let invalid = WatchRelayScope(endpoint: "https://example.com/", gameId: scope.gameId, watchDeviceId: scope.watchDeviceId, pairingId: scope.pairingId)
        XCTAssertThrowsError(try forwarder.updateBinding(invalid))
        let request = request()
        let encoded = try WatchRelayCodec.encodeRequest(request)
        let failed = await forwarder.forward(encoded)
        XCTAssertEqual(try result(failed, for: try WatchRelayCodec.decodeRequest(encoded)), .failure(.scopeMismatch))
        try forwarder.updateBinding(scope); try forwarder.updateBinding(nil)
        let cleared = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
        XCTAssertEqual(try result(cleared, for: request), .failure(.scopeMismatch))
        XCTAssertTrue(factory.endpoints.isEmpty)
    }

    func testBusyOwnershipPersistsUntilCancelledHTTPActuallyJoins() async throws {
        let (forwarder, _, http, factory) = try setup()
        await http.setPaused(true)
        let firstRequest = request(), nextRequest = request()
        let first = Task { await forwarder.forward(try WatchRelayCodec.encodeRequest(firstRequest)) }
        await http.waitForCalls(1)
        first.cancel()
        let busy = await forwarder.forward(try WatchRelayCodec.encodeRequest(nextRequest))
        XCTAssertEqual(try result(busy, for: nextRequest), .failure(.busy))
        await http.waitForCancellation()
        await http.release()
        let reply = try await first.value
        XCTAssertEqual(try result(reply, for: firstRequest), .failure(.cancelled))
        let cancelled = await http.cancelledAtCompletion; XCTAssertEqual(cancelled, [true])
        await http.setPaused(false)
        let next = await forwarder.forward(try WatchRelayCodec.encodeRequest(nextRequest))
        guard case .snapshot = try result(next, for: nextRequest) else { return XCTFail("Expected joined owner to reopen") }
        XCTAssertEqual(factory.endpoints.count, 2)
    }

    func testBindingChangeInvalidatesGenerationBeforeLateSuccessAndRetainsBusy() async throws {
        let (forwarder, _, http, factory) = try setup()
        await http.setPaused(true)
        let oldRequest = request()
        let old = Task { await forwarder.forward(try WatchRelayCodec.encodeRequest(oldRequest)) }
        await http.waitForCalls(1)
        let replacement = WatchRelayScope(endpoint: scope.endpoint, gameId: scope.gameId,
            watchDeviceId: scope.watchDeviceId, pairingId: "00000000-0000-4000-8000-000000000099")
        try forwarder.updateBinding(replacement)
        let newRequest = request(scope: replacement)
        let busy = await forwarder.forward(try WatchRelayCodec.encodeRequest(newRequest))
        XCTAssertEqual(try result(busy, for: newRequest), .failure(.busy))
        await http.release()
        let oldReply = try await old.value
        XCTAssertEqual(try result(oldReply, for: oldRequest), .failure(.scopeMismatch))
        let cancelled = await http.cancelledAtCompletion; XCTAssertEqual(cancelled, [true])
        await http.setPaused(false)
        let newReply = await forwarder.forward(try WatchRelayCodec.encodeRequest(newRequest))
        guard case .snapshot = try result(newReply, for: newRequest) else { return XCTFail("Expected current scope") }
        XCTAssertEqual(factory.endpoints.count, 2)
    }

    func testTimeoutCancelsButCannotReleaseBusyUntilHTTPJoin() async throws {
        let (forwarder, harness, http, _) = try setup()
        await http.setPaused(true)
        let request = request()
        let pending = Task { await forwarder.forward(try WatchRelayCodec.encodeRequest(request)) }
        await http.waitForCalls(1)
        harness.time += 3; harness.fire(0)
        let busy = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
        XCTAssertEqual(try result(busy, for: request), .failure(.busy))
        await http.release()
        let reply = try await pending.value
        XCTAssertEqual(try result(reply, for: request), .failure(.unavailable))
        let cancelled = await http.cancelledAtCompletion; XCTAssertEqual(cancelled, [true])
        XCTAssertEqual(harness.cancelled, [0])
    }

    func testCompletionChecksAbsoluteDeadlineEvenWhenTimerDidNotFire() async throws {
        for elapsed in [2.999, 3.0] {
            let (owner, harness, client, _) = try setup()
            await client.setPaused(true)
            let request = request()
            let pending = Task { await owner.forward(try WatchRelayCodec.encodeRequest(request)) }
            await client.waitForCalls(1)
            harness.time += elapsed
            await client.release()
            let reply = try await pending.value
            if elapsed < 3 {
                guard case .snapshot = try result(reply, for: request) else { return XCTFail("Expected before-deadline result") }
            } else { XCTAssertEqual(try result(reply, for: request), .failure(.unavailable)) }
        }
    }

    func testInvalidConfigurationClockAndPrecancelledCallerNeverConstructClient() async throws {
        let invalid: [TimeInterval] = [0, -1, .nan, .infinity]
        for timeout in invalid {
            let (forwarder, _, _, factory) = try setup(timeout: timeout)
            let request = request()
            let reply = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
            XCTAssertEqual(try result(reply, for: request), .failure(.unavailable))
            XCTAssertTrue(factory.endpoints.isEmpty)
        }
        let (forwarder, harness, _, factory) = try setup()
        let request = request()
        let encoded = try WatchRelayCodec.encodeRequest(request)
        harness.time = .nan
        let badClock = await forwarder.forward(encoded)
        XCTAssertEqual(try result(badClock, for: try WatchRelayCodec.decodeRequest(encoded)), .failure(.unavailable))
        harness.time = 100
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
        }
        let reply = try await cancelled.value
        XCTAssertEqual(try result(reply, for: request), .failure(.cancelled))
        XCTAssertTrue(factory.endpoints.isEmpty)
    }

    func testAuthoritativeAbsenceIsDistinctFromEveryHTTPFailure() async throws {
        let modes: [(ForwardHTTP.Failure, WatchRelayFailure)] = [
            (.client(.unauthorized), .unauthorized), (.client(.forbidden), .forbidden),
            (.client(.http(status: 404, code: "match_not_found")), .http(status: 404, code: "match_not_found")),
            (.client(.invalidResponse), .invalidResponse), (.client(.invalidIdentifier), .invalidRequest),
            (.relay(.cancelled), .cancelled), (.unknown, .invalidResponse),
        ]
        for (failure, expected) in modes {
            let (forwarder, _, http, _) = try setup(); await http.setFailure(failure)
            let request = request(.receipt(commandId: "unknown"))
            let reply = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
            XCTAssertEqual(try result(reply, for: request), .failure(expected))
        }
    }

    func testCancellationDuringFactoryCannotStartHTTPBeforeItsActorHandlerRuns() async throws {
        let http = ForwardHTTP(snapshot: try snapshot(), serverTime: forwarderDate(date), store: nil)
        let forwarder = WatchRelayPhoneForwarder(clientFactory: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return http
        })
        try forwarder.updateBinding(scope)
        let request = request()
        let task = Task { await forwarder.forward(try WatchRelayCodec.encodeRequest(request)) }
        let reply = try await task.value
        XCTAssertEqual(try result(reply, for: request), .failure(.cancelled))
        let calls = await http.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMalformedServerModelsAndUnboundedFailureCodesBecomeInvalidResponse() async throws {
        var invalid = try snapshot(); invalid.teams.home.name = String(repeating: "x", count: 100_000)
        let (forwarder, _, _, _) = try setup(snapshot: invalid)
        let request = request()
        let reply = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
        XCTAssertEqual(try result(reply, for: request), .failure(.invalidResponse))
        let (errors, _, http, _) = try setup()
        await http.setFailure(.client(.http(status: 500, code: String(repeating: "secret", count: 100))))
        let failureReply = await errors.forward(try WatchRelayCodec.encodeRequest(request))
        XCTAssertEqual(try result(failureReply, for: request), .failure(.invalidResponse))
        XCTAssertFalse(String(decoding: failureReply, as: UTF8.self).contains("secret"))
    }

    func testActualHTTPDecodingFailuresRemainInvalidResponsesForSnapshotAndReceipt() async throws {
        let malformedSnapshot = ["not-json", "{}", #"{"snapshot":"wrong-type","serverTime":"2026-09-14T01:00:00.000Z"}"#]
        let malformedReceipt = ["not-json", "{}", #"{"commandId":7,"accepted":true,"error":null,"snapshot":{}}"#]
        let cases: [(WatchRelayOperation, [String])] = [(.snapshot, malformedSnapshot), (.receipt(commandId: "original-command"), malformedReceipt)]
        for (operation, payloads) in cases {
            for payload in payloads {
                let http = MatchHTTPClient(endpoint: try ScoringEndpoint(scope.endpoint), transport: { request in
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (Data(payload.utf8), response)
                })
                let harness = ForwardHarness()
                let forwarder = WatchRelayPhoneForwarder(now: { harness.time },
                    schedule: { delay, fire in harness.schedule(delay, fire: fire) }, clientFactory: { _ in http })
                try forwarder.updateBinding(scope)
                let request = request(operation)
                let reply = await forwarder.forward(try WatchRelayCodec.encodeRequest(request))
                XCTAssertEqual(try result(reply, for: request), .failure(.invalidResponse), "Malformed HTTP200 response for \(operation.kind)")
            }
        }
    }

    func testServerCommitLostCompanionReplyRecoversOriginalDurableReceipt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let (forwarder, _, http, _) = try setup(store: store)
        let loss = ForwardLoss()
        let client = WatchRelayScoringClient(scope: scope, send: { data in
            let request = try WatchRelayCodec.decodeRequest(data)
            let reply = await forwarder.forward(data)
            if request.operation.kind == .execute, await loss.loseOnce() { throw ForwardTestError.lostReply }
            return reply
        })
        let date = date
        let first = MatchCommandCoordinator(client: client, credential: credential, endpointScope: "paired-watch", store: store, now: { date })
        _ = try await first.refresh()
        do { _ = try await first.submit(.awardPoint(side: .home)); XCTFail("Expected lost reply") }
        catch let error as ForwardTestError { XCTAssertEqual(error, .lostReply) }
        let pending = try XCTUnwrap(store.load())
        let calls = await http.calls
        XCTAssertEqual(calls.last?.operation, .execute(pending.command)); XCTAssertEqual(calls.last?.durable, pending)
        let second = MatchCommandCoordinator(client: client, credential: credential, endpointScope: "paired-watch",
            store: JSONFilePendingCommandStore(url: url), now: { date })
        let recovered = try await second.recover()
        XCTAssertEqual(recovered.outcome?.commandId, pending.command.commandId)
        XCTAssertEqual(recovered.outcome?.accepted, true); XCTAssertNil(try store.load())
        let finalCalls = await http.calls
        XCTAssertEqual(finalCalls.map { $0.operation.kind }, [.snapshot, .execute, .receipt])
        XCTAssertTrue(finalCalls.allSatisfy { $0.credential == credential })
        let applications = await http.applications; XCTAssertEqual(applications, 1)
    }

    func testActualHTTPTransportFailuresKeepTerminalAndRecoverableRoutesDistinct() async throws {
        let cases: [(ForwardRouteProbe.Failure, WatchRelayFailure?)] = [
            (.url(.cancelled), .cancelled), (.cancellation, .cancelled),
            (.url(.serverCertificateUntrusted), .invalidResponse),
            (.url(.secureConnectionFailed), .invalidResponse),
            (.url(.badURL), .invalidResponse), (.unknown, .invalidResponse),
            (.url(.timedOut), nil), (.url(.notConnectedToInternet), nil),
            (.url(.networkConnectionLost), nil),
        ]
        let payload = try JSONEncoder().encode(MatchSnapshotResponse(snapshot: snapshot(), serverTime: forwarderDate(date)))
        for (failure, terminal) in cases {
            let directProbe = ForwardRouteProbe(direct: true, failure: failure, payload: payload)
            let phoneProbe = ForwardRouteProbe(direct: false, failure: failure, payload: payload)
            let endpoint = try ScoringEndpoint(scope.endpoint)
            let direct = MatchHTTPClient(endpoint: endpoint, transport: { try await directProbe.send($0) })
            let phone = MatchHTTPClient(endpoint: endpoint, transport: { try await phoneProbe.send($0) })
            let forwarder = WatchRelayPhoneForwarder(clientFactory: { _ in phone })
            try forwarder.updateBinding(scope)
            let companion = WatchRelayScoringClient(scope: scope, send: { await forwarder.forward($0) })
            let routed = WatchRoutedScoringClient(direct: direct, companion: companion, companionAvailable: { true })
            // First direct read is offline; successful companion read pins that route.
            _ = try await routed.snapshot(credential: credential)
            do {
                _ = try await routed.snapshot(credential: credential)
                XCTAssertNil(terminal, "Terminal companion HTTP failure must not fall back: \(failure)")
            } catch {
                XCTAssertNotNil(terminal, "Connectivity failure should use the working direct route")
                if terminal == .invalidResponse {
                    XCTAssertEqual(error as? MatchClientError, .invalidResponse)
                } else {
                    XCTAssertEqual(error as? WatchRelayFailure, terminal)
                }
            }
            let directCalls = await directProbe.calls, phoneCalls = await phoneProbe.calls
            XCTAssertEqual(directCalls, terminal == nil ? 2 : 1, "Unexpected direct fallback for \(failure)")
            XCTAssertEqual(phoneCalls, 2)
        }
    }
}

private actor ForwardRouteProbe {
    enum Failure: Sendable { case url(URLError.Code), cancellation, unknown }
    private let direct: Bool
    private let failure: Failure
    private let payload: Data
    private(set) var calls = 0
    init(direct: Bool, failure: Failure, payload: Data) {
        self.direct = direct; self.failure = failure; self.payload = payload
    }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        calls += 1
        if direct, calls == 1 { throw URLError(.notConnectedToInternet) }
        if !direct, calls > 1 {
            switch failure {
            case .url(let code): throw URLError(code)
            case .cancellation: throw CancellationError()
            case .unknown: throw ForwardTestError.lostReply
            }
        }
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }
}

private func forwarderDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
private enum ForwardTestError: Error, Equatable { case lostReply }
private actor ForwardLoss { private var lost = false; func loseOnce() -> Bool { defer { lost = true }; return !lost } }

@MainActor
private final class ForwardHarness {
    var time: TimeInterval = 100
    var timers: [(@MainActor @Sendable () -> Void)] = []
    var cancelled: [Int] = []
    func schedule(_ delay: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) -> WatchRelayMessageTransport.ScheduledCancellation {
        let id = timers.count; timers.append(fire)
        return { [weak self] in self?.cancelled.append(id) }
    }
    func fire(_ id: Int) { timers[id]() }
}

private final class ForwardFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private let client: any MatchScoringClient
    init(_ client: any MatchScoringClient) { self.client = client }
    var endpoints: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func make(_ endpoint: ScoringEndpoint) -> any MatchScoringClient {
        lock.lock(); values.append(endpoint.canonicalAddress); lock.unlock()
        return client
    }
}

private actor ForwardHTTP: MatchScoringClient {
    enum Failure: Sendable { case client(MatchClientError), relay(WatchRelayFailure), unknown }
    struct Call: Sendable { let operation: WatchRelayOperation; let credential: MatchCredential; let durable: PendingMatchCommand? }
    private var value: MatchSnapshot
    private let serverTime: String
    private let store: (any PendingCommandStore)?
    private var paused = false
    private var failure: Failure?
    private var replies: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var outcomes: [String: CommandOutcome] = [:]
    private var cancellationObserved = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [Call] = []
    private(set) var applications = 0
    private(set) var cancelledAtCompletion: [Bool] = []
    init(snapshot: MatchSnapshot, serverTime: String, store: (any PendingCommandStore)?) { value = snapshot; self.serverTime = serverTime; self.store = store }
    func setPaused(_ value: Bool) { paused = value }
    func setFailure(_ value: Failure) { failure = value }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() { if !replies.isEmpty { replies.removeFirst().resume() } }
    func waitForCancellation() async {
        if cancellationObserved { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }
    private func recordCancellation() {
        cancellationObserved = true; cancellationWaiter?.resume(); cancellationWaiter = nil
    }
    private func call(_ operation: WatchRelayOperation, credential: MatchCredential) async throws {
        calls.append(Call(operation: operation, credential: credential, durable: try store?.load()))
        let ready = waiters.filter { $0.0 <= calls.count }; waiters.removeAll { $0.0 <= calls.count }
        for (_, waiter) in ready { waiter.resume() }
        if paused {
            await withTaskCancellationHandler {
                await withCheckedContinuation { replies.append($0) }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        cancelledAtCompletion.append(Task.isCancelled)
        if let failure {
            switch failure { case .client(let error): throw error; case .relay(let error): throw error; case .unknown: throw ForwardTestError.lostReply }
        }
    }
    func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse {
        try await call(.snapshot, credential: credential)
        return MatchSnapshotResponse(snapshot: value, serverTime: serverTime)
    }
    func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome {
        try await call(.execute(command), credential: credential)
        if let outcome = outcomes[command.commandId] { return outcome }
        value.revision += 1; value.score.home += 1; applications += 1
        let outcome = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: value)
        outcomes[command.commandId] = outcome
        return outcome
    }
    func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome? {
        try await call(.receipt(commandId: commandId), credential: credential)
        return outcomes[commandId]
    }
}

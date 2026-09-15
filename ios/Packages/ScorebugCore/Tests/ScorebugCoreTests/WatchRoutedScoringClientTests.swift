import Foundation
import XCTest
@testable import ScorebugCore

final class WatchRoutedScoringClientTests: XCTestCase {
    private let device = "00000000-0000-4000-8000-000000000014"
    private let date = Date(timeIntervalSince1970: 1_789_347_600)
    private var credential: MatchCredential {
        MatchCredential(gameId: "fixture-game", deviceId: device, role: .score,
            token: String(repeating: "a", count: 43))
    }
    private func snapshot() throws -> MatchSnapshot {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        var result = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot
        result.scorer.deviceId = device
        return result
    }
    private func fixtures() throws -> (RouteStub, RouteStub, RouteTrace) {
        let trace = RouteTrace(), snapshot = try snapshot()
        return (RouteStub(name: "direct", snapshot: snapshot, date: date, trace: trace),
                RouteStub(name: "companion", snapshot: snapshot, date: date, trace: trace), trace)
    }
    private func router(_ direct: RouteStub, _ companion: RouteStub,
                        available: @escaping @Sendable () async -> Bool = { true }) -> WatchRoutedScoringClient {
        WatchRoutedScoringClient(direct: direct, companion: companion, companionAvailable: available)
    }
    private func command(_ id: String = "original-command") -> MatchCommand {
        MatchCommand(commandId: id, gameId: credential.gameId, deviceId: credential.deviceId,
            expectedRevision: 0, scorerEpoch: 1, issuedAt: routedDate(date), operation: .awardPoint(side: .home))
    }

    func testStartsDirectAndPinsCompanionAfterOneReadFallback() async throws {
        let (direct, companion, trace) = try fixtures()
        await direct.failNext(.url(.notConnectedToInternet))
        let client = router(direct, companion)
        _ = try await client.snapshot(credential: credential)
        _ = try await client.snapshot(credential: credential)
        _ = try await client.execute(command(), credential: credential)
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "companion", "companion", "companion"])
        XCTAssertEqual(calls.last?.operation, .execute(command()))
        XCTAssertTrue(calls.allSatisfy { $0.credential == credential })
    }

    func testSharedRecoveryClassifierUsesExplicitTransportTaxonomy() {
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .networkConnectionLost,
                     .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertTrue(WatchRoutedScoringClient.isRecoverableTransportFailure(URLError(code)))
        }
        for failure in [WatchRelayFailure.unavailable, .busy, .scopeMismatch] {
            XCTAssertTrue(WatchRoutedScoringClient.isRecoverableTransportFailure(failure))
        }
        for failure in [RouteFailure.client(.unauthorized), .client(.forbidden),
                        .client(.http(status: 503, code: "unavailable")), .client(.invalidResponse),
                        .client(.invalidIdentifier), .decode, .cancelled, .url(.cancelled),
                        .url(.serverCertificateUntrusted), .url(.secureConnectionFailed),
                        .relay(.invalidResponse), .relay(.invalidRequest), .unknown] {
            XCTAssertFalse(WatchRoutedScoringClient.isRecoverableTransportFailure(failure.error))
        }
    }

    func testMutationFailureDoesNotFallbackAndOnlyMatchingReceiptUsesAlternateHint() async throws {
        let (direct, companion, trace) = try fixtures()
        let client = router(direct, companion)
        await direct.failNext(.url(.networkConnectionLost))
        do { _ = try await client.execute(command(), credential: credential); XCTFail("Expected uncertainty") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        var calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct"])
        _ = try await client.receipt(commandId: "unrelated-command", credential: credential)
        _ = try await client.receipt(commandId: command().commandId, credential: credential)
        calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "direct", "companion"])
        XCTAssertEqual(calls.last?.operation, .receipt(commandId: command().commandId))
    }

    func testRejectedCommandAndAuthoritativeAbsenceDoNotFallback() async throws {
        let (direct, companion, trace) = try fixtures()
        let client = router(direct, companion)
        await direct.rejectNext()
        let rejection = try await client.execute(command(), credential: credential)
        XCTAssertFalse(rejection.accepted)
        XCTAssertEqual(rejection.error, "set_not_won")
        let absent = try await client.receipt(commandId: "unknown", credential: credential)
        XCTAssertNil(absent)
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "direct"])
    }

    func testReadFallbackStopsAfterOneAlternateAndReturnsItsError() async throws {
        let (direct, companion, trace) = try fixtures()
        let client = router(direct, companion)
        await direct.failNext(.url(.timedOut)); await companion.failNext(.relay(.unavailable))
        do { _ = try await client.snapshot(credential: credential); XCTFail("Expected second failure") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .unavailable) }
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "companion"])
    }

    func testCompanionBusyAndScopeMismatchAllowReadFallbackToDirect() async throws {
        for failure in [WatchRelayFailure.busy, .scopeMismatch, .unavailable] {
            let (direct, companion, trace) = try fixtures()
            let client = router(direct, companion)
            await direct.failNext(.url(.timedOut))
            _ = try await client.snapshot(credential: credential) // Pin companion.
            await companion.failNext(.relay(failure))
            _ = try await client.receipt(commandId: "unknown", credential: credential)
            _ = try await client.snapshot(credential: credential)
            let calls = await trace.calls
            XCTAssertEqual(calls.map { $0.route }, ["direct", "companion", "companion", "direct", "direct"])
        }
    }

    func testUnavailableCompanionIsSkippedBeforeDispatchEvenWhenPinned() async throws {
        let (direct, companion, trace) = try fixtures()
        let availability = RouteAvailability()
        let client = router(direct, companion, available: { await availability.get() })
        await direct.failNext(.url(.timedOut))
        _ = try await client.snapshot(credential: credential)
        await availability.set(false)
        _ = try await client.execute(command(), credential: credential)
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "companion", "direct"])
    }

    func testTerminalErrorsPropagateWithoutFallbackOnEitherRoute() async throws {
        let terminal: [RouteFailure] = [.client(.unauthorized), .client(.forbidden),
            .client(.http(status: 503, code: "unavailable")), .client(.invalidResponse),
            .client(.invalidIdentifier), .decode, .cancelled, .url(.cancelled),
            .url(.serverCertificateUntrusted), .url(.secureConnectionFailed),
            .relay(.invalidResponse), .relay(.invalidRequest), .relay(.cancelled), .unknown]
        for selectedCompanion in [false, true] {
            for failure in terminal {
                let (direct, companion, trace) = try fixtures()
                let client = router(direct, companion)
                if selectedCompanion {
                    await direct.failNext(.url(.timedOut))
                    _ = try await client.snapshot(credential: credential)
                }
                let before = await trace.calls.count
                await (selectedCompanion ? companion : direct).failNext(failure)
                do { _ = try await client.receipt(commandId: "unknown", credential: credential); XCTFail("Expected terminal failure") }
                catch { failure.assertMatches(error) }
                let calls = await trace.calls
                XCTAssertEqual(calls.count, before + 1)
            }
        }
    }

    func testSingleFlightIncludesSuspendedAvailabilityCheck() async throws {
        let (direct, companion, trace) = try fixtures()
        let gate = RoutePause()
        let client = router(direct, companion, available: { await gate.pause(); return true })
        await direct.failNext(.url(.timedOut))
        let first = Task { try await client.snapshot(credential: credential) }
        await gate.waitUntilPaused()
        do { _ = try await client.receipt(commandId: "unknown", credential: credential); XCTFail("Expected router busy") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .busy) }
        await gate.release()
        _ = try await first.value
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "companion"])
    }

    func testCancellationWhileAvailabilityIgnoresItCannotDispatchFallback() async throws {
        let (direct, companion, trace) = try fixtures()
        let gate = RoutePause()
        let client = router(direct, companion, available: { await gate.pause(); return true })
        await direct.failNext(.url(.timedOut))
        let task = Task { try await client.snapshot(credential: credential) }
        await gate.waitUntilPaused(); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct"])
    }

    func testCancelledAlternateReadJoinsLateFailureAndReportsCancellation() async throws {
        let (direct, companion, trace) = try fixtures()
        let gate = RoutePause()
        let client = router(direct, companion)
        await direct.failNext(.url(.timedOut))
        await companion.failNext(.url(.timedOut))
        await companion.pauseBeforeFailure(gate)
        let task = Task { try await client.snapshot(credential: credential) }
        await gate.waitUntilPaused()
        task.cancel()
        do { _ = try await client.receipt(commandId: "unknown", credential: credential); XCTFail("Still joining alternate") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .busy) }
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation over late timeout") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.snapshot(credential: credential)
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "companion", "direct"],
            "Cancelled alternate neither pins itself nor dispatches another fallback")
    }

    func testOriginalFileOutboxRetriesOnlyAfterAlternateReceiptAndFreshSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let (direct, companion, trace) = try fixtures()
        await direct.observeStore(store); await companion.observeStore(store)
        let client = router(direct, companion)
        let date = date
        let coordinator = MatchCommandCoordinator(client: client, credential: credential,
            endpointScope: "same-persisted-pairing", store: store, now: { date })
        _ = try await coordinator.refresh()
        await direct.failNext(.url(.networkConnectionLost)) // Before server applies.
        do { _ = try await coordinator.submit(.awardPoint(side: .home)); XCTFail("Expected uncertainty") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let original = try XCTUnwrap(store.load())
        let state = try await coordinator.recover()
        let calls = await trace.calls
        XCTAssertEqual(calls.map { $0.route }, ["direct", "direct", "companion", "companion", "companion"])
        XCTAssertEqual(calls.map { $0.operation.kind }, [.snapshot, .execute, .receipt, .snapshot, .execute])
        XCTAssertEqual(calls[1].operation, .execute(original.command))
        XCTAssertEqual(calls[4].operation, .execute(original.command))
        XCTAssertEqual(calls[1].durable, original)
        XCTAssertEqual(calls[4].durable, original)
        XCTAssertTrue(calls.allSatisfy { $0.credential == credential })
        XCTAssertEqual(state.outcome?.commandId, original.command.commandId)
        XCTAssertEqual(state.outcome?.accepted, true)
        XCTAssertNil(try store.load())
    }
}

private func routedDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
private enum RouteFailure: Sendable {
    case url(URLError.Code), client(MatchClientError), relay(WatchRelayFailure), decode, cancelled, unknown
    var error: any Error {
        switch self {
        case .url(let code): return URLError(code)
        case .client(let value): return value
        case .relay(let value): return value
        case .decode: return DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid response"))
        case .cancelled: return CancellationError()
        case .unknown: return RouteUnknown()
        }
    }
    func assertMatches(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        switch self {
        case .url(let code): XCTAssertEqual((error as? URLError)?.code, code, file: file, line: line)
        case .client(let value): XCTAssertEqual(error as? MatchClientError, value, file: file, line: line)
        case .relay(let value): XCTAssertEqual(error as? WatchRelayFailure, value, file: file, line: line)
        case .decode: XCTAssertTrue(error is DecodingError, file: file, line: line)
        case .cancelled: XCTAssertTrue(error is CancellationError, file: file, line: line)
        case .unknown: XCTAssertTrue(error is RouteUnknown, file: file, line: line)
        }
    }
}
private struct RouteUnknown: Error {}
private actor RouteTrace {
    struct Call: Sendable {
        let route: String
        let operation: WatchRelayOperation
        let credential: MatchCredential
        let durable: PendingMatchCommand?
    }
    private(set) var calls: [Call] = []
    func append(_ call: Call) { calls.append(call) }
}
private actor RouteStub: MatchScoringClient {
    let name: String
    private var value: MatchSnapshot
    private let date: Date
    private let trace: RouteTrace
    private var failure: RouteFailure?
    private var rejecting = false
    private var store: (any PendingCommandStore)?
    private var pause: RoutePause?
    init(name: String, snapshot: MatchSnapshot, date: Date, trace: RouteTrace) {
        self.name = name; value = snapshot; self.date = date; self.trace = trace
    }
    func failNext(_ failure: RouteFailure) { self.failure = failure }
    func rejectNext() { rejecting = true }
    func observeStore(_ store: any PendingCommandStore) { self.store = store }
    func pauseBeforeFailure(_ gate: RoutePause) { pause = gate }
    private func record(_ operation: WatchRelayOperation, credential: MatchCredential) async throws {
        await trace.append(.init(route: name, operation: operation, credential: credential, durable: try store?.load()))
        if let pause { self.pause = nil; await pause.pause() }
        if let failure { self.failure = nil; throw failure.error }
    }
    func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse {
        try await record(.snapshot, credential: credential)
        return MatchSnapshotResponse(snapshot: value, serverTime: routedDate(date))
    }
    func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome {
        try await record(.execute(command), credential: credential)
        if rejecting {
            rejecting = false
            return CommandOutcome(commandId: command.commandId, accepted: false, error: "set_not_won", snapshot: value)
        }
        value.revision += 1; value.score.home += 1
        return CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: value)
    }
    func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome? {
        try await record(.receipt(commandId: commandId), credential: credential)
        return nil
    }
}
private actor RouteAvailability {
    private var available = true
    func get() -> Bool { available }
    func set(_ value: Bool) { available = value }
}
private actor RoutePause {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

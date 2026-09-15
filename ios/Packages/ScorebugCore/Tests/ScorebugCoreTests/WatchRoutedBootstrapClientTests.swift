import Foundation
import XCTest
@testable import ScorebugCore

final class WatchRoutedBootstrapClientTests: XCTestCase {
    private typealias F = WatchPairingClientTests
    private var pending: PendingWatchPairing {
        PendingWatchPairing(endpoint: "https://example.com/control", offer: F.offer,
            request: WatchPairingRedeemRequest(redemptionId: F.redemptionId, deviceId: F.deviceId), recoveryKey: F.secret)
    }
    private func fixtures(available: @escaping @Sendable () async -> Bool = { true }) throws -> (WatchRoutedBootstrapClient, BootstrapRouteStub, BootstrapRouteStub, BootstrapRouteTrace) {
        let trace = BootstrapRouteTrace()
        let direct = BootstrapRouteStub(name: "direct", response: try F.response(), trace: trace)
        let companion = BootstrapRouteStub(name: "companion", response: try F.response(), trace: trace)
        return (WatchRoutedBootstrapClient(direct: { try await direct.redeem($0) }, companion: { try await companion.redeem($0) },
            companionAvailable: available), direct, companion, trace)
    }

    func testUncertainFailureUsesAlternateOnlyOnNextInvocationAndPinsSuccess() async throws {
        let (client, direct, _, trace) = try fixtures()
        await direct.failNext(.url(.notConnectedToInternet))
        do { _ = try await client.redeem(pending); XCTFail("Initial failure must return without fallback") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let first = await trace.calls; XCTAssertEqual(first.map(\.route), ["direct"])
        _ = try await client.redeem(pending)
        _ = try await client.redeem(pending)
        let calls = await trace.calls
        XCTAssertEqual(calls.map(\.route), ["direct", "companion", "companion"])
        XCTAssertTrue(calls.allSatisfy { $0.pending == pending })
    }

    func testUnavailableCompanionUsesDirectOnceThenRemembersDirectSuccess() async throws {
        let availability = BootstrapRouteAvailability()
        let (client, direct, _, trace) = try fixtures(available: { await availability.get() })
        await direct.failNext(.url(.timedOut))
        do { _ = try await client.redeem(pending) } catch {}
        await availability.set(false)
        _ = try await client.redeem(pending)
        await availability.set(true)
        _ = try await client.redeem(pending)
        let calls = await trace.calls
        XCTAssertEqual(calls.map(\.route), ["direct", "direct", "direct"])
    }

    func testAlternateFailureReturnsWithoutInlineRetryAndHintsNextRouteOnly() async throws {
        for failure in [WatchRelayFailure.unavailable, .busy, .scopeMismatch] {
            let (client, direct, companion, trace) = try fixtures()
            await direct.failNext(.url(.networkConnectionLost))
            do { _ = try await client.redeem(pending) } catch {}
            await companion.failNext(.relay(failure))
            do { _ = try await client.redeem(pending); XCTFail("Companion failure must return") }
            catch { XCTAssertEqual(error as? WatchRelayFailure, failure) }
            let before = await trace.calls; XCTAssertEqual(before.map(\.route), ["direct", "companion"])
            _ = try await client.redeem(pending)
            let after = await trace.calls; XCTAssertEqual(after.map(\.route), ["direct", "companion", "direct"])
        }
    }

    func testTerminalDirectFailureAfterUnavailableCompanionClearsOldAlternateHint() async throws {
        for failure in [BootstrapRouteError.url(.serverCertificateUntrusted), .client(.unauthorized), .codec] {
            let availability = BootstrapRouteAvailability()
            let (client, direct, _, trace) = try fixtures(available: { await availability.get() })
            await direct.failNext(.url(.timedOut))
            do { _ = try await client.redeem(pending) } catch {}
            await availability.set(false)
            await direct.failNext(failure)
            do { _ = try await client.redeem(pending); XCTFail("Expected terminal direct failure") }
            catch { XCTAssertEqual(bootstrapRouteErrorDescription(error), bootstrapRouteErrorDescription(failure.error)) }
            await availability.set(true)
            _ = try await client.redeem(pending)
            let calls = await trace.calls
            XCTAssertEqual(calls.map(\.route), ["direct", "direct", "direct"], "An old hint must not bypass the most recent terminal route error")
        }
    }

    func testTerminalErrorsNeverCreateAlternateHintOnEitherRoute() async throws {
        let terminal: [BootstrapRouteError] = [.url(.serverCertificateUntrusted), .url(.secureConnectionFailed), .url(.cancelled),
            .client(.unauthorized), .client(.forbidden), .client(.invalidResponse), .client(.http(status: 409, code: "pairing_expired")),
            .client(.http(status: 503, code: "unavailable")), .relay(.invalidRequest), .relay(.cancelled), .codec, .cancelled, .unknown]
        for failure in terminal {
            for useCompanion in [false, true] {
                let (client, direct, companion, trace) = try fixtures()
                if useCompanion {
                    await direct.failNext(.url(.timedOut))
                    do { _ = try await client.redeem(pending) } catch {}
                    _ = try await client.redeem(pending)
                }
                let target = useCompanion ? companion : direct
                await target.failNext(failure)
                do { _ = try await client.redeem(pending); XCTFail("Expected terminal error") }
                catch { XCTAssertEqual(bootstrapRouteErrorDescription(error), bootstrapRouteErrorDescription(failure.error)) }
                _ = try await client.redeem(pending)
                let calls = await trace.calls
                XCTAssertEqual(Array(calls.suffix(2)).map(\.route), Array(repeating: useCompanion ? "companion" : "direct", count: 2))
            }
        }
        for failure in [WatchRelayFailure.unavailable, .scopeMismatch, .busy] {
            let (client, direct, _, trace) = try fixtures()
            await direct.failNext(.relay(failure))
            do { _ = try await client.redeem(pending) } catch {}
            _ = try await client.redeem(pending)
            let calls = await trace.calls; XCTAssertEqual(calls.map(\.route), ["direct", "direct"], "Companion-only failures must not authorize direct route hints")
        }
    }

    func testEveryChangedNonsecretIdentityResetsDirectAndInvalidScopeNeverDispatches() async throws {
        let alternatives = [changed(endpoint: "https://other.example"), changed(game: "another-game"),
            changed(device: UUID().uuidString), changed(pairing: UUID().uuidString), changed(redemption: UUID().uuidString)]
        for alternative in alternatives {
            let (client, direct, _, trace) = try fixtures()
            await direct.failNext(.url(.timedOut))
            do { _ = try await client.redeem(pending) } catch {}
            _ = try await client.redeem(alternative)
            _ = try await client.redeem(pending)
            let calls = await trace.calls
            XCTAssertEqual(calls.map(\.route), ["direct", "direct", "direct"])
            XCTAssertEqual(calls.map(\.pending), [pending, alternative, pending])
        }
        let (client, _, _, trace) = try fixtures()
        for invalid in [changed(endpoint: "https://example.com/control/"), changed(game: "../invalid"), changed(redemption: "invalid")] {
            do { _ = try await client.redeem(invalid); XCTFail("Invalid identity must not dispatch") }
            catch { XCTAssertEqual(error as? WatchRelayCodecError, .invalidMessage) }
        }
        let calls = await trace.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testBusyReservationCoversAvailabilityAwaitAndCancellationUntilJoin() async throws {
        let availability = BootstrapRouteAvailability()
        let (client, direct, _, trace) = try fixtures(available: { await availability.get() })
        await direct.failNext(.url(.timedOut))
        do { _ = try await client.redeem(pending) } catch {}
        await availability.pauseNext()
        let pending = pending
        let suspended = Task { try await client.redeem(pending) }
        await availability.waitUntilPaused()
        do { _ = try await client.redeem(pending); XCTFail("Availability await must reserve the only operation") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .busy) }
        suspended.cancel()
        do { _ = try await client.redeem(pending); XCTFail("Cancellation must not release an unjoined await") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .busy) }
        await availability.release()
        do { _ = try await suspended.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let before = await trace.calls; XCTAssertEqual(before.map(\.route), ["direct"])
        _ = try await client.redeem(pending)
        let after = await trace.calls; XCTAssertEqual(after.map(\.route), ["direct", "companion"])
    }

    func testCancelledTransportErrorDoesNotPublishFallbackHintOrReleaseBeforeJoin() async throws {
        let (client, direct, _, trace) = try fixtures()
        let pending = pending
        let precancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.redeem(pending)
        }
        do { _ = try await precancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await direct.failNext(.url(.networkConnectionLost), paused: true)
        let attempt = Task { try await client.redeem(pending) }
        await direct.waitUntilPaused()
        attempt.cancel()
        do { _ = try await client.redeem(pending); XCTFail("Unjoined transport remains busy") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .busy) }
        await direct.release()
        do { _ = try await attempt.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.redeem(pending)
        let calls = await trace.calls; XCTAssertEqual(calls.map(\.route), ["direct", "direct"])
    }

    func testCancelledLateSuccessIsNotAcknowledged() async throws {
        let (client, direct, _, trace) = try fixtures()
        await direct.pauseNextReply()
        let pending = pending
        let attempt = Task { try await client.redeem(pending) }
        await direct.waitUntilPaused()
        attempt.cancel(); await direct.release()
        do { _ = try await attempt.value; XCTFail("Cancelled late credential must not be acknowledged") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.redeem(pending)
        let calls = await trace.calls; XCTAssertEqual(calls.map(\.route), ["direct", "direct"])
    }

    func testRealCoordinatorRetriesOfflineDirectThroughCompanionUsingFilePending() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutedBootstrapFileStore(url: root.appendingPathComponent("setup.json"))
        let server = RoutedBootstrapServer(store: store, response: try F.response(), commitBeforeFirstFailure: false)
        let client = WatchRoutedBootstrapClient(direct: { try await server.redeem($0, route: "direct") },
            companion: { try await server.redeem($0, route: "companion") }, companionAvailable: { true })
        do { _ = try await coordinator(store, client).accept(endpoint: pending.endpoint, offer: pending.offer); XCTFail("Initial route failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(try store.load()?.pending, pending)
        let first = await server.calls; XCTAssertEqual(first.map(\.route), ["direct"])
        let recovered = try await coordinator(RoutedBootstrapFileStore(url: store.url), client).recover()
        XCTAssertEqual(recovered.record?.paired?.credential, try F.response().credential)
        let calls = await server.calls, applications = await server.applications
        XCTAssertEqual(calls.map(\.route), ["direct", "companion"])
        XCTAssertTrue(calls.allSatisfy { $0.pending == pending })
        XCTAssertEqual(applications, 1); XCTAssertNil(try store.load()?.pending)
    }

    func testCommittedLostReplyAndFailedSaveRecoverSameCredentialAfterOfferExpiry() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutedBootstrapFileStore(url: root.appendingPathComponent("setup.json"), rejectPaired: true)
        let response = try F.response()
        let expiredRecovery = WatchPairingRedeemed(pairingId: response.pairingId, redemptionId: response.redemptionId,
            credential: response.credential, snapshot: response.snapshot, serverTime: "2026-09-15T00:00:00Z")
        let server = RoutedBootstrapServer(store: store, response: expiredRecovery, commitBeforeFirstFailure: true)
        let client = WatchRoutedBootstrapClient(direct: { try await server.redeem($0, route: "direct") },
            companion: { try await server.redeem($0, route: "companion") }, companionAvailable: { true })
        do { _ = try await coordinator(store, client).accept(endpoint: pending.endpoint, offer: pending.offer); XCTFail("Lost committed reply") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        do { _ = try await coordinator(store, client).recover(); XCTFail("Paired save fails") }
        catch { XCTAssertEqual(error as? WatchSetupError, .storageFailure) }
        XCTAssertEqual(try store.load()?.pending, pending)
        let recovered = try await coordinator(RoutedBootstrapFileStore(url: store.url), client).recover()
        XCTAssertEqual(recovered.record?.paired?.credential, response.credential)
        let calls = await server.calls, applications = await server.applications
        XCTAssertEqual(calls.map(\.route), ["direct", "companion", "companion"])
        XCTAssertTrue(calls.allSatisfy { $0.pending == pending }); XCTAssertEqual(applications, 1)
    }

    private func changed(endpoint: String? = nil, game: String? = nil, device: String? = nil,
                         pairing: String? = nil, redemption: String? = nil) -> PendingWatchPairing {
        let original = pending
        return PendingWatchPairing(endpoint: endpoint ?? original.endpoint,
            offer: WatchPairingIssued(pairingId: pairing ?? original.offer.pairingId, gameId: game ?? original.offer.gameId,
                watchDeviceId: device ?? original.offer.watchDeviceId, pairingToken: original.offer.pairingToken,
                expiresAt: original.offer.expiresAt, serverTime: original.offer.serverTime),
            request: WatchPairingRedeemRequest(redemptionId: redemption ?? original.request.redemptionId, deviceId: device ?? original.request.deviceId),
            recoveryKey: original.recoveryKey)
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func coordinator(_ store: RoutedBootstrapFileStore, _ client: WatchRoutedBootstrapClient) -> WatchSetupCoordinator {
        WatchSetupCoordinator(storage: store,
            scoringOutbox: JSONFilePendingCommandStore(url: store.url.deletingLastPathComponent().appendingPathComponent("outbox.json")),
            redemption: { try await client.redeem($0) }, newDeviceId: { F.deviceId },
            newRedemptionId: { F.redemptionId }, newRecoveryKey: { F.secret })
    }
}

private enum BootstrapRouteError {
    case url(URLError.Code), client(MatchClientError), relay(WatchRelayFailure), codec, cancelled, unknown
    var error: Error {
        switch self {
        case .url(let code): URLError(code)
        case .client(let value): value
        case .relay(let value): value
        case .codec: WatchRelayCodecError.invalidMessage
        case .cancelled: CancellationError()
        case .unknown: CocoaError(.fileReadUnknown)
        }
    }
}
private func bootstrapRouteErrorDescription(_ error: Error) -> String { String(reflecting: error) }
private actor BootstrapRouteTrace {
    struct Call { let route: String; let pending: PendingWatchPairing }
    private(set) var calls: [Call] = []
    func add(_ route: String, _ pending: PendingWatchPairing) { calls.append(Call(route: route, pending: pending)) }
}
private actor BootstrapRouteStub {
    let name: String, response: WatchPairingRedeemed, trace: BootstrapRouteTrace
    private var failure: BootstrapRouteError?
    private var pause = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var replyWaiter: CheckedContinuation<Void, Never>?
    init(name: String, response: WatchPairingRedeemed, trace: BootstrapRouteTrace) { self.name = name; self.response = response; self.trace = trace }
    func failNext(_ value: BootstrapRouteError, paused: Bool = false) { failure = value; pause = paused }
    func pauseNextReply() { pause = true }
    func waitUntilPaused() async { if replyWaiter == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { replyWaiter?.resume(); replyWaiter = nil }
    func redeem(_ pending: PendingWatchPairing) async throws -> WatchPairingRedeemed {
        await trace.add(name, pending)
        let failure = failure; self.failure = nil
        if pause {
            pause = false
            await withCheckedContinuation { replyWaiter = $0; waiter?.resume(); waiter = nil }
        }
        if let failure { throw failure.error }
        return response
    }
}
private actor BootstrapRouteAvailability {
    private var available = true, pause = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var replyWaiter: CheckedContinuation<Void, Never>?
    func set(_ value: Bool) { available = value }
    func pauseNext() { pause = true }
    func waitUntilPaused() async { if replyWaiter == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { replyWaiter?.resume(); replyWaiter = nil }
    func get() async -> Bool {
        if pause { pause = false; await withCheckedContinuation { replyWaiter = $0; waiter?.resume(); waiter = nil } }
        return available
    }
}
private struct RoutedBootstrapFileStore: WatchSetupStorage {
    let url: URL
    var rejectPaired = false
    func load() throws -> WatchSetupRecord? {
        do { return try JSONDecoder().decode(WatchSetupRecord.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ record: WatchSetupRecord) throws {
        if rejectPaired && record.paired != nil { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}
private actor RoutedBootstrapServer {
    let store: RoutedBootstrapFileStore, response: WatchPairingRedeemed, commitBeforeFirstFailure: Bool
    private var committed: PendingWatchPairing?
    private(set) var calls: [BootstrapRouteTrace.Call] = []
    private(set) var applications = 0
    init(store: RoutedBootstrapFileStore, response: WatchPairingRedeemed, commitBeforeFirstFailure: Bool) {
        self.store = store; self.response = response; self.commitBeforeFirstFailure = commitBeforeFirstFailure
    }
    func redeem(_ pending: PendingWatchPairing, route: String) throws -> WatchPairingRedeemed {
        XCTAssertEqual(try RoutedBootstrapFileStore(url: store.url).load()?.pending, pending)
        calls.append(.init(route: route, pending: pending))
        if calls.count == 1 && !commitBeforeFirstFailure { throw URLError(.notConnectedToInternet) }
        if let committed { XCTAssertEqual(committed, pending) }
        else { committed = pending; applications += 1 }
        if calls.count == 1 { throw URLError(.networkConnectionLost) }
        return response
    }
}

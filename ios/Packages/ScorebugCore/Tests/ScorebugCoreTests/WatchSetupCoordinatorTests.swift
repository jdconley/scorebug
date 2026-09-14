import Foundation
import XCTest
@testable import ScorebugCore

private final class SetupMemory: WatchSetupStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: WatchSetupRecord?
    private var remainingSaves = Int.max
    private var failsLoad = false
    init(_ value: WatchSetupRecord? = nil) { self.value = value }
    func failAfter(saves: Int) { lock.lock(); defer { lock.unlock() }; remainingSaves = saves }
    func failLoad(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failsLoad = value }
    func load() throws -> WatchSetupRecord? {
        lock.lock(); defer { lock.unlock() }
        if failsLoad { throw WatchSetupError.storageFailure }; return value
    }
    func save(_ record: WatchSetupRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard remainingSaves > 0 else { throw WatchSetupError.storageFailure }
        remainingSaves -= 1; value = record
    }
}

private final class SetupOutbox: PendingCommandStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingMatchCommand?
    func load() throws -> PendingMatchCommand? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ value: PendingMatchCommand?) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private actor PairingNetwork {
    var requests: [URLRequest] = []
    var failure: MatchClientError?
    var response: WatchPairingRedeemed
    var pause: CheckedContinuation<Void, Never>?
    var shouldPause = false
    init(_ response: WatchPairingRedeemed) { self.response = response }
    func configure(failure: MatchClientError? = nil, response: WatchPairingRedeemed? = nil, paused: Bool = false) {
        self.failure = failure; if let response { self.response = response }; shouldPause = paused
    }
    func release() { pause?.resume(); pause = nil }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if shouldPause { await withCheckedContinuation { pause = $0 } }
        if let failure { throw failure }
        return (try JSONEncoder().encode(response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func count() -> Int { requests.count }
    func allRequests() -> [URLRequest] { requests }
}

final class WatchSetupCoordinatorTests: XCTestCase {
    private typealias F = WatchPairingClientTests
    private func coordinator(_ storage: SetupMemory, _ network: PairingNetwork, outbox: SetupOutbox = SetupOutbox()) -> WatchSetupCoordinator {
        WatchSetupCoordinator(storage: storage, scoringOutbox: outbox,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await network.send($0) }) },
            newDeviceId: { F.deviceId }, newRedemptionId: { F.redemptionId }, newRecoveryKey: { F.secret })
    }
    private func rejected(_ expected: WatchSetupError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? WatchSetupError, expected) }
    }

    func testPersistsDistinctWatchIdentityAndCommitsOnlyScopedSetupWithoutTakeover() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        let owner = coordinator(storage, network)
        do {
            let initial = try await owner.restore()
            XCTAssertEqual(initial.record?.deviceId, F.deviceId)
            XCTAssertEqual(try storage.load(), initial.record)
            let result = try await owner.accept(endpoint: "https://example.com/control", offer: F.offer)
            XCTAssertNil(result.record?.pending)
            XCTAssertEqual(result.record?.paired?.credential, try F.response().credential)
            XCTAssertEqual(try storage.load(), result.record)
            let requests = await network.allRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests.allSatisfy { $0.url!.path.hasSuffix("/redeem") })
            XCTAssertEqual(result.snapshot?.scorer.deviceId, "fixture-phone")
            XCTAssertFalse(result.record!.paired!.scoringScope.contains("scoped-watch-secret"))
        } catch { XCTFail("Durable Watch setup should succeed: \(error)") }
    }

    func testSaveFailureBeforeSendLeavesServerUntouched() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        let owner = coordinator(storage, network)
        storage.failAfter(saves: 1) // Identity commits; pending attempt cannot commit.
        await rejected(.storageFailure) { _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer) }
        let count = await network.count()
        XCTAssertEqual(count, 0)
        XCTAssertNil(try storage.load()?.pending)
    }

    func testLostReplyAndPostSuccessSaveFailureRecoverExactAttemptAfterRelaunch() async throws {
        for postSuccessSaveFailure in [false, true] {
            let storage = SetupMemory(), network = PairingNetwork(try F.response())
            let owner = coordinator(storage, network)
            if postSuccessSaveFailure { storage.failAfter(saves: 2) }
            else { await network.configure(failure: .http(status: 503, code: nil)) }
            do { _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer); XCTFail("Expected uncertain attempt") }
            catch {}
            let pending = try XCTUnwrap(storage.load()?.pending)
            XCTAssertEqual(pending.request.redemptionId, F.redemptionId)
            XCTAssertEqual(pending.recoveryKey, F.secret)
            XCTAssertNil(try storage.load()?.paired)
            storage.failAfter(saves: .max)
            await network.configure()
            let relaunched = coordinator(storage, network)
            let result = try await relaunched.recover()
            XCTAssertNotNil(result.record?.paired)
            let sent = await network.allRequests()
            XCTAssertEqual(sent.count, 2)
            XCTAssertEqual(sent[0].url, sent[1].url)
            XCTAssertEqual(sent[0].httpBody, sent[1].httpBody)
            XCTAssertEqual(sent[0].allHTTPHeaderFields, sent[1].allHTTPHeaderFields)
        }
    }

    func testWrongResponseIdentityOrAuthorityNeverBecomesPaired() async throws {
        let good = try F.response()
        let wrong = [try F.response(deviceId: UUID().uuidString), try F.response(role: .capture),
            try F.response(pairingId: UUID().uuidString), try F.response(redemptionId: UUID().uuidString),
            WatchPairingRedeemed(pairingId: good.pairingId, redemptionId: good.redemptionId,
                credential: MatchCredential(gameId: "another-game", deviceId: F.deviceId, role: .score, token: "secret"),
                snapshot: good.snapshot, serverTime: good.serverTime),
            WatchPairingRedeemed(pairingId: good.pairingId, redemptionId: good.redemptionId,
                credential: good.credential, snapshot: good.snapshot, serverTime: "invalid")]
        for response in wrong {
            let storage = SetupMemory(), network = PairingNetwork(response)
            let owner = coordinator(storage, network)
            await rejected(.invalidResponse) { _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer) }
            XCTAssertNotNil(try storage.load()?.pending)
            XCTAssertNil(try storage.load()?.paired)
        }
    }

    func testPendingSetupCannotBeReplacedByAnotherEndpointOrOffer() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        await network.configure(failure: .unauthorized)
        let owner = coordinator(storage, network)
        do { _ = try await owner.accept(endpoint: "https://EXAMPLE.com:443/control/", offer: F.offer) } catch {}
        let original = try XCTUnwrap(storage.load())
        XCTAssertEqual(original.pending?.endpoint, "https://example.com/control")
        let another = WatchPairingIssued(pairingId: UUID().uuidString, gameId: F.offer.gameId, watchDeviceId: F.deviceId,
            pairingToken: F.secret, expiresAt: F.offer.expiresAt, serverTime: F.offer.serverTime)
        await rejected(.pendingPairing) { _ = try await owner.accept(endpoint: "https://different.example", offer: F.offer, replacingCurrent: true) }
        await rejected(.pendingPairing) { _ = try await owner.accept(endpoint: "https://example.com/control", offer: another, replacingCurrent: true) }
        XCTAssertEqual(try storage.load(), original)
        let count = await network.count(); XCTAssertEqual(count, 1)
    }

    func testCancellationAndLateReplyPreservePendingAttemptAndBusyRejectsCompetingSetup() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        await network.configure(paused: true)
        let owner = coordinator(storage, network)
        let task = Task { try await owner.accept(endpoint: "https://example.com", offer: F.offer) }
        for _ in 0..<10_000 {
            if await network.count() == 1 { break }
            await Task.yield()
        }
        let count = await network.count(); XCTAssertEqual(count, 1)
        let pending = try storage.load()
        await rejected(.busy) { _ = try await owner.accept(endpoint: "https://another.example", offer: F.offer) }
        task.cancel()
        await network.release()
        do { _ = try await task.value; XCTFail("Cancelled setup must not acknowledge a late reply") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try storage.load(), pending)
        XCTAssertNil(try storage.load()?.paired)
        await network.configure()
        let result = try await coordinator(storage, network).recover()
        XCTAssertNotNil(result.record?.paired)
    }

    func testOnlyDefinitiveUnusedExpiryCanDiscardAnUncertainPairing() async throws {
        for failure in [MatchClientError.unauthorized, .http(status: 409, code: "pairing_conflict"),
                        .http(status: 503, code: nil), .http(status: 409, code: "pairing_expired")] {
            let storage = SetupMemory(), network = PairingNetwork(try F.response())
            await network.configure(failure: failure)
            let owner = coordinator(storage, network)
            do { _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer) } catch {}
            let before = try XCTUnwrap(storage.load()?.pending)
            do { _ = try await owner.discardExpired() } catch {}
            if failure == .http(status: 409, code: "pairing_expired") {
                XCTAssertNil(try storage.load()?.pending)
                XCTAssertEqual(try storage.load()?.deviceId, F.deviceId)
            } else { XCTAssertEqual(try storage.load()?.pending, before) }
        }
    }

    func testDiscardRecoversPreviouslyCommittedPairingInsteadOfDroppingIt() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        await network.configure(failure: .http(status: 503, code: nil))
        let owner = coordinator(storage, network)
        do { _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer) } catch {}
        await network.configure()
        let result = try await owner.discardExpired()
        XCTAssertNotNil(result.record?.paired)
        XCTAssertNil(result.record?.pending)
    }

    func testScoringUncertaintyBlocksNewSetupAndExistingPairRequiresExplicitReplacement() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response()), outbox = SetupOutbox()
        let owner = coordinator(storage, network, outbox: outbox)
        _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer)
        let paired = try storage.load()
        let next = WatchPairingIssued(pairingId: UUID().uuidString, gameId: F.offer.gameId, watchDeviceId: F.deviceId,
            pairingToken: F.secret, expiresAt: F.offer.expiresAt, serverTime: F.offer.serverTime)
        await rejected(.alreadyPaired) { _ = try await owner.accept(endpoint: "https://example.com", offer: next) }
        let command = MatchCommand(commandId: "pending", gameId: F.offer.gameId, deviceId: F.deviceId,
            expectedRevision: 0, scorerEpoch: 1, issuedAt: F.offer.serverTime, operation: .awardPoint(side: .home))
        try outbox.save(PendingMatchCommand(endpointScope: paired!.paired!.scoringScope, command: command, originalScorerDeviceId: F.deviceId))
        await rejected(.pendingScoring) { _ = try await owner.accept(endpoint: "https://example.com", offer: next, replacingCurrent: true) }
        XCTAssertEqual(try storage.load(), paired)
        XCTAssertNotNil(try outbox.load())
        let count = await network.count(); XCTAssertEqual(count, 1)
    }

    func testInvalidOfferAndStorageLoadFailureDoNotContactServer() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        storage.failLoad(true)
        let owner = coordinator(storage, network)
        await rejected(.storageFailure) { _ = try await owner.restore() }
        storage.failLoad(false)
        let invalid = WatchPairingIssued(pairingId: F.pairingId, gameId: F.offer.gameId, watchDeviceId: UUID().uuidString,
            pairingToken: F.secret, expiresAt: F.offer.expiresAt, serverTime: F.offer.serverTime)
        await rejected(.invalidOffer) { _ = try await owner.accept(endpoint: "https://example.com", offer: invalid) }
        let count = await network.count(); XCTAssertEqual(count, 0)
        XCTAssertNil(try storage.load()?.pending)
    }

    func testMalformedStoredSetupIsNeverReplacedOrSent() async throws {
        let response = try F.response()
        let pending = PendingWatchPairing(endpoint: "https://example.com", offer: F.offer,
            request: WatchPairingRedeemRequest(redemptionId: F.redemptionId, deviceId: F.deviceId), recoveryKey: F.secret)
        let paired = WatchPairedSetup(endpoint: "https://example.com", pairingId: F.pairingId,
            redemptionId: F.redemptionId, credential: response.credential)
        let invalidKey = PendingWatchPairing(endpoint: pending.endpoint, offer: pending.offer, request: pending.request,
            recoveryKey: String(repeating: "A", count: 42) + "B")
        for record in [WatchSetupRecord(deviceId: "broken"), WatchSetupRecord(deviceId: F.deviceId, pending: pending, paired: paired),
                       WatchSetupRecord(deviceId: UUID().uuidString, pending: pending),
                       WatchSetupRecord(deviceId: F.deviceId, pending: invalidKey)] {
            let storage = SetupMemory(record), network = PairingNetwork(response)
            let owner = coordinator(storage, network)
            await rejected(.invalidSetup) { _ = try await owner.recover() }
            XCTAssertEqual(try storage.load(), record)
            let count = await network.count(); XCTAssertEqual(count, 0)
        }
    }

    func testRepeatedCompanionOfferCannotReplaceAnAlreadyCommittedCredential() async throws {
        let storage = SetupMemory(), network = PairingNetwork(try F.response())
        let owner = coordinator(storage, network)
        let initial = try await owner.accept(endpoint: "https://example.com", offer: F.offer)
        let repeated = try await coordinator(storage, network).accept(endpoint: "https://EXAMPLE.com:443/", offer: F.offer)
        XCTAssertEqual(repeated.record, initial.record)
        let count = await network.count(); XCTAssertEqual(count, 1)
    }

    func testDefaultDeviceAndRecoverySecretsArePersistedOnceAndRemainDistinct() async throws {
        let storage = SetupMemory(), outbox = SetupOutbox()
        let network = PairingNetwork(try F.response())
        let owner = WatchSetupCoordinator(storage: storage, scoringOutbox: outbox,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await network.send($0) }) })
        let restored = try await owner.restore()
        let id = try XCTUnwrap(restored.record?.deviceId)
        XCTAssertNotNil(UUID(uuidString: id))
        let offer = WatchPairingIssued(pairingId: F.pairingId, gameId: F.offer.gameId, watchDeviceId: id,
            pairingToken: F.secret, expiresAt: F.offer.expiresAt, serverTime: F.offer.serverTime)
        await network.configure(failure: .unauthorized)
        do { _ = try await owner.accept(endpoint: "https://example.com", offer: offer) } catch {}
        let pending = try XCTUnwrap(storage.load()?.pending)
        XCTAssertNotNil(UUID(uuidString: pending.request.redemptionId))
        XCTAssertEqual(pending.request.deviceId, id)
        XCTAssertEqual(pending.recoveryKey.count, 43)
        XCTAssertNotEqual(pending.recoveryKey, F.secret)
        let restoredAgain = try await WatchSetupCoordinator(storage: storage, scoringOutbox: outbox).restore()
        XCTAssertEqual(restoredAgain.record?.pending, pending)
    }

    func testNoncanonicalRecoveryKeyCannotCreateAnUnrecoverablePendingRecord() async throws {
        let storage = SetupMemory(), outbox = SetupOutbox(), network = PairingNetwork(try F.response())
        let owner = WatchSetupCoordinator(storage: storage, scoringOutbox: outbox,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await network.send($0) }) },
            newDeviceId: { F.deviceId }, newRedemptionId: { F.redemptionId },
            newRecoveryKey: { String(repeating: "A", count: 42) + "B" })
        await rejected(.invalidSetup) { _ = try await owner.accept(endpoint: "https://example.com", offer: F.offer) }
        XCTAssertNil(try storage.load()?.pending)
        let count = await network.count(); XCTAssertEqual(count, 0)
    }
}

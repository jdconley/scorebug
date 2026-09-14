import Foundation
import ScorebugCore
import XCTest

private let device = "30000000-0000-4000-8000-000000000001"
private let phone = "20000000-0000-4000-8000-000000000001"
private let game = "10000000-0000-4000-8000-000000000001"
private let pair = "40000000-0000-4000-8000-000000000001"
private let redemption = "50000000-0000-4000-8000-000000000001"
private let date = "2026-09-14T01:00:00.000Z"
private let endpoint = "https://watch.example.com"
private func credential(_ gameId: String = game) -> MatchCredential {
    MatchCredential(gameId: gameId, deviceId: device, role: .score, token: "watch-scoped-token")
}
private func paired() -> WatchSetupRecord {
    WatchSetupRecord(deviceId: device, paired: WatchPairedSetup(endpoint: endpoint, pairingId: pair,
        redemptionId: redemption, credential: credential()))
}
private func envelope(_ gameId: String = game, pairingId: String = pair) -> WatchPairingEnvelope {
    WatchPairingEnvelope(endpoint: endpoint, offer: WatchPairingIssued(pairingId: pairingId,
        gameId: gameId, watchDeviceId: device, pairingToken: String(repeating: "A", count: 43),
        expiresAt: "2026-09-14T01:05:00.000Z", serverTime: date))
}
private func snapshot(_ owner: String = phone) -> MatchSnapshot {
    MatchSnapshot(id: game, createdAt: date, revision: 0,
        teams: MatchTeams(home: MatchTeam(name: "Home", shortName: "H", color: "#123456"),
            away: MatchTeam(name: "Away", shortName: "A", color: "#654321")),
        rules: MatchRules(bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil),
        score: MatchScore(home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0), completedSets: [],
        status: .active, endReason: nil, canUndo: false, scorer: MatchScorer(deviceId: owner, epoch: 1),
        broadcast: MatchBroadcast(desired: .stopped, generation: 0))
}
private enum Failure: Error { case storage, network }
private final class SetupStore: WatchSetupStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: WatchSetupRecord?
    var failPairedSave = false
    init(_ value: WatchSetupRecord? = nil) { self.value = value }
    func load() throws -> WatchSetupRecord? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ record: WatchSetupRecord) throws {
        lock.lock(); defer { lock.unlock() }
        if failPairedSave && record.paired != nil { throw Failure.storage }; value = record
    }
}
private final class Outbox: PendingCommandStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingMatchCommand?
    var failClear = false
    var failSave = false
    var failLoad = false
    func load() throws -> PendingMatchCommand? {
        lock.lock(); defer { lock.unlock() }
        if failLoad { throw Failure.storage }; return value
    }
    func save(_ pending: PendingMatchCommand?) throws {
        lock.lock(); defer { lock.unlock() }
        if (pending == nil && failClear) || (pending != nil && failSave) { throw Failure.storage }
        value = pending
    }
}
private actor Server {
    var current: MatchSnapshot
    var requests: [URLRequest] = []
    var receipts: [String: CommandOutcome] = [:]
    var loseCommand = false
    var losePair = false
    var heldPath: String?
    var continuation: CheckedContinuation<Void, Never>?
    var isHeld = false
    var lastHeldRequestWasCancelled = false
    var rejectTiedSet = false
    var pairingExpired = false
    var serverTime = date
    init(owner: String = phone) { current = snapshot(owner) }
    func setLoseCommand() { loseCommand = true }
    func setLosePair() { losePair = true }
    func setRejectTiedSet() { rejectTiedSet = true }
    func setPairingExpired() { pairingExpired = true }
    func advanceClock() { serverTime = "2026-09-14T01:01:00.000Z" }
    func hold(_ path: String) { heldPath = path }
    func waitForHold() async { while !isHeld { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil; isHeld = false }
    func setRevision(_ revision: Int, owner: String = device) { current.revision = revision; current.scorer.deviceId = owner }
    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        if heldPath.map({ path.hasSuffix($0) }) == true {
            heldPath = nil
            await withCheckedContinuation { continuation = $0; isHeld = true }
            lastHeldRequestWasCancelled = Task.isCancelled
        }
        func response<T: Encodable>(_ value: T, _ status: Int = 200) throws -> (Data, URLResponse) {
            (try JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!)
        }
        if path.hasSuffix("/redeem") {
            if pairingExpired { return try response(["error": "pairing_expired"], 409) }
            let body = try JSONDecoder().decode(WatchPairingRedeemRequest.self, from: request.httpBody!)
            let parts = path.split(separator: "/")
            let gameId = String(parts[2]), pairingId = String(parts[4])
            var value = current; value.id = gameId
            if losePair { losePair = false; throw Failure.network }
            return try response(WatchPairingRedeemed(pairingId: pairingId, redemptionId: body.redemptionId,
                credential: credential(gameId), snapshot: value, serverTime: serverTime))
        }
        if request.httpMethod == "POST" {
            let command = try JSONDecoder().decode(MatchCommand.self, from: request.httpBody!)
            if let receipt = receipts[command.commandId] { return try response(receipt) }
            var error: String?
            switch command.operation {
            case .takeOver: current.scorer.deviceId = device; current.scorer.epoch += 1
            case .awardPoint(let side):
                if side == .home { current.score.home += 1 } else { current.score.away += 1 }
            case .endSet: if rejectTiedSet { error = "set_tied" }
            case .endMatch: current.status = .ended
            case .undo: current.score.home = max(0, current.score.home - 1)
            }
            if error == nil { current.revision += 1; current.canUndo = true }
            let receipt = CommandOutcome(commandId: command.commandId, accepted: error == nil,
                error: error, snapshot: current)
            receipts[command.commandId] = receipt
            if loseCommand { loseCommand = false; throw Failure.network }
            return try response(receipt, error == nil ? 200 : 409)
        }
        if path.contains("/commands/") {
            if let receipt = receipts[request.url!.lastPathComponent] { return try response(receipt) }
            return try response(["error": "command_not_found"], 404)
        }
        return try response(MatchSnapshotResponse(snapshot: current, serverTime: serverTime))
    }
}

@MainActor
final class WatchScoringModelTests: XCTestCase {
    private func model(_ store: SetupStore, _ server: Server, outbox: Outbox = Outbox(),
                       notice: @escaping (WatchCompanionNotice) -> Void = { _ in },
                       haptic: @escaping () -> Void = {}) -> WatchScoringModel {
        let factory: @Sendable (ScoringEndpoint) -> MatchHTTPClient = {
            MatchHTTPClient(endpoint: $0, transport: { try await server.handle($0) })
        }
        let setup = WatchSetupCoordinator(storage: store, scoringOutbox: outbox, clientFactory: factory,
            newDeviceId: { device }, newRedemptionId: { redemption },
            newRecoveryKey: { String(repeating: "A", count: 43) })
        return WatchScoringModel(setupCoordinator: setup, pendingStore: outbox, clientFactory: factory,
            onNotice: notice, acknowledgmentHaptic: haptic)
    }

    func testWakeAdvertisesPersistedIdentityWithoutImplicitTakeover() async {
        let server = Server(), store = SetupStore(paired())
        var notices: [WatchCompanionNotice] = []
        let model = model(store, server, notice: { notices.append($0) })
        await model.wake()
        XCTAssertEqual(model.snapshot?.id, game)
        XCTAssertEqual(notices.last?.phase, .paired)
        XCTAssertEqual(notices.last?.deviceId, device)
        XCTAssertFalse(model.canScore)
        XCTAssertTrue(model.canTakeOver)
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        await model.send(.awardPoint(side: .home))
        let after = await server.requests.count
        XCTAssertEqual(after, requests.count)
    }

    func testInactiveLatestOfferRequiresExplicitAcceptanceAfterWake() async throws {
        let store = SetupStore(), server = Server()
        let model = model(store, server)
        await model.receive(envelope(pairingId: "40000000-0000-4000-8000-000000000002"))
        await model.receive(envelope())
        XCTAssertNil(try store.load())
        let before = await server.requests.count
        XCTAssertEqual(before, 0)
        await model.wake()
        XCTAssertNil(try store.load()?.paired)
        XCTAssertNil(try store.load()?.pending)
        XCTAssertEqual(model.offeredSetup, envelope())
        XCTAssertEqual(model.phase, .unpaired)
        let beforeAcceptance = await server.requests.count
        XCTAssertEqual(beforeAcceptance, 0)
        await model.acceptOfferedSetup()
        XCTAssertEqual(try store.load()?.paired?.pairingId, pair)
        XCTAssertEqual(model.phase, .paired)
        XCTAssertFalse(model.canScore)
    }

    func testActiveOfferDoesNotRedeemUntilExplicitAcceptance() async throws {
        let store = SetupStore(), server = Server()
        let model = model(store, server)
        await model.wake()
        await model.receive(envelope())
        await model.refresh()
        XCTAssertEqual(model.offeredSetup, envelope())
        XCTAssertNil(try store.load()?.pending)
        XCTAssertNil(try store.load()?.paired)
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
        await model.acceptOfferedSetup()
        XCTAssertEqual(model.phase, .paired)
    }

    func testExplicitTakeoverAndAcceptedPointHapticOnlyOnce() async {
        var haptics = 0
        let server = Server()
        let scorer = self.model(SetupStore(paired()), server, haptic: { haptics += 1 })
        await scorer.wake()
        await scorer.send(.takeOver)
        XCTAssertTrue(scorer.canScore)
        XCTAssertEqual(haptics, 1)
        await scorer.send(.awardPoint(side: .home))
        XCTAssertEqual(scorer.snapshot?.score.home, 1)
        XCTAssertEqual(haptics, 2)
        await scorer.refresh()
        XCTAssertEqual(haptics, 2)
        XCTAssertEqual(scorer.message, "Action accepted.")
    }

    func testLostReplyRecoversReceiptAcrossRelaunchWithoutSecondPoint() async throws {
        let store = SetupStore(paired()), server = Server(owner: device), outbox = Outbox()
        var haptics = 0
        let first = model(store, server, outbox: outbox, haptic: { haptics += 1 })
        await first.wake(); await server.setLoseCommand()
        await first.send(.awardPoint(side: .home))
        XCTAssertTrue(first.pending)
        XCTAssertEqual(haptics, 0)
        let original = try XCTUnwrap(outbox.load())
        await first.suspend()
        let restarted = model(store, server, outbox: outbox, haptic: { haptics += 1 })
        await restarted.wake()
        XCTAssertNil(try outbox.load())
        XCTAssertEqual(restarted.snapshot?.score.home, 1)
        XCTAssertEqual(haptics, 1)
        let requests = await server.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(requests.contains { $0.url?.lastPathComponent == original.command.commandId })
    }

    func testClearFailureKeepsPendingAndSuppressesHapticUntilDurableRecovery() async throws {
        let outbox = Outbox(), server = Server(owner: device)
        var haptics = 0
        let model = model(SetupStore(paired()), server, outbox: outbox, haptic: { haptics += 1 })
        await model.wake(); outbox.failClear = true
        await model.send(.awardPoint(side: .home))
        XCTAssertTrue(model.pending)
        XCTAssertNotNil(try outbox.load())
        XCTAssertEqual(haptics, 0)
        XCTAssertFalse(model.canScore)
        outbox.failClear = false
        await model.refresh()
        XCTAssertFalse(model.pending)
        XCTAssertEqual(haptics, 1)
    }

    func testPairingSaveFailureAdvertisesPendingAndRecoversBeforePairedNotice() async throws {
        let store = SetupStore(), server = Server()
        store.failPairedSave = true
        var notices: [WatchCompanionNotice] = []
        let model = model(store, server, notice: { notices.append($0) })
        await model.wake(); await model.receive(envelope())
        await model.acceptOfferedSetup()
        XCTAssertEqual(model.phase, .pending)
        XCTAssertNotNil(try store.load()?.pending)
        XCTAssertFalse(notices.contains { $0.phase == .paired })
        store.failPairedSave = false
        await model.refresh()
        XCTAssertEqual(model.phase, .paired)
        XCTAssertEqual(notices.last?.phase, .paired)
    }

    func testNewOfferRequiresExplicitReplacementAndPendingScoringBlocksIt() async throws {
        let outbox = Outbox(), store = SetupStore(paired()), server = Server(owner: device)
        let model = model(store, server, outbox: outbox)
        await model.wake(); await server.setLoseCommand()
        await model.send(.awardPoint(side: .home))
        let other = envelope("10000000-0000-4000-8000-000000000002", pairingId: "40000000-0000-4000-8000-000000000002")
        await model.receive(other)
        await model.acceptOfferedSetup(replacingCurrent: true)
        XCTAssertEqual(try store.load()?.paired?.credential.gameId, game)
        XCTAssertFalse(model.canReplaceSetup)
        await model.refresh()
        XCTAssertTrue(model.canReplaceSetup)
        await model.acceptOfferedSetup()
        XCTAssertEqual(try store.load()?.paired?.credential.gameId, game)
        await model.acceptOfferedSetup(replacingCurrent: true)
        XCTAssertEqual(try store.load()?.paired?.credential.gameId, other.offer.gameId)
    }

    func testSuspendJoinsIgnoredCancellationAndSuppressesLateSnapshotAndNotice() async {
        let server = Server(owner: device)
        var notices: [WatchCompanionNotice] = []
        let model = model(SetupStore(paired()), server, notice: { notices.append($0) })
        await model.wake()
        let count = notices.count
        await server.setRevision(10); await server.hold(game)
        let refresh = Task { await model.refresh() }
        await server.waitForHold()
        var suspended = false
        let stop = Task { await model.suspend(); suspended = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(suspended)
        XCTAssertTrue(model.busy)
        await model.send(.awardPoint(side: .home))
        await model.wake() // Cannot overlap a teardown still awaiting a late response.
        await server.release(); await refresh.value; await stop.value
        XCTAssertEqual(model.snapshot?.revision, 0)
        XCTAssertEqual(notices.count, count)
        XCTAssertFalse(model.isActive)
        await model.wake()
        XCTAssertEqual(model.snapshot?.revision, 10)
    }

    func testSuspendDuringPairingLeavesDurablePendingAndWakeRecovers() async throws {
        let store = SetupStore(), server = Server()
        var notices: [WatchCompanionNotice] = []
        let model = model(store, server, notice: { notices.append($0) })
        await model.wake(); await model.receive(envelope())
        await server.hold("/redeem")
        let accepting = Task { await model.acceptOfferedSetup() }
        await server.waitForHold()
        let durable = try XCTUnwrap(store.load()?.pending)
        let stopping = Task { await model.suspend() }
        for _ in 0..<10 { await Task.yield() }
        await server.release(); await stopping.value
        XCTAssertFalse(model.busy, "Suspend must join and release admission before returning")
        XCTAssertNil(try store.load()?.paired)
        XCTAssertEqual(try store.load()?.pending, durable)
        XCTAssertFalse(notices.contains { $0.phase == .paired })
        await model.wake() // Does not need to await the original caller first.
        await accepting.value
        XCTAssertEqual(model.phase, .paired)
        XCTAssertEqual(try store.load()?.paired?.redemptionId, durable.request.redemptionId)
    }

    func testInitialOutboxSaveFailurePreventsPostAndBlocksReplacementInMemory() async throws {
        let outbox = Outbox(), store = SetupStore(paired()), server = Server(owner: device)
        let model = model(store, server, outbox: outbox)
        await model.wake(); outbox.failSave = true
        await model.send(.awardPoint(side: .home))
        XCTAssertTrue(model.pending)
        XCTAssertNil(try outbox.load())
        XCTAssertFalse(model.canReplaceSetup)
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        outbox.failSave = false
        await model.refresh()
        XCTAssertEqual(model.snapshot?.score.home, 1)
        XCTAssertFalse(model.pending)
    }

    func testScopeMismatchNeverSendsCredentialToRecoverWrongOutbox() async throws {
        let outbox = Outbox(), server = Server(owner: device)
        try outbox.save(PendingMatchCommand(endpointScope: "another-server",
            command: MatchCommand(commandId: UUID().uuidString, gameId: game, deviceId: device,
                expectedRevision: 0, scorerEpoch: 1, issuedAt: date, operation: .awardPoint(side: .home)),
            originalScorerDeviceId: device))
        let model = model(SetupStore(paired()), server, outbox: outbox)
        await model.wake()
        XCTAssertEqual(model.state?.status, .scopeMismatch)
        XCTAssertTrue(model.pending)
        XCTAssertFalse(model.canReplaceSetup)
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testExpiredAbsentScoringRequiresExplicitReceiptFirstReconciliation() async throws {
        let outbox = Outbox(), server = Server(owner: device)
        let model = model(SetupStore(paired()), server, outbox: outbox)
        await model.wake(); outbox.failSave = true
        await model.send(.awardPoint(side: .home))
        outbox.failSave = false
        await server.advanceClock()
        await model.refresh()
        XCTAssertEqual(model.state?.status, .reconciliationRequired)
        XCTAssertTrue(model.pending)
        await model.discardExpiredScoring()
        XCTAssertFalse(model.pending)
        XCTAssertNil(try outbox.load())
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(requests.filter { $0.url!.path.contains("/commands/") }.count, 3)
    }

    func testExpiredPairingOnlyClearsOnExplicitServerConfirmedDiscard() async throws {
        let store = SetupStore(), server = Server()
        let model = model(store, server)
        await model.wake(); await server.setPairingExpired()
        await model.receive(envelope())
        await model.acceptOfferedSetup()
        XCTAssertEqual(model.phase, .pending)
        await model.refresh()
        XCTAssertEqual(model.phase, .pending)
        await model.discardExpiredPairing()
        XCTAssertEqual(model.phase, .unpaired)
        XCTAssertNil(try store.load()?.pending)
        XCTAssertNil(model.offeredSetup)
    }

    func testInvalidAndWrongDeviceOffersDoNotReplaceSetupOrSend() async {
        let server = Server()
        let scorer = self.model(SetupStore(paired()), server)
        await scorer.wake()
        let prior = await server.requests.count
        let bad = WatchPairingEnvelope(endpoint: endpoint, offer: WatchPairingIssued(pairingId: pair,
            gameId: game, watchDeviceId: phone, pairingToken: String(repeating: "A", count: 43),
            expiresAt: "2026-09-14T01:05:00.000Z", serverTime: date))
        await scorer.receive(bad)
        await scorer.receive(WatchPairingEnvelope(endpoint: String(repeating: "x", count: 9000), offer: envelope().offer))
        XCTAssertNil(scorer.offeredSetup)
        let after = await server.requests.count
        XCTAssertEqual(after, prior)
    }

    func testUnreadableOutboxDisablesScoringDespiteRetainedSnapshot() async {
        let server = Server(owner: device), outbox = Outbox()
        let model = model(SetupStore(paired()), server, outbox: outbox)
        await model.wake()
        // A failed write makes Core reload the outbox on the following request.
        outbox.failSave = true
        await model.send(.awardPoint(side: .home))
        outbox.failLoad = true
        await model.refresh()
        XCTAssertEqual(model.state?.status, .storageFailure)
        XCTAssertFalse(model.canScore)
        XCTAssertFalse(model.canReplaceSetup)
    }

    func testLostPairingReplyRecoversSameDurableRedemptionAfterRelaunch() async throws {
        let server = Server(), store = SetupStore()
        let first = model(store, server)
        await first.wake(); await server.setLosePair()
        await first.receive(envelope())
        await first.acceptOfferedSetup()
        let pending = try XCTUnwrap(store.load()?.pending)
        XCTAssertEqual(first.phase, .pending)
        await first.suspend()
        let restarted = model(store, server)
        await restarted.wake()
        XCTAssertEqual(restarted.phase, .paired)
        XCTAssertEqual(try store.load()?.paired?.redemptionId, pending.request.redemptionId)
        let requests = await server.requests.filter { $0.url!.path.hasSuffix("/redeem") }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"),
            requests.last?.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery"))
    }

    func testLateAcceptedCommandCannotHapticOrUpdateWhileSuspended() async throws {
        let server = Server(owner: device), outbox = Outbox()
        var haptics = 0
        let model = model(SetupStore(paired()), server, outbox: outbox, haptic: { haptics += 1 })
        await model.wake(); await server.hold("/commands")
        let sending = Task { await model.send(.awardPoint(side: .home)) }
        await server.waitForHold()
        let stopping = Task { await model.suspend() }
        for _ in 0..<10 { await Task.yield() }
        await server.release(); await stopping.value; await sending.value
        XCTAssertNil(try outbox.load(), "The coordinator may durably acknowledge a late reply")
        XCTAssertEqual(model.snapshot?.score.home, 0)
        XCTAssertEqual(haptics, 0)
        await model.wake()
        XCTAssertEqual(model.snapshot?.score.home, 1)
        XCTAssertEqual(haptics, 1)
        await model.refresh()
        XCTAssertEqual(haptics, 1)
    }

    func testOlderRefreshCannotRegressAuthoritativeScoreRevision() async {
        let server = Server(owner: device)
        let model = model(SetupStore(paired()), server)
        await server.setRevision(10); await model.wake()
        await server.setRevision(5); await model.refresh()
        XCTAssertEqual(model.snapshot?.revision, 10)
    }

    func testAcceptedCanonicalEndpointVariantsClearOfferAndIgnoreRedelivery() async throws {
        for address in ["https://watch.example.com/", "https://watch.example.com:443",
                        "HTTPS://WATCH.EXAMPLE.COM", "HTTPS://WATCH.EXAMPLE.COM:443///"] {
            let server = Server(), store = SetupStore()
            let model = model(store, server)
            await model.wake()
            let incoming = WatchPairingEnvelope(endpoint: address, offer: envelope().offer)
            await model.receive(incoming)
            await model.acceptOfferedSetup()
            XCTAssertEqual(try store.load()?.paired?.endpoint, endpoint)
            XCTAssertNil(model.offeredSetup, address)
            let count = await server.requests.count
            await model.receive(incoming)
            XCTAssertNil(model.offeredSetup, "Equivalent endpoint redelivery must not resurface a joined offer: \(address)")
            let after = await server.requests.count
            XCTAssertEqual(after, count)
        }
    }

    func testSamePairingIdentityOnDifferentEndpointRemainsExplicitOfferedSetup() async {
        let server = Server()
        let model = model(SetupStore(paired()), server)
        await model.wake()
        let incoming = WatchPairingEnvelope(endpoint: "https://other.example.com", offer: envelope().offer)
        await model.receive(incoming)
        XCTAssertEqual(model.offeredSetup, incoming)
        await model.refresh()
        XCTAssertEqual(model.offeredSetup, incoming, "Refreshing the old setup cannot dismiss another server's offer")
    }

    func testTapDuringPassivePollIsReservedAndSubmittedExactlyOnce() async {
        for owner in [phone, device] {
            let server = Server(owner: owner)
            var haptics = 0
            let model = model(SetupStore(paired()), server, haptic: { haptics += 1 })
            await model.wake(); await server.hold(game)
            let polling = Task { await model.poll() }
            await server.waitForHold()
            XCTAssertFalse(model.busy)
            XCTAssertTrue(owner == phone ? model.canTakeOver : model.canScore)
            let action: MatchOperation = owner == phone ? .takeOver : .awardPoint(side: .home)
            var sent = false
            let tapping = Task { await model.send(action); sent = true }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(model.busy)
            XCTAssertFalse(sent, "An admitted tap waits for the canceled poll to finish")
            await model.send(.awardPoint(side: .away)) // A second tap cannot queue.
            let before = await server.requests.filter { $0.httpMethod == "POST" }
            XCTAssertTrue(before.isEmpty)
            await server.release(); await polling.value; await tapping.value
            let posts = await server.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(haptics, 1)
            XCTAssertEqual(model.snapshot?.score.away, 0)
            XCTAssertTrue(model.canScore)
            let wasCancelled = await server.lastHeldRequestWasCancelled
            XCTAssertTrue(wasCancelled)
        }
    }

    func testSuspendCancelsReservedTapAndJoinsPassivePollBeforeReturning() async {
        let server = Server(owner: device)
        let model = model(SetupStore(paired()), server)
        await model.wake(); await server.hold(game)
        let polling = Task { await model.poll() }
        await server.waitForHold()
        let tapping = Task { await model.send(.awardPoint(side: .home)) }
        for _ in 0..<10 { await Task.yield() }
        var suspended = false
        let stopping = Task { await model.suspend(); suspended = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(suspended)
        await server.release(); await stopping.value; await polling.value; await tapping.value
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.isActive)
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        await model.wake()
        XCTAssertEqual(model.snapshot?.score.home, 0)
    }

    func testReservedTapRechecksNewScorerAfterPassivePollJoins() async {
        let server = Server(owner: device)
        let model = model(SetupStore(paired()), server)
        await model.wake(); await server.hold(game)
        let polling = Task { await model.poll() }
        await server.waitForHold()
        let tapping = Task { await model.send(.awardPoint(side: .home)) }
        for _ in 0..<10 { await Task.yield() }
        await server.setRevision(1, owner: phone)
        await server.release(); await polling.value; await tapping.value
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        XCTAssertFalse(model.canScore)
        XCTAssertTrue(model.canTakeOver)
        XCTAssertNotNil(model.message)
    }

    func testPassivePollNeverRecoversPendingCommandOrAdmitsAnotherAction() async throws {
        let outbox = Outbox(), server = Server(owner: device)
        let model = model(SetupStore(paired()), server, outbox: outbox)
        await model.wake(); await server.setLoseCommand()
        await model.send(.awardPoint(side: .home))
        let pending = try XCTUnwrap(outbox.load())
        let count = await server.requests.count
        await model.poll()
        await model.send(.awardPoint(side: .away))
        XCTAssertEqual(try outbox.load(), pending)
        XCTAssertTrue(model.pending)
        let after = await server.requests.count
        XCTAssertEqual(after, count)
        await model.refresh()
        XCTAssertFalse(model.pending)
        XCTAssertEqual(model.snapshot?.score.home, 1)
    }

    func testPassivePollStillExclusivelyOwnsSetupRecoveryAndOutboxLifecycle() async throws {
        let server = Server(owner: device), store = SetupStore(paired())
        let model = model(store, server)
        await model.wake()
        let incoming = envelope("10000000-0000-4000-8000-000000000002",
            pairingId: "40000000-0000-4000-8000-000000000002")
        await model.receive(incoming)
        await server.hold(game)
        let polling = Task { await model.poll() }
        await server.waitForHold()
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.canReplaceSetup)
        let count = await server.requests.count
        await model.acceptOfferedSetup(replacingCurrent: true)
        await model.refresh()
        await model.wake()
        await model.discardExpiredScoring()
        await model.discardExpiredPairing()
        await model.poll()
        let after = await server.requests.count
        XCTAssertEqual(after, count)
        XCTAssertEqual(try store.load(), paired())
        XCTAssertEqual(model.offeredSetup, incoming)
        await server.release(); await polling.value
        XCTAssertTrue(model.canReplaceSetup)
    }

    func testTiedSetRejectionIsVisibleWithoutAcceptedHaptic() async {
        let server = Server(owner: device)
        var haptics = 0
        let model = model(SetupStore(paired()), server, haptic: { haptics += 1 })
        await model.wake(); await server.setRejectTiedSet()
        await model.send(.endSet(winner: nil, overrideReason: nil))
        XCTAssertFalse(model.pending)
        XCTAssertEqual(model.state?.outcome?.accepted, false)
        XCTAssertTrue(model.message?.localizedCaseInsensitiveContains("tied") == true)
        XCTAssertEqual(haptics, 0)
        await model.refresh()
        XCTAssertTrue(model.message?.localizedCaseInsensitiveContains("tied") == true)
    }
}

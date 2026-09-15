import Foundation
import ScorebugCore
import XCTest

/// Functional native model integration with injected WC/HTTP callbacks. It does
/// not qualify physical pairing, radio switching or background wake behavior.
@MainActor final class NativeWatchBootstrapTests: XCTestCase {
    func testBootstrapRecoversCommittedLostReplyThenScoresThroughSameNativeRelay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = BootstrapNativeFixture()
        let watchStore = BootstrapNativeWatchStore(url: root.appendingPathComponent("watch-setup.json"))
        let outbox = JSONFilePendingCommandStore(url: root.appendingPathComponent("watch-outbox.json"))
        let phoneStore = BootstrapNativePhoneStore(url: root.appendingPathComponent("phone-setup.json"))
        try phoneStore.save(PhoneWatchSetupRecord(pending: fixture.phonePending))
        phoneStore.saves.removeAll()
        let server = BootstrapNativeHTTP(fixture: fixture, watchStore: watchStore, outbox: outbox)
        let bootstrapForwarder = WatchBootstrapPhoneForwarder(clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { try await server.send($0) })
        })
        let scoringForwarder = WatchRelayPhoneForwarder(clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { try await server.send($0) })
        })
        var authorityErrors = 0, pairedNotices = 0, haptics = 0
        let phone = PhoneWatchModel(storage: phoneStore,
            onRelayBindingChanged: { binding in
                do {
                    if binding != nil {
                        XCTAssertNotNil(try watchStore.load()?.paired, "Watch commit precedes phone binding")
                        XCTAssertNil(try phoneStore.load()?.pending, "Phone transition is already durable")
                    }
                    try scoringForwarder.updateBinding(binding)
                } catch { authorityErrors += 1 }
            }, onBootstrapAuthorityChanged: { authority in
                do { try bootstrapForwarder.updateAuthority(authority) } catch { authorityErrors += 1 }
            }, sendEnvelope: { _ in XCTFail("The phone already saved this offer") })
        phone.restoreRelayAssociation()
        XCTAssertEqual(phone.bootstrapAuthority, fixture.authority)
        XCTAssertNil(phone.relayBinding)

        let link = BootstrapNativeLink(bootstrap: bootstrapForwarder, scoring: scoringForwarder,
            watchStore: watchStore, readHaptics: { haptics })
        let transport = WatchRelayMessageTransport(allowsBootstrap: true, isReachable: { true },
            now: { link.time }, schedule: { delay, fire in link.schedule(delay, fire) },
            send: { data, callback in try link.send(data, callback) })
        let bootstrap = WatchBootstrapRelayClient(send: { try await transport.send($0) })
        let routes = WatchRoutedBootstrapClient(direct: { pending in
            let client = MatchHTTPClient(endpoint: try ScoringEndpoint(pending.endpoint),
                transport: { try await server.offline($0) })
            return try await client.redeemWatchPairing(gameId: pending.offer.gameId,
                pairingId: pending.offer.pairingId, pairingToken: pending.offer.pairingToken,
                recoveryKey: pending.recoveryKey, request: pending.request)
        }, companion: { try await bootstrap.redeem($0) }, companionAvailable: { true })
        let setup = WatchSetupCoordinator(storage: watchStore, scoringOutbox: outbox,
            redemption: { try await routes.redeem($0) }, newDeviceId: { fixture.device },
            newRedemptionId: { fixture.redemption }, newRecoveryKey: { fixture.recoveryKey })
        let watch = WatchScoringModel(setupCoordinator: setup, pendingStore: outbox,
            scoringClientFactory: { paired in
                XCTAssertEqual(paired.credential, fixture.credential)
                let companion = WatchRelayScoringClient(scope: fixture.authority.scope,
                    send: { try await transport.send($0) })
                let direct = MatchHTTPClient(endpoint: try ScoringEndpoint(paired.endpoint),
                    transport: { try await server.offline($0) })
                return WatchRoutedScoringClient(direct: direct, companion: companion, companionAvailable: { true })
            }, recoverUncertainSendImmediately: true,
            onNotice: { notice in
                if notice.phase == .paired {
                    pairedNotices += 1
                    do {
                        let committed = try watchStore.load()?.paired?.credential
                        XCTAssertEqual(committed, fixture.credential)
                    }
                    catch { XCTFail("Paired notice must follow committed Watch storage") }
                }
                phone.receive(notice)
            }, acknowledgmentHaptic: {
                do {
                    let durable = try outbox.load()
                    XCTAssertNil(durable, "Haptic follows durable outbox clear")
                }
                catch { XCTFail("Outbox must remain readable after acknowledgment: \(error)") }
                haptics += 1
            })
        await watch.wake()
        XCTAssertEqual(watch.phase, .unpaired)
        await watch.receive(WatchPairingEnvelope(endpoint: fixture.authority.scope.endpoint, offer: fixture.offer))
        XCTAssertNotNil(watch.offeredSetup)
        XCTAssertNil(try watchStore.load()?.pending, "Receiving an offer does not accept it")
        await watch.acceptOfferedSetup()
        let original = try XCTUnwrap(watchStore.load()?.pending)
        XCTAssertEqual(original, fixture.watchPending)
        try assertStillPending(watch, phone, watchStore, fixture, haptics)
        var evidence = await server.evidence()
        XCTAssertEqual(evidence.offlineBootstrap, [original.request])
        XCTAssertTrue(evidence.bootstrap.isEmpty)

        // Attempt two commits through companion, but its credential reply is lost.
        await watch.refresh()
        try assertStillPending(watch, phone, watchStore, fixture, haptics)
        XCTAssertEqual(link.lostReplies, 1)
        XCTAssertEqual(link.pendingAtLoss, original)
        XCTAssertEqual(link.hapticsAtLoss, 0)
        evidence = await server.evidence()
        XCTAssertEqual(evidence.bootstrap, [original])
        XCTAssertEqual(evidence.credentialMints, 1)
        XCTAssertEqual(pairedNotices, 0)

        // Route selection changes only between coordinator attempts. Attempt
        // three finds direct still unavailable; attempt four recovers companion.
        await server.advancePastExpiry()
        await watch.refresh()
        try assertStillPending(watch, phone, watchStore, fixture, haptics)
        evidence = await server.evidence()
        XCTAssertEqual(evidence.offlineBootstrap, [original.request, original.request])
        XCTAssertEqual(evidence.bootstrap, [original])
        await watch.refresh()
        XCTAssertEqual(watch.phase, .paired)
        XCTAssertEqual(try watchStore.load()?.paired?.credential, fixture.credential)
        XCTAssertNil(try watchStore.load()?.pending)
        XCTAssertEqual(pairedNotices, 1)
        XCTAssertNil(phone.bootstrapAuthority)
        XCTAssertEqual(phone.relayBinding, fixture.authority.scope)
        XCTAssertNil(phone.pending)
        XCTAssertEqual(phoneStore.saves, [PhoneWatchSetupRecord(relayBinding: fixture.authority.scope)])
        let phoneBytes = try Data(contentsOf: phoneStore.url)
        XCTAssertFalse(String(decoding: phoneBytes, as: UTF8.self).contains(fixture.installationToken))
        XCTAssertFalse(String(decoding: phoneBytes, as: UTF8.self).contains(fixture.recoveryKey))
        XCTAssertFalse(String(decoding: phoneBytes, as: UTF8.self).contains(fixture.credential.token))
        XCTAssertTrue(watch.canTakeOver)
        XCTAssertEqual(haptics, 0)
        evidence = await server.evidence()
        XCTAssertEqual(evidence.bootstrap, [original, original])
        XCTAssertEqual(evidence.credentialMints, 1)
        XCTAssertEqual(evidence.bootstrapResponseTimes, [fixture.initialTime, fixture.afterExpiry])

        await watch.send(.takeOver)
        XCTAssertTrue(watch.canScore)
        await watch.send(.awardPoint(side: .home))
        XCTAssertEqual(watch.snapshot?.score.home, 1)
        XCTAssertEqual(watch.snapshot?.scorer.deviceId, fixture.device)
        XCTAssertFalse(watch.pending)
        XCTAssertNil(try outbox.load())
        XCTAssertEqual(haptics, 2)
        evidence = await server.evidence()
        XCTAssertEqual(evidence.commands.map(\.operation), [.takeOver, .awardPoint(side: .home)])
        XCTAssertEqual(evidence.commands, evidence.durableCommands)
        XCTAssertEqual(Set(evidence.commands.map(\.commandId)).count, 2)
        XCTAssertEqual(Set(evidence.scoringTokens), Set([fixture.credential.token]))
        XCTAssertTrue(evidence.http.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") != "Bearer \(fixture.installationToken)"
        })
        XCTAssertTrue(evidence.bootstrapHTTP.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.offer.pairingToken)" &&
            $0.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery") == original.recoveryKey &&
            (try? JSONDecoder().decode(WatchPairingRedeemRequest.self, from: $0.httpBody ?? Data())) == original.request
        })
        XCTAssertEqual(link.kinds.filter { $0 == "bootstrap" }.count, 2)
        XCTAssertTrue(link.kinds.contains("scoring"))
        XCTAssertEqual(link.maximumActive, 1)
        XCTAssertEqual(authorityErrors, 0)
        await watch.suspend()
    }

    private func assertStillPending(_ watch: WatchScoringModel, _ phone: PhoneWatchModel,
                                    _ store: BootstrapNativeWatchStore, _ fixture: BootstrapNativeFixture,
                                    _ haptics: Int) throws {
        XCTAssertEqual(watch.phase, .pending)
        XCTAssertEqual(try store.load()?.pending, fixture.watchPending)
        XCTAssertNil(try store.load()?.paired)
        XCTAssertNil(phone.relayBinding)
        XCTAssertEqual(phone.bootstrapAuthority, fixture.authority)
        XCTAssertEqual(phone.pending, fixture.phonePending)
        XCTAssertEqual(haptics, 0)
    }
}

private struct BootstrapNativeFixture: Sendable {
    let device = "20000000-0000-4000-8000-000000000002"
    let pairing = "40000000-0000-4000-8000-000000000004"
    let redemption = "50000000-0000-4000-8000-000000000005"
    let recoveryKey = String(repeating: "B", count: 42) + "A"
    let installationToken = "fixture-phone-installation-secret"
    let initialTime = "2026-09-15T10:00:00.000Z"
    let afterExpiry = "2026-09-15T12:00:00.000Z"
    var credential: MatchCredential {
        MatchCredential(gameId: "bootstrap-native", deviceId: device, role: .score,
            token: String(repeating: "C", count: 42) + "A")
    }
    var offer: WatchPairingIssued {
        WatchPairingIssued(pairingId: pairing, gameId: credential.gameId, watchDeviceId: device,
            pairingToken: String(repeating: "A", count: 43), expiresAt: "2026-09-15T10:05:00.000Z", serverTime: initialTime)
    }
    var authority: WatchBootstrapAuthority {
        WatchBootstrapAuthority(scope: WatchRelayScope(endpoint: "https://bootstrap.example/control",
            gameId: credential.gameId, watchDeviceId: device, pairingId: pairing), pairingToken: offer.pairingToken)
    }
    var watchPending: PendingWatchPairing {
        PendingWatchPairing(endpoint: authority.scope.endpoint, offer: offer,
            request: WatchPairingRedeemRequest(redemptionId: redemption, deviceId: device), recoveryKey: recoveryKey)
    }
    var phonePending: PhoneWatchRequest {
        PhoneWatchRequest(connection: PhoneWatchConnection(label: "Saved phone server", endpoint: authority.scope.endpoint,
            installationToken: installationToken), gameId: credential.gameId,
            request: WatchPairingIssueRequest(pairingId: pairing, watchDeviceId: device), offer: offer)
    }
}

private struct BootstrapNativeWatchStore: WatchSetupStorage {
    let url: URL
    func load() throws -> WatchSetupRecord? {
        do { return try JSONDecoder().decode(WatchSetupRecord.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ record: WatchSetupRecord) throws { try JSONEncoder().encode(record).write(to: url, options: .atomic) }
}
private final class BootstrapNativePhoneStore: PhoneWatchRequestStorage {
    let url: URL
    var saves: [PhoneWatchSetupRecord] = []
    init(url: URL) { self.url = url }
    func load() throws -> PhoneWatchSetupRecord? {
        do { return try JSONDecoder().decode(PhoneWatchSetupRecord.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ record: PhoneWatchSetupRecord) throws {
        try JSONEncoder().encode(record).write(to: url, options: .atomic); saves.append(record)
    }
}
@MainActor private final class BootstrapNativeLink {
    let bootstrap: WatchBootstrapPhoneForwarder
    let scoring: WatchRelayPhoneForwarder
    let watchStore: BootstrapNativeWatchStore
    let readHaptics: () -> Int
    let gate = WatchRelaySessionGate()
    var time: TimeInterval = 100
    var timer: (UUID, TimeInterval, @MainActor @Sendable () -> Void)?
    var lostReplies = 0, maximumActive = 0, active = 0
    var kinds: [String] = []
    var pendingAtLoss: PendingWatchPairing?
    var hapticsAtLoss: Int?
    init(bootstrap: WatchBootstrapPhoneForwarder, scoring: WatchRelayPhoneForwarder,
         watchStore: BootstrapNativeWatchStore, readHaptics: @escaping () -> Int) {
        self.bootstrap = bootstrap; self.scoring = scoring; self.watchStore = watchStore; self.readHaptics = readHaptics
    }
    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> WatchRelayMessageTransport.ScheduledCancellation {
        let id = UUID(); timer = (id, time + delay, fire)
        return { [weak self] in if self?.timer?.0 == id { self?.timer = nil } }
    }
    func send(_ data: Data, _ callback: @escaping WatchRelayMessageTransport.Callback) throws {
        let request = try WatchRelayInboundRequest(validating: data)
        guard let token = gate.admit() else { throw WatchRelayFailure.busy }
        let once = WatchRelayReplyOnce { callback(.success($0)) }
        active += 1; maximumActive = max(maximumActive, active)
        Task { @MainActor in
            let response: Data
            switch request {
            case .scoring: kinds.append("scoring"); response = await scoring.forward(data)
            case .bootstrap: kinds.append("bootstrap"); response = await bootstrap.forward(data)
            }
            let current = gate.isCurrent(token)
            gate.release(token); active -= 1
            guard current else { once.send(request.failureReply(.cancelled)); return }
            if case .bootstrap(let bootstrapRequest) = request, lostReplies == 0 {
                do {
                    guard case .redeemed = try WatchBootstrapCodec.decodeReply(response, for: bootstrapRequest).result else {
                        throw BootstrapNativeError.unexpected
                    }
                    pendingAtLoss = try watchStore.load()?.pending
                    hapticsAtLoss = readHaptics(); lostReplies += 1
                    let deadline = try XCTUnwrap(timer)
                    time = deadline.1; deadline.2()
                } catch { XCTFail("Expected a committed bootstrap reply before loss: \(error)"); once.send(response) }
            } else { once.send(response) }
        }
    }
}
private enum BootstrapNativeError: Error { case unexpected }
private actor BootstrapNativeHTTP {
    struct Evidence {
        let offlineBootstrap: [WatchPairingRedeemRequest]
        let bootstrap: [PendingWatchPairing]
        let bootstrapHTTP: [URLRequest]
        let bootstrapResponseTimes: [String]
        let credentialMints: Int
        let commands: [MatchCommand]
        let durableCommands: [MatchCommand]
        let scoringTokens: [String]
        let http: [URLRequest]
    }
    let fixture: BootstrapNativeFixture
    let watchStore: BootstrapNativeWatchStore
    let outbox: JSONFilePendingCommandStore
    private var now: String
    private var committed: PendingWatchPairing?
    private var offlineBootstrap: [WatchPairingRedeemRequest] = []
    private var bootstrap: [PendingWatchPairing] = [], bootstrapHTTP: [URLRequest] = [], http: [URLRequest] = []
    private var bootstrapResponseTimes: [String] = [], scoringTokens: [String] = []
    private var credentialMints = 0
    private var commands: [MatchCommand] = [], durableCommands: [MatchCommand] = []
    private var snapshot: MatchSnapshot
    init(fixture: BootstrapNativeFixture, watchStore: BootstrapNativeWatchStore, outbox: JSONFilePendingCommandStore) {
        self.fixture = fixture; self.watchStore = watchStore; self.outbox = outbox; now = fixture.initialTime
        let team = MatchTeam(name: "Home", shortName: "HOM", color: "#112233")
        snapshot = MatchSnapshot(id: fixture.credential.gameId, createdAt: fixture.initialTime, revision: 0,
            teams: MatchTeams(home: team, away: team), rules: MatchRules(bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil),
            score: MatchScore(home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0), completedSets: [], status: .active,
            endReason: nil, canUndo: false, scorer: MatchScorer(deviceId: "another-phone", epoch: 1),
            broadcast: MatchBroadcast(desired: .stopped, generation: 0))
    }
    func advancePastExpiry() { now = fixture.afterExpiry }
    func evidence() -> Evidence {
        Evidence(offlineBootstrap: offlineBootstrap, bootstrap: bootstrap, bootstrapHTTP: bootstrapHTTP,
            bootstrapResponseTimes: bootstrapResponseTimes, credentialMints: credentialMints,
            commands: commands, durableCommands: durableCommands, scoringTokens: scoringTokens, http: http)
    }
    func offline(_ request: URLRequest) throws -> (Data, URLResponse) {
        http.append(request)
        if request.url?.path.hasSuffix("/redeem") == true {
            let durable = try XCTUnwrap(watchStore.load()?.pending)
            let redemption = try JSONDecoder().decode(WatchPairingRedeemRequest.self, from: XCTUnwrap(request.httpBody))
            guard redemption == durable.request else { throw BootstrapNativeError.unexpected }
            offlineBootstrap.append(redemption); bootstrapHTTP.append(request)
        }
        throw URLError(.notConnectedToInternet)
    }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        http.append(request)
        let url = try XCTUnwrap(request.url), prefix = "/control/v1/matches/\(fixture.credential.gameId)"
        guard url.scheme == "https", url.host == "bootstrap.example" else { throw BootstrapNativeError.unexpected }
        if url.path == prefix + "/watch-pairings/\(fixture.pairing)/redeem", request.httpMethod == "POST" {
            let durable = try XCTUnwrap(watchStore.load()?.pending)
            let redemption = try JSONDecoder().decode(WatchPairingRedeemRequest.self, from: XCTUnwrap(request.httpBody))
            guard durable == fixture.watchPending, redemption == durable.request,
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer \(durable.offer.pairingToken)",
                  request.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery") == durable.recoveryKey else { throw BootstrapNativeError.unexpected }
            if let committed { guard committed == durable else { throw BootstrapNativeError.unexpected } }
            else { committed = durable; credentialMints += 1 }
            bootstrap.append(durable); bootstrapHTTP.append(request); bootstrapResponseTimes.append(now)
            return try response(WatchPairingRedeemed(pairingId: fixture.pairing, redemptionId: fixture.redemption,
                credential: fixture.credential, snapshot: snapshot, serverTime: now), url: url)
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.credential.token)",
              request.value(forHTTPHeaderField: "X-Scorebug-Pairing-Recovery") == nil else { throw BootstrapNativeError.unexpected }
        scoringTokens.append(fixture.credential.token)
        if url.path == prefix, request.httpMethod == "GET" {
            return try response(MatchSnapshotResponse(snapshot: snapshot, serverTime: now), url: url)
        }
        if url.path == prefix + "/commands", request.httpMethod == "POST" {
            let command = try JSONDecoder().decode(MatchCommand.self, from: XCTUnwrap(request.httpBody))
            let durable = try XCTUnwrap(outbox.load()?.command)
            guard command == durable, command.deviceId == fixture.device, command.gameId == snapshot.id,
                  command.expectedRevision == snapshot.revision, command.scorerEpoch == snapshot.scorer.epoch,
                  !commands.contains(where: { $0.commandId == command.commandId }) else { throw BootstrapNativeError.unexpected }
            commands.append(command); durableCommands.append(durable)
            switch command.operation {
            case .takeOver: snapshot.scorer = MatchScorer(deviceId: fixture.device, epoch: snapshot.scorer.epoch + 1)
            case .awardPoint(let side):
                guard snapshot.scorer.deviceId == fixture.device, side == .home else { throw BootstrapNativeError.unexpected }
                snapshot.score.home += 1
            default: throw BootstrapNativeError.unexpected
            }
            snapshot.revision += 1
            return try response(CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot), url: url)
        }
        throw BootstrapNativeError.unexpected
    }
    private func response<Value: Encodable>(_ value: Value, url: URL) throws -> (Data, URLResponse) {
        (try JSONEncoder().encode(value), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

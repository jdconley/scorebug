import Foundation
import ScorebugCore
import XCTest

@MainActor
final class ScoringModelTests: XCTestCase {
    func testPreviouslyRejectedOutcomeCannotOverwriteNewerActionNotSentFeedback() async {
        let server = ModelServer()
        let model = makeModel(SetupStore(saved(credential: credential)), server: server)
        await model.wake()
        await server.rejectNextCommand()
        await model.send(.endSet(winner: nil, overrideReason: nil))
        XCTAssertEqual(model.message, "A tied set cannot end. Correct the score first.")
        await server.holdNextSnapshot()
        let refresh = Task { await model.refresh() }
        await server.waitUntilHeld()
        await model.send(.endMatch(reason: "Finished"))
        let retryMessage = "An update is in progress. Try the action again when it finishes. Nothing was sent."
        XCTAssertEqual(model.message, retryMessage)
        await server.release()
        await refresh.value
        XCTAssertEqual(model.message, retryMessage)
        let posts = await server.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1, "The end-match attempt must not have been sent")
    }

    func testReceiptRecoveryClearsLostResponseWarningAndDurablePendingAction() async throws {
        let server = ModelServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = JSONFilePendingCommandStore(url: directory.appendingPathComponent("pending.json"))
        let model = makeModel(SetupStore(saved(credential: credential)), server: server, pendingStore: outbox)
        await model.wake()
        await model.send(.awardPoint(side: .home)) // The server applies it, then loses the response.
        let pending = try XCTUnwrap(outbox.load())
        XCTAssertTrue(model.pending)
        XCTAssertFalse(model.canScore)
        XCTAssertEqual(model.message, "Connection interrupted. Your action is saved and will be checked again.")
        let requestCount = await server.requests.count
        await model.refresh()
        XCTAssertNil(try outbox.load())
        XCTAssertFalse(model.pending)
        XCTAssertEqual(model.snapshot?.score.home, 1)
        XCTAssertTrue(model.canScore)
        XCTAssertNil(model.message, "Confirmed recovery must clear the resolved connection warning")
        let recoveryRequests = await server.requests.dropFirst(requestCount)
        XCTAssertEqual(recoveryRequests.map { $0.url!.path }, ["/v1/matches/old-game/commands/\(pending.command.commandId)"])
        let applications = await server.commandApplications
        XCTAssertEqual(applications, 1)
    }

    func testSuccessfulSnapshotRefreshClearsEarlierConnectionWarning() async {
        let server = ModelServer()
        let model = makeModel(SetupStore(saved(credential: credential)), server: server)
        await model.wake()
        await server.failNextSnapshot()
        await model.refresh()
        XCTAssertNotNil(model.message)
        await model.refresh()
        XCTAssertTrue(model.canScore)
        XCTAssertNil(model.message)
    }

    func testFailedInitialStorageReadBlocksChangesAndNextWakeRestoresPendingCreation() async throws {
        let store = SetupStore(saved())
        let server = ModelServer()
        let first = makeModel(store, server: server)
        await first.wake()
        await first.createMatch() // Persist the identity of a committed match whose response was lost.
        let original = try XCTUnwrap(store.load())
        XCTAssertNotNil(original.creation)
        store.failNextLoad = true
        let restarted = makeModel(store, server: server)
        await restarted.wake()
        XCTAssertTrue(restarted.needsStorageRetry)
        XCTAssertFalse(restarted.canChangeSetup)
        restarted.endpoint = "https://different.example.com"
        restarted.installationToken = "different-account"
        let requestCount = await server.requests.count
        let saveCount = store.saveCount
        await restarted.connect()
        XCTAssertEqual(store.saveCount, saveCount, "Unread secure settings must never be replaced")
        let requests = await server.requests
        XCTAssertEqual(requests.count, requestCount)
        await restarted.wake()
        XCTAssertFalse(restarted.needsStorageRetry)
        XCTAssertTrue(restarted.hasPendingCreation)
        XCTAssertEqual(restarted.endpoint, original.endpoint)
        XCTAssertEqual(restarted.installationToken, original.installationToken)
        XCTAssertEqual(try store.load()?.creation, original.creation)
        XCTAssertEqual(try store.load()?.deviceId, original.deviceId)
        XCTAssertFalse(restarted.canChangeSetup)
    }

    func testSendWithoutCoordinatorExplainsThatActionWasNotSent() async {
        let model = makeModel(SetupStore(), server: ModelServer())
        await model.send(.endMatch(reason: "Finished"))
        XCTAssertEqual(model.message, "Connect to a match, then try the action again. Nothing was sent.")
    }

    func testConfirmedActionDuringRefreshGetsRetryFeedbackWithoutSending() async {
        let server = ModelServer()
        let model = makeModel(SetupStore(saved(credential: credential)), server: server)
        await model.wake()
        await server.failNextSnapshot()
        await model.refresh()
        XCTAssertNotNil(model.message)
        await server.holdNextSnapshot()
        let refresh = Task { await model.refresh() }
        await server.waitUntilHeld()
        XCTAssertTrue(model.busy)
        await model.send(.endMatch(reason: "Finished"))
        XCTAssertEqual(model.message, "An update is in progress. Try the action again when it finishes. Nothing was sent.")
        await server.release()
        await refresh.value
        let requests = await server.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(model.message, "An update is in progress. Try the action again when it finishes. Nothing was sent.")
    }

    func testFailedConnectionToDifferentServerOrAccountCannotRestoreOldCredential() async throws {
        for changeEndpoint in [true, false] {
            let store = SetupStore(saved(credential: credential))
            let server = ModelServer()
            let model = makeModel(store, server: server)
            await model.wake()
            model.showSetup()
            if changeEndpoint { model.endpoint = "https://new.example.com" }
            else { model.installationToken = "new-account" }
            await server.failDiscovery()
            await model.connect()
            XCTAssertNil(try store.load()?.credential)
            let requestCount = await server.requests.count
            let restarted = makeModel(store, server: server)
            await restarted.wake()
            XCTAssertFalse(restarted.hasJoinedMatch)
            let requests = await server.requests
            XCTAssertEqual(requests.count, requestCount, "Relaunch must not send a stale scoped credential")
        }
    }

    func testFailedSecureSaveDoesNotSendOrPartiallyReplaceScope() async throws {
        let store = SetupStore(saved(credential: credential))
        let server = ModelServer()
        let model = makeModel(store, server: server)
        await model.wake()
        model.showSetup()
        model.endpoint = "https://new.example.com"
        store.failSave = true
        let count = await server.requests.count
        await model.connect()
        XCTAssertEqual(try store.load()?.endpoint, "https://old.example.com")
        XCTAssertEqual(try store.load()?.credential, credential)
        let requests = await server.requests
        XCTAssertEqual(requests.count, count)
    }

    func testLostCreationThenClientRejectionKeepsExactCreationAcrossRelaunch() async throws {
        for status in [400, 401, 403, 409] {
            let store = SetupStore(saved())
            let server = ModelServer()
            let model = makeModel(store, server: server)
            await model.wake()
            await model.createMatch() // Server commits but its response is lost.
            let original = try XCTUnwrap(store.load()?.creation)
            await server.rejectCreation(status)
            await model.createMatch()
            XCTAssertEqual(try store.load()?.creation, original, "HTTP \(status) cannot disprove the earlier commit")
            let restarted = makeModel(store, server: server)
            await restarted.wake()
            XCTAssertTrue(restarted.hasPendingCreation)
            XCTAssertFalse(restarted.canChangeSetup)
        }
    }

    func testFirstCreationDefinitivelyRejectedAllowsCorrectingSettings() async throws {
        let store = SetupStore(saved())
        let server = ModelServer()
        let model = makeModel(store, server: server)
        await model.wake()
        await server.rejectCreation(400)
        await model.createMatch()
        XCTAssertNil(try store.load()?.creation)
        XCTAssertFalse(model.hasPendingCreation)
        XCTAssertTrue(model.canChangeSetup)
    }

    func testWhitespaceOnlyEndpointEditKeepsMatchingScopedCredential() async throws {
        let store = SetupStore(saved(credential: credential))
        let server = ModelServer()
        let model = makeModel(store, server: server)
        await model.wake()
        model.showSetup()
        model.endpoint = "  https://old.example.com\n"
        await server.failDiscovery()
        await model.connect()
        XCTAssertEqual(try store.load()?.credential, credential)
        XCTAssertEqual(try store.load()?.endpoint, "https://old.example.com")
    }

    func testPendingCreationRepairsTokenAndRecoversOriginalMatch() async throws {
        let store = SetupStore(saved())
        let server = ModelServer()
        let model = makeModel(store, server: server)
        await model.wake()
        await model.createMatch()
        let original = try XCTUnwrap(store.load()?.creation)
        await server.rejectCreation(401)
        await model.createMatch()
        let restarted = makeModel(store, server: server)
        await restarted.wake()
        restarted.installationToken = "repaired-token"
        restarted.homeName = "Must not replace original teams"
        await server.acceptCreation()
        await restarted.createMatch()
        XCTAssertNil(try store.load()?.creation)
        XCTAssertEqual(try store.load()?.installationToken, "repaired-token")
        XCTAssertEqual(restarted.snapshot?.id, original.id)
        let posts = await server.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(try posts.map { try JSONDecoder().decode(MatchCreation.self, from: XCTUnwrap($0.httpBody)) }, [original, original, original])
        XCTAssertEqual(posts.last?.value(forHTTPHeaderField: "Authorization"), "Bearer repaired-token")
        XCTAssertEqual(posts.last?.url?.host, "old.example.com")
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
    }

    func testPendingCreationCannotBeRetriedAgainstEditedEndpoint() async throws {
        let store = SetupStore(saved())
        let server = ModelServer()
        let model = makeModel(store, server: server)
        await model.wake()
        await model.createMatch()
        let original = try XCTUnwrap(store.load()?.creation)
        let count = await server.requests.count
        model.endpoint = "https://new.example.com"
        await model.createMatch()
        let requests = await server.requests
        XCTAssertEqual(requests.count, count)
        XCTAssertEqual(try store.load()?.creation, original)
        XCTAssertEqual(try store.load()?.endpoint, "https://old.example.com")
        XCTAssertEqual(model.message, "Confirm the pending match on its original server before changing the server address.")
    }

    private var credential: MatchCredential {
        MatchCredential(gameId: "old-game", deviceId: "phone", role: .score, token: "old-scoped-secret")
    }
    private func saved(credential: MatchCredential? = nil) -> SavedScoringSetup {
        SavedScoringSetup(endpoint: "https://old.example.com", installationToken: "old-account", deviceId: "phone", credential: credential)
    }
    private func makeModel(_ store: SetupStore, server: ModelServer,
                           pendingStore: any PendingCommandStore = EmptyOutbox()) -> ScoringModel {
        ScoringModel(storage: store, pendingStore: pendingStore, clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { request in try await server.handle(request) })
        })
    }
}

private final class SetupStore: ScoringSetupStorage {
    private var data: Data?
    var failSave = false
    var failNextLoad = false
    private(set) var saveCount = 0
    init(_ value: SavedScoringSetup? = nil) { data = value.map { try! JSONEncoder().encode($0) } }
    func load() throws -> SavedScoringSetup? {
        if failNextLoad { failNextLoad = false; throw NSError(domain: "ScorebugKeychain", code: -1) }
        return try data.map { try JSONDecoder().decode(SavedScoringSetup.self, from: $0) }
    }
    func save(_ setup: SavedScoringSetup) throws {
        saveCount += 1
        if failSave { throw NSError(domain: "ScorebugKeychain", code: -1) }
        data = try JSONEncoder().encode(setup)
    }
}

private struct EmptyOutbox: PendingCommandStore {
    func load() throws -> PendingMatchCommand? { nil }
    func save(_ pending: PendingMatchCommand?) throws { }
}

private actor ModelServer {
    var requests: [URLRequest] = []
    var applications = 0
    var commandApplications = 0
    private var creationStatus: Int?
    private var acceptsCreation = false
    private var discoveryFails = false
    private var holdSnapshot = false
    private var snapshotFails = false
    private var commandReceipt: CommandOutcome?
    private var rejectsNextCommand = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var createdIDs: Set<String> = []
    func rejectCreation(_ status: Int) { creationStatus = status }
    func acceptCreation() { creationStatus = nil; acceptsCreation = true }
    func failDiscovery() { discoveryFails = true }
    func holdNextSnapshot() { holdSnapshot = true }
    func failNextSnapshot() { snapshotFails = true }
    func rejectNextCommand() { rejectsNextCommand = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { held?.resume(); held = nil }
    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if request.url?.lastPathComponent == "active", discoveryFails { throw URLError(.cannotConnectToHost) }
        if request.httpMethod == "POST", request.url?.lastPathComponent == "commands" {
            let command = try JSONDecoder().decode(MatchCommand.self, from: XCTUnwrap(request.httpBody))
            if rejectsNextCommand {
                rejectsNextCommand = false
                let rejected = CommandOutcome(commandId: command.commandId, accepted: false, error: "tied_set", snapshot: snapshot(command.gameId))
                return (try JSONEncoder().encode(rejected), response(request, status: 409))
            }
            var applied = snapshot(command.gameId)
            applied.revision += 1; applied.score.home += 1
            commandApplications += 1
            commandReceipt = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: applied)
            throw URLError(.networkConnectionLost)
        }
        if request.url!.path.contains("/commands/"), let commandReceipt {
            return (try JSONEncoder().encode(commandReceipt), response(request))
        }
        if request.httpMethod == "POST" {
            if let status = creationStatus {
                return (Data(#"{"error":"rejected"}"#.utf8), response(request, status: status))
            }
            let creation = try JSONDecoder().decode(MatchCreation.self, from: XCTUnwrap(request.httpBody))
            if createdIDs.insert(creation.id).inserted { applications += 1 }
            if !acceptsCreation { throw URLError(.networkConnectionLost) }
            let credential = MatchCredential(gameId: creation.id, deviceId: creation.deviceId, role: .score, token: "new-scoped")
            let value = MatchSessionResponse(snapshot: snapshot(creation.id), credential: credential, serverTime: now)
            return (try JSONEncoder().encode(value), response(request))
        }
        if holdSnapshot {
            holdSnapshot = false
            await withCheckedContinuation { continuation in held = continuation; waiter?.resume(); waiter = nil }
        }
        if snapshotFails { snapshotFails = false; throw URLError(.networkConnectionLost) }
        let value = MatchSnapshotResponse(snapshot: snapshot(request.url!.lastPathComponent), serverTime: now)
        return (try JSONEncoder().encode(value), response(request))
    }
    private var now: String { ISO8601DateFormatter().string(from: Date()) }
    private func snapshot(_ id: String) -> MatchSnapshot {
        let team = MatchTeam(name: "Team", shortName: "TEAM", color: "#2563eb")
        return MatchSnapshot(id: id, createdAt: now, revision: 0, teams: MatchTeams(home: team, away: team),
            rules: MatchRules(bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil),
            score: MatchScore(home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0), completedSets: [], status: .active,
            endReason: nil, canUndo: false, scorer: MatchScorer(deviceId: "phone", epoch: 1),
            broadcast: MatchBroadcast(desired: .stopped, generation: 0))
    }
    private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

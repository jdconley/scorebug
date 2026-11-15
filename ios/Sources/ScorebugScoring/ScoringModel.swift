import CryptoKit
import Foundation
import ScorebugCore
import Security
import SwiftUI

struct SavedScoringSetup: Codable {
    var endpoint: String
    var installationToken: String
    var deviceId: String
    var credential: MatchCredential?
    var creation: MatchCreation?
}

// Contains credentials: production uses Keychain only. Saving must atomically
// replace the complete setup, or throw while preserving its previous value.
protocol ScoringSetupStorage {
    func load() throws -> SavedScoringSetup?
    func save(_ setup: SavedScoringSetup) throws
}

private struct ScoringKeychain: ScoringSetupStorage {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "live.scorebug.scoring.setup", kSecAttrAccount as String: "native-scorer"]
    func load() throws -> SavedScoringSetup? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw NSError(domain: "ScorebugKeychain", code: Int(status)) }
        return try JSONDecoder().decode(SavedScoringSetup.self, from: data)
    }
    func save(_ setup: SavedScoringSetup) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(setup),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: "ScorebugKeychain", code: Int(status)) }
    }
}

@MainActor
final class ScoringModel: ObservableObject {
    @Published var endpoint = "http://localhost:18787" {
        didSet { if endpoint != oldValue { invalidateWorkerStatus() } }
    }
    @Published var installationToken = "" {
        didSet { if installationToken != oldValue { invalidateWorkerStatus() } }
    }
    @Published var homeName = "Home"
    @Published var awayName = "Away"
    @Published var bestOf = 3
    @Published var pointsToWin = 25
    @Published var decidingPointsToWin = 15
    @Published var winBy = 2
    @Published var usesCap = false
    @Published var pointCap = 30
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var needsStorageRetry = false
    @Published private(set) var state: MatchCoordinatorState?
    @Published private(set) var message: String?
    private enum MessageSource { case action, recovery }
    private var messageSource: MessageSource = .action
    private var setup: SavedScoringSetup?
    var watchSetupConnection: (endpoint: String, installationToken: String)? {
        // The Watch tab can discover the committed connection before Score wakes.
        // Reading it must not activate scoring, recover its outbox, or use form edits.
        guard !needsStorageRetry, let saved = setup ?? (try? keychain.load()),
              let endpoint = try? ScoringEndpoint(saved.endpoint),
              !saved.installationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (endpoint.url.absoluteString, saved.installationToken)
    }
    private var coordinator: MatchCommandCoordinator? {
        didSet { describedOutcomeId = nil; invalidateWorkerStatus() }
    }
    struct WorkerStatusIdentity: Equatable {
        let epoch: UUID
        let endpoint: String
        let credential: MatchCredential
        let generation: Int
    }
    private struct WorkerStatusValue {
        let identity: WorkerStatusIdentity
        let response: WorkerMediaStatusResponse?
        let freshness: WorkerStatusFreshness?
    }
    private var workerStatusEpoch = UUID()
    @Published private var workerStatus: WorkerStatusValue?
    private var describedOutcomeId: String?
    // A point can join this one bounded refresh, but never cancels or replaces it.
    private var refreshTask: Task<Bool, Never>?
    private var pointReserved = false
    private struct PointContext: Equatable {
        let connection: WorkerStatusIdentity
        let matchId: String
        let revision: Int
        let scorer: MatchScorer
    }
    private var didRestore = false
    private let keychain: any ScoringSetupStorage
    private let pendingStore: any PendingCommandStore
    private let clientFactory: (ScoringEndpoint) -> MatchHTTPClient

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scorebug", isDirectory: true)
        self.init(storage: ScoringKeychain(),
                  pendingStore: JSONFilePendingCommandStore(url: directory.appendingPathComponent("pending-command.json")))
    }
    init(storage: any ScoringSetupStorage, pendingStore: any PendingCommandStore,
         clientFactory: @escaping (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) }) {
        self.keychain = storage
        self.pendingStore = pendingStore
        self.clientFactory = clientFactory
    }
    var snapshot: MatchSnapshot? { state?.snapshot }
    var hasJoinedMatch: Bool { setup?.credential != nil }
    private var unresolvedStorage: Bool {
        do { return try pendingStore.load() != nil } catch { return true }
    }
    var hasPendingCreation: Bool { setup?.creation != nil }
    var pending: Bool { state?.pending != nil }
    var ownsScoring: Bool { snapshot?.scorer.deviceId == setup?.deviceId }
    var canScore: Bool { !busy && !pending && ownsScoring && snapshot?.status == .active }
    private var pointContext: PointContext? {
        guard coordinator != nil, !pending, !unresolvedStorage, ownsScoring,
              let snapshot, snapshot.status == .active,
              let connection = workerStatusIdentity else { return nil }
        return PointContext(connection: connection, matchId: snapshot.id,
                            revision: snapshot.revision, scorer: snapshot.scorer)
    }
    var canAwardPoint: Bool {
        !pointReserved && (!busy || refreshTask != nil) && pointContext != nil
    }
    var canChangeSetup: Bool {
        guard didRestore, !busy, !pending, !hasPendingCreation else { return false }
        do { return try pendingStore.load() == nil } catch { return false }
    }
    private func persist(_ value: SavedScoringSetup) throws {
        try keychain.save(value)
        setup = value
    }
    private func client(_ value: SavedScoringSetup) throws -> MatchHTTPClient {
        clientFactory(try ScoringEndpoint(value.endpoint))
    }
    private func install(_ response: MatchSessionResponse, setup original: SavedScoringSetup) async throws {
        var value = original
        value.credential = response.credential
        value.creation = nil
        try persist(value)
        try await resume(value)
    }
    private func resume(_ value: SavedScoringSetup) async throws {
        guard let credential = value.credential else { return }
        let account = SHA256.hash(data: Data(value.installationToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let scope = "\(try ScoringEndpoint(value.endpoint).url.absoluteString)|\(account)"
        coordinator = MatchCommandCoordinator(client: try client(value), credential: credential, endpointScope: scope, store: pendingStore)
        connected = true
        state = try await coordinator?.recover()
        describeOutcome()
    }
    func wake() async {
        if didRestore { await refresh(); return }
        busy = true
        defer { busy = false }
        do {
            setup = try keychain.load()
            didRestore = true
            needsStorageRetry = false
            showMessage(nil)
            if let setup {
                endpoint = setup.endpoint; installationToken = setup.installationToken
                if let creation = setup.creation {
                    homeName = creation.teams.home.name; awayName = creation.teams.away.name
                    bestOf = creation.rules.bestOf; pointsToWin = creation.rules.pointsToWin
                    decidingPointsToWin = creation.rules.decidingPointsToWin; winBy = creation.rules.winBy
                    usesCap = creation.rules.pointCap != nil; pointCap = creation.rules.pointCap ?? 30
                    connected = true
                    showMessage("Match creation needs confirmation. Retry uses the same match ID.")
                } else { try await resume(setup) }
            } else {
                #if DEBUG
                let env = ProcessInfo.processInfo.environment
                if let url = env["SCOREBUG_TEST_API_URL"], url.hasPrefix("http://127.0.0.1:"),
                   let token = env["SCOREBUG_TEST_TOKEN"] {
                    endpoint = url; installationToken = token
                }
                #endif
            }
        } catch {
            needsStorageRetry = !didRestore
            await report(error)
        }
    }
    func connect() async {
        guard canChangeSetup else { return }
        busy = true; showMessage(nil)
        defer { busy = false }
        do {
            let endpoint = try ScoringEndpoint(endpoint).url.absoluteString
            guard !installationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showMessage("Enter the installation access token."); return
            }
            var value = setup ?? SavedScoringSetup(endpoint: endpoint, installationToken: installationToken, deviceId: UUID().uuidString)
            let changedScope = try ScoringEndpoint(value.endpoint).url.absoluteString != endpoint
                || value.installationToken != installationToken
            value.endpoint = endpoint; value.installationToken = installationToken
            if changedScope { value.credential = nil }
            try persist(value)
            if changedScope { coordinator = nil; state = nil; connected = false }
            let api = try client(value)
            if let creation = value.creation {
                let response = try await api.create(id: creation.id, deviceId: creation.deviceId, teams: creation.teams,
                                                    rules: creation.rules, installationToken: value.installationToken)
                try await install(response, setup: value)
            } else if let active = try await api.active(installationToken: value.installationToken).snapshot {
                let response = try await api.join(gameId: active.id, deviceId: value.deviceId, role: .score, installationToken: value.installationToken)
                try await install(response, setup: value)
            } else {
                value.credential = nil; try persist(value)
                coordinator = nil; state = nil; connected = true
            }
        } catch { await report(error) }
    }
    func createMatch() async {
        guard !busy, let original = setup, !pending, !unresolvedStorage else { return }
        busy = true; showMessage(nil)
        defer { busy = false }
        do {
            var value = original
            if original.creation != nil {
                guard try ScoringEndpoint(endpoint) == ScoringEndpoint(original.endpoint) else {
                    showMessage("Confirm the pending match on its original server before changing the server address.")
                    return
                }
                guard !installationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    showMessage("Enter the installation access token."); return
                }
                // Credential repair must retain the original server, ID, teams, and rules.
                if value.installationToken != installationToken { value.credential = nil }
                value.installationToken = installationToken
            }
            let creation = value.creation ?? MatchCreation(id: UUID().uuidString, deviceId: value.deviceId,
                teams: MatchTeams(home: MatchTeam(name: homeName, shortName: String(homeName.prefix(4)).uppercased(), color: "#2563eb"),
                                  away: MatchTeam(name: awayName, shortName: String(awayName.prefix(4)).uppercased(), color: "#dc2626")),
                rules: MatchRules(bestOf: bestOf, pointsToWin: pointsToWin, decidingPointsToWin: decidingPointsToWin,
                                  winBy: winBy, pointCap: usesCap ? pointCap : nil))
            value.creation = creation
            try persist(value) // Record identity before POST, including uncertain creation replies.
            if value.installationToken != original.installationToken { coordinator = nil; state = nil }
            let response = try await client(value).create(id: creation.id, deviceId: creation.deviceId, teams: creation.teams,
                                                          rules: creation.rules, installationToken: value.installationToken)
            try await install(response, setup: value)
        } catch {
            if let clientError = error as? MatchClientError {
                let rejected: Bool
                switch clientError {
                case .unauthorized, .forbidden: rejected = true
                case .http(let status, _): rejected = (400..<500).contains(status)
                default: rejected = false
                }
                // A rejection of the first attempt proves it was not created. A
                // retry's rejection says nothing about an earlier lost response.
                if rejected, original.creation == nil, var value = setup {
                    value.creation = nil
                    do { try persist(value) } catch { await report(error); return }
                }
            }
            await report(error)
        }
    }
    func send(_ operation: MatchOperation) async {
        guard !busy else {
            showMessage("An update is in progress. Try the action again when it finishes. Nothing was sent.")
            return
        }
        guard let coordinator else {
            showMessage("Connect to a match, then try the action again. Nothing was sent.")
            return
        }
        busy = true; showMessage(nil)
        defer { busy = false }
        do { state = try await coordinator.submit(operation); describeOutcome() }
        catch { await report(error) }
    }
    func sendPoint(side: MatchSide) async {
        guard canAwardPoint, let coordinator, let context = pointContext, !Task.isCancelled else {
            showMessage("The point could not be sent. Check the score and try again. Nothing was sent.")
            return
        }
        // Reserve before suspension. Refresh completion must retain busy ownership
        // until this point either submits through the durable outbox or declines.
        pointReserved = true
        busy = true
        showMessage(nil)
        defer { pointReserved = false; busy = refreshTask != nil }
        let refreshed = await refreshTask?.value ?? true
        guard refreshed, !Task.isCancelled, self.coordinator === coordinator,
              pointContext == context else {
            showMessage("The score or connection changed, or the update did not finish. Check the score and try again. Nothing was sent.")
            return
        }
        do { state = try await coordinator.submit(.awardPoint(side: side)); describeOutcome() }
        catch { await report(error) }
    }
    func refresh() async {
        guard !busy, let coordinator else { return }
        busy = true
        let task = Task { @MainActor in
            defer { refreshTask = nil; busy = pointReserved }
            do {
                state = try await coordinator.recover()
                describeOutcome()
                return true
            } catch {
                await report(error)
                return false
            }
        }
        refreshTask = task
        _ = await task.value
    }
    private func invalidateWorkerStatus() {
        workerStatusEpoch = UUID()
        workerStatus = nil
    }

    var workerStatusIdentity: WorkerStatusIdentity? {
        guard connected, let setup, let credential = setup.credential, let snapshot,
              snapshot.id == credential.gameId,
              installationToken == setup.installationToken,
              let endpoint = try? ScoringEndpoint(endpoint),
              endpoint == (try? ScoringEndpoint(setup.endpoint)) else { return nil }
        return WorkerStatusIdentity(epoch: workerStatusEpoch, endpoint: endpoint.url.absoluteString,
                                    credential: credential, generation: snapshot.broadcast.generation)
    }

    /// This request never acquires the scoring busy flag or calls the coordinator.
    func refreshWorkerStatus() async {
        guard let identity = workerStatusIdentity, let setup, snapshot?.broadcast.desired == .running else { return }
        let startedAt = ContinuousClock.now
        do {
            let response = try await client(setup).workerStatus(credential: identity.credential)
            let receivedAt = ContinuousClock.now
            guard !Task.isCancelled, identity == workerStatusIdentity,
                  response.status.gameId == identity.credential.gameId,
                  response.status.generation == identity.generation else { return }
            if let observation = response.status.observation {
                guard observation.gameId == identity.credential.gameId,
                      observation.generation == identity.generation else { return }
            }
            workerStatus = WorkerStatusValue(identity: identity, response: response,
                freshness: WorkerStatusFreshness(response: response, receivedAt: receivedAt,
                                                  requestDuration: startedAt.duration(to: receivedAt)))
        } catch {
            guard !Task.isCancelled, identity == workerStatusIdentity else { return }
            workerStatus = WorkerStatusValue(identity: identity, response: nil, freshness: nil)
        }
    }

    func broadcastStatusText(at instant: ContinuousClock.Instant = .now) -> String {
        // The authoritative request can stop independently of delayed telemetry.
        if snapshot?.broadcast.desired == .stopped { return "Broadcast not requested" }
        guard let identity = workerStatusIdentity, let value = workerStatus,
              value.identity == identity else { return "Waiting for worker status" }
        guard let response = value.response else { return "Worker status unavailable" }
        switch response.status.state {
        case .notRequested: return "Broadcast not requested"
        case .unknown: return "Waiting for worker status"
        case .stale: return "Worker status unavailable"
        default:
            guard value.freshness?.isFresh(at: instant) == true else { return "Worker status unavailable" }
        }
        switch response.status.state {
        case .idle: return "Worker idle"
        case .waitingSource: return "Worker waiting for video source"
        case .starting: return "Worker starting"
        case .producingOutput: return "Worker encoding video"
        case .stopping: return "Worker stopping"
        case .retrying: return "Worker retrying"
        case .failed: return "Worker failed"
        case .closed: return "Worker closed"
        case .notRequested, .unknown, .stale: return "Worker status unavailable"
        }
    }

    func discardExpired() async {
        guard !busy, let coordinator else { return }
        busy = true
        defer { busy = false }
        do { state = try await coordinator.discardExpired(); showMessage("Pending action reconciled. Check the score before continuing.") }
        catch { await report(error) }
    }
    func newMatch() {
        guard canChangeSetup, var value = setup else { return }
        do {
            value.credential = nil; value.creation = nil; try persist(value)
            coordinator = nil; state = nil; showMessage(nil)
        } catch { showMessage("Could not save match settings. Try again.") }
    }
    func showSetup() {
        guard canChangeSetup else { return }
        connected = false; coordinator = nil; state = nil
    }
    private func showMessage(_ text: String?, source: MessageSource = .action) {
        message = text
        messageSource = source
    }
    private func describeOutcome() {
        // Recovery retains the last receipt. Present it once, so polling an old
        // rejection cannot overwrite feedback about a more recent user action.
        if let outcome = state?.outcome, outcome.commandId != describedOutcomeId {
            describedOutcomeId = outcome.commandId
            if let error = outcome.error { showMessage(Self.explain(error)); return }
        }
        if state?.status == .reconciliationRequired { showMessage("The pending action needs review. The score or connection changed.", source: .recovery) }
        else if messageSource == .recovery { showMessage(nil) }
    }
    private func report(_ error: Error) async {
        if let coordinator { state = await coordinator.state() }
        if (error as NSError).domain == "ScorebugKeychain" {
            showMessage("Secure settings storage is unavailable (\((error as NSError).code)). Try again after unlocking the device.", source: .recovery)
            return
        }
        let detail: String
        switch error {
        case MatchClientError.unauthorized: detail = "Server access was rejected. Check the installation token."
        case MatchClientError.forbidden: detail = "This device does not have permission for that action."
        case MatchCoordinatorError.storageFailure: detail = "Could not save scoring data. The action remains unresolved; retry when storage is available."
        case MatchCoordinatorError.scopeMismatch: detail = "A pending action belongs to different server settings. Restore those settings before continuing."
        case MatchCoordinatorError.notExpired: detail = "That action may still arrive. Wait before reconciling it."
        case MatchCoordinatorError.scoringNotAllowed: detail = "Take over scoring before awarding points."
        case MatchClientError.http(_, let code): detail = Self.explain(code ?? "server_error")
        default: detail = pending ? "Connection interrupted. Your action is saved and will be checked again." : "Could not connect or save settings. Check the server and try again."
        }
        showMessage(detail, source: .recovery)
    }
    private static func explain(_ code: String) -> String {
        switch code {
        case "tied_set": return "A tied set cannot end. Correct the score first."
        case "set_not_won": return "Neither team has won this set under the selected rules."
        case "match_already_won": return "The match has been won. End the match or undo the last action."
        case "revision_conflict", "scorer_changed": return "The match changed on another device. Review the current score."
        case "command_expired": return "The action was too old to apply. Review the score and try again."
        case "match_ended": return "This match has ended."
        case "match_in_flight": return "Another match is active. Connect again to join it."
        default: return "The server rejected the action (\(code))."
        }
    }
}

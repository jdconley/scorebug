import Combine
import Foundation
import ScorebugCore

/// The New match sheet. Remembers the last teams, colors, format, style and
/// destination so the next match is two taps.
@MainActor final class NewMatchModel: ObservableObject {
    @Published var draft: NewMatchDraft
    @Published private(set) var destinations: [Destination] = []
    @Published private(set) var loadedDestinations = false
    @Published private(set) var busy = false
    @Published var error: String?
    /// The server already has a different match open (left over from a crash, or another phone).
    @Published private(set) var otherMatchOpen = false

    private let config: ServerConfig
    private let preferences: AppPreferences
    private let clientFactory: AppModel.ClientFactory
    private let newID: () -> String
    /// Reused on retry so a lost reply can't create two matches.
    private var pendingCreationID: String?

    init(config: ServerConfig, preferences: AppPreferences,
         clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) },
         newID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.config = config
        self.preferences = preferences
        self.clientFactory = clientFactory
        self.newID = newID
        draft = preferences.lastDraft ?? NewMatchDraft()
    }

    private var client: MatchHTTPClient? { (try? ScoringEndpoint(config.endpoint)).map(clientFactory) }

    func loadDestinations() async {
        guard let client, let token = config.ownerToken else { return }
        do {
            destinations = try await client.destinations(ownerToken: token)
            if let chosen = draft.destinationId, !destinations.contains(where: { $0.id == chosen }) {
                draft.destinationId = nil // a remembered destination was deleted: fall back to the default
            }
        } catch {
            destinations = []
        }
        loadedDestinations = true
    }

    /// The destination "Go live" streams to. Nil with no destinations: the server's own output.
    var streamDestination: Destination? {
        if let id = draft.destinationId, let match = destinations.first(where: { $0.id == id }) { return match }
        return destinations.first(where: \.isDefault) ?? destinations.first
    }

    var streamLabel: String { streamDestination?.name ?? "Server default" }

    func chooseDestination(_ destination: Destination) { draft.destinationId = destination.id }

    var issues: [NewMatchIssue] { draft.issues }
    var canStart: Bool { draft.isValid && !busy && config.isOwner }

    /// Creates the match on the server. The caller starts recording (and the stream unless `recordOnly`).
    func start(recordOnly: Bool) async -> MatchSession? {
        guard canStart, let client, let token = config.ownerToken else {
            error = draft.issues.first?.message
            return nil
        }
        busy = true; error = nil; otherMatchOpen = false
        defer { busy = false }
        let id = pendingCreationID ?? newID()
        pendingCreationID = id
        let creation = draft.creation(id: id, deviceId: config.deviceId, recordOnly: recordOnly)
        do {
            let response: MatchSessionResponse
            do {
                response = try await client.create(creation, ownerToken: token)
            } catch MatchClientError.http(409, "match_in_flight") {
                // Our own earlier attempt may have succeeded with its reply lost.
                guard let active = try await client.active(ownerToken: token).snapshot, active.id == id else {
                    otherMatchOpen = true
                    error = "Another match is still open on the server. Close it to start this one."
                    return nil
                }
                response = try await client.join(gameId: id, deviceId: config.deviceId, role: .score, installationToken: token)
            }
            guard response.credential.gameId == id, response.credential.role == .score else { throw MatchClientError.invalidResponse }
            pendingCreationID = nil
            preferences.lastDraft = draft
            return MatchSession(kind: .filming, endpoint: config.endpoint, credential: response.credential,
                                recordOnly: recordOnly, layout: CourtLayout(), startedAt: Date())
        } catch {
            if case MatchClientError.http(let status, _) = error, (400..<500).contains(status) { pendingCreationID = nil }
            self.error = FriendlyError.message(error)
            return nil
        }
    }

    /// Ends the leftover match so a new one can start.
    func closeOtherMatch() async {
        guard let client, let token = config.ownerToken else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let active = try await client.active(ownerToken: token).snapshot else { otherMatchOpen = false; return }
            let joined = try await client.join(gameId: active.id, deviceId: config.deviceId, role: .score, installationToken: token)
            let coordinator = MatchCommandCoordinator(client: client, credential: joined.credential,
                                                      endpointScope: "\(config.endpoint)|close", store: MemoryPendingCommandStore())
            var state = try await coordinator.refresh()
            if state.snapshot?.scorer.deviceId != config.deviceId { state = try await coordinator.submit(.takeOver) }
            if state.snapshot?.status == .active { _ = try await coordinator.submit(.endMatch(reason: "Closed to start a new match")) }
            otherMatchOpen = false
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

extension MatchHTTPClient {
    func active(ownerToken: String) async throws -> ActiveMatchResponse { try await active(installationToken: ownerToken) }
}

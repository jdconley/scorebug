import Combine
import Foundation
import ScorebugCore

/// The New match sheet for one team. Remembers the last opponent, colors, format and
/// style so the next match is two taps; Team 1 starts as this team. The stream goes to
/// the team's YouTube channel, so there is no destination to pick.
@MainActor final class NewMatchModel: ObservableObject {
    @Published var draft: NewMatchDraft
    @Published private(set) var busy = false
    @Published var error: String?
    /// The team already has a different match open (left over from a crash, or another phone).
    @Published private(set) var otherMatchOpen = false

    let team: Team
    private let access: TeamAccess
    private let preferences: AppPreferences
    private let clientFactory: AppModel.ClientFactory
    private let newID: () -> String
    /// Reused on retry so a lost reply can't create two matches.
    private var pendingCreationID: String?

    init(team: Team, access: TeamAccess, preferences: AppPreferences,
         clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) },
         newID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.team = team
        self.access = access
        self.preferences = preferences
        self.clientFactory = clientFactory
        self.newID = newID
        var draft = preferences.lastDraft ?? NewMatchDraft()
        draft.destinationId = nil
        if draft.team1.trimmedName != team.name {
            // A different team than last time: Team 1 is this team, and the old Team 1 isn't its opponent.
            if draft.team2.trimmedName == team.name { draft.team2 = TeamDraft(color: TeamPalette.swatches[1].hex) }
            draft.team1 = TeamDraft(name: team.name, shortName: team.shortName, color: team.color.lowercased())
        }
        self.draft = draft
    }

    private var client: MatchHTTPClient? { (try? ScoringEndpoint(access.endpoint)).map(clientFactory)?.team(access.teamId) }

    var issues: [NewMatchIssue] { draft.issues }
    var canStart: Bool { draft.isValid && !busy }

    /// Creates the match on the server. The caller starts recording (and the stream unless `recordOnly`).
    func start(recordOnly: Bool) async -> MatchSession? {
        guard canStart, let client else {
            error = draft.issues.first?.message
            return nil
        }
        busy = true; error = nil; otherMatchOpen = false
        defer { busy = false }
        let id = pendingCreationID ?? newID()
        pendingCreationID = id
        let token = access.token
        let creation = draft.creation(id: id, deviceId: access.deviceId, recordOnly: recordOnly)
        do {
            let response: MatchSessionResponse
            do {
                response = try await client.create(creation, ownerToken: token)
            } catch MatchClientError.http(409, "match_in_flight") {
                // Our own earlier attempt may have succeeded with its reply lost.
                guard let active = try await client.active(ownerToken: token).snapshot, active.id == id else {
                    otherMatchOpen = true
                    error = "\(team.name) already has a match open. Close it to start this one."
                    return nil
                }
                response = try await client.join(gameId: id, deviceId: access.deviceId, role: .score, installationToken: token)
            }
            guard response.credential.gameId == id, response.credential.role == .score else { throw MatchClientError.invalidResponse }
            pendingCreationID = nil
            preferences.lastDraft = draft
            return MatchSession(kind: .filming, endpoint: access.endpoint, credential: response.credential,
                                recordOnly: recordOnly, layout: CourtLayout(), startedAt: Date(), teamId: access.teamId)
        } catch {
            if case MatchClientError.http(let status, _) = error, (400..<500).contains(status) { pendingCreationID = nil }
            self.error = FriendlyError.message(error)
            return nil
        }
    }

    /// Ends the leftover match so a new one can start.
    func closeOtherMatch() async {
        guard let client else { return }
        let token = access.token, deviceId = access.deviceId
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let active = try await client.active(ownerToken: token).snapshot else { otherMatchOpen = false; return }
            let joined = try await client.join(gameId: active.id, deviceId: deviceId, role: .score, installationToken: token)
            let coordinator = MatchCommandCoordinator(client: client, credential: joined.credential,
                                                      endpointScope: "\(access.endpoint)|close", store: MemoryPendingCommandStore())
            var state = try await coordinator.refresh()
            if state.snapshot?.scorer.deviceId != deviceId { state = try await coordinator.submit(.takeOver) }
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

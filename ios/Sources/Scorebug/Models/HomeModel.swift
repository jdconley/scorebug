import Combine
import Foundation
import ScorebugCore

/// Home: each team's active match, opening one to film or score, and creating a team.
@MainActor final class HomeModel: ObservableObject {
    /// Team ID → its active match. A team with no open match has no entry.
    @Published private(set) var activeMatches: [String: MatchSnapshot] = [:]
    /// Team ID → its open match's YouTube broadcast, once it has gone live.
    @Published private(set) var watchLinks: [String: MatchYouTube] = [:]
    /// Team ID → its YouTube channel (nil value: none set). Teams not read yet have no key.
    @Published private(set) var channels: [String: TeamYouTube?] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error: String?

    private let clientFactory: AppModel.ClientFactory
    init(clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) }) {
        self.clientFactory = clientFactory
    }

    /// Reloads the person's teams, then each team's active match.
    func refresh(_ app: AppModel) async {
        await app.refreshMe()
        await loadMatches(app)
    }

    func loadMatches(_ app: AppModel) async {
        var found: [String: MatchSnapshot] = [:]
        var links: [String: MatchYouTube] = [:]
        var teamChannels: [String: TeamYouTube?] = [:]
        await withTaskGroup(of: (String, ActiveMatchResponse?, TeamDetail?).self) { group in
            for team in app.teams {
                guard let access = app.access(teamId: team.id) else { continue }
                let client = clientFactory(app.server)
                group.addTask {
                    async let active = try? client.team(team.id).active(installationToken: access.token)
                    async let detail = try? client.teamDetail(team.id, token: access.token)
                    return (team.id, await active, await detail)
                }
            }
            for await (teamId, active, detail) in group {
                if let snapshot = active?.snapshot, snapshot.status == .active {
                    found[teamId] = snapshot
                    if let link = active?.youtube, link.url != nil { links[teamId] = link }
                }
                if let detail { teamChannels[teamId] = .some(detail.youtube) }
            }
        }
        activeMatches = found
        watchLinks = links
        channels = teamChannels
        loaded = true
    }

    /// Joins a team's open match from this phone: to film it (camera, stream and scoring)
    /// or only to score it. Scoring takes over from whoever is scoring now.
    func open(_ snapshot: MatchSnapshot, team: TeamMembership, kind: MatchSession.Kind, app: AppModel) async -> MatchSession? {
        guard !busy, let access = app.access(teamId: team.id) else { return nil }
        busy = true; error = nil
        defer { busy = false }
        do {
            let client = clientFactory(app.server).team(team.id)
            let joined = try await client.join(gameId: snapshot.id, deviceId: access.deviceId, role: .score,
                                               installationToken: access.token)
            guard joined.credential.gameId == snapshot.id, joined.credential.role == .score,
                  joined.credential.deviceId == access.deviceId else { throw MatchClientError.invalidResponse }
            return MatchSession(kind: kind, endpoint: access.endpoint, credential: joined.credential,
                                recordOnly: kind == .scoring || joined.snapshot.output.recordOnly,
                                layout: CourtLayout(), startedAt: Date(), teamId: team.id)
        } catch {
            if case MatchClientError.http(_, "match_ended") = error { activeMatches[team.id] = nil }
            self.error = FriendlyError.message(error)
            return nil
        }
    }

    /// Owners JD has let create teams. Returns the new team's ID.
    func createTeam(name: String, app: AppModel) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty, let account = app.account else { return nil }
        busy = true; error = nil
        defer { busy = false }
        do {
            let created = try await clientFactory(app.server).createTeam(name: String(trimmed.prefix(80)), token: account.token)
            await app.refreshMe()
            return created.team.id
        } catch MatchClientError.forbidden {
            error = "Your account can't create teams yet."
            return nil
        } catch {
            self.error = FriendlyError.message(error)
            return nil
        }
    }
}

/// In-memory scoring outbox for one-off commands (closing a leftover match).
final class MemoryPendingCommandStore: PendingCommandStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingMatchCommand?
    func load() throws -> PendingMatchCommand? { lock.withLock { value } }
    func save(_ pending: PendingMatchCommand?) throws { lock.withLock { value = pending } }
}

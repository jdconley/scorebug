import Combine
import Foundation
import ScorebugCore

/// The team screen: members and invites. Owners rename the team, invite by email or
/// link, revoke invites and remove members; anyone can leave.
@MainActor final class TeamModel: ObservableObject {
    @Published private(set) var detail: TeamDetail?
    @Published private(set) var busy = false
    @Published var error: String?
    /// The invite just made, for the share sheet.
    @Published var issued: TeamInviteIssued?
    /// This person's own YouTube connections, for the owner's channel picker.
    @Published private(set) var connections: [YouTubeConnection] = []

    let teamId: String
    private let clientFactory: AppModel.ClientFactory

    init(teamId: String, clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) }) {
        self.teamId = teamId
        self.clientFactory = clientFactory
    }

    var isOwner: Bool { detail?.role == .owner }
    var channel: TeamYouTube? { detail?.youtube }
    var members: [TeamMember] { detail?.members ?? [] }
    /// Live invites only, newest first.
    var invites: [TeamInvite] { (detail?.invites ?? []).filter { $0.isLive() } }

    func load(_ app: AppModel) async {
        guard let account = app.account else { return }
        do {
            let client = clientFactory(app.server)
            detail = try await client.teamDetail(teamId, token: account.token)
            error = nil
            if isOwner { connections = (try? await client.youtubeConnections(token: account.token)) ?? connections }
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    // MARK: YouTube channel (owners)

    /// Connects a channel (or reconnects one: the same channel keeps its connection) and makes it
    /// the team's channel.
    func connectChannel(app: AppModel) async {
        guard !busy else { return }
        busy = true
        let connection = await app.connectYouTube()
        busy = false
        if let message = app.error { error = message; app.error = nil }
        guard let connection else { return }
        await choose(connection, app: app)
    }

    /// Streams this team's matches to `connection`, or to no channel.
    func choose(_ connection: YouTubeConnection?, app: AppModel) async {
        if await run(app, { client, token in
            let youtube = try await client.setTeamChannel(self.teamId, connectionId: connection?.id, token: token)
            self.detail?.youtube = youtube
        }) { await load(app) }
    }

    /// Checks the team's channel again (after YouTube's 24-hour wait, say).
    func checkChannel(app: AppModel) async {
        guard let channel else { return }
        if await run(app, { client, token in
            _ = try await client.checkYouTubeConnection(channel.connectionId, token: token)
        }) { await load(app) }
    }

    /// Whether this person can reconnect or re-check the team's channel: it's their connection.
    func ownsChannel(_ app: AppModel) -> Bool { channel?.connectedBy == app.account?.person.id }

    @discardableResult func rename(_ name: String, app: AppModel) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != detail?.team.name else { return true }
        return await run(app) { client, token in
            let team = try await client.renameTeam(self.teamId, name: String(trimmed.prefix(80)), token: token)
            self.detail?.team = team
            await app.refreshMe()
        }
    }

    /// An email invite only works for that Google account; a link invite works for anyone who has it.
    @discardableResult func invite(email: String?, app: AppModel) async -> TeamInviteIssued? {
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address, !address.isEmpty, !Self.looksLikeEmail(address) {
            error = "Enter an email address, like coach@example.com."
            return nil
        }
        var result: TeamInviteIssued?
        _ = await run(app) { client, token in
            result = try await client.createTeamInvite(self.teamId, email: address?.isEmpty == false ? address : nil, token: token)
        }
        if let result {
            issued = result
            await load(app)
        }
        return result
    }

    func revoke(_ invite: TeamInvite, app: AppModel) async {
        if await run(app, { client, token in
            try await client.revokeTeamInvite(self.teamId, inviteId: invite.id, token: token)
        }) { await load(app) }
    }

    func remove(_ member: TeamMember, app: AppModel) async {
        if await run(app, { client, token in
            try await client.removeMember(self.teamId, personId: member.personId, token: token)
        }) { await load(app) }
    }

    /// Leaves the team. Returns true once this person is off it.
    func leave(app: AppModel) async -> Bool {
        guard let person = app.account?.person else { return false }
        let left = await run(app) { client, token in
            try await client.removeMember(self.teamId, personId: person.id, token: token)
        }
        if left { await app.refreshMe() }
        return left
    }

    /// The text that goes with a shared invite link.
    func shareText(_ issued: TeamInviteIssued) -> String {
        let name = detail?.team.name ?? "our team"
        return "Join \(name) on Scorebug to film and score our volleyball matches: \(issued.link)"
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    private func run(_ app: AppModel, _ work: @escaping (MatchHTTPClient, String) async throws -> Void) async -> Bool {
        guard !busy, let account = app.account else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await work(clientFactory(app.server), account.token)
            return true
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    static func message(_ error: Error) -> String {
        switch error {
        case MatchClientError.http(409, "last_owner"):
            return "A team needs an owner, so its only owner can't leave or be removed."
        case MatchClientError.http(409, "invite_limit"):
            return "This team has too many open invites. Revoke some first."
        case MatchClientError.forbidden:
            return "Only a team owner can do that."
        case MatchClientError.http(409, "youtube_needs_reconnect"):
            return "YouTube needs reconnecting. Tap Reconnect."
        case MatchClientError.http(404, "connection_not_found"):
            return "That YouTube channel isn't connected anymore. Connect it again."
        case MatchClientError.http(_, let code?) where code == "youtube_unavailable" || code == "youtube_quota":
            return "YouTube isn't answering right now. Try again in a few minutes."
        default:
            return FriendlyError.message(error)
        }
    }
}

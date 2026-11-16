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

    let teamId: String
    private let clientFactory: AppModel.ClientFactory

    init(teamId: String, clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) }) {
        self.teamId = teamId
        self.clientFactory = clientFactory
    }

    var isOwner: Bool { detail?.role == .owner }
    var members: [TeamMember] { detail?.members ?? [] }
    /// Live invites only, newest first.
    var invites: [TeamInvite] { (detail?.invites ?? []).filter { $0.isLive() } }

    func load(_ app: AppModel) async {
        guard let account = app.account else { return }
        do {
            detail = try await clientFactory(app.server).teamDetail(teamId, token: account.token)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

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
        _ = await run(app) { client, token in
            try await client.revokeTeamInvite(self.teamId, inviteId: invite.id, token: token)
        }
        await load(app)
    }

    func remove(_ member: TeamMember, app: AppModel) async {
        _ = await run(app) { client, token in
            try await client.removeMember(self.teamId, personId: member.personId, token: token)
        }
        await load(app)
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
        default:
            return FriendlyError.message(error)
        }
    }
}

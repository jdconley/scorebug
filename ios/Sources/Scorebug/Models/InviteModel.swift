import Combine
import Foundation
import ScorebugCore

/// "Invite scorer": a code, QR and share link for another phone at the game.
@MainActor final class InviteModel: ObservableObject {
    @Published private(set) var invite: MatchInviteIssued?
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private let clientFactory: AppModel.ClientFactory
    init(clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) }) {
        self.clientFactory = clientFactory
    }

    /// Any team member signed in on this phone can mint a code for the team's match;
    /// a phone that joined with a code can't.
    func create(session: MatchSession, access: TeamAccess?) async {
        guard !busy else { return }
        guard let access, session.teamId == access.teamId else {
            error = "Only a team member's phone can invite scorers."
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let server = try ScoringEndpoint(session.endpoint)
            let issued = try await clientFactory(server).team(access.teamId)
                .createInvite(gameId: session.credential.gameId, token: access.token)
            guard case .matchJoin? = ScorebugLink(string: issued.link, hosts: ScorebugLink.hosts(for: server)) else {
                throw MatchClientError.invalidResponse
            }
            invite = issued
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    var shareText: String? {
        invite.map { "Help score our volleyball match in Scorebug. Open \($0.link) or enter code \($0.code)." }
    }
}

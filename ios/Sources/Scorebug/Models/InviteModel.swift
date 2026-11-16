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

    /// The owner token can mint invites for any match; a joined scorer phone can't.
    func create(session: MatchSession, ownerToken: String?) async {
        guard !busy else { return }
        guard let ownerToken else { error = "Only the phone that started the match can invite scorers."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let issued = try await clientFactory(try ScoringEndpoint(session.endpoint))
                .createInvite(gameId: session.credential.gameId, token: ownerToken)
            guard ScorebugLink(string: issued.link) != nil else { throw MatchClientError.invalidResponse }
            invite = issued
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    var shareText: String? {
        invite.map { "Help score our volleyball match in Scorebug. Open \($0.link) or enter code \($0.code)." }
    }
}

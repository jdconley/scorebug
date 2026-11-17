import Combine
import Foundation
import ScorebugCore

/// Opens the Google sign-in page and returns the `scorebug://auth` callback URL.
/// `ASWebAuthenticationSession` in the app; a fake in tests.
@MainActor protocol SignInBrowser {
    /// Throws `SignInBrowserError.cancelled` when the person closes the sheet.
    func open(_ url: URL, callbackScheme: String) async throws -> URL
}

enum SignInBrowserError: Error { case cancelled, unavailable }

/// App-wide state: the signed-in person and their teams, which screen is showing,
/// and the `scorebug.live/invite/…` and `/join/…` links.
@MainActor final class AppModel: ObservableObject {
    enum Route: Equatable {
        case signIn
        case home
        case filming(MatchSession)
        case scoring(MatchSession)
    }

    /// A link waiting for the person to confirm, so a stray link can't join anything on its own.
    enum PendingLink: Equatable, Identifiable {
        case teamInvite(code: String)
        case matchJoin(code: String)
        var id: String {
            switch self {
            case .teamInvite(let code): "team|\(code)"
            case .matchJoin(let code): "match|\(code)"
            }
        }
    }

    typealias ClientFactory = (ScoringEndpoint) -> MatchHTTPClient

    @Published private(set) var account: Account?
    @Published private(set) var me: Me?
    @Published private(set) var route: Route = .signIn
    @Published var pendingLink: PendingLink?
    @Published private(set) var busy = false
    @Published var error: String?
    /// Signed in with Google, but not let in: the private beta screen.
    @Published private(set) var notInBeta = false
    /// The server everything goes to: scorebug.live, or the Debug override.
    @Published private(set) var server: ScoringEndpoint

    let preferences: AppPreferences
    let deviceId: String
    private let store: SecureStore
    private let clientFactory: ClientFactory
    private let browser: SignInBrowser
    private let deviceName: () -> String
    private let newID: () -> String

    init(store: SecureStore, preferences: AppPreferences, server: ScoringEndpoint,
         clientFactory: @escaping ClientFactory = { MatchHTTPClient(endpoint: $0) },
         browser: SignInBrowser, deviceName: @escaping () -> String,
         newID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.preferences = preferences
        self.server = server
        self.clientFactory = clientFactory
        self.browser = browser
        self.deviceName = deviceName
        self.newID = newID
        if let saved = try? store.value(String.self, for: StoreKey.deviceId) { deviceId = saved }
        else { deviceId = newID(); try? store.setValue(deviceId, for: StoreKey.deviceId) }
        account = try? store.value(Account.self, for: StoreKey.account)
        if let session = try? store.value(MatchSession.self, for: StoreKey.session) {
            route = session.kind == .filming ? .filming(session) : .scoring(session)
        } else {
            route = account == nil ? .signIn : .home
        }
    }

    var client: MatchHTTPClient { clientFactory(server) }
    var linkHosts: Set<String> { ScorebugLink.hosts(for: server) }
    var teams: [TeamMembership] { me?.teams ?? [] }

    /// The session token and IDs for a team's match routes, when signed in.
    func access(teamId: String?) -> TeamAccess? {
        guard let account, let teamId else { return nil }
        return TeamAccess(endpoint: server.url.absoluteString, token: account.token, teamId: teamId, deviceId: deviceId)
    }

    var activeSession: MatchSession? {
        switch route {
        case .filming(let session), .scoring(let session): session
        default: nil
        }
    }

    // MARK: Sign in

    /// Google sign-in in a browser sheet, then the one-time ticket for a session token.
    /// `invite` is a team invite code: it lets a person in who isn't on the beta list.
    func signIn(invite: String? = nil) async {
        guard !busy else { return }
        busy = true; error = nil; notInBeta = false
        defer { busy = false }
        let pkce = PKCE.make()
        let callback: URL
        do {
            callback = try await browser.open(client.signInURL(challenge: pkce.challenge, invite: invite),
                                              callbackScheme: ScorebugService.callbackScheme)
        } catch SignInBrowserError.cancelled {
            return
        } catch {
            self.error = "Couldn't open Google sign-in. Try again."
            return
        }
        switch SignInCallback(url: callback) {
        case .ok(let ticket)?:
            do {
                let signedIn = try await client.createSession(ticket: ticket, verifier: pkce.verifier, deviceName: deviceName())
                let value = Account(token: signedIn.token, person: signedIn.person)
                try store.setValue(value, for: StoreKey.account)
                account = value
                if activeSession == nil { route = .home }
                await refreshMe()
            } catch MatchClientError.unauthorized {
                error = "Sign-in took too long. Try again."
            } catch {
                self.error = FriendlyError.message(error)
            }
        case .notInBeta?:
            notInBeta = true
        case .cancelled?:
            return
        case .error?, nil:
            error = "Google sign-in didn't finish. Try again."
        }
    }

    /// Revokes the session token (best effort) and forgets it. Recordings stay.
    func signOut() async {
        guard activeSession == nil, let account else { return }
        try? await client.deleteSession(token: account.token)
        forgetAccount()
    }

    private func forgetAccount() {
        try? store.setValue(Account?.none, for: StoreKey.account)
        account = nil; me = nil
        if activeSession == nil { route = .signIn }
    }

    func dismissNotInBeta() { notInBeta = false }

    /// The person, their teams and whether they can create teams. A revoked token signs out.
    func refreshMe() async {
        guard let account else { return }
        do {
            let value = try await client.me(token: account.token)
            me = value
            if value.person != account.person {
                self.account?.person = value.person
                try? store.setValue(self.account, for: StoreKey.account)
            }
        } catch MatchClientError.unauthorized {
            forgetAccount()
            error = "You've been signed out. Sign in again."
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    // MARK: YouTube

    /// Connects a YouTube channel: Google asks for the account, the channel and the `youtube`
    /// permission, then the app claims the result with its own session. Nil when it didn't finish;
    /// `error` says why, except when the person closed the sheet.
    func connectYouTube() async -> YouTubeConnection? {
        guard let account else { return nil }
        error = nil
        do {
            let start = try await client.youtubeConnectURL(token: account.token)
            let callback: URL
            do {
                callback = try await browser.open(start, callbackScheme: ScorebugService.callbackScheme)
            } catch SignInBrowserError.cancelled {
                return nil
            }
            switch YouTubeCallback(url: callback) {
            case .ok(let ticket)?:
                return try await client.claimYouTubeConnection(ticket: ticket, token: account.token)
            case .cancelled?:
                return nil
            case .scopeDenied?:
                error = "Scorebug needs permission to manage your YouTube live streams. Try again and tick the YouTube box."
            case .error?, nil:
                error = "Connecting YouTube didn't finish. Try again."
            }
        } catch MatchClientError.http(409, "youtube_no_channel") {
            error = "That Google account has no YouTube channel. Create one on YouTube, or pick another account."
        } catch MatchClientError.http(_, let code?) where code == "youtube_unavailable" || code == "youtube_quota" {
            error = "YouTube isn't answering right now. Try again in a few minutes."
        } catch MatchClientError.unauthorized {
            forgetAccount()
            error = "You've been signed out. Sign in again."
        } catch {
            self.error = FriendlyError.message(error)
        }
        return nil
    }

    // MARK: Debug server

    /// Debug builds: point the app at another server. Signs out, since tokens belong to one server.
    @discardableResult func useServer(_ address: String?) -> Bool {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint: ScoringEndpoint
        if trimmed.isEmpty {
            endpoint = try! ScoringEndpoint(ScorebugService.url.absoluteString)
        } else {
            guard let custom = try? ScoringEndpoint(trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
                error = FriendlyError.message(ScoringEndpoint.ValidationError.invalidAddress)
                return false
            }
            endpoint = custom
        }
        guard activeSession == nil else { return false }
        if endpoint.canonicalAddress != server.canonicalAddress { forgetAccount() }
        preferences.serverOverride = trimmed.isEmpty ? nil : endpoint.url.absoluteString
        server = endpoint
        error = nil
        return true
    }

    // MARK: Links

    /// A universal link, or one pasted. Returns false when it isn't a Scorebug link.
    @discardableResult func open(_ text: String) -> Bool {
        switch ScorebugLink(string: text, hosts: linkHosts) {
        case .teamInvite(let code)?: pendingLink = .teamInvite(code: code)
        case .matchJoin(let code)?: pendingLink = .matchJoin(code: code)
        case nil: return false
        }
        return true
    }

    func confirmPendingLink() async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        switch link {
        case .teamInvite(let code): await acceptTeamInvite(code: code)
        case .matchJoin(let code): await join(code: code)
        }
    }

    /// Signed in: join the team now. Signed out: sign in with the invite, which lets them in.
    /// True once the person is signed in and on the team.
    @discardableResult func acceptTeamInvite(code: String) async -> Bool {
        guard let account else {
            await signIn(invite: code)
            return self.account != nil && error == nil
        }
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await client.acceptTeamInvite(code: code, token: account.token)
        } catch MatchClientError.forbidden {
            error = "That invite is for a different Google account. Sign in with the email it was sent to."
            return false
        } catch MatchClientError.unauthorized {
            forgetAccount()
            error = "You've been signed out. Open the invite link again to sign in."
            return false
        } catch MatchClientError.http(404, _) {
            error = "That team invite didn't work. Ask the team owner for a new link."
            return false
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
        busy = false
        await refreshMe()
        if activeSession == nil { route = .home }
        return true
    }

    // MARK: Joining with a code

    /// A typed or pasted code or link: six characters score one match (no account needed);
    /// eight characters are a team invite.
    @discardableResult func join(text: String) async -> Bool {
        if case .teamInvite(let code)? = ScorebugLink(string: text, hosts: linkHosts) { return await acceptTeamInvite(code: code) }
        if let code = ScorebugLink.matchCode(from: text, hosts: linkHosts) { return await join(code: code) }
        if let code = TeamInviteCode.normalize(text) { return await acceptTeamInvite(code: code) }
        error = "Enter the code, like K7P-4QX for a match or ABCD-EFGH for a team, or paste the invite link."
        return false
    }

    @discardableResult func join(code: String) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            let redeemed = try await client.redeemInvite(code: code, deviceId: deviceId)
            guard redeemed.credential.role == .score, redeemed.credential.deviceId == deviceId,
                  redeemed.snapshot.id == redeemed.credential.gameId else { throw MatchClientError.invalidResponse }
            begin(MatchSession(kind: .scoring, endpoint: server.url.absoluteString, credential: redeemed.credential,
                               recordOnly: true, layout: CourtLayout(), startedAt: Date()))
            return true
        } catch MatchClientError.unauthorized {
            error = FriendlyError.message(code: "invite_invalid", status: 401)
            return false
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
    }

    // MARK: Sessions

    func begin(_ session: MatchSession) {
        do { try store.setValue(session, for: StoreKey.session) }
        catch { self.error = FriendlyError.message(error) }
        route = session.kind == .filming ? .filming(session) : .scoring(session)
    }

    func saveLayout(_ layout: CourtLayout) {
        guard var session = activeSession, session.layout != layout else { return }
        session.layout = layout
        try? store.setValue(session, for: StoreKey.session)
        route = session.kind == .filming ? .filming(session) : .scoring(session)
    }

    /// Leaves the match screen. A finished match becomes the Home card.
    func finish(lastSnapshot: MatchSnapshot?) {
        if let lastSnapshot, activeSession?.kind == .filming || lastSnapshot.status == .ended {
            preferences.lastMatch = MatchRecap(snapshot: lastSnapshot, date: Date())
        }
        try? store.setValue(MatchSession?.none, for: StoreKey.session)
        route = account == nil ? .signIn : .home
    }
}

import Foundation
import ScorebugCore
import XCTest

/// Stands in for `ASWebAuthenticationSession`: the fake server plays Google and the Worker's callback.
@MainActor final class FakeSignInBrowser: SignInBrowser {
    let server: FakeScorebugServer
    /// Who signs in on Google's page; nil closes the sheet.
    var email: String? = "jd@example.com"
    var opened: [URL] = []
    init(server: FakeScorebugServer) { self.server = server }

    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        XCTAssertEqual(callbackScheme, "scorebug")
        opened.append(url)
        guard let email else { throw SignInBrowserError.cancelled }
        if url.host == "accounts.google.test" { return await server.authorizeYouTube(url) }
        return await server.authorize(url, as: email)
    }
}

@MainActor final class AppModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var browser: FakeSignInBrowser!
    private var ids: [String] = []

    override func setUp() async throws {
        server = FakeScorebugServer()
        store = MemorySecureStore()
        defaults = UserDefaults(suiteName: "scorebug.tests.\(UUID().uuidString)")!
        browser = FakeSignInBrowser(server: server)
        ids = (1...20).map { "00000000-0000-4000-8000-\(String(format: "%012d", $0))" }
    }

    private func factory() -> AppModel.ClientFactory {
        let server = server!
        return { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) }
    }

    private func makeApp() -> AppModel {
        AppModel(store: store, preferences: AppPreferences(defaults: defaults),
                 server: try! ScoringEndpoint("https://scorebug.live"), clientFactory: factory(), browser: browser,
                 deviceName: { "JD's iPhone" }, newID: { [unowned self] in ids.removeFirst() })
    }

    // MARK: Sign in

    func testSignInWithGoogleExchangesTheTicketWithThePKCEVerifierAndKeepsTheToken() async throws {
        await server.addTeam("t1", name: "Cascade 14 Black", member: "p-jd", role: .owner)
        let app = makeApp()
        XCTAssertEqual(app.route, .signIn)
        await app.signIn()
        XCTAssertEqual(app.route, .home, String(describing: app.error))
        XCTAssertNil(app.error)
        XCTAssertEqual(app.account?.person.email, "jd@example.com")
        XCTAssertEqual(try store.value(Account.self, for: StoreKey.account), app.account, "the token lives in the Keychain")
        XCTAssertEqual(app.teams.map(\.name), ["Cascade 14 Black"])
        XCTAssertEqual(app.me?.canCreateTeams, true)

        let start = try XCTUnwrap(browser.opened.first)
        XCTAssertEqual(start.host, "scorebug.live")
        XCTAssertEqual(start.path, "/v1/auth/google/start")
        let challenge = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "challenge" }?.value
        XCTAssertEqual(challenge?.count, 43, "only the S256 challenge goes through the browser")
        let exchange = await server.requests.first { $0.path == "/v1/auth/session" }
        let verifier = try XCTUnwrap(exchange?.body?["verifier"] as? String)
        XCTAssertNotEqual(verifier, challenge)
        XCTAssertEqual(PKCE.challenge(for: verifier), challenge)
        XCTAssertEqual(exchange?.body?["deviceName"] as? String, "JD's iPhone")

        let relaunched = makeApp()
        XCTAssertEqual(relaunched.route, .home)
        XCTAssertEqual(relaunched.account, app.account)
        XCTAssertEqual(relaunched.deviceId, app.deviceId, "one device ID per install")
    }

    func testNotInBetaShowsThePrivateBetaScreenAndStoresNothing() async {
        browser.email = "stranger@example.com"
        let app = makeApp()
        await app.signIn()
        XCTAssertTrue(app.notInBeta)
        XCTAssertNil(app.account)
        XCTAssertEqual(app.route, .signIn)
        XCTAssertNil(try store.value(Account.self, for: StoreKey.account))
        app.dismissNotInBeta()
        XCTAssertFalse(app.notInBeta)
    }

    func testClosingTheSignInSheetIsNotAnError() async {
        browser.email = nil
        let app = makeApp()
        await app.signIn()
        XCTAssertNil(app.error)
        XCTAssertNil(app.account)
        XCTAssertFalse(app.notInBeta)
    }

    func testAReplayedTicketOrWrongVerifierIsRefused() async throws {
        let app = makeApp()
        // The ticket from someone else's sign-in, without their verifier.
        let stolen = await server.authorize(URL(string: "https://scorebug.live/v1/auth/google/start?challenge=\(PKCE.make().challenge)")!,
                                            as: "jd@example.com")
        guard case .ok(let ticket)? = SignInCallback(url: stolen) else { return XCTFail() }
        do {
            _ = try await app.client.createSession(ticket: ticket, verifier: PKCE.make().verifier, deviceName: "x")
            XCTFail("a ticket is useless without its verifier")
        } catch let error as MatchClientError { XCTAssertEqual(error, .unauthorized) }
    }

    func testSignOutRevokesTheTokenAndReturnsToSignIn() async throws {
        let app = makeApp()
        await app.signIn()
        let token = try XCTUnwrap(app.account?.token)
        await app.signOut()
        XCTAssertEqual(app.route, .signIn)
        XCTAssertNil(app.account)
        XCTAssertNil(try store.value(Account.self, for: StoreKey.account))
        let revoked = await server.revokedSessions
        XCTAssertEqual(revoked, [token])
    }

    func testARevokedTokenSignsOutOnTheNextRefresh() async throws {
        let app = makeApp()
        await app.signIn()
        await server.revoke(token: try XCTUnwrap(app.account?.token))
        await app.refreshMe()
        XCTAssertNil(app.account)
        XCTAssertEqual(app.route, .signIn)
        XCTAssertEqual(app.error, "You've been signed out. Sign in again.")
    }

    func testSelfHostedLeftoversAreCleared() {
        store.values["server"] = Data("{}".utf8)
        store.values["enrollment-device"] = Data("\"x\"".utf8)
        let app = makeApp()
        XCTAssertNil(store.values["server"])
        XCTAssertNil(store.values["enrollment-device"])
        XCTAssertEqual(app.route, .signIn)
    }

    func testDebugServerOverrideSignsOut() async throws {
        let app = makeApp()
        await app.signIn()
        XCTAssertFalse(app.useServer("http://public.example.com"))
        XCTAssertNotNil(app.account, "an invalid address changes nothing")
        XCTAssertTrue(app.useServer("http://localhost:8787"))
        XCTAssertNil(app.account)
        XCTAssertEqual(app.server.url.absoluteString, "http://localhost:8787")
        XCTAssertEqual(app.preferences.serverOverride, "http://localhost:8787")
        XCTAssertEqual(app.client.signInURL(challenge: "c").host, "localhost")
        XCTAssertTrue(app.open("http://localhost:8787/join/K7P4QX"), "links on the debug server are trusted")
        XCTAssertTrue(app.useServer(""))
        XCTAssertEqual(app.server.url.absoluteString, "https://scorebug.live")
        XCTAssertNil(app.preferences.serverOverride)
    }

    // MARK: Team invites

    func testTeamInviteLinkWhenSignedOutSignsInWithTheInvite() async {
        await server.addTeam("t1", name: "Cascade 14 Black", member: "p-jd", role: .owner)
        await server.addTeamInvite(code: "ABCD2345", teamId: "t1")
        browser.email = "mom@example.com" // not on the beta list: the invite lets her in
        let app = makeApp()
        XCTAssertTrue(app.open("https://scorebug.live/invite/ABCD-2345"))
        XCTAssertEqual(app.pendingLink, .teamInvite(code: "ABCD2345"), "a link never joins without a tap")
        XCTAssertNil(app.account)
        await app.confirmPendingLink()
        XCTAssertEqual(app.route, .home, String(describing: app.error))
        XCTAssertEqual(app.teams.map(\.id), ["t1"])
        XCTAssertEqual(app.teams.first?.role, .member)
        let start = browser.opened.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(start?.queryItems?.first { $0.name == "invite" }?.value, "ABCD2345")
    }

    func testTeamInviteWhenSignedInAcceptsIt() async {
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-coach", role: .owner)
        await server.addTeamInvite(code: "WXYZ2345", teamId: "t2")
        let app = makeApp()
        await app.signIn()
        XCTAssertTrue(app.open("https://scorebug.live/invite/wxyz2345"))
        await app.confirmPendingLink()
        XCTAssertEqual(app.teams.map(\.name), ["Summit 14 Red"])
        let accepts = await server.requests.filter { $0.path == "/v1/team-invites/accept" }
        XCTAssertEqual(accepts.first?.body?["code"] as? String, "WXYZ2345")
    }

    func testTeamInviteForAnotherEmailExplainsItself() async {
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-coach", role: .owner)
        await server.addTeamInvite(code: "WXYZ2345", teamId: "t2", email: "dad@example.com")
        let app = makeApp()
        await app.signIn()
        let joined = await app.join(text: "WXYZ-2345")
        XCTAssertFalse(joined)
        XCTAssertEqual(app.error, "That invite is for a different Google account. Sign in with the email it was sent to.")
        let unknown = await app.acceptTeamInvite(code: "ZZZZ2345")
        XCTAssertFalse(unknown)
        XCTAssertEqual(app.error, "That team invite didn't work. Ask the team owner for a new link.")
    }

    func testNonScorebugTextIsNotALink() {
        let app = makeApp()
        XCTAssertFalse(app.open("https://example.com/join/K7P4QX"))
        XCTAssertFalse(app.open("scorebug://connect?server=https%3A%2F%2Fa.example&code=setup-code-123456789012"))
        XCTAssertNil(app.pendingLink)
    }

    // MARK: Joining a match with a code

    func testJoinLinkOnASignedOutPhoneOpensTheScorer() async throws {
        await server.addMatch(makeSnapshot(scorer: "filming-phone"), team: "t1")
        await server.addInvite(code: "K7P4QX", gameId: "m1")
        let app = makeApp()
        XCTAssertTrue(app.open("https://scorebug.live/join/k7p-4qx"))
        await app.confirmPendingLink()
        guard case .scoring(let session) = app.route else { return XCTFail("\(app.route) \(String(describing: app.error))") }
        XCTAssertEqual(session.credential.role, .score)
        XCTAssertEqual(session.credential.gameId, "m1")
        XCTAssertEqual(session.credential.deviceId, app.deviceId)
        XCTAssertEqual(session.endpoint, "https://scorebug.live")
        XCTAssertNil(session.teamId)
        XCTAssertNil(app.account, "a match code never signs anyone in")

        app.finish(lastSnapshot: nil)
        XCTAssertEqual(app.route, .signIn, "a signed-out scorer goes back to sign in")
    }

    func testBareCodeAndBadInput() async {
        await server.addMatch(makeSnapshot(scorer: "filming-phone"), team: "t1")
        await server.addInvite(code: "K7P4QX", gameId: "m1")
        let app = makeApp()
        let nonsense = await app.join(text: "hello")
        XCTAssertFalse(nonsense)
        XCTAssertTrue(app.error?.hasPrefix("Enter the code") == true)
        let joined = await app.join(text: "k7p 4qx")
        XCTAssertTrue(joined, String(describing: app.error))
    }

    func testEndedMatchInviteExplainsItself() async {
        await server.addMatch(makeSnapshot(status: .ended))
        await server.addInvite(code: "K7P4QX", gameId: "m1")
        let app = makeApp()
        _ = await app.join(text: "https://scorebug.live/join/K7P4QX")
        XCTAssertEqual(app.error, "That match has ended.")
    }

    func testUnknownMatchCodeSaysSo() async {
        let app = makeApp()
        _ = await app.join(text: "https://scorebug.live/join/ZZZZZZ")
        XCTAssertEqual(app.error, "That invite code didn't work. Check it and try again.")
    }

    // MARK: Sessions

    func testSessionSurvivesRelaunchAndLayoutIsSaved() async {
        let app = makeApp()
        await app.signIn()
        let credential = MatchCredential(gameId: "m1", deviceId: "d", role: .score, token: "t")
        app.begin(MatchSession(kind: .filming, endpoint: "https://scorebug.live", credential: credential,
                               recordOnly: false, layout: CourtLayout(), startedAt: Date(), teamId: "t1"))
        var swapped = CourtLayout(); swapped.swap()
        app.saveLayout(swapped)
        let relaunched = makeApp()
        guard case .filming(let session) = relaunched.route else { return XCTFail() }
        XCTAssertEqual(session.layout.leftTeam, .team2)
        XCTAssertEqual(session.teamId, "t1")

        relaunched.finish(lastSnapshot: makeSnapshot(home: 15, away: 12, set: 3, homeSets: 2, awaySets: 1, status: .ended))
        XCTAssertEqual(relaunched.route, .home)
        XCTAssertEqual(relaunched.preferences.lastMatch?.title, "CASCADE 2–1 SUMMIT")
        XCTAssertEqual(relaunched.preferences.lastMatch?.final, true)
        XCTAssertFalse(MatchRecap(snapshot: makeSnapshot(home: 5, homeSets: 1, status: .ended), date: Date()).final,
                       "ended early is not a final")
        XCTAssertNil(try store.value(MatchSession.self, for: StoreKey.session))
    }

    func testSessionsSavedBeforeTeamsStillDecode() throws {
        let old = #"{"kind":"scoring","endpoint":"https://scorebug.live","credential":{"gameId":"m1","deviceId":"d","role":"score","token":"t"},"recordOnly":true,"layout":{"leftTeam":"team1"},"startedAt":0}"#
        let session = try JSONDecoder().decode(MatchSession.self, from: Data(old.utf8))
        XCTAssertNil(session.teamId)
    }

    func testSignOutIsRefusedMidMatch() async {
        let app = makeApp()
        await app.signIn()
        app.begin(MatchSession(kind: .scoring, endpoint: "https://scorebug.live",
                               credential: MatchCredential(gameId: "m1", deviceId: "d", role: .score, token: "t"),
                               recordOnly: true, layout: CourtLayout(), startedAt: Date(), teamId: "t1"))
        await app.signOut()
        XCTAssertNotNil(app.account)
    }
}

// MARK: Home

@MainActor final class HomeModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var app: AppModel!

    override func setUp() async throws {
        server = FakeScorebugServer()
        let server = server!
        await server.addTeam("t1", name: "Cascade 14 Black", member: "p-jd", role: .owner)
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-jd", role: .member)
        app = AppModel(store: MemorySecureStore(), preferences: AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                       server: try ScoringEndpoint("https://scorebug.live"),
                       clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) },
                       browser: FakeSignInBrowser(server: server), deviceName: { "Phone" })
        await app.signIn()
    }

    private func makeHome() -> HomeModel {
        let server = server!
        return HomeModel(clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) })
    }

    func testEachTeamShowsItsOwnActiveMatch() async {
        await server.addMatch(makeSnapshot(id: "m1", scorer: "other-phone"), team: "t1")
        await server.addMatch(makeSnapshot(id: "m2", status: .ended), team: "t2")
        let home = makeHome()
        await home.refresh(app)
        XCTAssertEqual(app.teams.map(\.role), [.owner, .member])
        XCTAssertEqual(home.activeMatches.keys.sorted(), ["t1"])
        XCTAssertEqual(home.activeMatches["t1"]?.id, "m1")
        let paths = await server.requests.map(\.path)
        XCTAssertTrue(paths.contains("/v1/teams/t1/matches/active"))
        XCTAssertTrue(paths.contains("/v1/teams/t2/matches/active"))
    }

    func testOpeningATeamMatchJoinsWithTheSessionToken() async throws {
        await server.addMatch(makeSnapshot(id: "m1", scorer: "other-phone"), team: "t1")
        let home = makeHome()
        await home.refresh(app)
        let snapshot = try XCTUnwrap(home.activeMatches["t1"])
        let sessionValue = await home.open(snapshot, team: app.teams[0], kind: .scoring, app: app)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(session.kind, .scoring)
        XCTAssertEqual(session.teamId, "t1")
        XCTAssertEqual(session.credential.role, .score)
        XCTAssertEqual(session.credential.deviceId, app.deviceId)
        XCTAssertTrue(session.recordOnly, "a scorer phone never streams")
        let filmValue = await home.open(snapshot, team: app.teams[0], kind: .filming, app: app)
        XCTAssertEqual(filmValue?.recordOnly, false)
    }

    func testCreateTeamNeedsPermission() async {
        let home = makeHome()
        let id = await home.createTeam(name: "  Cascade 15 Blue ", app: app)
        XCTAssertNotNil(id)
        XCTAssertTrue(app.teams.contains { $0.name == "Cascade 15 Blue" && $0.role == .owner })
        await server.allow("jd@example.com", canCreateTeams: false)
        let refused = await home.createTeam(name: "Another", app: app)
        XCTAssertNil(refused)
        XCTAssertEqual(home.error, "Your account can't create teams yet.")
    }
}

// MARK: Team screen

@MainActor final class TeamModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var app: AppModel!

    override func setUp() async throws {
        server = FakeScorebugServer()
        let server = server!
        await server.addTeam("t1", name: "Cascade 14 Black", member: "p-jd", role: .owner)
        await server.signedIn("mom@example.com", token: "mom-token", team: "t1", role: .member)
        app = AppModel(store: MemorySecureStore(), preferences: AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                       server: try ScoringEndpoint("https://scorebug.live"),
                       clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) },
                       browser: FakeSignInBrowser(server: server), deviceName: { "Phone" })
        await app.signIn()
    }

    private func makeTeam() -> TeamModel {
        let server = server!
        return TeamModel(teamId: "t1", clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) })
    }

    func testOwnerInvitesRenamesRevokesAndRemoves() async throws {
        let team = makeTeam()
        await team.load(app)
        XCTAssertTrue(team.isOwner)
        XCTAssertEqual(team.members.map(\.email), ["jd@example.com", "mom@example.com"])

        let bad = await team.invite(email: "not an email", app: app)
        XCTAssertNil(bad)
        XCTAssertEqual(team.error, "Enter an email address, like coach@example.com.")
        let byEmail = try await XCTUnwrapAsync(await team.invite(email: " dad@example.com ", app: app))
        XCTAssertEqual(byEmail.invite.email, "dad@example.com")
        let link = try await XCTUnwrapAsync(await team.invite(email: nil, app: app))
        XCTAssertNil(link.invite.email)
        XCTAssertEqual(ScorebugLink(string: link.link), .teamInvite(code: link.code.replacingOccurrences(of: "-", with: "")))
        XCTAssertEqual(team.issued, link)
        XCTAssertTrue(team.shareText(link).contains(link.link))
        XCTAssertEqual(team.invites.count, 2)

        await team.revoke(team.invites[0], app: app)
        XCTAssertEqual(team.invites.count, 1)

        let renamed = await team.rename("Cascade 14 Black Elite", app: app)
        XCTAssertTrue(renamed)
        XCTAssertEqual(team.detail?.team.name, "Cascade 14 Black Elite")
        XCTAssertEqual(app.teams.first?.name, "Cascade 14 Black Elite", "Home sees the new name")

        await team.remove(team.members[1], app: app)
        XCTAssertEqual(team.members.map(\.email), ["jd@example.com"])
    }

    func testTheOnlyOwnerCannotLeave() async {
        let team = makeTeam()
        await team.load(app)
        let left = await team.leave(app: app)
        XCTAssertFalse(left)
        XCTAssertEqual(team.error, "A team needs an owner, so its only owner can't leave or be removed.")
    }

    func testAMemberSeesNoInvitesAndCanLeave() async throws {
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-coach", role: .owner)
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-jd", role: .member)
        await app.refreshMe()
        let server = server!
        let team = TeamModel(teamId: "t2", clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) })
        await team.load(app)
        XCTAssertFalse(team.isOwner)
        XCTAssertNil(team.detail?.invites)
        let left = await team.leave(app: app)
        XCTAssertTrue(left)
        XCTAssertFalse(app.teams.contains { $0.id == "t2" })
    }
}

@MainActor final class InviteModelTests: XCTestCase {
    func testInviteGivesCodeLinkAndShareTextForTeamMembersOnly() async throws {
        let server = FakeScorebugServer()
        await server.signedIn("jd@example.com", token: "session", team: "t1")
        await server.addMatch(makeSnapshot(), team: "t1")
        let model = InviteModel(clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) })
        let session = MatchSession(kind: .filming, endpoint: "https://scorebug.live",
                                   credential: MatchCredential(gameId: "m1", deviceId: "d", role: .score, token: "t"),
                                   recordOnly: false, layout: CourtLayout(), startedAt: Date(), teamId: "t1")
        await model.create(session: session, access: nil)
        XCTAssertEqual(model.error, "Only a team member's phone can invite scorers.")
        await model.create(session: session, access: TeamAccess(endpoint: "https://scorebug.live", token: "session", teamId: "t1", deviceId: "d"))
        XCTAssertEqual(model.invite?.code, "K7P-4QX")
        XCTAssertTrue(model.shareText?.contains("https://scorebug.live/join/K7P4QX") == true)
        XCTAssertTrue(model.shareText?.contains("K7P-4QX") == true)
        let path = await server.requests.last?.path
        XCTAssertEqual(path, "/v1/teams/t1/matches/m1/invites")
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

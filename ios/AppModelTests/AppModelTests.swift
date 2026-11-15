import Foundation
import ScorebugCore
import XCTest

@MainActor final class AppModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var store: MemorySecureStore!
    private var defaults: UserDefaults!
    private var ids: [String] = []

    override func setUp() async throws {
        server = FakeScorebugServer()
        store = MemorySecureStore()
        defaults = UserDefaults(suiteName: "scorebug.tests.\(UUID().uuidString)")!
        ids = (1...20).map { "00000000-0000-4000-8000-\(String(format: "%012d", $0))" }
    }

    private func factory() -> AppModel.ClientFactory {
        let server = server!
        return { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) }
    }

    private func makeApp() -> AppModel {
        AppModel(store: store, preferences: AppPreferences(defaults: defaults), clientFactory: factory(),
                 deviceName: { "JD's iPhone" }, newID: { [unowned self] in ids.removeFirst() })
    }

    private let setupLink = "scorebug://connect?server=https%3A%2F%2Fscore.example.com&code=setup-code-123456789012"

    // MARK: Enrollment

    func testFirstLaunchShowsConnectAndALinkNeedsConfirmation() async {
        let app = makeApp()
        XCTAssertEqual(app.route, .connect)
        XCTAssertTrue(app.open(setupLink))
        XCTAssertNotNil(app.pendingLink, "a link never connects without the person confirming")
        XCTAssertNil(app.config)
        await app.confirmPendingLink()
        XCTAssertEqual(app.route, .home)
        XCTAssertEqual(app.config?.endpoint, "https://score.example.com")
        XCTAssertEqual(app.config?.ownerToken, "owner-00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(app.config?.deviceName, "JD's iPhone")
        XCTAssertEqual(try store.value(ServerConfig.self, for: StoreKey.server), app.config, "kept in the Keychain")

        let relaunched = makeApp()
        XCTAssertEqual(relaunched.route, .home)
        XCTAssertEqual(relaunched.config, app.config)
    }

    func testLostEnrollmentReplyRetriesWithTheSameDeviceID() async {
        let app = makeApp()
        await server.set(dropNextReply: true)
        let first = await app.enroll(server: try! ScoringEndpoint("https://score.example.com"), code: "setup-code-123456789012")
        XCTAssertFalse(first)
        XCTAssertNotNil(app.error)
        let second = await app.enroll(server: try! ScoringEndpoint("https://score.example.com"), code: "setup-code-123456789012")
        XCTAssertTrue(second, String(describing: app.error))
        XCTAssertEqual(app.config?.deviceId, "00000000-0000-4000-8000-000000000001")
    }

    func testManualEnrollmentAddsHTTPSAndExplainsBadCodes() async {
        let app = makeApp()
        let ok = await app.enroll(address: "score.example.com", code: "setup-code-1234 56789012")
        XCTAssertTrue(ok, String(describing: app.error))
        XCTAssertEqual(app.config?.endpoint, "https://score.example.com")

        let other = AppModel(store: MemorySecureStore(), preferences: AppPreferences(defaults: defaults), clientFactory: factory(),
                             deviceName: { "x" })
        let bad = await other.enroll(address: "score.example.com", code: "not-a-real-code-000000")
        XCTAssertFalse(bad)
        XCTAssertEqual(other.error, "That setup code isn't valid. Check it, or make a new link on the server.")
        let empty = await other.enroll(address: "http://public.example.com", code: "setup-code-123456789012")
        XCTAssertFalse(empty)
        XCTAssertEqual(other.error, "Enter the server address, like https://scorebug.example.com.")
    }

    func testNonScorebugTextIsNotALink() {
        XCTAssertFalse(makeApp().open("https://example.com"))
    }

    // MARK: Joining by invite

    func testJoinLinkOnAFreshPhoneOpensTheScorer() async throws {
        await server.addMatch(makeSnapshot(scorer: "filming-phone"))
        await server.addInvite(code: "K7P4QX", gameId: "m1")
        let app = makeApp()
        XCTAssertTrue(app.open("scorebug://join?server=https%3A%2F%2Fscore.example.com&code=k7p-4qx"))
        await app.confirmPendingLink()
        guard case .scoring(let session) = app.route else { return XCTFail("\(app.route) \(String(describing: app.error))") }
        XCTAssertEqual(session.credential.role, .score)
        XCTAssertEqual(session.credential.gameId, "m1")
        XCTAssertEqual(session.endpoint, "https://score.example.com")
        XCTAssertFalse(app.config?.isOwner ?? true, "an invite never makes this phone an owner")

        app.finish(lastSnapshot: nil)
        XCTAssertEqual(app.route, .connect, "a scorer-only phone goes back to Connect")
    }

    func testBareCodeNeedsAKnownServer() async {
        let app = makeApp()
        let joined = await app.join(text: "K7P-4QX")
        XCTAssertFalse(joined)
        XCTAssertTrue(app.error?.contains("Scan the invite") == true)
        let nonsense = await app.join(text: "hello")
        XCTAssertFalse(nonsense)
    }

    func testBareCodeUsesTheConnectedServer() async {
        await server.addMatch(makeSnapshot(scorer: "filming-phone"))
        await server.addInvite(code: "K7P4QX", gameId: "m1")
        let app = makeApp()
        _ = await app.enroll(address: "https://score.example.com", code: "setup-code-123456789012")
        let joined = await app.join(text: "k7p 4qx")
        XCTAssertTrue(joined, String(describing: app.error))
        guard case .scoring = app.route else { return XCTFail() }
        app.finish(lastSnapshot: nil)
        XCTAssertEqual(app.route, .home)
    }

    func testEndedMatchInviteExplainsItself() async {
        await server.addMatch(makeSnapshot(status: .ended))
        await server.addInvite(code: "K7P4QX", gameId: "m1")
        let app = makeApp()
        _ = await app.join(text: "scorebug://join?server=https%3A%2F%2Fscore.example.com&code=K7P4QX")
        XCTAssertEqual(app.error, "That match has ended.")
    }

    // MARK: Sessions

    func testSessionSurvivesRelaunchAndLayoutIsSaved() async {
        let app = makeApp()
        _ = await app.enroll(address: "https://score.example.com", code: "setup-code-123456789012")
        let credential = MatchCredential(gameId: "m1", deviceId: "d", role: .score, token: "t")
        app.begin(MatchSession(kind: .filming, endpoint: "https://score.example.com", credential: credential,
                               recordOnly: false, layout: CourtLayout(), startedAt: Date()))
        var swapped = CourtLayout(); swapped.swap()
        app.saveLayout(swapped)
        let relaunched = makeApp()
        guard case .filming(let session) = relaunched.route else { return XCTFail() }
        XCTAssertEqual(session.layout.leftTeam, .team2)

        relaunched.finish(lastSnapshot: makeSnapshot(home: 15, away: 12, set: 3, homeSets: 2, awaySets: 1, status: .ended))
        XCTAssertEqual(relaunched.route, .home)
        XCTAssertEqual(relaunched.preferences.lastMatch?.title, "CASCADE 2–1 SUMMIT")
        XCTAssertNil(try store.value(MatchSession.self, for: StoreKey.session))
    }

    // MARK: Home

    func testHomeStatusLine() async {
        let app = makeApp()
        _ = await app.enroll(address: "https://score.example.com", code: "setup-code-123456789012")
        let home = HomeModel(clientFactory: factory())
        await home.refresh(app.config)
        XCTAssertEqual(home.detail, "connected · YouTube ready")
        await server.setDestinations([])
        await home.refresh(app.config)
        XCTAssertEqual(home.detail, "connected")
        var revoked = app.config!; revoked.ownerToken = "nope"
        await home.refresh(revoked)
        XCTAssertEqual(home.connection, .rejected)
        await server.set(failNextWith: .cannotConnectToHost)
        await home.refresh(app.config)
        XCTAssertEqual(home.detail, "not reachable")
    }
}

@MainActor final class InviteModelTests: XCTestCase {
    func testInviteGivesCodeLinkAndShareText() async throws {
        let server = FakeScorebugServer()
        await server.registerOwner(token: "owner", deviceId: "d")
        await server.addMatch(makeSnapshot())
        let model = InviteModel(clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) })
        let session = MatchSession(kind: .filming, endpoint: "https://score.example.com",
                                   credential: MatchCredential(gameId: "m1", deviceId: "d", role: .score, token: "t"),
                                   recordOnly: false, layout: CourtLayout(), startedAt: Date())
        await model.create(session: session, ownerToken: nil)
        XCTAssertEqual(model.error, "Only the phone that started the match can invite scorers.")
        await model.create(session: session, ownerToken: "owner")
        XCTAssertEqual(model.invite?.code, "K7P-4QX")
        XCTAssertTrue(model.shareText?.contains("scorebug://join?") == true)
        XCTAssertTrue(model.shareText?.contains("K7P-4QX") == true)
    }

    func testUnknownInviteCodeSaysSo() async {
        let server = FakeScorebugServer()
        let app = AppModel(store: MemorySecureStore(), preferences: AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                           clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) },
                           deviceName: { "x" })
        _ = await app.join(text: "scorebug://join?server=https%3A%2F%2Fscore.example.com&code=ZZZZZZ")
        XCTAssertEqual(app.error, "That invite code didn't work. Check it and try again.")
    }
}

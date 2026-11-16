import Foundation
import ScorebugCore
import XCTest

@MainActor final class YouTubeModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var app: AppModel!
    private var browser: FakeSignInBrowser!

    override func setUp() async throws {
        server = FakeScorebugServer()
        let server = server!
        await server.addTeam("t1", name: "Cascade 14 Black", member: "p-jd", role: .owner)
        browser = FakeSignInBrowser(server: server)
        app = AppModel(store: MemorySecureStore(), preferences: AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                       server: try ScoringEndpoint("https://scorebug.live"), clientFactory: factory(), browser: browser,
                       deviceName: { "Phone" })
        await app.signIn()
    }

    private func factory() -> AppModel.ClientFactory {
        let server = server!
        return { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) }
    }

    private func makeTeam(_ id: String = "t1") -> TeamModel { TeamModel(teamId: id, clientFactory: factory()) }

    // MARK: Connecting a channel

    func testConnectingAChannelClaimsItAndMakesItTheTeamChannel() async throws {
        let team = makeTeam()
        await team.load(app)
        XCTAssertNil(team.channel)
        await team.connectChannel(app: app)
        XCTAssertNil(team.error)
        XCTAssertEqual(team.channel?.channelTitle, "Wildcats Volleyball")
        XCTAssertEqual(team.channel?.status, .ready)
        XCTAssertTrue(team.ownsChannel(app))
        XCTAssertEqual(team.connections.map(\.channelTitle), ["Wildcats Volleyball"])
        let opened = try XCTUnwrap(browser.opened.last)
        XCTAssertEqual(opened.host, "accounts.google.test", "the app opens the URL the Worker returned")
        let claims = await server.requests.filter { $0.path == "/v1/youtube/connections" && $0.method == "POST" }
        XCTAssertEqual((claims.first?.body?["ticket"] as? String)?.count, 43)
    }

    func testReconnectKeepsTheSameConnection() async {
        await server.addChannel("c1", title: "Wildcats Volleyball", by: "jd@example.com", team: "t1", status: .needsReconnect)
        let team = makeTeam()
        await team.load(app)
        XCTAssertEqual(team.channel?.status, .needsReconnect)
        await team.connectChannel(app: app)
        XCTAssertEqual(team.channel?.connectionId, "c1")
        XCTAssertEqual(team.channel?.status, .ready)
    }

    func testCancelledOrRefusedConnectExplainsItself() async {
        browser.email = nil
        let team = makeTeam()
        await team.load(app)
        await team.connectChannel(app: app)
        XCTAssertNil(team.error, "closing the sheet is not an error")
        browser.email = "jd@example.com"
        await server.setNextChannel(nil)
        await team.connectChannel(app: app)
        XCTAssertEqual(team.error, "That Google account has no YouTube channel. Create one on YouTube, or pick another account.")
        XCTAssertNil(team.channel)
    }

    func testScopeDeniedCallback() async throws {
        XCTAssertEqual(YouTubeCallback(url: URL(string: "scorebug://auth?purpose=youtube&status=scope_denied")!), .scopeDenied)
    }

    func testOwnerPicksClearsAndRechecksTheChannel() async {
        await server.addChannel("c1", title: "Wildcats Volleyball", by: "jd@example.com", status: .liveDisabled)
        await server.addChannel("c2", title: "JD Conley", by: "jd@example.com")
        let team = makeTeam()
        await team.load(app)
        XCTAssertEqual(team.connections.map(\.id), ["c1", "c2"])
        await team.choose(team.connections[0], app: app)
        XCTAssertEqual(team.channel?.status, .liveDisabled)
        await team.checkChannel(app: app)
        XCTAssertEqual(team.channel?.status, .ready, "after YouTube's wait, Check again clears it")
        await team.choose(nil, app: app)
        XCTAssertNil(team.channel)
    }

    func testAMemberSeesTheChannelButCannotChangeIt() async {
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-coach", role: .owner)
        await server.addTeam("t2", name: "Summit 14 Red", member: "p-jd", role: .member)
        await server.addChannel("c9", title: "Summit Club", by: "coach@example.com", team: "t2", status: .needsReconnect)
        let team = makeTeam("t2")
        await team.load(app)
        XCTAssertEqual(team.channel?.channelTitle, "Summit Club")
        XCTAssertFalse(team.ownsChannel(app))
        XCTAssertTrue(team.connections.isEmpty, "members never load connections")
        await team.choose(nil, app: app)
        XCTAssertEqual(team.error, "Only a team owner can do that.")
    }

    // MARK: New match and Home

    func testNewMatchSaysWhyGoLiveIsOff() async {
        let access = TeamAccess(endpoint: "https://scorebug.live", token: app.account!.token, teamId: "t1", deviceId: "d1")
        let team = Team(id: "t1", name: "Cascade 14 Black", shortName: "CASCADE", color: "#2563EB")
        func model(owner: Bool) async -> NewMatchModel {
            let model = NewMatchModel(team: team, isOwner: owner, access: access,
                                      preferences: AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                      clientFactory: factory())
            await model.loadChannel()
            return model
        }
        let unset = await model(owner: true)
        XCTAssertEqual(unset.goLiveBlocked, "Connect a YouTube channel on the team screen to go live.")
        XCTAssertEqual(unset.streamLabel, "No channel")
        let member = await model(owner: false)
        XCTAssertEqual(member.goLiveBlocked, "Your team owner hasn't picked a YouTube channel yet.")

        await server.addChannel("c1", title: "Wildcats Volleyball", by: "jd@example.com", team: "t1", status: .needsReconnect)
        let reconnect = await model(owner: false)
        XCTAssertEqual(reconnect.goLiveBlocked, "Ask your team owner to reconnect YouTube.")
        await server.setChannelStatus("c1", .liveDisabled)
        let waiting = await model(owner: true)
        XCTAssertEqual(waiting.goLiveBlocked, "Wildcats Volleyball can't live stream yet. YouTube makes new channels wait 24 hours.")
        await server.setChannelStatus("c1", .ready)
        let ready = await model(owner: true)
        XCTAssertNil(ready.goLiveBlocked)
        XCTAssertEqual(ready.streamLabel, "Wildcats Volleyball")
    }

    func testHomeShowsChannelsAndTheOpenMatchWatchLink() async throws {
        await server.addChannel("c1", title: "Wildcats Volleyball", by: "jd@example.com", team: "t1")
        await server.addMatch(makeSnapshot(id: "m1"), team: "t1")
        let link = MatchYouTube(broadcastId: "abc123", watchUrl: "https://www.youtube.com/watch?v=abc123",
                                channelTitle: "Wildcats Volleyball", channelThumbnail: nil, privacy: "unlisted")
        await server.setWatchLink("m1", link)
        let home = HomeModel(clientFactory: factory())
        await home.refresh(app)
        XCTAssertEqual(home.channels["t1"]??.channelTitle, "Wildcats Volleyball")
        XCTAssertEqual(home.watchLinks["t1"], link)
    }

    // MARK: The match's watch link

    func testWatchLinkAppearsAfterTheFirstGoLive() async throws {
        await server.addMatch(makeSnapshot(id: "m1"), team: "t1")
        let credential = await server.issueCredential(gameId: "m1", deviceId: "d1", role: .score)
        let session = MatchSession(kind: .filming, endpoint: "https://scorebug.live", credential: credential,
                                   recordOnly: false, layout: CourtLayout(), startedAt: Date(), teamId: "t1")
        let model = WatchLinkModel(clientFactory: factory())
        let watching = Task { await model.watch(session, every: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(model.url, "no link before Go Live")
        await server.setWatchLink("m1", MatchYouTube(broadcastId: "abc123", watchUrl: "https://www.youtube.com/watch?v=abc123",
                                                     channelTitle: "Wildcats", channelThumbnail: nil, privacy: "unlisted"))
        await watching.value
        XCTAssertEqual(model.url?.absoluteString, "https://www.youtube.com/watch?v=abc123")
        XCTAssertEqual(model.shareText(teams: "Cascade vs Summit"),
                       "Watch Cascade vs Summit live on YouTube: https://www.youtube.com/watch?v=abc123")
        let reads = await server.requests.filter { $0.path == "/v1/matches/m1" }.count
        model.found(MatchYouTube(broadcastId: "other", watchUrl: "https://www.youtube.com/watch?v=other",
                                 channelTitle: "W", channelThumbnail: nil, privacy: "unlisted"))
        XCTAssertEqual(model.youtube?.broadcastId, "abc123", "the link never changes within a match")
        XCTAssertGreaterThan(reads, 1)
    }

    func testGoLiveRefusalsReadPlainly() {
        let cases: [(String, String)] = [
            ("youtube_not_set", "Your team has no YouTube channel yet, so this match can't go live. Recording continues."),
            ("youtube_needs_reconnect", "YouTube needs reconnecting. Ask your team owner to reconnect it. Recording continues."),
            ("youtube_live_disabled", "This YouTube channel can't live stream yet. YouTube makes new channels wait 24 hours. Recording continues."),
            ("youtube_unavailable", "YouTube isn't answering right now. Try going live again in a minute. Recording continues."),
            ("stream_unavailable", "Scorebug couldn't start the stream. Try going live again. Recording continues."),
            ("container_unavailable", "Scorebug couldn't start the stream. Try going live again. Recording continues."),
            ("busy", "Scorebug is busy, try again shortly. Recording continues."),
            ("time_limit", "This match reached the 4-hour streaming limit. Recording continues."),
        ]
        for (code, message) in cases { XCTAssertEqual(CaptureControlError(rejection: code).goLiveMessage, message, code) }
        XCTAssertNil(CaptureControlError(rejection: "something_else").goLiveMessage)
    }
}

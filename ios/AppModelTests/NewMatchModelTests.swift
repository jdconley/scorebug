import Foundation
import ScorebugCore
import XCTest

@MainActor final class NewMatchModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var preferences: AppPreferences!
    private let access = TeamAccess(endpoint: "https://scorebug.live", token: "session", teamId: "t1", deviceId: "d1")
    private let team = Team(id: "t1", name: "Cascade 14 Black", shortName: "CASCADE", color: "#2563EB")

    override func setUp() async throws {
        server = FakeScorebugServer()
        await server.signedIn("jd@example.com", token: "session", team: "t1")
        preferences = AppPreferences(defaults: UserDefaults(suiteName: "scorebug.tests.\(UUID().uuidString)")!)
    }

    private func makeModel(ids: [String] = ["m1", "m2", "m3"]) -> NewMatchModel {
        var ids = ids
        let server = server!
        return NewMatchModel(team: team, access: access, preferences: preferences,
                             clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) },
                             newID: { ids.removeFirst() })
    }

    private func fill(_ model: NewMatchModel) {
        model.draft.team2.setName("Summit 14 Red")
    }

    func testTeam1StartsAsThisTeamAndTeam2MustBeNamed() async {
        let model = makeModel()
        XCTAssertEqual(model.draft.team1.name, "Cascade 14 Black")
        XCTAssertEqual(model.draft.team1.color, "#2563eb")
        XCTAssertFalse(model.canStart)
        let session = await model.start(recordOnly: false)
        XCTAssertNil(session)
        XCTAssertEqual(model.error, "Enter a name for Team 2.")
        fill(model)
        XCTAssertTrue(model.canStart)
        XCTAssertEqual(model.draft.team1.shortName, "CASCADE")
        XCTAssertEqual(model.draft.team2.shortName, "SUMMIT")
    }

    func testGoLiveCreatesTheTeamMatchWithTeam1AsHome() async throws {
        let model = makeModel()
        fill(model)
        model.draft.style = .lowerThird
        model.draft.format = .bestOf5
        let sessionValue = await model.start(recordOnly: false)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(session.kind, .filming)
        XCTAssertFalse(session.recordOnly)
        XCTAssertEqual(session.credential.gameId, "m1")
        XCTAssertEqual(session.teamId, "t1")
        let created = await server.requests.first { $0.method == "POST" && $0.path.hasSuffix("/matches") }?.path
        XCTAssertEqual(created, "/v1/teams/t1/matches")
        let bodies = await server.creationBodies
        let body = try XCTUnwrap(bodies.last)
        let teams = body["teams"] as? [String: [String: String]]
        XCTAssertEqual(teams?["home"]?["name"], "Cascade 14 Black")
        XCTAssertEqual(teams?["away"]?["shortName"], "SUMMIT")
        XCTAssertEqual(body["scorebugStyle"] as? String, "lowerThird")
        XCTAssertEqual((body["rules"] as? [String: Any])?["bestOf"] as? Int, 5)
        XCTAssertNil(body["recordOnly"])
    }

    func testRecordOnlyAndRememberedDraft() async throws {
        let model = makeModel()
        fill(model)
        model.draft.team2.color = "#16a34a"
        model.draft.recordIn4K = true
        let sessionValue = await model.start(recordOnly: true)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertTrue(session.recordOnly)
        let bodies = await server.creationBodies
        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body["recordOnly"] as? Bool, true)

        let next = makeModel()
        XCTAssertEqual(next.draft.team1.name, "Cascade 14 Black")
        XCTAssertEqual(next.draft.team2.name, "Summit 14 Red", "the last opponent is remembered")
        XCTAssertEqual(next.draft.team2.color, "#16a34a")
        XCTAssertTrue(next.draft.recordIn4K)
    }

    func testAnotherTeamReplacesTeam1() async {
        var draft = NewMatchDraft()
        draft.team1.setName("Summit 14 Red"); draft.team2.setName("Cascade 14 Black")
        preferences.lastDraft = draft
        let model = makeModel()
        XCTAssertEqual(model.draft.team1.name, "Cascade 14 Black")
        XCTAssertEqual(model.draft.team2.name, "", "the team doesn't play itself")
    }

    func testLostCreateReplyRecoversTheSameMatch() async throws {
        let model = makeModel()
        fill(model)
        await server.set(dropNextReply: true)
        let first = await model.start(recordOnly: false)
        XCTAssertNil(first)
        let secondValue = await model.start(recordOnly: false)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.credential.gameId, "m1", "the retry reuses the first match ID")
        XCTAssertFalse(model.otherMatchOpen)
    }

    func testLeftoverMatchCanBeClosed() async throws {
        await server.addMatch(makeSnapshot(scorer: "someone-else"), team: "t1")
        let model = makeModel(ids: ["m9"])
        fill(model)
        let blocked = await model.start(recordOnly: false)
        XCTAssertNil(blocked)
        XCTAssertTrue(model.otherMatchOpen)
        await model.closeOtherMatch()
        XCTAssertFalse(model.otherMatchOpen, String(describing: model.error))
        let ended = await server.snapshot("m1")
        XCTAssertEqual(ended?.status, .ended)
        let sessionValue = await model.start(recordOnly: false)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(session.credential.gameId, "m9")
    }
}

import Foundation
import ScorebugCore
import XCTest

@MainActor final class NewMatchModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var preferences: AppPreferences!
    private let config = ServerConfig(endpoint: "https://score.example.com", ownerToken: "owner-d1", deviceId: "d1", deviceName: "Phone")

    override func setUp() async throws {
        server = FakeScorebugServer()
        await server.registerOwner(token: "owner-d1", deviceId: "d1")
        preferences = AppPreferences(defaults: UserDefaults(suiteName: "scorebug.tests.\(UUID().uuidString)")!)
    }

    private func makeModel(ids: [String] = ["m1", "m2", "m3"]) -> NewMatchModel {
        var ids = ids
        let server = server!
        return NewMatchModel(config: config, preferences: preferences,
                             clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) },
                             newID: { ids.removeFirst() })
    }

    private func fill(_ model: NewMatchModel) {
        model.draft.team1.setName("Cascade 14 Black")
        model.draft.team2.setName("Summit 14 Red")
    }

    func testCannotStartUntilBothTeamsAreNamed() async {
        let model = makeModel()
        XCTAssertFalse(model.canStart)
        let session = await model.start(recordOnly: false)
        XCTAssertNil(session)
        XCTAssertEqual(model.error, "Enter a name for Team 1.")
        fill(model)
        XCTAssertTrue(model.canStart)
        XCTAssertEqual(model.draft.team1.shortName, "CASCADE")
        XCTAssertEqual(model.draft.team2.shortName, "SUMMIT")
    }

    func testGoLiveCreatesTheMatchWithTeam1AsHomeAndTheChosenDestination() async throws {
        let model = makeModel()
        await model.loadDestinations()
        XCTAssertEqual(model.streamLabel, "YouTube")
        fill(model)
        model.draft.style = .lowerThird
        model.draft.format = .bestOf5
        let sessionValue = await model.start(recordOnly: false)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(session.kind, .filming)
        XCTAssertFalse(session.recordOnly)
        XCTAssertEqual(session.credential.gameId, "m1")
        let bodies = await server.creationBodies
        let body = try XCTUnwrap(bodies.last)
        let teams = body["teams"] as? [String: [String: String]]
        XCTAssertEqual(teams?["home"]?["name"], "Cascade 14 Black")
        XCTAssertEqual(teams?["away"]?["shortName"], "SUMMIT")
        XCTAssertEqual(body["scorebugStyle"] as? String, "lowerThird")
        XCTAssertEqual((body["rules"] as? [String: Any])?["bestOf"] as? Int, 5)
        XCTAssertNil(body["destinationId"], "nil means the server default")
        XCTAssertNil(body["recordOnly"])
    }

    func testRecordOnlyAndRememberedDraft() async throws {
        let model = makeModel()
        await model.loadDestinations()
        fill(model)
        model.draft.team2.color = "#16a34a"
        model.chooseDestination(model.destinations[0])
        model.draft.recordIn4K = true
        let sessionValue = await model.start(recordOnly: true)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertTrue(session.recordOnly)
        let bodies = await server.creationBodies
        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body["recordOnly"] as? Bool, true)
        XCTAssertNil(body["destinationId"])

        let next = makeModel()
        XCTAssertEqual(next.draft.team1.name, "Cascade 14 Black")
        XCTAssertEqual(next.draft.team2.color, "#16a34a")
        XCTAssertEqual(next.draft.destinationId, "yt")
        XCTAssertTrue(next.draft.recordIn4K)
    }

    func testDeletedRememberedDestinationFallsBackToDefault() async {
        var draft = NewMatchDraft(destinationId: "gone")
        draft.team1.setName("A"); draft.team2.setName("B")
        preferences.lastDraft = draft
        let model = makeModel()
        await model.loadDestinations()
        XCTAssertNil(model.draft.destinationId)
        XCTAssertEqual(model.streamDestination?.id, "yt")
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
        await server.addMatch(makeSnapshot(scorer: "someone-else"))
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

extension FakeScorebugServer {
    func registerOwner(token: String, deviceId: String) { ownerTokens[token] = deviceId }
}

import Foundation
import ScorebugCore
import XCTest

@MainActor final class ScoreboardModelTests: XCTestCase {
    private var server: FakeScorebugServer!
    private var feedback: [ScoreboardModel.Feedback] = []
    private var savedLayouts: [CourtLayout] = []

    override func setUp() async throws {
        server = FakeScorebugServer()
        feedback = []; savedLayouts = []
    }

    private func makeBoard(scorer: String = "phone", kind: MatchSession.Kind = .filming, takeOver: Bool = false,
                           snapshot: MatchSnapshot? = nil) async -> ScoreboardModel {
        await server.addMatch(snapshot ?? makeSnapshot(scorer: scorer))
        let credential = await server.issueCredential(gameId: "m1", deviceId: "phone", role: .score)
        let server = server!
        let session = MatchSession(kind: kind, endpoint: "https://score.example.com", credential: credential,
                                   recordOnly: false, layout: CourtLayout(), startedAt: Date())
        let client = MatchHTTPClient(endpoint: try! ScoringEndpoint(session.endpoint), transport: { try await server.respond($0) })
        let board = ScoreboardModel(session: session, client: client, pendingStore: MemoryPendingCommandStore(), takeOverOnStart: takeOver)
        board.feedback = { [unowned self] in feedback.append($0) }
        board.onLayoutChange = { [unowned self] in savedLayouts.append($0) }
        await board.start()
        await board.drain()
        return board
    }

    private func settle(_ board: ScoreboardModel) async {
        for _ in 0..<50 { await Task.yield() }
        await board.drain()
    }

    func testTapHalvesScoreTheTeamOnThatSide() async {
        let board = await makeBoard()
        XCTAssertTrue(board.canScore)
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.home, 1, "Team 1 starts on the left")
        board.tap(.right)
        board.tap(.right)
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.away, 2)
        XCTAssertEqual(feedback.filter { $0 == .point }.count, 3, "a haptic per point")
        let operations = await server.operations("m1")
        XCTAssertEqual(operations, ["award_point", "award_point", "award_point"])
    }

    func testSwapSidesFlipsWhichTeamEachHalfScores() async {
        let board = await makeBoard()
        board.swapSides()
        XCTAssertEqual(board.team(on: .left), .team2)
        XCTAssertEqual(savedLayouts.last?.leftTeam, .team2, "saved so a relaunch keeps the sides")
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.away, 1)
        XCTAssertEqual(board.snapshot?.score.home, 0)
    }

    func testUndoRemovesTheLastPoint() async {
        let board = await makeBoard()
        XCTAssertFalse(board.canUndo)
        board.tap(.left); board.tap(.left)
        await settle(board)
        XCTAssertTrue(board.canUndo)
        board.undo()
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.home, 1)
        XCTAssertTrue(feedback.contains(.undo))
    }

    func testSetPointConfirmEndsSetAndAsksAboutSwitchingSides() async {
        let board = await makeBoard()
        await server.force("m1", home: 24, away: 20)
        await board.poll()
        XCTAssertNil(board.flow.prompt)
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.flow.prompt?.title, "Cascade wins set 1?")
        XCTAssertEqual(board.flow.prompt?.confirmLabel, "End set")
        board.confirmSetEnd()
        XCTAssertNil(board.flow.prompt, "hidden right away")
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.set, 2)
        XCTAssertEqual(board.snapshot?.score.homeSets, 1)
        XCTAssertTrue(board.flow.asksToSwap)
        XCTAssertTrue(feedback.contains(.setEnded))
        board.answerSwap(true)
        XCTAssertFalse(board.flow.asksToSwap)
        XCTAssertEqual(board.team(on: .left), .team2)
    }

    func testAnsweringNoKeepsSides() async {
        let board = await makeBoard()
        await server.force("m1", home: 25, away: 20)
        await board.poll()
        board.confirmSetEnd()
        await settle(board)
        board.answerSwap(false)
        XCTAssertEqual(board.team(on: .left), .team1)
        XCTAssertFalse(board.flow.asksToSwap)
    }

    func testDecliningKeepsPlayingAndUndoFromPromptRemovesThePoint() async {
        let board = await makeBoard()
        await server.force("m1", home: 24, away: 22)
        await board.poll()
        board.tap(.left)
        await settle(board)
        XCTAssertNotNil(board.flow.prompt)
        board.declineSetEnd()
        await board.poll()
        XCTAssertNil(board.flow.prompt, "a poll doesn't bring a declined set point back")
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.flow.prompt?.scoreLine, "26 – 22")
        board.undoFromPrompt()
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.home, 25)
        XCTAssertEqual(board.snapshot?.score.set, 1, "no set was ended")
    }

    func testDecidingSetEndsTheMatch() async {
        let board = await makeBoard()
        await server.force("m1", home: 14, away: 12, set: 3, homeSets: 1, awaySets: 1)
        await board.poll()
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.flow.prompt?.confirmLabel, "End match")
        XCTAssertEqual(board.flow.prompt?.detail, "That makes it 2–1 in sets and ends the match.")
        board.confirmSetEnd()
        await settle(board)
        XCTAssertTrue(board.isEnded)
        XCTAssertFalse(board.flow.asksToSwap)
        let operations = await server.operations("m1")
        XCTAssertEqual(Array(operations.suffix(2)), ["end_set", "end_match"])
    }

    func testInvitedScorerTakesOverOnceAndTheFilmingPhoneCanTakeBack() async {
        let board = await makeBoard(scorer: "filming-phone", kind: .scoring, takeOver: true)
        await settle(board)
        XCTAssertTrue(board.ownsScoring)
        XCTAssertEqual(board.snapshot?.scorer.epoch, 2)

        let other = await makeBoard(scorer: "filming-phone", kind: .filming, takeOver: false)
        XCTAssertTrue(other.scoringElsewhere)
        other.tap(.left)
        XCTAssertEqual(other.problem, "Another device is scoring. Tap Take over to score here.")
        other.takeOver()
        await settle(other)
        XCTAssertTrue(other.ownsScoring)
    }

    /// The screens poll right after start(); that must not starve the queued take-over.
    func testTakeOverSurvivesAnImmediatePoll() async {
        await server.addMatch(makeSnapshot(scorer: "filming-phone"))
        let credential = await server.issueCredential(gameId: "m1", deviceId: "phone", role: .score)
        let server = server!
        let session = MatchSession(kind: .scoring, endpoint: "https://score.example.com", credential: credential,
                                   recordOnly: true, layout: CourtLayout(), startedAt: Date())
        let board = ScoreboardModel(session: session,
                                    client: MatchHTTPClient(endpoint: try! ScoringEndpoint(session.endpoint),
                                                            transport: { try await server.respond($0) }),
                                    pendingStore: MemoryPendingCommandStore(), takeOverOnStart: true)
        await board.start()
        async let polled: Void = board.poll()
        async let again: Void = board.poll()
        _ = await (polled, again)
        await settle(board)
        XCTAssertTrue(board.ownsScoring, String(describing: board.problem))
        XCTAssertNil(board.problem)
    }

    func testPollKeepsARejectionVisible() async {
        let board = await makeBoard()
        await server.force("m1", home: 3, away: 3)
        board.tap(.left)
        await settle(board)
        XCTAssertNotNil(board.problem)
        await board.poll()
        XCTAssertNotNil(board.problem, "only connection problems clear on a good poll")
    }

    func testRejectedChangeShowsAPlainMessage() async {
        let board = await makeBoard()
        // Someone else scored on the server since our last look.
        await server.force("m1", home: 3, away: 3)
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.problem, "The score changed on another device. Check it and try again.")
        XCTAssertTrue(feedback.contains(.problem))
    }

    func testOfflinePointIsCheckedThenSentWhenBack() async {
        let board = await makeBoard()
        await server.set(dropNextReply: true) // the point arrives, the reply is lost
        board.tap(.left)
        await settle(board)
        XCTAssertEqual(board.problem, "Can't reach the server. The last change will be checked and sent.")
        await board.poll()
        XCTAssertNil(board.problem)
        XCTAssertEqual(board.snapshot?.score.home, 1, "counted exactly once")
    }

    func testWatchIntentsDriveTheBoardAndMirrorCourtSides() async throws {
        let board = await makeBoard()
        var pushes = 0
        board.onChange = { pushes += 1 }
        board.handle(.point(.team2))
        await settle(board)
        board.handle(.swapSides)
        let state = try XCTUnwrap(board.watchState)
        XCTAssertEqual(state.left.slot, .team2)
        XCTAssertEqual(state.left.points, 1)
        XCTAssertTrue(state.canScore)
        XCTAssertGreaterThan(pushes, 0)
        board.handle(.undo)
        await settle(board)
        XCTAssertEqual(board.snapshot?.score.away, 0)
    }

    func testEndMatchFromTheEndButton() async {
        let board = await makeBoard()
        await board.endMatch()
        XCTAssertTrue(board.isEnded)
        XCTAssertEqual(board.snapshot?.endReason, "Ended by scorer")
    }
}

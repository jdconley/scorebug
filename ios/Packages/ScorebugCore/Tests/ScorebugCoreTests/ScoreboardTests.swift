import XCTest
@testable import ScorebugCore

func makeSnapshot(home: Int = 0, away: Int = 0, set: Int = 1, homeSets: Int = 0, awaySets: Int = 0,
                  completed: [MatchSetResult] = [], pending: MatchSide? = nil, status: MatchStatus = .active,
                  bestOf: Int = 3, revision: Int = 0, scorer: String = "phone", canUndo: Bool = false) -> MatchSnapshot {
    MatchSnapshot(id: "m1", createdAt: "2026-11-15T10:00:00.000Z", revision: revision,
                  teams: MatchTeams(home: MatchTeam(name: "Cascade", shortName: "CASCADE", color: "#2563eb"),
                                    away: MatchTeam(name: "Summit", shortName: "SUMMIT", color: "#f97316")),
                  rules: MatchRules(bestOf: bestOf, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil),
                  score: MatchScore(home: home, away: away, set: set, homeSets: homeSets, awaySets: awaySets),
                  completedSets: completed, status: status, endReason: nil, canUndo: canUndo,
                  scorer: MatchScorer(deviceId: scorer, epoch: 1),
                  broadcast: MatchBroadcast(desired: .running, generation: 1),
                  pendingSetEnd: pending.map(PendingSetEnd.init(winner:)))
}

final class ScoreboardTests: XCTestCase {
    func testCourtLayoutMapsSidesAndSwaps() {
        var layout = CourtLayout()
        XCTAssertEqual(layout.team(on: .left), .team1)
        XCTAssertEqual(layout.team(on: .right), .team2)
        XCTAssertEqual(layout.side(of: .team2), .right)
        layout.swap()
        XCTAssertEqual(layout.team(on: .left), .team2)
        XCTAssertEqual(layout.team(on: .right), .team1)
        XCTAssertEqual(layout.side(of: .team1), .right)
        XCTAssertEqual(layout.team(on: .left).side, .away)
        layout.swap()
        XCTAssertEqual(layout, CourtLayout())
    }

    func testSetPointPromptWording() throws {
        let prompt = try XCTUnwrap(SetPointPrompt(snapshot: makeSnapshot(home: 25, away: 22, pending: .home)))
        XCTAssertEqual(prompt.title, "Cascade wins set 1?")
        XCTAssertEqual(prompt.scoreLine, "25 – 22")
        XCTAssertEqual(prompt.detail, "That makes it 1–0 in sets.")
        XCTAssertEqual(prompt.confirmLabel, "End set")
        XCTAssertFalse(prompt.decidesMatch)

        let decider = try XCTUnwrap(SetPointPrompt(snapshot: makeSnapshot(home: 12, away: 15, set: 3, homeSets: 1, awaySets: 1, pending: .away)))
        XCTAssertEqual(decider.title, "Summit wins set 3?")
        XCTAssertEqual(decider.scoreLine, "15 – 12")
        XCTAssertEqual(decider.detail, "That makes it 2–1 in sets and ends the match.")
        XCTAssertEqual(decider.confirmLabel, "End match")
        XCTAssertTrue(decider.decidesMatch)

        XCTAssertNil(SetPointPrompt(snapshot: makeSnapshot(home: 24, away: 22)))
        XCTAssertNil(SetPointPrompt(snapshot: makeSnapshot(home: 25, away: 22, pending: .home, status: .ended)))
    }

    func testDecliningHidesThatSetPointUntilScoreMoves() {
        var flow = SetPointFlow()
        flow.observe(makeSnapshot(home: 24, away: 20))
        XCTAssertNil(flow.prompt)
        flow.observe(makeSnapshot(home: 25, away: 20, pending: .home))
        XCTAssertNotNil(flow.prompt)
        flow.decline()
        XCTAssertNil(flow.prompt)
        flow.observe(makeSnapshot(home: 25, away: 20, pending: .home)) // same score, e.g. a poll
        XCTAssertNil(flow.prompt)
        flow.observe(makeSnapshot(home: 26, away: 20, pending: .home)) // they kept playing
        XCTAssertEqual(flow.prompt?.scoreLine, "26 – 20")
        flow.decline()
        flow.observe(makeSnapshot(home: 25, away: 20, pending: .home)) // undo back to a declined score
        XCTAssertNotNil(flow.prompt, "a different set point than the one declined")
    }

    func testSetEndAsksToSwapUnlessMatchIsDecided() {
        var flow = SetPointFlow()
        flow.observe(makeSnapshot(home: 25, away: 20, pending: .home))
        XCTAssertFalse(flow.asksToSwap)
        let first = MatchSetResult(set: 1, home: 25, away: 20, winner: .home, overrideReason: nil)
        flow.observe(makeSnapshot(set: 2, homeSets: 1, completed: [first]))
        XCTAssertNil(flow.prompt)
        XCTAssertTrue(flow.asksToSwap)
        flow.answerSwap()
        XCTAssertFalse(flow.asksToSwap)

        let second = MatchSetResult(set: 2, home: 25, away: 23, winner: .home, overrideReason: nil)
        flow.observe(makeSnapshot(home: 25, away: 23, set: 2, homeSets: 2, completed: [first, second]))
        XCTAssertFalse(flow.asksToSwap, "no side switch once the match is decided")
    }

    func testUndoingASetEndClearsTheSwapQuestion() {
        var flow = SetPointFlow()
        let first = MatchSetResult(set: 1, home: 25, away: 20, winner: .home, overrideReason: nil)
        flow.observe(makeSnapshot(home: 25, away: 20, pending: .home))
        flow.observe(makeSnapshot(set: 2, homeSets: 1, completed: [first]))
        XCTAssertTrue(flow.asksToSwap)
        flow.observe(makeSnapshot(home: 25, away: 20, pending: .home))
        XCTAssertFalse(flow.asksToSwap)
        XCTAssertNotNil(flow.prompt)
    }

    func testFirstObservationNeverAsksToSwap() {
        var flow = SetPointFlow()
        let first = MatchSetResult(set: 1, home: 25, away: 20, winner: .home, overrideReason: nil)
        flow.observe(makeSnapshot(set: 2, homeSets: 1, completed: [first]))
        XCTAssertFalse(flow.asksToSwap)
    }

    func testMatchSummaryListsTeam1First() {
        let sets = [MatchSetResult(set: 1, home: 25, away: 21, winner: .home, overrideReason: nil),
                    MatchSetResult(set: 2, home: 19, away: 25, winner: .away, overrideReason: nil)]
        XCTAssertEqual(MatchSummary.setScores(makeSnapshot(completed: sets)), "25–21, 19–25")
    }

    func testWatchStateFollowsCourtSides() throws {
        var layout = CourtLayout()
        layout.swap()
        var flow = SetPointFlow()
        let snapshot = makeSnapshot(home: 25, away: 20, set: 2, homeSets: 1, pending: .home, canUndo: true)
        flow.observe(snapshot)
        let state = WatchRemote.State(snapshot: snapshot, layout: layout, flow: flow, isLive: true, canScore: true, busy: false, note: nil)
        XCTAssertEqual(state.left.slot, .team2)
        XCTAssertEqual(state.left.shortName, "SUMMIT")
        XCTAssertEqual(state.right.points, 25)
        XCTAssertEqual(state.header, "SET 2 · 0–1")
        XCTAssertEqual(state.prompt?.title, "Cascade wins set 2?")
        XCTAssertTrue(state.canUndo)

        let message = try WatchRemote.message(WatchRemote.Envelope(state: state, sentAt: 1))
        XCTAssertEqual(WatchRemote.decode(WatchRemote.Envelope.self, from: message)?.state, state)
    }

    func testWatchIntentsRoundTrip() throws {
        let intents: [WatchRemote.Intent] = [.hello, .point(.team1), .point(.team2), .undo, .swapSides,
                                             .confirmSetEnd, .declineSetEnd, .answerSwap(true), .answerSwap(false)]
        for intent in intents {
            XCTAssertEqual(WatchRemote.decode(WatchRemote.Intent.self, from: try WatchRemote.message(intent)), intent)
        }
        XCTAssertNil(WatchRemote.decode(WatchRemote.Intent.self, from: [WatchRemote.messageKey: Data(#"{"type":"nuke"}"#.utf8)]))
        XCTAssertNil(WatchRemote.decode(WatchRemote.Intent.self, from: ["other": 1]))
    }
}

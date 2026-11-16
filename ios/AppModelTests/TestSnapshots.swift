import Foundation
import ScorebugCore

func makeSnapshot(id: String = "m1", home: Int = 0, away: Int = 0, set: Int = 1, homeSets: Int = 0, awaySets: Int = 0,
                  completed: [MatchSetResult] = [], pending: MatchSide? = nil, status: MatchStatus = .active,
                  bestOf: Int = 3, revision: Int = 0, scorer: String = "phone", canUndo: Bool = false) -> MatchSnapshot {
    MatchSnapshot(id: id, createdAt: "2026-11-15T10:00:00.000Z", revision: revision,
                  teams: MatchTeams(home: MatchTeam(name: "Cascade", shortName: "CASCADE", color: "#2563eb"),
                                    away: MatchTeam(name: "Summit", shortName: "SUMMIT", color: "#f97316")),
                  rules: MatchRules(bestOf: bestOf, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil),
                  score: MatchScore(home: home, away: away, set: set, homeSets: homeSets, awaySets: awaySets),
                  completedSets: completed, status: status, endReason: nil, canUndo: canUndo,
                  scorer: MatchScorer(deviceId: scorer, epoch: 1),
                  broadcast: MatchBroadcast(desired: .running, generation: 1),
                  pendingSetEnd: pending.map(PendingSetEnd.init(winner:)))
}

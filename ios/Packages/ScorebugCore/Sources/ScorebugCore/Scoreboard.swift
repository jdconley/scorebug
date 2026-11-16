import Foundation

/// Which half of the picture, as filmed. Tapping a half scores for the team on that side.
public enum CourtSide: String, Codable, CaseIterable, Sendable {
    case left, right
    public var other: CourtSide { self == .left ? .right : .left }
}

/// Teams change ends between sets; this keeps tap halves matching the court.
/// The broadcast scorebug keeps its own fixed order (Team 1 first).
public struct CourtLayout: Codable, Equatable, Sendable {
    public private(set) var leftTeam: TeamSlot

    public init(leftTeam: TeamSlot = .team1) { self.leftTeam = leftTeam }

    public func team(on side: CourtSide) -> TeamSlot { side == .left ? leftTeam : leftTeam.other }
    public func side(of team: TeamSlot) -> CourtSide { team == leftTeam ? .left : .right }
    public mutating func swap() { leftTeam = leftTeam.other }
}

/// The confirm sheet shown when the server reports `pendingSetEnd`.
public struct SetPointPrompt: Equatable, Sendable {
    public let winner: TeamSlot
    public let winnerName: String
    public let set: Int
    public let winnerPoints: Int
    public let loserPoints: Int
    /// Sets won by (winner, other team) after this set.
    public let setsAfter: (winner: Int, other: Int)
    public let decidesMatch: Bool

    public init?(snapshot: MatchSnapshot) {
        guard snapshot.status == .active, let pending = snapshot.pendingSetEnd else { return nil }
        let winner = TeamSlot(pending.winner)
        self.winner = winner
        winnerName = snapshot.teams[winner].name
        set = snapshot.score.set
        winnerPoints = snapshot.score.points(winner)
        loserPoints = snapshot.score.points(winner.other)
        let setsToWin = (snapshot.rules.bestOf + 1) / 2
        setsAfter = (snapshot.score.sets(winner) + 1, snapshot.score.sets(winner.other))
        decidesMatch = setsAfter.winner >= setsToWin
    }

    public static func == (lhs: SetPointPrompt, rhs: SetPointPrompt) -> Bool {
        lhs.winner == rhs.winner && lhs.set == rhs.set && lhs.winnerPoints == rhs.winnerPoints
            && lhs.loserPoints == rhs.loserPoints && lhs.decidesMatch == rhs.decidesMatch
    }

    public var title: String { "\(winnerName) wins set \(set)?" }
    public var scoreLine: String { "\(winnerPoints) – \(loserPoints)" }
    public var detail: String {
        decidesMatch
            ? "That makes it \(setsAfter.winner)–\(setsAfter.other) in sets and ends the match."
            : "That makes it \(setsAfter.winner)–\(setsAfter.other) in sets."
    }
    public var confirmLabel: String { decidesMatch ? "End match" : "End set" }

    /// Identifies this exact set point, so declining it is remembered until the score moves.
    public var key: String { "\(set):\(winnerPoints):\(loserPoints):\(winner.rawValue)" }
}

/// Set point → confirm → "Teams switching sides?" as a small state machine shared
/// by the phone screens and the Watch mirror.
public struct SetPointFlow: Equatable, Sendable {
    public private(set) var prompt: SetPointPrompt?
    /// Shown after a set ends (here or on another device) while the match continues.
    public private(set) var asksToSwap = false
    private var declinedKey: String?
    private var completedSets: Int?

    public init() {}

    /// Feed every snapshot, in order.
    public mutating func observe(_ snapshot: MatchSnapshot) {
        let candidate = SetPointPrompt(snapshot: snapshot)
        if let candidate, candidate.key != declinedKey { prompt = candidate } else { prompt = nil }
        if candidate == nil { declinedKey = nil }
        let count = snapshot.completedSets.count
        if let previous = completedSets, count > previous, snapshot.status == .active, !Self.isDecided(snapshot) {
            asksToSwap = true
        }
        if let previous = completedSets, count < previous { asksToSwap = false } // a set end was undone
        if snapshot.status == .ended { asksToSwap = false }
        completedSets = count
    }

    /// "Keep playing": hide this set point until the score changes.
    public mutating func decline() {
        declinedKey = prompt?.key
        prompt = nil
    }

    /// Shows a hidden set point again (after a failed "End set").
    public mutating func forgetDecline(_ snapshot: MatchSnapshot) {
        declinedKey = nil
        prompt = SetPointPrompt(snapshot: snapshot)
    }

    public mutating func answerSwap() { asksToSwap = false }

    public static func isDecided(_ snapshot: MatchSnapshot) -> Bool {
        let setsToWin = (snapshot.rules.bestOf + 1) / 2
        return snapshot.score.homeSets >= setsToWin || snapshot.score.awaySets >= setsToWin
    }
}

/// Final or running result line, Team 1 first: "25–21, 19–25, 15–12".
public enum MatchSummary {
    public static func setScores(_ snapshot: MatchSnapshot) -> String {
        snapshot.completedSets.map { "\($0.home)–\($0.away)" }.joined(separator: ", ")
    }
}

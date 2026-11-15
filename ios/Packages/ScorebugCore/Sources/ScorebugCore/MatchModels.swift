import Foundation

// Wire dates remain ISO-8601 strings, preserving fractional seconds across clients.
public enum MatchSide: String, Codable, Equatable, Sendable {
    case home, away
}

public enum MatchStatus: String, Codable, Equatable, Sendable {
    case active, ended
}

public enum MatchRole: String, Codable, Equatable, Sendable {
    case score, capture
}

public enum BroadcastDesired: String, Codable, Equatable, Sendable {
    case stopped, running
}

public struct MatchTeam: Codable, Equatable, Sendable {
    public var name: String
    public var shortName: String
    public var color: String

    public init(name: String, shortName: String, color: String) {
        self.name = name
        self.shortName = shortName
        self.color = color
    }
}

public struct MatchTeams: Codable, Equatable, Sendable {
    public var home: MatchTeam
    public var away: MatchTeam

    public init(home: MatchTeam, away: MatchTeam) {
        self.home = home
        self.away = away
    }
}

public struct MatchScore: Codable, Equatable, Sendable {
    public var home: Int
    public var away: Int
    public var set: Int
    public var homeSets: Int
    public var awaySets: Int

    public init(home: Int, away: Int, set: Int, homeSets: Int, awaySets: Int) {
        self.home = home
        self.away = away
        self.set = set
        self.homeSets = homeSets
        self.awaySets = awaySets
    }
}

public struct MatchRules: Codable, Equatable, Sendable {
    public var bestOf: Int
    public var pointsToWin: Int
    public var decidingPointsToWin: Int
    public var winBy: Int
    public var pointCap: Int?

    public init(bestOf: Int, pointsToWin: Int, decidingPointsToWin: Int, winBy: Int, pointCap: Int?) {
        self.bestOf = bestOf
        self.pointsToWin = pointsToWin
        self.decidingPointsToWin = decidingPointsToWin
        self.winBy = winBy
        self.pointCap = pointCap
    }

    private enum CodingKeys: String, CodingKey {
        case bestOf, pointsToWin, decidingPointsToWin, winBy, pointCap
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bestOf, forKey: .bestOf)
        try container.encode(pointsToWin, forKey: .pointsToWin)
        try container.encode(decidingPointsToWin, forKey: .decidingPointsToWin)
        try container.encode(winBy, forKey: .winBy)
        try container.encode(pointCap, forKey: .pointCap)
    }
}

public struct MatchSetResult: Codable, Equatable, Sendable {
    public var set: Int
    public var home: Int
    public var away: Int
    public var winner: MatchSide
    public var overrideReason: String?

    public init(set: Int, home: Int, away: Int, winner: MatchSide, overrideReason: String?) {
        self.set = set
        self.home = home
        self.away = away
        self.winner = winner
        self.overrideReason = overrideReason
    }

    private enum CodingKeys: String, CodingKey {
        case set, home, away, winner, overrideReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(set, forKey: .set)
        try container.encode(home, forKey: .home)
        try container.encode(away, forKey: .away)
        try container.encode(winner, forKey: .winner)
        try container.encode(overrideReason, forKey: .overrideReason)
    }
}

public struct MatchScorer: Codable, Equatable, Sendable {
    public var deviceId: String
    public var epoch: Int

    public init(deviceId: String, epoch: Int) {
        self.deviceId = deviceId
        self.epoch = epoch
    }
}

public struct MatchBroadcast: Codable, Equatable, Sendable {
    public var desired: BroadcastDesired
    public var generation: Int

    public init(desired: BroadcastDesired, generation: Int) {
        self.desired = desired
        self.generation = generation
    }
}

public struct MatchSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: String
    public var revision: Int
    public var teams: MatchTeams
    public var rules: MatchRules
    public var score: MatchScore
    public var completedSets: [MatchSetResult]
    public var status: MatchStatus
    public var endReason: String?
    public var canUndo: Bool
    public var scorer: MatchScorer
    public var broadcast: MatchBroadcast

    public init(id: String, createdAt: String, revision: Int, teams: MatchTeams, rules: MatchRules, score: MatchScore, completedSets: [MatchSetResult], status: MatchStatus, endReason: String?, canUndo: Bool, scorer: MatchScorer, broadcast: MatchBroadcast) {
        self.id = id
        self.createdAt = createdAt
        self.revision = revision
        self.teams = teams
        self.rules = rules
        self.score = score
        self.completedSets = completedSets
        self.status = status
        self.endReason = endReason
        self.canUndo = canUndo
        self.scorer = scorer
        self.broadcast = broadcast
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, revision, teams, rules, score, completedSets, status, endReason, canUndo, scorer, broadcast
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(revision, forKey: .revision)
        try container.encode(teams, forKey: .teams)
        try container.encode(rules, forKey: .rules)
        try container.encode(score, forKey: .score)
        try container.encode(completedSets, forKey: .completedSets)
        try container.encode(status, forKey: .status)
        try container.encode(endReason, forKey: .endReason)
        try container.encode(canUndo, forKey: .canUndo)
        try container.encode(scorer, forKey: .scorer)
        try container.encode(broadcast, forKey: .broadcast)
    }
}

public struct MatchCredential: Codable, Equatable, Sendable {
    public var gameId: String
    public var deviceId: String
    public var role: MatchRole
    public var token: String

    public init(gameId: String, deviceId: String, role: MatchRole, token: String) {
        self.gameId = gameId
        self.deviceId = deviceId
        self.role = role
        self.token = token
    }
}

public struct MatchCommand: Codable, Equatable, Sendable {
    public var commandId: String
    public var gameId: String
    public var deviceId: String
    public var expectedRevision: Int
    public var scorerEpoch: Int
    public var issuedAt: String
    public var operation: MatchOperation

    public init(commandId: String, gameId: String, deviceId: String, expectedRevision: Int, scorerEpoch: Int, issuedAt: String, operation: MatchOperation) {
        self.commandId = commandId
        self.gameId = gameId
        self.deviceId = deviceId
        self.expectedRevision = expectedRevision
        self.scorerEpoch = scorerEpoch
        self.issuedAt = issuedAt
        self.operation = operation
    }
}

public struct CommandOutcome: Codable, Equatable, Sendable {
    public var commandId: String
    public var accepted: Bool
    public var error: String?
    public var snapshot: MatchSnapshot

    public init(commandId: String, accepted: Bool, error: String?, snapshot: MatchSnapshot) {
        self.commandId = commandId
        self.accepted = accepted
        self.error = error
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case commandId, accepted, error, snapshot
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(accepted, forKey: .accepted)
        try container.encode(error, forKey: .error)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

public struct MatchCreation: Codable, Equatable, Sendable {
    public var id: String
    public var deviceId: String
    public var teams: MatchTeams
    public var rules: MatchRules

    public init(id: String, deviceId: String, teams: MatchTeams, rules: MatchRules) {
        self.id = id
        self.deviceId = deviceId
        self.teams = teams
        self.rules = rules
    }
}

public struct MatchSessionResponse: Codable, Equatable, Sendable {
    public var snapshot: MatchSnapshot
    public var credential: MatchCredential
    public var serverTime: String

    public init(snapshot: MatchSnapshot, credential: MatchCredential, serverTime: String) {
        self.snapshot = snapshot
        self.credential = credential
        self.serverTime = serverTime
    }
}

public struct MatchSnapshotResponse: Codable, Equatable, Sendable {
    public var snapshot: MatchSnapshot
    public var serverTime: String

    public init(snapshot: MatchSnapshot, serverTime: String) {
        self.snapshot = snapshot
        self.serverTime = serverTime
    }
}

public struct ActiveMatchResponse: Codable, Equatable, Sendable {
    public var snapshot: MatchSnapshot?
    public var serverTime: String

    public init(snapshot: MatchSnapshot?, serverTime: String) {
        self.snapshot = snapshot
        self.serverTime = serverTime
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot, serverTime
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(serverTime, forKey: .serverTime)
    }
}

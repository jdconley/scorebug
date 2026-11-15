import Foundation

public enum MatchOperation: Equatable, Sendable, Codable {
    case awardPoint(side: MatchSide)
    case undo
    case endSet(winner: MatchSide?, overrideReason: String?)
    case endMatch(reason: String)
    case takeOver

    private enum CodingKeys: String, CodingKey {
        case type, side, winner, overrideReason, reason
    }

    private enum Kind: String, Codable {
        case awardPoint = "award_point"
        case undo
        case endSet = "end_set"
        case endMatch = "end_match"
        case takeOver = "take_over"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .awardPoint:
            self = .awardPoint(side: try container.decode(MatchSide.self, forKey: .side))
        case .undo:
            self = .undo
        case .endSet:
            self = .endSet(winner: try container.decodeIfPresent(MatchSide.self, forKey: .winner),
                           overrideReason: try container.decodeIfPresent(String.self, forKey: .overrideReason))
        case .endMatch:
            self = .endMatch(reason: try container.decode(String.self, forKey: .reason))
        case .takeOver:
            self = .takeOver
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .awardPoint(let side):
            try container.encode(Kind.awardPoint, forKey: .type)
            try container.encode(side, forKey: .side)
        case .undo:
            try container.encode(Kind.undo, forKey: .type)
        case .endSet(let winner, let reason):
            try container.encode(Kind.endSet, forKey: .type)
            try container.encodeIfPresent(winner, forKey: .winner)
            try container.encodeIfPresent(reason, forKey: .overrideReason)
        case .endMatch(let reason):
            try container.encode(Kind.endMatch, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .takeOver:
            try container.encode(Kind.takeOver, forKey: .type)
        }
    }
}

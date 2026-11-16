import Foundation

/// Phone ↔ Watch messages. The Watch holds no server setup or credential: it mirrors
/// the paired iPhone's current match and sends scoring intents back, which the phone
/// runs through its own durable scoring outbox. Works for the filming phone and for
/// a phone that joined through an invite.
public enum WatchRemote {
    public static let messageKey = "scorebug.remote.v1"
    public static let version = 1

    public struct Team: Codable, Equatable, Sendable {
        public var slot: TeamSlot
        public var shortName: String
        public var color: String
        public var points: Int
        public var sets: Int
        public init(slot: TeamSlot, shortName: String, color: String, points: Int, sets: Int) {
            self.slot = slot; self.shortName = shortName; self.color = color; self.points = points; self.sets = sets
        }
    }

    public struct Prompt: Codable, Equatable, Sendable {
        public var title: String
        public var scoreLine: String
        public var confirmLabel: String
        public init(title: String, scoreLine: String, confirmLabel: String) {
            self.title = title; self.scoreLine = scoreLine; self.confirmLabel = confirmLabel
        }
    }

    /// Ordered by court side as filmed: `left` is the left half of the phone's picture.
    public struct State: Codable, Equatable, Sendable {
        public var version: Int
        public var matchId: String
        public var left: Team
        public var right: Team
        public var set: Int
        public var isLive: Bool
        public var canScore: Bool
        public var canUndo: Bool
        public var ended: Bool
        public var prompt: Prompt?
        public var asksToSwap: Bool
        public var busy: Bool
        public var note: String?

        public init(matchId: String, left: Team, right: Team, set: Int, isLive: Bool, canScore: Bool, canUndo: Bool,
                    ended: Bool, prompt: Prompt?, asksToSwap: Bool, busy: Bool, note: String?) {
            version = WatchRemote.version
            self.matchId = matchId; self.left = left; self.right = right; self.set = set; self.isLive = isLive
            self.canScore = canScore; self.canUndo = canUndo; self.ended = ended; self.prompt = prompt
            self.asksToSwap = asksToSwap; self.busy = busy; self.note = note
        }

        /// "SET 3 · 1–1", sets shown left team first.
        public var header: String { "SET \(set) · \(left.sets)–\(right.sets)" }
    }

    /// Nil `state` means the phone has no match open.
    public struct Envelope: Codable, Equatable, Sendable {
        public var state: State?
        public var sentAt: Double
        public init(state: State?, sentAt: Double) { self.state = state; self.sentAt = sentAt }
    }

    public enum Intent: Codable, Equatable, Sendable {
        case hello
        case point(TeamSlot)
        case undo
        case swapSides
        case confirmSetEnd
        case declineSetEnd
        case answerSwap(Bool)

        private enum CodingKeys: String, CodingKey { case type, team, swap }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "hello": self = .hello
            case "point": self = .point(try c.decode(TeamSlot.self, forKey: .team))
            case "undo": self = .undo
            case "swapSides": self = .swapSides
            case "confirmSetEnd": self = .confirmSetEnd
            case "declineSetEnd": self = .declineSetEnd
            case "answerSwap": self = .answerSwap(try c.decode(Bool.self, forKey: .swap))
            default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown intent")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hello: try c.encode("hello", forKey: .type)
            case .point(let team): try c.encode("point", forKey: .type); try c.encode(team, forKey: .team)
            case .undo: try c.encode("undo", forKey: .type)
            case .swapSides: try c.encode("swapSides", forKey: .type)
            case .confirmSetEnd: try c.encode("confirmSetEnd", forKey: .type)
            case .declineSetEnd: try c.encode("declineSetEnd", forKey: .type)
            case .answerSwap(let swap): try c.encode("answerSwap", forKey: .type); try c.encode(swap, forKey: .swap)
            }
        }
    }

    // WatchConnectivity dictionaries carry one Data value under `messageKey`.
    public static func message<T: Encodable>(_ value: T) throws -> [String: Any] {
        [messageKey: try JSONEncoder().encode(value)]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[messageKey] as? Data, data.count <= 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension WatchRemote.State {
    /// Builds the mirror from what the phone shows.
    public init(snapshot: MatchSnapshot, layout: CourtLayout, flow: SetPointFlow, isLive: Bool, canScore: Bool,
                busy: Bool, note: String?) {
        func team(_ side: CourtSide) -> WatchRemote.Team {
            let slot = layout.team(on: side)
            let info = snapshot.teams[slot]
            return WatchRemote.Team(slot: slot, shortName: info.shortName, color: info.color,
                                    points: snapshot.score.points(slot), sets: snapshot.score.sets(slot))
        }
        self.init(matchId: snapshot.id, left: team(.left), right: team(.right), set: snapshot.score.set,
                  isLive: isLive, canScore: canScore, canUndo: snapshot.canUndo && canScore,
                  ended: snapshot.status == .ended,
                  prompt: flow.prompt.map { WatchRemote.Prompt(title: $0.title, scoreLine: $0.scoreLine, confirmLabel: $0.confirmLabel) },
                  asksToSwap: flow.asksToSwap, busy: busy, note: note)
    }
}

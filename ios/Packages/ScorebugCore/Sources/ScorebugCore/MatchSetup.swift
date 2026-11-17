import Foundation

/// The app never says home or away. "Team 1" is the API's `home`, "Team 2" its `away`.
public enum TeamSlot: String, Codable, CaseIterable, Sendable {
    case team1, team2

    public var side: MatchSide { self == .team1 ? .home : .away }
    public init(_ side: MatchSide) { self = side == .home ? .team1 : .team2 }
    public var other: TeamSlot { self == .team1 ? .team2 : .team1 }
    public var label: String { self == .team1 ? "Team 1" : "Team 2" }
}

extension MatchTeams {
    public subscript(slot: TeamSlot) -> MatchTeam { slot == .team1 ? home : away }
}

extension MatchScore {
    public func points(_ slot: TeamSlot) -> Int { slot == .team1 ? home : away }
    public func sets(_ slot: TeamSlot) -> Int { slot == .team1 ? homeSets : awaySets }
}

extension MatchSetResult {
    public func points(_ slot: TeamSlot) -> Int { slot == .team1 ? home : away }
}

/// Scorebug label: at most 8 characters, prefilled uppercase from the team name.
public enum ShortName {
    public static let maxLength = 8

    /// "Cascade 14 Black" → "CASCADE"; "Lakeside" → "LAKESIDE"; "Northgate Volleyball" → "NORTHGAT".
    /// A first word of 3–8 characters is used on its own; otherwise the first 8 characters.
    public static func derive(from name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return "" }
        if words.count > 1, (3...maxLength).contains(first.count) { return first.uppercased() }
        let collapsed = words.joined(separator: " ").uppercased()
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Uppercases and caps the length while typing.
    public static func sanitize(_ input: String) -> String {
        String(input.uppercased().prefix(maxLength))
    }

    public static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= maxLength
    }
}

/// One team as entered on the New match sheet. The short name follows the name
/// until someone edits it by hand.
public struct TeamDraft: Codable, Equatable, Sendable {
    public private(set) var name: String
    public private(set) var shortName: String
    public private(set) var shortNameEdited: Bool
    public var color: String

    public init(name: String = "", shortName: String? = nil, color: String) {
        self.name = name
        self.shortName = shortName.map(ShortName.sanitize) ?? ShortName.derive(from: name)
        self.shortNameEdited = shortName != nil && shortName != ShortName.derive(from: name)
        self.color = color
    }

    public mutating func setName(_ value: String) {
        name = String(value.prefix(80))
        if !shortNameEdited { shortName = ShortName.derive(from: name) }
    }

    /// Clearing the field returns it to following the name.
    public mutating func setShortName(_ value: String) {
        let sanitized = ShortName.sanitize(value)
        if sanitized.trimmingCharacters(in: .whitespaces).isEmpty {
            shortNameEdited = false
            shortName = sanitized.isEmpty ? ShortName.derive(from: name) : sanitized
        } else {
            shortNameEdited = sanitized != ShortName.derive(from: name)
            shortName = sanitized
        }
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedShortName: String { shortName.trimmingCharacters(in: .whitespaces) }
    public var team: MatchTeam { MatchTeam(name: trimmedName, shortName: trimmedShortName, color: color.lowercased()) }
}

public enum MatchFormat: String, Codable, CaseIterable, Sendable {
    case bestOf3, bestOf5

    public var label: String { self == .bestOf3 ? "Best of 3 · 25/15" : "Best of 5 · 25/15" }
    public var rules: MatchRules {
        MatchRules(bestOf: self == .bestOf3 ? 3 : 5, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil)
    }
    public init(rules: MatchRules) { self = rules.bestOf == 5 ? .bestOf5 : .bestOf3 }
}

/// Team colors offered on the sheet. Score chips pick black or white text by contrast.
public enum TeamPalette {
    public struct Swatch: Equatable, Sendable, Identifiable {
        public let name: String
        public let hex: String
        public var id: String { hex }
    }
    public static let swatches: [Swatch] = [
        Swatch(name: "Blue", hex: "#2563eb"), Swatch(name: "Orange", hex: "#f97316"),
        Swatch(name: "Green", hex: "#16a34a"), Swatch(name: "Purple", hex: "#7c3aed"),
        Swatch(name: "Red", hex: "#dc2626"), Swatch(name: "Gold", hex: "#eab308"),
        Swatch(name: "Teal", hex: "#0d9488"), Swatch(name: "Black", hex: "#111827"),
        Swatch(name: "White", hex: "#f2f4f7"),
    ]
    public static let team1Default = "#2563eb"
    public static let team2Default = "#f97316"

    public static func isValidHex(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// sRGB components 0…1, or nil for an invalid value.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard isValidHex(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// WCAG relative luminance.
    public static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = components(hex) else { return 0 }
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// True when near-black text reads better than white on this color.
    public static func prefersDarkText(on hex: String) -> Bool {
        let l = luminance(hex)
        let againstWhite = 1.05 / (l + 0.05)
        let againstDark = (l + 0.05) / 0.0533 // #0B0D10
        return againstDark > againstWhite
    }
}

public enum NewMatchIssue: Equatable, Sendable {
    case missingName(TeamSlot)
    case invalidShortName(TeamSlot)
    case sameShortName
    case invalidColor(TeamSlot)

    public var message: String {
        switch self {
        case .missingName(let slot): "Enter a name for \(slot.label)."
        case .invalidShortName(let slot): "\(slot.label)'s short name must be 1–8 characters."
        case .sameShortName: "Give the two teams different short names."
        case .invalidColor(let slot): "Pick a color for \(slot.label)."
        }
    }
}

/// Everything the New match sheet collects.
public struct NewMatchDraft: Codable, Equatable, Sendable {
    public var team1: TeamDraft
    public var team2: TeamDraft
    public var format: MatchFormat
    public var style: ScorebugStyle
    public var recordIn4K: Bool

    public init(team1: TeamDraft = TeamDraft(color: TeamPalette.team1Default),
                team2: TeamDraft = TeamDraft(color: TeamPalette.team2Default),
                format: MatchFormat = .bestOf3, style: ScorebugStyle = .bar, recordIn4K: Bool = false) {
        self.team1 = team1; self.team2 = team2; self.format = format; self.style = style
        self.recordIn4K = recordIn4K
    }

    public subscript(slot: TeamSlot) -> TeamDraft {
        get { slot == .team1 ? team1 : team2 }
        set { if slot == .team1 { team1 = newValue } else { team2 = newValue } }
    }

    public var issues: [NewMatchIssue] {
        var issues: [NewMatchIssue] = []
        for slot in TeamSlot.allCases {
            let team = self[slot]
            if team.trimmedName.isEmpty { issues.append(.missingName(slot)) }
            if !ShortName.isValid(team.shortName) { issues.append(.invalidShortName(slot)) }
            if !TeamPalette.isValidHex(team.color) { issues.append(.invalidColor(slot)) }
        }
        if ShortName.isValid(team1.shortName), team1.trimmedShortName.caseInsensitiveCompare(team2.trimmedShortName) == .orderedSame {
            issues.append(.sameShortName)
        }
        return issues
    }

    public var isValid: Bool { issues.isEmpty }

    /// Team 1 is sent as `home`, Team 2 as `away`.
    public func creation(id: String, deviceId: String, recordOnly: Bool) -> MatchCreation {
        MatchCreation(id: id, deviceId: deviceId, teams: MatchTeams(home: team1.team, away: team2.team),
                      rules: format.rules, scorebugStyle: style, recordOnly: recordOnly ? true : nil)
    }
}

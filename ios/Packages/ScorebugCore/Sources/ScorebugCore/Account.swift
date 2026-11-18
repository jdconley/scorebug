import CryptoKit
import Foundation

/// The hosted service. The app always talks to it; a Debug build can point elsewhere.
public enum ScorebugService {
    public static let url = URL(string: "https://scorebug.live")!
    /// Universal links (`/invite/…`, `/join/…`) come from here.
    public static let linkHost = "scorebug.live"
    /// Sign-in finishes on `scorebug://auth?status=…`.
    public static let callbackScheme = "scorebug"
}

/// A signed-in person (`/v1/me`, `/v1/auth/session`).
public struct Person: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var name: String?
    public var picture: String?

    public init(id: String, email: String, name: String?, picture: String?) {
        self.id = id; self.email = email; self.name = name; self.picture = picture
    }

    /// "Jordan" for greetings, or the email when Google sent no name.
    public var displayName: String { name?.isEmpty == false ? name! : email }
}

public enum TeamRole: String, Codable, Equatable, Sendable { case owner, member }

public struct Team: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var shortName: String
    public var color: String

    public init(id: String, name: String, shortName: String, color: String) {
        self.id = id; self.name = name; self.shortName = shortName; self.color = color
    }
}

/// One of the person's teams, with their role on it.
public struct TeamMembership: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var shortName: String
    public var color: String
    public var role: TeamRole

    public init(id: String, name: String, shortName: String, color: String, role: TeamRole) {
        self.id = id; self.name = name; self.shortName = shortName; self.color = color; self.role = role
    }
    public init(team: Team, role: TeamRole) {
        self.init(id: team.id, name: team.name, shortName: team.shortName, color: team.color, role: role)
    }
    public var team: Team { Team(id: id, name: name, shortName: shortName, color: color) }
    public var isOwner: Bool { role == .owner }
}

/// `GET /v1/me`.
public struct Me: Codable, Equatable, Sendable {
    public var person: Person
    public var teams: [TeamMembership]

    public init(person: Person, teams: [TeamMembership]) {
        self.person = person; self.teams = teams
    }
}

/// `POST /v1/auth/session`: a long-lived, revocable session token for this phone.
public struct SignedIn: Codable, Equatable, Sendable {
    public var token: String
    public var person: Person
}

public struct TeamMember: Codable, Equatable, Sendable, Identifiable {
    public var personId: String
    public var name: String?
    public var email: String
    public var role: TeamRole
    public var id: String { personId }
    public var displayName: String { name?.isEmpty == false ? name! : email }

    public init(personId: String, name: String?, email: String, role: TeamRole) {
        self.personId = personId; self.name = name; self.email = email; self.role = role
    }
}

public struct TeamInvite: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var teamId: String
    /// Only this Google account can accept it; nil for a link anyone can use.
    public var email: String?
    public var createdAt: String
    public var expiresAt: String
    public var revokedAt: String?

    public init(id: String, teamId: String, email: String?, createdAt: String, expiresAt: String, revokedAt: String?) {
        self.id = id; self.teamId = teamId; self.email = email
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.revokedAt = revokedAt
    }

    /// Not revoked and not expired.
    public func isLive(now: Date = Date()) -> Bool {
        guard revokedAt == nil else { return false }
        guard let expiry = ServerDate.parse(expiresAt) else { return true }
        return expiry > now
    }
}

/// `GET /v1/teams/:id`. Invites are only sent to owners.
public struct TeamDetail: Codable, Equatable, Sendable {
    public var team: Team
    public var role: TeamRole
    public var members: [TeamMember]
    public var invites: [TeamInvite]?
    /// The team's YouTube channel; nil when none is set (Go Live is off, recording still works).
    public var youtube: TeamYouTube?

    public init(team: Team, role: TeamRole, members: [TeamMember], invites: [TeamInvite]?, youtube: TeamYouTube? = nil) {
        self.team = team; self.role = role; self.members = members; self.invites = invites; self.youtube = youtube
    }
}

/// `POST /v1/teams/:id/invites`. `code` is grouped (`ABCD-EFGH`); `link` is `https://scorebug.live/invite/…`.
public struct TeamInviteIssued: Codable, Equatable, Sendable {
    public var invite: TeamInvite
    public var code: String
    public var link: String
}

/// `POST /v1/teams` and `POST /v1/team-invites/accept`.
public struct TeamJoined: Codable, Equatable, Sendable {
    public var team: Team
    public var role: TeamRole
}

enum ServerDate {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: Sign in

/// Proof Key for Code Exchange. The app keeps the verifier; only the challenge
/// travels through the browser, so an intercepted ticket is useless on its own.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes → a 43-character base64url verifier.
    public static func make() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        return make(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func make(bytes: [UInt8]) -> PKCE {
        let verifier = base64url(Data(bytes))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Where Google sign-in lands: `scorebug://auth?status=ok&ticket=…`.
public enum SignInCallback: Equatable, Sendable {
    case ok(ticket: String)
    case cancelled
    case error

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == ScorebugService.callbackScheme,
              components.host?.lowercased() == "auth" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        // Connecting a YouTube channel lands on the same URL with purpose=youtube.
        guard items.first(where: { $0.name == "purpose" }) == nil else { return nil }
        switch value("status") {
        case "ok":
            guard let ticket = value("ticket"), Self.isTicket(ticket) else { self = .error; return }
            self = .ok(ticket: ticket)
        case "cancelled": self = .cancelled
        default: self = .error
        }
    }

    /// The server issues 32 random bytes as base64url.
    static func isTicket(_ text: String) -> Bool {
        text.count == 43 && text.unicodeScalars.allSatisfy { base64url.contains($0) }
    }

    private static let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}

/// Eight-character team invite codes, the same alphabet as match codes.
public enum TeamInviteCode {
    public static let length = 8

    public static func normalize(_ input: String) -> String? {
        let code = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == length, code.allSatisfy({ InviteCode.alphabet.contains($0) }) else { return nil }
        return code
    }
}

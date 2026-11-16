import Foundation

/// `scorebug://connect?server=…&code=…` (one-time phone setup) and
/// `scorebug://join?server=…&code=…` (score a match). See docs/api.md.
public enum ScorebugLink: Equatable, Sendable {
    case connect(server: ScoringEndpoint, code: String)
    case join(server: ScoringEndpoint, code: String)

    public static let scheme = "scorebug"

    /// Accepts a URL string as scanned from a QR code or pasted. Surrounding whitespace is ignored.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        self.init(url: url)
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              let action = components.host?.lowercased() else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count == 1 else { return nil }
            return matches[0].value
        }
        guard let serverText = value("server"), let server = try? ScoringEndpoint(serverText),
              let rawCode = value("code") else { return nil }
        switch action {
        case "connect":
            guard let code = Self.normalizeSetupCode(rawCode) else { return nil }
            self = .connect(server: server, code: code)
        case "join":
            guard let code = InviteCode.normalize(rawCode) else { return nil }
            self = .join(server: server, code: code)
        default:
            return nil
        }
    }

    public var server: ScoringEndpoint {
        switch self {
        case .connect(let server, _), .join(let server, _): server
        }
    }

    public var code: String {
        switch self {
        case .connect(_, let code), .join(_, let code): code
        }
    }

    /// Setup codes are URL-safe; the server issues 24 characters. Manual entry ignores spaces.
    public static func normalizeSetupCode(_ input: String) -> String? {
        let code = input.filter { !$0.isWhitespace }
        guard (8...64).contains(code.count),
              code.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) })
        else { return nil }
        return code
    }
}

/// Six-character match invite codes. The alphabet has no 0/O, 1/I/L or U.
public enum InviteCode {
    public static let alphabet = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
    public static let length = 6

    /// Uppercases and drops spaces and dashes; nil unless exactly six alphabet characters remain.
    public static func normalize(_ input: String) -> String? {
        let code = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == length, code.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return code
    }

    /// `K7P4QX` → `K7P-4QX`.
    public static func format(_ code: String) -> String {
        guard let normalized = normalize(code) else { return code }
        return "\(normalized.prefix(3))-\(normalized.suffix(3))"
    }
}

/// What a person typed or scanned to join a match: a full link, or a bare code
/// for the server this phone already uses.
public enum JoinInput: Equatable, Sendable {
    case link(server: ScoringEndpoint, code: String)
    case code(String)

    public init?(_ text: String) {
        if case let .join(server, code)? = ScorebugLink(string: text) {
            self = .link(server: server, code: code)
        } else if let code = InviteCode.normalize(text) {
            self = .code(code)
        } else {
            return nil
        }
    }
}

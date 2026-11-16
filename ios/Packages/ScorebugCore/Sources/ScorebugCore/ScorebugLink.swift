import Foundation

/// Links the app opens. Both are universal links on the service's own domain:
/// - `https://scorebug.live/invite/ABCD2345`: join a team (sign in first if needed);
/// - `https://scorebug.live/join/K7P4QX`: score one match, no account needed.
public enum ScorebugLink: Equatable, Sendable {
    case teamInvite(code: String)
    case matchJoin(code: String)

    /// `hosts` are the domains trusted for links: scorebug.live, plus the Debug server override.
    public init?(string: String, hosts: Set<String> = [ScorebugService.linkHost]) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        self.init(url: url, hosts: hosts)
    }

    public init?(url: URL, hosts: Set<String> = [ScorebugService.linkHost]) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              hosts.contains(host) || (host.hasPrefix("www.") && hosts.contains(String(host.dropFirst(4)))),
              components.user == nil, components.password == nil else { return nil }
        // Plain HTTP only for a local development server.
        if scheme == "http", (try? ScoringEndpoint("http://\(host)")) == nil { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0].lowercased() {
        case "invite":
            guard let code = TeamInviteCode.normalize(parts[1]) else { return nil }
            self = .teamInvite(code: code)
        case "join":
            guard let code = InviteCode.normalize(parts[1]) else { return nil }
            self = .matchJoin(code: code)
        default:
            return nil
        }
    }

    /// A pasted or typed match code: a `/join/` link or the bare six characters.
    public static func matchCode(from text: String, hosts: Set<String> = [ScorebugService.linkHost]) -> String? {
        if case .matchJoin(let code)? = ScorebugLink(string: text, hosts: hosts) { return code }
        return InviteCode.normalize(text)
    }

    /// Hosts for links, given the server the app talks to.
    public static func hosts(for server: ScoringEndpoint) -> Set<String> {
        var hosts: Set<String> = [ScorebugService.linkHost]
        if let host = server.url.host?.lowercased() { hosts.insert(host) }
        return hosts
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

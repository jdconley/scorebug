import Foundation

/// A control-plane address, shared by native scoring clients.
/// Validation checks address syntax only; it does not establish connectivity.
public struct ScoringEndpoint: Equatable, Sendable {
    public let url: URL

    public enum ValidationError: Error {
        case invalidAddress
    }

    public init(_ address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              scheme == "https" || (scheme == "http" && Self.isLocalHost(host)),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else {
            throw ValidationError.invalidAddress
        }
        self.url = url
    }

    // HTTP is useful for the simulator or a development server on the same LAN.
    // Public servers require HTTPS. No network or transport policy is changed here.
    private static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "[::1]" || name == "::1" || name.hasSuffix(".local") {
            return true
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 127 || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

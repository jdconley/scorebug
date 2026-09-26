import Foundation

/// XCTest-only controller credentials. Never forwarded into the application.
struct RecoveryControlConfiguration {
    enum Failure: Error { case invalid }
    let endpoint: URL
    let token: String
    let runID: String

    init(environment: [String: String], allowLAN: Bool = false) throws {
        guard let endpoint = environment["SCOREBUG_RECOVERY_CONTROL_URL"],
              let components = URLComponents(string: endpoint),
              components.scheme == "http", let host = components.host, components.percentEncodedHost == host,
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              ["", "/"].contains(components.path), let base = components.url,
              let token = environment["SCOREBUG_RECOVERY_CONTROL_TOKEN"], token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let runID = environment["SCOREBUG_RECOVERY_RUN_ID"], UUID(uuidString: runID) != nil else {
            throw Failure.invalid
        }
        if host != "127.0.0.1" {
            guard allowLAN, Self.isPrivateIPv4(host),
                  let api = environment["SCOREBUG_DEVICE_API_URL"].flatMap({ URLComponents(string: $0) }),
                  ["http", "https"].contains(api.scheme ?? ""), api.host == host, api.percentEncodedHost == host,
                  api.user == nil, api.password == nil, api.query == nil, api.fragment == nil else {
                throw Failure.invalid
            }
        }
        self.endpoint = base; self.token = token; self.runID = runID
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              zip(parts, octets).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }
}

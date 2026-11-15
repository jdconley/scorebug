#if DEBUG
import Foundation

/// Explicit, per-run configuration shared by the Debug app and physical runner.
/// No credentials or request bodies are included in errors or logging.
struct RecoveryLoopbackConfiguration {
    enum Failure: Error { case invalid }
    let port: UInt16
    let api: URL
    let controller: URL
    let token: String
    let runID: String
    var endpoint: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    static let environmentKeys = ["SCOREBUG_RECOVERY_RUNNER_TRANSPORT", "SCOREBUG_RECOVERY_BRIDGE_PORT",
        "SCOREBUG_DEVICE_API_URL", "SCOREBUG_RECOVERY_CONTROL_URL", "SCOREBUG_RECOVERY_CONTROL_TOKEN", "SCOREBUG_RECOVERY_RUN_ID"]

    init(environment: [String: String]) throws {
        guard environment["SCOREBUG_RECOVERY_RUNNER_TRANSPORT"] == "app-loopback",
              let rawPort = environment["SCOREBUG_RECOVERY_BRIDGE_PORT"], let port = UInt16(rawPort),
              port >= 49152, String(port) == rawPort,
              let api = Self.root(environment["SCOREBUG_DEVICE_API_URL"], schemes: ["http", "https"]),
              let controller = Self.root(environment["SCOREBUG_RECOVERY_CONTROL_URL"], schemes: ["http"]),
              api.host == controller.host,
              let token = environment["SCOREBUG_RECOVERY_CONTROL_TOKEN"], token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let runID = environment["SCOREBUG_RECOVERY_RUN_ID"], UUID(uuidString: runID) != nil else { throw Failure.invalid }
        self.port = port; self.api = api; self.controller = controller; self.token = token; self.runID = runID
    }

    private static func root(_ raw: String?, schemes: Set<String>) -> URL? {
        guard let raw, let c = URLComponents(string: raw), let scheme = c.scheme, schemes.contains(scheme),
              let host = c.host, c.percentEncodedHost == host,
              let port = c.port, (1...65535).contains(port),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              ["", "/"].contains(c.path), raw == "\(scheme)://\(host):\(port)\(c.path)" else { return nil }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = pieces.compactMap { Int($0) }
        guard pieces.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              zip(pieces, octets).allSatisfy({ String($0.0) == String($0.1) }),
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168) else { return nil }
        return URL(string: "\(scheme)://\(host):\(port)/")
    }
}

struct RecoveryLoopbackRequest {
    let method: String
    let path: String
    let body: Data
    static let headerLimit = 8192
    static let bodyLimit = 8192

    /// Returns nil only for an incomplete request. One request per connection.
    static func parse(_ data: Data, configuration: RecoveryLoopbackConfiguration) throws -> Self? {
        let invalid = RecoveryLoopbackConfiguration.Failure.invalid
        guard data.count <= headerLimit + bodyLimit else { throw invalid }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count < headerLimit else { throw invalid }; return nil
        }
        guard split.upperBound <= headerLimit,
              let header = String(data: data[..<split.lowerBound], encoding: .ascii) else { throw invalid }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[2] == "HTTP/1.1",
              (first[0] == "GET" && ["/", "/api-health"].contains(first[1])) ||
                (first[0] == "POST" && ["/constrain", "/restore", "/stop"].contains(first[1])) else { throw invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw invalid }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }), headers[name] == nil else { throw invalid }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(configuration.port)",
              headers["authorization"] == "Bearer \(configuration.token)",
              headers["transfer-encoding"] == nil, headers["expect"] == nil, headers["upgrade"] == nil else { throw invalid }
        let lengthString = headers["content-length"] ?? "0"
        guard let length = Int(lengthString), length >= 0, length <= bodyLimit, String(length) == lengthString,
              (first[0] == "POST" && first[1] != "/stop") || length == 0 else { throw invalid }
        let body = data[split.upperBound...]
        guard body.count <= length else { throw invalid }
        guard body.count == length else { return nil }
        return Self(method: first[0], path: first[1], body: Data(body))
    }
}
#endif

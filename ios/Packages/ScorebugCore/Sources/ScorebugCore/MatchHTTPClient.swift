import Foundation

public enum MatchClientError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case http(status: Int, code: String?)
    case invalidResponse
    case invalidIdentifier
}

/// The Scorebug API client. Credentials are only sent
/// in Authorization headers; HTTP errors retain the server's code, never its body.
public struct MatchHTTPClient: MatchScoringClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Failure: Decodable { let error: String }

    private let endpoint: ScoringEndpoint
    private let transport: Transport
    /// Set by `team(_:)`: create, active, join, invites and broadcast commands go through
    /// `/v1/teams/:teamId/matches`, authorized by the person's session token. Match-token
    /// routes (snapshot, commands, media) use `/v1/matches/:id` and need no team.
    public private(set) var teamId: String?

    // Reuse one owned session across clients. Waiting lets the first
    // LAN request survive the privacy prompt; the resource timeout also bounds
    // that connectivity wait, unlike URLRequest's inactivity timeout alone.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    public init(endpoint: ScoringEndpoint) {
        self.init(endpoint: endpoint, session: Self.defaultSession)
    }

    public init(endpoint: ScoringEndpoint, session: URLSession) {
        self.init(endpoint: endpoint, transport: { request in
            try await session.data(for: request)
        })
    }

    public init(endpoint: ScoringEndpoint, transport: @escaping Transport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// The same client, with member routes scoped to one team.
    public func team(_ teamId: String) -> MatchHTTPClient {
        var copy = self
        copy.teamId = teamId
        return copy
    }

    public var serverURL: URL { endpoint.url }

    /// `["teams", teamId, "matches"]`. Member routes exist only under a team.
    private func memberRoot() throws -> [String] {
        guard let teamId, Self.isIdentifier(teamId) else { throw MatchClientError.invalidIdentifier }
        return ["teams", teamId, "matches"]
    }

    static func isIdentifier(_ component: String) -> Bool {
        !component.isEmpty && component.utf8.count <= 128 && component.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 })
    }

    /// Repeating the same creation (same ID) after a lost response is safe.
    public func create(_ creation: MatchCreation, token: String) async throws -> MatchSessionResponse {
        try await send(root: try memberRoot(), path: [], method: "POST", token: token, body: JSONEncoder().encode(creation))
    }

    // MARK: Match join codes (docs/api.md)

    /// The team member's session token.
    public func createInvite(gameId: String, token: String) async throws -> MatchInviteIssued {
        try await send(root: try memberRoot(), path: [gameId, "invites"], method: "POST", token: token, body: Data("{}".utf8))
    }

    /// Unauthenticated. Returns a per-match score credential; send `take_over` before scoring.
    public func redeemInvite(code: String, deviceId: String) async throws -> InviteRedeemed {
        struct Request: Encodable { let code: String; let deviceId: String }
        return try await send(root: ["invites"], path: ["redeem"], method: "POST", token: nil,
                              body: JSONEncoder().encode(Request(code: code, deviceId: deviceId)))
    }

    public func active(token: String) async throws -> ActiveMatchResponse {
        try await send(root: try memberRoot(), path: ["active"], token: token)
    }

    public func join(gameId: String, deviceId: String, role: MatchRole, token: String) async throws -> MatchSessionResponse {
        struct Join: Encodable { let deviceId: String; let role: MatchRole }
        return try await send(root: try memberRoot(), path: [gameId, "join"], method: "POST", token: token,
                              body: JSONEncoder().encode(Join(deviceId: deviceId, role: role)))
    }

    public func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse {
        try await send(path: [credential.gameId], token: credential.token)
    }

    /// A 409 with a valid command outcome is a domain rejection, not a transport failure.
    public func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome {
        try await send(path: [credential.gameId, "commands"], method: "POST", token: credential.token,
                       body: JSONEncoder().encode(command), additionalStatuses: [409])
    }

    public func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome? {
        do {
            return try await send(path: [credential.gameId, "commands", commandId], token: credential.token)
        } catch MatchClientError.http(status: 404, code: "command_not_found") {
            return nil
        }
    }

    public func mediaSnapshot(credential: MatchCredential) async throws -> MediaSnapshotResponse {
        try await send(path: [credential.gameId, "media"], token: credential.token)
    }

    public func reportRecording(_ report: RecordingReport, credential: MatchCredential) async throws -> RecordingReportResponse {
        try await send(path: [credential.gameId, "media", "recordings"], method: "POST", token: credential.token,
                       body: JSONEncoder().encode(report))
    }

    /// Request access only for the current recording, broadcast generation and publishing attempt.
    /// The caller must still check its own lifecycle after this await: a matching
    /// response can arrive after the local recording has stopped.
    public func publishAccess(recordingId: String, generation: Int, publishingAttemptId: UUID, credential: MatchCredential) async throws -> PublishAccess {
        struct Request: Encodable { let recordingId: String; let generation: Int; let publishingAttemptId: String }
        struct Response: Decodable {
            let gameId: String
            let generation: Int
            let recordingId: String
            let publishUrl: String
            let serverTime: String
            let publishingAttemptId: String
        }
        let attempt = publishingAttemptId.uuidString.lowercased()
        let response: Response = try await send(path: [credential.gameId, "media", "publish"], method: "POST", token: credential.token,
                                               body: JSONEncoder().encode(Request(recordingId: recordingId, generation: generation, publishingAttemptId: attempt)))
        // The stream ID is Cloudflare Stream's own; the server authenticates it. The app needs
        // exactly one, intact, and the grant bound to this exact publishing attempt.
        guard response.gameId == credential.gameId, response.recordingId == recordingId, response.generation == generation,
              response.publishingAttemptId == attempt,
              let components = URLComponents(string: response.publishUrl), components.scheme == "srt",
              let host = components.host, !host.isEmpty,
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil, components.fragment == nil,
              let streamIDs = components.queryItems?.filter({ $0.name == "streamid" }), streamIDs.count == 1,
              let streamID = streamIDs.first?.value, !streamID.isEmpty, streamID.count <= 512,
              streamID.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              let url = components.url else { throw MatchClientError.invalidResponse }
        return PublishAccess(gameId: response.gameId, generation: response.generation, recordingId: response.recordingId,
                             publishUrl: url, serverTime: response.serverTime, publishingAttemptId: publishingAttemptId)
    }

    /// The member's session token controls publishing; a 409 is a normal domain outcome.
    public func executeBroadcast(_ command: BroadcastCommand, token: String) async throws -> BroadcastOutcome {
        try await send(root: try memberRoot(), path: [command.gameId, "media", "commands"], method: "POST", token: token,
                       body: JSONEncoder().encode(command), additionalStatuses: [409])
    }

    public func broadcastReceipt(gameId: String, commandId: String, token: String) async throws -> BroadcastOutcome? {
        do {
            return try await send(root: try memberRoot(), path: [gameId, "media", "commands", commandId], token: token)
        } catch MatchClientError.http(status: 404, code: "command_not_found") {
            return nil
        }
    }

    func send<Response: Decodable>(root: [String] = ["matches"], path: [String], method: String = "GET", token: String?,
                                          body: Data? = nil, additionalStatuses: Set<Int> = []) async throws -> Response {
        var url = endpoint.url.appendingPathComponent("v1")
        for component in root { url.appendPathComponent(component) }
        // Identifiers follow the server's ASCII grammar, preventing a scoped path
        // from being redirected by a slash, percent escape, or dot segment.
        for component in path {
            guard Self.isIdentifier(component) else { throw MatchClientError.invalidIdentifier }
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else { throw MatchClientError.invalidResponse }
        switch response.statusCode {
        case 401: throw MatchClientError.unauthorized
        case 403: throw MatchClientError.forbidden
        case 200..<300: break
        default:
            guard additionalStatuses.contains(response.statusCode) else {
                let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
                throw MatchClientError.http(status: response.statusCode, code: code)
            }
        }
        if Response.self == NoContent.self { return NoContent() as! Response }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

/// A 2xx reply whose body doesn't matter (204 No Content, or a body we ignore).
struct NoContent: Decodable {}

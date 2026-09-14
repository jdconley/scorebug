import Foundation

public enum MatchClientError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case http(status: Int, code: String?)
    case invalidResponse
    case invalidIdentifier
}

/// Camera-independent client shared by iPhone and watch. Credentials are only sent
/// in Authorization headers; HTTP errors retain the server's code, never its body.
public struct MatchHTTPClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Failure: Decodable { let error: String }

    private let endpoint: ScoringEndpoint
    private let transport: Transport

    public init(endpoint: ScoringEndpoint, session: URLSession = .shared) {
        self.init(endpoint: endpoint, transport: { request in
            try await session.data(for: request)
        })
    }

    public init(endpoint: ScoringEndpoint, transport: @escaping Transport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func create(id: String, deviceId: String, teams: MatchTeams, rules: MatchRules,
                       installationToken: String) async throws -> MatchSessionResponse {
        try await send(path: [], method: "POST", token: installationToken,
                       body: JSONEncoder().encode(MatchCreation(id: id, deviceId: deviceId, teams: teams, rules: rules)))
    }

    public func active(installationToken: String) async throws -> ActiveMatchResponse {
        try await send(path: ["active"], token: installationToken)
    }

    public func join(gameId: String, deviceId: String, role: MatchRole,
                     installationToken: String) async throws -> MatchSessionResponse {
        struct Join: Encodable { let deviceId: String; let role: MatchRole }
        return try await send(path: [gameId, "join"], method: "POST", token: installationToken,
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

    public func workerStatus(credential: MatchCredential) async throws -> WorkerMediaStatusResponse {
        try await send(path: [credential.gameId, "media", "status"], token: credential.token)
    }

    public func reportRecording(_ report: RecordingReport, credential: MatchCredential) async throws -> RecordingReportResponse {
        try await send(path: [credential.gameId, "media", "recordings"], method: "POST", token: credential.token,
                       body: JSONEncoder().encode(report))
    }

    /// Request access only for the current recording and broadcast generation.
    /// The caller must still check its own lifecycle after this await: a matching
    /// response can arrive after the local recording has stopped.
    public func publishAccess(recordingId: String, generation: Int, credential: MatchCredential) async throws -> PublishAccess {
        struct Request: Encodable { let recordingId: String; let generation: Int }
        struct Response: Decodable {
            let gameId: String
            let generation: Int
            let recordingId: String
            let publishUrl: String
            let serverTime: String
        }
        let response: Response = try await send(path: [credential.gameId, "media", "publish"], method: "POST", token: credential.token,
                                               body: JSONEncoder().encode(Request(recordingId: recordingId, generation: generation)))
        guard response.gameId == credential.gameId, response.recordingId == recordingId, response.generation == generation,
              let components = URLComponents(string: response.publishUrl), components.scheme == "srt",
              let host = components.host, !host.isEmpty,
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw MatchClientError.invalidResponse }
        return PublishAccess(gameId: response.gameId, generation: response.generation, recordingId: response.recordingId,
                             publishUrl: url, serverTime: response.serverTime)
    }

    /// Installation authorization controls publishing; a 409 is a normal domain outcome.
    public func executeBroadcast(_ command: BroadcastCommand, installationToken: String) async throws -> BroadcastOutcome {
        try await send(path: [command.gameId, "media", "commands"], method: "POST", token: installationToken,
                       body: JSONEncoder().encode(command), additionalStatuses: [409])
    }

    public func broadcastReceipt(gameId: String, commandId: String, installationToken: String) async throws -> BroadcastOutcome? {
        do {
            return try await send(path: [gameId, "media", "commands", commandId], token: installationToken)
        } catch MatchClientError.http(status: 404, code: "command_not_found") {
            return nil
        }
    }

    private func send<Response: Decodable>(path: [String], method: String = "GET", token: String,
                                          body: Data? = nil, additionalStatuses: Set<Int> = []) async throws -> Response {
        var url = endpoint.url.appendingPathComponent("v1").appendingPathComponent("matches")
        // Identifiers follow the server's ASCII grammar, preventing a scoped path
        // from being redirected by a slash, percent escape, or dot segment.
        for component in path {
            guard !component.isEmpty, component.utf8.count <= 128,
                  component.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw MatchClientError.invalidIdentifier
            }
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

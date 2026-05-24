import Foundation

struct TeamSpec: Codable {
    let name: String
    let shortName: String
    let color: String
}

struct StartGameRequest: Codable {
    let homeTeam: TeamSpec
    let awayTeam: TeamSpec
    let youtubeStreamKey: String
}

struct PublishCredentials: Codable {
    let host: String
    let port: Int
    let streamId: String
    let passphrase: String
}

struct StartGameResponse: Codable {
    let id: String
    let status: String
    let createdAt: String
    let publish: PublishCredentials
}

enum ControlPlaneError: Error {
    case badURL
    case http(Int, Data?)
    case decode(Error)
}

actor ControlPlaneClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init?(baseURL: String, token: String, session: URLSession = .shared) {
        guard let url = URL(string: baseURL) else { return nil }
        self.baseURL = url
        self.token = token
        self.session = session
    }

    func startGame(_ req: StartGameRequest) async throws -> StartGameResponse {
        try await post(path: "/games/start", body: req)
    }

    func endGame(id: String) async throws {
        let _: EmptyResponse = try await post(path: "/games/\(id)/end", body: EmptyRequest())
    }

    private struct EmptyRequest: Codable {}
    private struct EmptyResponse: Codable {}

    private func post<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        var url = baseURL
        if let join = URL(string: path, relativeTo: baseURL) { url = join.absoluteURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ControlPlaneError.http(0, data) }
        guard (200..<300).contains(http.statusCode) else {
            throw ControlPlaneError.http(http.statusCode, data)
        }
        if Res.self == EmptyResponse.self {
            // The end-game route returns a small body; we discard it.
            return EmptyResponse() as! Res
        }
        do {
            return try JSONDecoder().decode(Res.self, from: data)
        } catch {
            throw ControlPlaneError.decode(error)
        }
    }
}

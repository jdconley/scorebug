import Foundation

/// Where a channel stands for live streaming.
public enum YouTubeStatus: String, Codable, Equatable, Sendable {
    case ready
    /// YouTube makes a channel wait 24 hours after live streaming is turned on.
    case liveDisabled = "live_disabled"
    /// The grant was revoked or the channel removed: connect it again.
    case needsReconnect = "needs_reconnect"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = YouTubeStatus(rawValue: raw) ?? .needsReconnect
    }
}

/// One YouTube channel a person connected (`/v1/youtube/connections`). Connections belong to that person.
public struct YouTubeConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var channelId: String
    public var channelTitle: String
    public var channelThumbnail: String?
    public var status: YouTubeStatus
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, channelId: String, channelTitle: String, channelThumbnail: String?, status: YouTubeStatus,
                createdAt: String, updatedAt: String) {
        self.id = id; self.channelId = channelId; self.channelTitle = channelTitle
        self.channelThumbnail = channelThumbnail; self.status = status
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// The channel a team's matches stream to (`GET /v1/teams/:id` → `youtube`), or nil when none is set.
public struct TeamYouTube: Codable, Equatable, Sendable {
    public var connectionId: String
    public var channelTitle: String
    public var channelThumbnail: String?
    public var status: YouTubeStatus
    /// The person whose connection it is; only they can reconnect it.
    public var connectedBy: String

    public init(connectionId: String, channelTitle: String, channelThumbnail: String?, status: YouTubeStatus, connectedBy: String) {
        self.connectionId = connectionId; self.channelTitle = channelTitle; self.channelThumbnail = channelThumbnail
        self.status = status; self.connectedBy = connectedBy
    }
}

/// A match's one YouTube broadcast. Nil before its first Go Live; the link never changes within a match.
public struct MatchYouTube: Codable, Equatable, Sendable {
    public var broadcastId: String
    public var watchUrl: String
    public var channelTitle: String
    public var channelThumbnail: String?
    public var privacy: String

    public init(broadcastId: String, watchUrl: String, channelTitle: String, channelThumbnail: String?, privacy: String) {
        self.broadcastId = broadcastId; self.watchUrl = watchUrl; self.channelTitle = channelTitle
        self.channelThumbnail = channelThumbnail; self.privacy = privacy
    }

    /// Only an https link on YouTube is shown or shared.
    public var url: URL? {
        guard let url = URL(string: watchUrl), url.scheme == "https",
              let host = url.host?.lowercased(), host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        return url
    }
}

/// Where connecting a channel lands: `scorebug://auth?purpose=youtube&status=…[&ticket=…]`.
public enum YouTubeCallback: Equatable, Sendable {
    case ok(ticket: String)
    case cancelled
    /// The YouTube permission box was left unticked on Google's screen.
    case scopeDenied
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
        guard value("purpose") == "youtube" else { return nil }
        switch value("status") {
        case "ok":
            guard let ticket = value("ticket"), SignInCallback.isTicket(ticket) else { self = .error; return }
            self = .ok(ticket: ticket)
        case "cancelled": self = .cancelled
        case "scope_denied": self = .scopeDenied
        default: self = .error
        }
    }
}

extension MatchHTTPClient {
    /// The Google page that asks for the account, the channel and the `youtube` scope.
    public func youtubeConnectURL(token: String) async throws -> URL {
        struct Response: Decodable { let url: String }
        let response: Response = try await send(root: ["youtube"], path: ["connect"], method: "POST", token: token, body: Data("{}".utf8))
        guard let url = URL(string: response.url), url.scheme == "https" || url.scheme == "http" else {
            throw MatchClientError.invalidResponse
        }
        return url
    }

    /// Claims the callback's ticket. 404 `ticket_invalid`; 409 `youtube_no_channel` / `youtube_needs_reconnect`.
    public func claimYouTubeConnection(ticket: String, token: String) async throws -> YouTubeConnection {
        struct Request: Encodable { let ticket: String }
        struct Response: Decodable { let connection: YouTubeConnection }
        let response: Response = try await send(root: ["youtube"], path: ["connections"], method: "POST", token: token,
                                                body: JSONEncoder().encode(Request(ticket: ticket)))
        return response.connection
    }

    public func youtubeConnections(token: String) async throws -> [YouTubeConnection] {
        struct Response: Decodable { let connections: [YouTubeConnection] }
        let response: Response = try await send(root: ["youtube"], path: ["connections"], token: token)
        return response.connections
    }

    /// Checks the channel again, after YouTube's 24-hour live streaming wait for example.
    public func checkYouTubeConnection(_ id: String, token: String) async throws -> YouTubeConnection {
        struct Response: Decodable { let connection: YouTubeConnection }
        let response: Response = try await send(root: ["youtube"], path: ["connections", id, "check"], method: "POST",
                                                token: token, body: Data("{}".utf8))
        return response.connection
    }

    public func deleteYouTubeConnection(_ id: String, token: String) async throws {
        let _: NoContent = try await send(root: ["youtube"], path: ["connections", id], method: "DELETE", token: token)
    }

    /// Owner only, one of their own connections, or nil for none.
    public func setTeamChannel(_ teamId: String, connectionId: String?, token: String) async throws -> TeamYouTube? {
        struct Request: Encodable {
            let connectionId: String?
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(connectionId, forKey: .connectionId) // null clears it
            }
            enum CodingKeys: String, CodingKey { case connectionId }
        }
        struct Response: Decodable { let youtube: TeamYouTube? }
        let response: Response = try await send(root: ["teams"], path: [teamId, "youtube"], method: "PUT", token: token,
                                                body: JSONEncoder().encode(Request(connectionId: connectionId)))
        return response.youtube
    }
}

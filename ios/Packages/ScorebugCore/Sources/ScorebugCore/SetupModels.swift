import Foundation

/// An enrolled owner phone (`/v1/setup/redeem`, `/v1/devices`). See docs/api.md.
public struct Device: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var createdAt: String
    public var lastSeenAt: String?
    public var revokedAt: String?

    public init(id: String, name: String, role: String, createdAt: String, lastSeenAt: String?, revokedAt: String?) {
        self.id = id; self.name = name; self.role = role
        self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.revokedAt = revokedAt
    }
}

public struct SetupRedeemed: Codable, Equatable, Sendable {
    public var device: Device
    public var token: String
    public var serverTime: String
}

/// `GET /v1/devices/me`. `legacy` is only sent by servers from before setup links.
public struct CurrentDevice: Codable, Equatable, Sendable {
    public var role: String
    public var legacy: Bool?
    public var device: Device?
}

/// A named RTMP(S) target. The stream key is write-only; only its last four characters come back.
public struct Destination: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var rtmpUrl: String
    public var streamKeyLast4: String
    public var isDefault: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, name: String, rtmpUrl: String, streamKeyLast4: String, isDefault: Bool,
                createdAt: String, updatedAt: String) {
        self.id = id; self.name = name; self.rtmpUrl = rtmpUrl; self.streamKeyLast4 = streamKeyLast4
        self.isDefault = isDefault; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct MatchInvite: Codable, Equatable, Sendable {
    public var id: String
    public var gameId: String
    public var createdAt: String
    public var expiresAt: String
    public var revokedAt: String?
    public var redemptions: Int
}

/// `code` is the grouped display form (`K7P-4QX`); `link` is a `scorebug://join` URL.
public struct MatchInviteIssued: Codable, Equatable, Sendable {
    public var invite: MatchInvite
    public var code: String
    public var link: String
    public var expiresAt: String
}

/// Always a per-match `score` credential. The new scorer must `take_over` before scoring.
public struct InviteRedeemed: Codable, Equatable, Sendable {
    public var credential: MatchCredential
    public var snapshot: MatchSnapshot
    public var serverTime: String
}

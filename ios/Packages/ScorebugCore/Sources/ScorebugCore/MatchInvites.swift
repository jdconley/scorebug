import Foundation

/// Match join codes (`/v1/matches/:id/invites`, `/v1/invites/redeem`). See docs/api.md.
public struct MatchInvite: Codable, Equatable, Sendable {
    public var id: String
    public var gameId: String
    public var createdAt: String
    public var expiresAt: String
    public var revokedAt: String?
    public var redemptions: Int
}

/// `code` is the grouped display form (`K7P-4QX`); `link` is `https://scorebug.live/join/K7P4QX`.
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

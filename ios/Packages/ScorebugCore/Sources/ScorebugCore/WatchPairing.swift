import Foundation

public struct WatchPairingIssueRequest: Codable, Equatable, Sendable {
    public let pairingId: String
    public let watchDeviceId: String
    public init(pairingId: String, watchDeviceId: String) {
        self.pairingId = pairingId; self.watchDeviceId = watchDeviceId
    }
}

public struct WatchPairingRedeemRequest: Codable, Equatable, Sendable {
    public let redemptionId: String
    public let deviceId: String
    public init(redemptionId: String, deviceId: String) {
        self.redemptionId = redemptionId; self.deviceId = deviceId
    }
}

/// A short-lived capability for one Watch. Never contains installation authority.
public struct WatchPairingIssued: Codable, Equatable, Sendable {
    public let pairingId: String
    public let gameId: String
    public let watchDeviceId: String
    public let role: MatchRole
    public let pairingToken: String
    public let expiresAt: String
    public let serverTime: String
    public init(pairingId: String, gameId: String, watchDeviceId: String, role: MatchRole = .score,
                pairingToken: String, expiresAt: String, serverTime: String) {
        self.pairingId = pairingId; self.gameId = gameId; self.watchDeviceId = watchDeviceId
        self.role = role; self.pairingToken = pairingToken; self.expiresAt = expiresAt; self.serverTime = serverTime
    }
}

public struct WatchPairingRedeemed: Codable, Equatable, Sendable {
    public let pairingId: String
    public let redemptionId: String
    public let credential: MatchCredential
    public let snapshot: MatchSnapshot
    public let serverTime: String
    public init(pairingId: String, redemptionId: String, credential: MatchCredential,
                snapshot: MatchSnapshot, serverTime: String) {
        self.pairingId = pairingId; self.redemptionId = redemptionId
        self.credential = credential; self.snapshot = snapshot; self.serverTime = serverTime
    }
}

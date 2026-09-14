import Foundation

public enum WatchCompanionPhase: String, Codable, Equatable, Sendable { case unpaired, pending, paired }
public struct WatchCompanionNotice: Codable, Equatable, Sendable {
    public let version: Int
    public let deviceId: String
    public let phase: WatchCompanionPhase
    public let gameId: String?
    public let pairingId: String?
    public init(deviceId: String, phase: WatchCompanionPhase, gameId: String? = nil, pairingId: String? = nil) {
        version = 1; self.deviceId = deviceId; self.phase = phase; self.gameId = gameId; self.pairingId = pairingId
    }
}
public struct WatchPairingEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let endpoint: String
    public let offer: WatchPairingIssued
    public init(endpoint: String, offer: WatchPairingIssued) { version = 1; self.endpoint = endpoint; self.offer = offer }
}
public enum WatchCompanionError: Error { case invalidMessage }

/// A setup-only boundary. These payloads never contain installation authority,
/// redeemed credentials, recovery keys, or a queue of scoring commands.
public enum WatchCompanionCodec {
    public static let maximumBytes = 8192
    public static let noticeKey = "scorebug.watch.notice"
    public static let pairingKey = "scorebug.watch.pairing"
    public static func encodeNotice(_ value: WatchCompanionNotice) throws -> Data {
        let data = try JSONEncoder().encode(value); _ = try decodeNotice(data); return data
    }
    public static func decodeNotice(_ data: Data) throws -> WatchCompanionNotice {
        let object = try object(data)
        guard Set(object.keys).isSubset(of: ["version", "deviceId", "phase", "gameId", "pairingId"]) else { throw WatchCompanionError.invalidMessage }
        let value = try JSONDecoder().decode(WatchCompanionNotice.self, from: data)
        guard value.version == 1, uuid(value.deviceId) else { throw WatchCompanionError.invalidMessage }
        if value.phase == .unpaired {
            guard value.gameId == nil, value.pairingId == nil else { throw WatchCompanionError.invalidMessage }
        } else {
            guard let gameId = value.gameId, identifier(gameId), let pairingId = value.pairingId, uuid(pairingId) else { throw WatchCompanionError.invalidMessage }
        }
        return value
    }
    public static func encodeEnvelope(_ value: WatchPairingEnvelope) throws -> Data {
        let data = try JSONEncoder().encode(value); _ = try decodeEnvelope(data); return data
    }
    public static func decodeEnvelope(_ data: Data) throws -> WatchPairingEnvelope {
        let object = try object(data)
        guard Set(object.keys) == ["version", "endpoint", "offer"],
              let offer = object["offer"] as? [String: Any],
              Set(offer.keys) == ["pairingId", "gameId", "watchDeviceId", "role", "pairingToken", "expiresAt", "serverTime"] else {
            throw WatchCompanionError.invalidMessage
        }
        let value = try JSONDecoder().decode(WatchPairingEnvelope.self, from: data)
        guard value.version == 1, uuid(value.offer.pairingId), uuid(value.offer.watchDeviceId),
              identifier(value.offer.gameId), value.offer.role == .score,
              value.offer.pairingToken.utf8.count == 43, identifier(value.offer.pairingToken) else { throw WatchCompanionError.invalidMessage }
        _ = try ScoringEndpoint(value.endpoint)
        return value
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WatchCompanionError.invalidMessage
        }
        return object
    }
    private static func uuid(_ value: String) -> Bool { value.utf8.count == 36 && UUID(uuidString: value) != nil }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

import CryptoKit
import Foundation

public struct PendingWatchPairing: Codable, Equatable, Sendable {
    public let endpoint: String
    public let offer: WatchPairingIssued
    public let request: WatchPairingRedeemRequest
    public let recoveryKey: String
    public init(endpoint: String, offer: WatchPairingIssued, request: WatchPairingRedeemRequest, recoveryKey: String) {
        self.endpoint = endpoint; self.offer = offer; self.request = request; self.recoveryKey = recoveryKey
    }
}

public struct WatchPairedSetup: Codable, Equatable, Sendable {
    public let endpoint: String
    public let pairingId: String
    public let redemptionId: String
    public let credential: MatchCredential
    public init(endpoint: String, pairingId: String, redemptionId: String, credential: MatchCredential) {
        self.endpoint = endpoint; self.pairingId = pairingId; self.redemptionId = redemptionId; self.credential = credential
    }
    /// Nonsecret scope for the existing durable scoring outbox.
    public var scoringScope: String {
        "watch|\(endpoint)|\(SHA256.hash(data: Data(credential.token.utf8)).map { String(format: "%02x", $0) }.joined())"
    }
}

/// Contains secrets. Native adapters must persist this atomically in device Keychain.
/// At most one of pending/paired may be present. An empty record retains device identity.
public struct WatchSetupRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let deviceId: String
    public let pending: PendingWatchPairing?
    public let paired: WatchPairedSetup?
    public init(deviceId: String, pending: PendingWatchPairing? = nil, paired: WatchPairedSetup? = nil) {
        self.version = 1; self.deviceId = deviceId; self.pending = pending; self.paired = paired
    }
}

/// One active owner per store. A thrown save must leave the prior committed value unchanged.
public protocol WatchSetupStorage: Sendable {
    func load() throws -> WatchSetupRecord?
    func save(_ record: WatchSetupRecord) throws
}

public enum WatchSetupError: Error, Equatable, Sendable {
    case busy, storageFailure, invalidSetup, invalidOffer, invalidResponse
    case pendingPairing, alreadyPaired, pendingScoring
}

public struct WatchSetupState: Equatable, Sendable {
    public let record: WatchSetupRecord?
    public let snapshot: MatchSnapshot?
    public let busy: Bool
}

/// The native owner must quiesce scoring before replacing setup. Setup and scoring
/// coordinators must not concurrently mutate the same device's configuration/outbox.
public actor WatchSetupCoordinator {
    private let storage: any WatchSetupStorage
    private let scoringOutbox: any PendingCommandStore
    private let clientFactory: @Sendable (ScoringEndpoint) -> MatchHTTPClient
    private let newDeviceId: @Sendable () -> String
    private let newRedemptionId: @Sendable () -> String
    private let newRecoveryKey: @Sendable () -> String
    private var record: WatchSetupRecord?
    private var snapshot: MatchSnapshot?
    private var loaded = false
    private var busy = false

    public init(storage: any WatchSetupStorage, scoringOutbox: any PendingCommandStore,
                clientFactory: @escaping @Sendable (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
                newDeviceId: @escaping @Sendable () -> String = { UUID().uuidString },
                newRedemptionId: @escaping @Sendable () -> String = { UUID().uuidString },
                newRecoveryKey: @escaping @Sendable () -> String = {
                    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }) {
        self.storage = storage; self.scoringOutbox = scoringOutbox; self.clientFactory = clientFactory
        self.newDeviceId = newDeviceId; self.newRedemptionId = newRedemptionId; self.newRecoveryKey = newRecoveryKey
    }

    public func state() -> WatchSetupState { WatchSetupState(record: record, snapshot: snapshot, busy: busy) }
    public func restore() throws -> WatchSetupState {
        try begin(); defer { busy = false }
        try load()
        return settledState()
    }

    public func accept(endpoint: String, offer: WatchPairingIssued, replacingCurrent: Bool = false) async throws -> WatchSetupState {
        try begin(); defer { busy = false }
        try load()
        let endpoint = try Self.endpoint(endpoint)
        guard let record else { throw WatchSetupError.invalidSetup }
        if let pending = record.pending {
            guard pending.endpoint == endpoint, Self.sameOffer(pending.offer, offer) else { throw WatchSetupError.pendingPairing }
            return try await redeem(pending)
        }
        if let paired = record.paired {
            if paired.endpoint == endpoint && paired.pairingId == offer.pairingId
                && paired.credential.gameId == offer.gameId && paired.credential.deviceId == offer.watchDeviceId {
                return settledState()
            }
            guard replacingCurrent else { throw WatchSetupError.alreadyPaired }
        }
        try requireEmptyScoringOutbox()
        guard Self.validOffer(offer, deviceId: record.deviceId),
              let expires = Self.date(offer.expiresAt), let server = Self.date(offer.serverTime), expires > server else {
            throw WatchSetupError.invalidOffer
        }
        let request = WatchPairingRedeemRequest(redemptionId: newRedemptionId(), deviceId: record.deviceId)
        let key = newRecoveryKey()
        guard Self.uuid(request.redemptionId), Self.secret(key) else { throw WatchSetupError.invalidSetup }
        let pending = PendingWatchPairing(endpoint: endpoint, offer: offer, request: request, recoveryKey: key)
        try persist(WatchSetupRecord(deviceId: record.deviceId, pending: pending))
        snapshot = nil
        return try await redeem(pending)
    }

    public func recover() async throws -> WatchSetupState {
        try begin(); defer { busy = false }
        try load()
        guard let pending = record?.pending else { return settledState() }
        return try await redeem(pending)
    }

    /// An explicit discard first retries the durable redemption. Only the server's
    /// definitive unused-and-expired response permits clearing it; a committed
    /// redemption is recovered instead, even after its original capability expired.
    public func discardExpired() async throws -> WatchSetupState {
        try begin(); defer { busy = false }
        try load()
        guard let pending = record?.pending else { return settledState() }
        do { return try await redeem(pending) }
        catch MatchClientError.http(status: 409, code: "pairing_expired") {
            try Task.checkCancellation()
            try persist(WatchSetupRecord(deviceId: pending.request.deviceId))
            snapshot = nil
            return settledState()
        }
    }

    private func redeem(_ pending: PendingWatchPairing) async throws -> WatchSetupState {
        try requireEmptyScoringOutbox()
        try Task.checkCancellation()
        let response = try await clientFactory(ScoringEndpoint(pending.endpoint)).redeemWatchPairing(
            gameId: pending.offer.gameId, pairingId: pending.offer.pairingId, pairingToken: pending.offer.pairingToken,
            recoveryKey: pending.recoveryKey, request: pending.request)
        try Task.checkCancellation()
        guard response.pairingId == pending.offer.pairingId, response.redemptionId == pending.request.redemptionId,
              response.credential.gameId == pending.offer.gameId, response.credential.deviceId == pending.request.deviceId,
              response.credential.role == .score, Self.credentialToken(response.credential.token),
              response.snapshot.id == pending.offer.gameId, Self.date(response.serverTime) != nil else {
            throw WatchSetupError.invalidResponse
        }
        let paired = WatchPairedSetup(endpoint: pending.endpoint, pairingId: response.pairingId,
            redemptionId: response.redemptionId, credential: response.credential)
        try persist(WatchSetupRecord(deviceId: pending.request.deviceId, paired: paired))
        snapshot = response.snapshot
        return settledState()
    }

    private func begin() throws {
        guard !busy else { throw WatchSetupError.busy }
        busy = true
    }
    private func settledState() -> WatchSetupState { WatchSetupState(record: record, snapshot: snapshot, busy: false) }
    private func requireEmptyScoringOutbox() throws {
        let pending: PendingMatchCommand?
        do { pending = try scoringOutbox.load() } catch { throw WatchSetupError.storageFailure }
        guard pending == nil else { throw WatchSetupError.pendingScoring }
    }
    private func load() throws {
        guard !loaded else { return }
        let saved: WatchSetupRecord?
        do { saved = try storage.load() } catch { throw WatchSetupError.storageFailure }
        if let saved {
            guard Self.validRecord(saved) else { throw WatchSetupError.invalidSetup }
            record = saved; loaded = true
        } else {
            try requireEmptyScoringOutbox()
            let deviceId = newDeviceId()
            guard Self.uuid(deviceId) else { throw WatchSetupError.invalidSetup }
            try persist(WatchSetupRecord(deviceId: deviceId))
        }
    }
    private func persist(_ value: WatchSetupRecord) throws {
        do { try storage.save(value) } catch { throw WatchSetupError.storageFailure }
        record = value; loaded = true
    }
    private static func sameOffer(_ a: WatchPairingIssued, _ b: WatchPairingIssued) -> Bool {
        a.pairingId == b.pairingId && a.gameId == b.gameId && a.watchDeviceId == b.watchDeviceId
            && a.role == b.role && a.pairingToken == b.pairingToken && a.expiresAt == b.expiresAt
    }
    private static func validRecord(_ record: WatchSetupRecord) -> Bool {
        guard record.version == 1, uuid(record.deviceId), record.pending == nil || record.paired == nil else { return false }
        if let pending = record.pending {
            guard (try? endpoint(pending.endpoint)) == pending.endpoint,
                  validOffer(pending.offer, deviceId: record.deviceId),
                  pending.request.deviceId == record.deviceId, uuid(pending.request.redemptionId), secret(pending.recoveryKey) else { return false }
        }
        if let paired = record.paired {
            guard (try? endpoint(paired.endpoint)) == paired.endpoint, uuid(paired.pairingId), uuid(paired.redemptionId),
                  paired.credential.deviceId == record.deviceId, paired.credential.role == .score,
                  identifier(paired.credential.gameId), credentialToken(paired.credential.token) else { return false }
        }
        return true
    }
    private static func validOffer(_ offer: WatchPairingIssued, deviceId: String) -> Bool {
        guard uuid(offer.pairingId), offer.watchDeviceId == deviceId, offer.role == .score,
              identifier(offer.gameId), secret(offer.pairingToken),
              let expires = date(offer.expiresAt), let server = date(offer.serverTime) else { return false }
        // A retried issuance may report current serverTime after expiry. Pending
        // attempts still recover; first acceptance separately requires positive life.
        return expires.timeIntervalSince(server) <= 300
    }
    private static func uuid(_ value: String) -> Bool { value.utf8.count == 36 && UUID(uuidString: value) != nil }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func secret(_ value: String) -> Bool {
        guard value.utf8.count == 43, identifier(value),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else { return false }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
    }
    private static func credentialToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    private static func endpoint(_ value: String) throws -> String {
        try ScoringEndpoint(value).canonicalAddress
    }
    private static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = parser.date(from: value) { return value }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}

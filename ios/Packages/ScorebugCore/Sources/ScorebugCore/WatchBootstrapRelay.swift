import Foundation

/// Capability-bearing view of a saved pending offer. Syntax alone does not
/// authorize forwarding; the phone must match its durably persisted authority.
public struct WatchBootstrapAuthority: Codable, Equatable, Sendable {
    public let scope: WatchRelayScope
    public let pairingToken: String
    public init(scope: WatchRelayScope, pairingToken: String) {
        self.scope = scope; self.pairingToken = pairingToken
    }
}

/// Transient secret data. Never publish through application context or logs.
public struct WatchBootstrapRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestId: String
    public let authority: WatchBootstrapAuthority
    public let redemption: WatchPairingRedeemRequest
    public let recoveryKey: String
    public init(requestId: String, authority: WatchBootstrapAuthority,
                redemption: WatchPairingRedeemRequest, recoveryKey: String) {
        version = 1; type = "watch_bootstrap_request"; self.requestId = requestId
        self.authority = authority; self.redemption = redemption; self.recoveryKey = recoveryKey
    }
}

public enum WatchBootstrapResult: Codable, Equatable, Sendable {
    case redeemed(WatchPairingRedeemed)
    case failure(WatchRelayFailure)
    private enum Kind: String, Codable { case redeemed, failure }
    private enum Keys: String, CodingKey { case type, value, error }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .redeemed: self = .redeemed(try c.decode(WatchPairingRedeemed.self, forKey: .value))
        case .failure: self = .failure(try c.decode(WatchRelayFailure.self, forKey: .error))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .redeemed(let value): try c.encode(Kind.redeemed, forKey: .type); try c.encode(value, forKey: .value)
        case .failure(let failure): try c.encode(Kind.failure, forKey: .type); try c.encode(failure, forKey: .error)
        }
    }
}

/// A successful reply contains a scoped Watch credential, never phone authority.
public struct WatchBootstrapReply: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestId: String
    public let scope: WatchRelayScope
    public let redemptionId: String
    public let result: WatchBootstrapResult
    public init(request: WatchBootstrapRequest, result: WatchBootstrapResult) {
        version = 1; type = "watch_bootstrap_reply"; requestId = request.requestId
        scope = request.authority.scope; redemptionId = request.redemption.redemptionId; self.result = result
    }
}

import Foundation

/// A nonsecret pairing identity. Syntax validity does not authorize forwarding.
public struct WatchRelayScope: Codable, Equatable, Sendable {
    public let endpoint: String
    public let gameId: String
    public let watchDeviceId: String
    public let pairingId: String
    public init(endpoint: String, gameId: String, watchDeviceId: String, pairingId: String) {
        self.endpoint = endpoint; self.gameId = gameId
        self.watchDeviceId = watchDeviceId; self.pairingId = pairingId
    }
}

public enum WatchRelayOperationKind: String, Codable, Equatable, Sendable {
    case snapshot, execute, receipt
}

public enum WatchRelayOperation: Codable, Equatable, Sendable {
    case snapshot
    case execute(MatchCommand)
    case receipt(commandId: String)

    public var kind: WatchRelayOperationKind {
        switch self { case .snapshot: return .snapshot; case .execute: return .execute; case .receipt: return .receipt }
    }
    private enum Keys: String, CodingKey { case type, command, commandId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(WatchRelayOperationKind.self, forKey: .type) {
        case .snapshot: self = .snapshot
        case .execute: self = .execute(try c.decode(MatchCommand.self, forKey: .command))
        case .receipt: self = .receipt(commandId: try c.decode(String.self, forKey: .commandId))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .snapshot: break
        case .execute(let command): try c.encode(command, forKey: .command)
        case .receipt(let commandId): try c.encode(commandId, forKey: .commandId)
        }
    }
}

public struct WatchRelayRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestId: String
    public let scope: WatchRelayScope
    public let credential: MatchCredential
    public let operation: WatchRelayOperation
    public init(requestId: String, scope: WatchRelayScope, credential: MatchCredential, operation: WatchRelayOperation) {
        version = 1; self.requestId = requestId; self.scope = scope
        self.credential = credential; self.operation = operation
    }
}

/// Failure never means a mutation was rejected or a receipt is absent. These
/// values carry no raw HTTP body, credential, or underlying exception text.
public enum WatchRelayFailure: Error, Codable, Equatable, Sendable {
    case unauthorized, forbidden, invalidResponse, invalidRequest, scopeMismatch, unavailable, cancelled, busy
    case http(status: Int, code: String?)

    private enum Kind: String, Codable {
        case unauthorized, forbidden, http, invalidResponse, invalidRequest, scopeMismatch, unavailable, cancelled, busy
    }
    private enum Keys: String, CodingKey { case type, status, code }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .unauthorized: self = .unauthorized
        case .forbidden: self = .forbidden
        case .invalidResponse: self = .invalidResponse
        case .invalidRequest: self = .invalidRequest
        case .scopeMismatch: self = .scopeMismatch
        case .unavailable: self = .unavailable
        case .cancelled: self = .cancelled
        case .busy: self = .busy
        case .http: self = .http(status: try c.decode(Int.self, forKey: .status), code: try c.decodeIfPresent(String.self, forKey: .code))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        let kind: Kind
        switch self {
        case .unauthorized: kind = .unauthorized
        case .forbidden: kind = .forbidden
        case .invalidResponse: kind = .invalidResponse
        case .invalidRequest: kind = .invalidRequest
        case .scopeMismatch: kind = .scopeMismatch
        case .unavailable: kind = .unavailable
        case .cancelled: kind = .cancelled
        case .busy: kind = .busy
        case .http(let status, let code):
            kind = .http; try c.encode(status, forKey: .status); try c.encode(code, forKey: .code)
        }
        try c.encode(kind, forKey: .type)
    }
}

public enum WatchRelayResult: Codable, Equatable, Sendable {
    case snapshot(MatchSnapshotResponse)
    case outcome(CommandOutcome)
    case receiptFound(CommandOutcome)
    case receiptAbsent
    case failure(WatchRelayFailure)

    private enum Kind: String, Codable { case snapshot, outcome, receiptFound = "receipt_found", receiptAbsent = "receipt_absent", failure }
    private enum Keys: String, CodingKey { case type, value, error }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .snapshot: self = .snapshot(try c.decode(MatchSnapshotResponse.self, forKey: .value))
        case .outcome: self = .outcome(try c.decode(CommandOutcome.self, forKey: .value))
        case .receiptFound: self = .receiptFound(try c.decode(CommandOutcome.self, forKey: .value))
        case .receiptAbsent: self = .receiptAbsent
        case .failure: self = .failure(try c.decode(WatchRelayFailure.self, forKey: .error))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        let kind: Kind
        switch self {
        case .snapshot(let value): kind = .snapshot; try c.encode(value, forKey: .value)
        case .outcome(let value): kind = .outcome; try c.encode(value, forKey: .value)
        case .receiptFound(let value): kind = .receiptFound; try c.encode(value, forKey: .value)
        case .receiptAbsent: kind = .receiptAbsent
        case .failure(let error): kind = .failure; try c.encode(error, forKey: .error)
        }
        try c.encode(kind, forKey: .type)
    }
}

public struct WatchRelayReply: Codable, Equatable, Sendable {
    public let version: Int
    public let requestId: String
    public let scope: WatchRelayScope
    public let operation: WatchRelayOperationKind
    public let result: WatchRelayResult
    public init(request: WatchRelayRequest, result: WatchRelayResult) {
        version = 1; requestId = request.requestId; scope = request.scope
        operation = request.operation.kind; self.result = result
    }
}

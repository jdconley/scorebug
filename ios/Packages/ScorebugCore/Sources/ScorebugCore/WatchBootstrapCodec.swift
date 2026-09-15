import Foundation

/// Strict bootstrap-only boundary. The shared bounded JSON preflight and snapshot
/// validator keep scoring and bootstrap limits consistent, without wrapping one
/// message kind inside the other. Plain Codable does not provide this validation.
public enum WatchBootstrapCodec {
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumReplyBytes = 32 * 1024
    private typealias V = WatchRelayCodec

    public static func validateAuthority(_ value: WatchBootstrapAuthority) throws {
        try V.validateScope(value.scope)
        guard secret(value.pairingToken) else { throw WatchRelayCodecError.invalidMessage }
    }
    public static func encodeRequest(_ value: WatchBootstrapRequest) throws -> Data {
        do {
            let data = try V.encode(value)
            _ = try decodeRequest(data)
            return data
        } catch { throw WatchRelayCodecError.invalidMessage }
    }
    public static func decodeRequest(_ data: Data) throws -> WatchBootstrapRequest {
        do {
            let object = try V.object(data, maximum: maximumRequestBytes)
            try V.keys(object, ["version", "type", "requestId", "authority", "redemption", "recoveryKey"])
            try V.version(object)
            guard try V.string(object["type"]) == "watch_bootstrap_request" else { throw WatchRelayCodecError.invalidMessage }
            let authority = try V.dictionary(object["authority"])
            try V.keys(authority, ["scope", "pairingToken"])
            try V.scopeObject(authority["scope"])
            let redemption = try V.dictionary(object["redemption"])
            try V.keys(redemption, ["deviceId", "redemptionId"])
            guard V.uuid(try V.string(redemption["deviceId"])), V.uuid(try V.string(redemption["redemptionId"])),
                  secret(try V.string(object["recoveryKey"])) else { throw WatchRelayCodecError.invalidMessage }
            let value = try JSONDecoder().decode(WatchBootstrapRequest.self, from: data)
            try validateAuthority(value.authority)
            guard value.redemption.deviceId == value.authority.scope.watchDeviceId else { throw WatchRelayCodecError.invalidMessage }
            return value
        } catch { throw WatchRelayCodecError.invalidMessage }
    }
    public static func encodeReply(_ value: WatchBootstrapReply, for request: WatchBootstrapRequest) throws -> Data {
        do {
            let data = try V.encode(value)
            _ = try decodeReply(data, for: request)
            return data
        } catch { throw WatchRelayCodecError.invalidMessage }
    }
    public static func decodeReply(_ data: Data, for request: WatchBootstrapRequest) throws -> WatchBootstrapReply {
        do {
            _ = try encodeRequest(request)
            let object = try V.object(data, maximum: maximumReplyBytes)
            try V.keys(object, ["version", "type", "requestId", "scope", "redemptionId", "result"])
            try V.version(object)
            guard try V.string(object["type"]) == "watch_bootstrap_reply",
                  V.uuid(try V.string(object["redemptionId"])) else { throw WatchRelayCodecError.invalidMessage }
            try V.scopeObject(object["scope"])
            let result = try V.dictionary(object["result"])
            switch try V.string(result["type"]) {
            case "redeemed":
                try V.keys(result, ["type", "value"])
                try redeemedObject(result["value"])
            case "failure":
                try V.keys(result, ["type", "error"])
                try V.failureObject(result["error"])
            default: throw WatchRelayCodecError.invalidMessage
            }
            let value = try JSONDecoder().decode(WatchBootstrapReply.self, from: data)
            let scope = request.authority.scope
            guard value.requestId == request.requestId, value.scope == scope,
                  value.redemptionId == request.redemption.redemptionId else { throw WatchRelayCodecError.invalidMessage }
            if case .redeemed(let redeemed) = value.result {
                guard redeemed.pairingId == scope.pairingId, redeemed.redemptionId == request.redemption.redemptionId,
                      redeemed.credential.gameId == scope.gameId, redeemed.credential.deviceId == scope.watchDeviceId,
                      redeemed.snapshot.id == scope.gameId else { throw WatchRelayCodecError.invalidMessage }
            }
            return value
        } catch { throw WatchRelayCodecError.invalidMessage }
    }

    private static func redeemedObject(_ input: Any?) throws {
        let value = try V.dictionary(input)
        try V.keys(value, ["pairingId", "redemptionId", "credential", "snapshot", "serverTime"])
        guard V.uuid(try V.string(value["pairingId"])), V.uuid(try V.string(value["redemptionId"])) else { throw WatchRelayCodecError.invalidMessage }
        let credential = try V.dictionary(value["credential"])
        try V.keys(credential, ["gameId", "deviceId", "role", "token"])
        guard try V.string(credential["role"]) == "score",
              secret(try V.string(credential["token"])) else { throw WatchRelayCodecError.invalidMessage }
        // Identity strings are compared with the already validated request scope.
        _ = try V.string(credential["gameId"]); _ = try V.string(credential["deviceId"])
        try V.snapshotObject(value["snapshot"])
        try V.date(value["serverTime"])
    }
    private static func secret(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              data.count == 32 else { return false }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
    }
}

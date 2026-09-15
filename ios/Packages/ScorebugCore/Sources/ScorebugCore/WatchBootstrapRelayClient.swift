import Foundation

/// One bootstrap attempt over an externally owned, bounded message transport.
/// The setup coordinator owns retries and persistence of the redemption identity.
public struct WatchBootstrapRelayClient: Sendable {
    public typealias Sender = @Sendable (Data) async throws -> Data
    private let send: Sender
    private let requestId: @Sendable () -> String
    public init(send: @escaping Sender, requestId: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.send = send; self.requestId = requestId
    }
    public func redeem(_ pending: PendingWatchPairing) async throws -> WatchPairingRedeemed {
        try Task.checkCancellation()
        guard pending.offer.role == .score else { throw WatchRelayCodecError.invalidMessage }
        let scope = WatchRelayScope(endpoint: pending.endpoint, gameId: pending.offer.gameId,
            watchDeviceId: pending.offer.watchDeviceId, pairingId: pending.offer.pairingId)
        let request = WatchBootstrapRequest(requestId: requestId(),
            authority: WatchBootstrapAuthority(scope: scope, pairingToken: pending.offer.pairingToken),
            redemption: pending.request, recoveryKey: pending.recoveryKey)
        let encoded = try WatchBootstrapCodec.encodeRequest(request)
        try Task.checkCancellation()
        let data = try await send(encoded)
        try Task.checkCancellation()
        let reply = try WatchBootstrapCodec.decodeReply(data, for: request)
        try Task.checkCancellation()
        switch reply.result {
        case .redeemed(let value): return value
        case .failure(let failure):
            switch failure {
            case .unauthorized: throw MatchClientError.unauthorized
            case .forbidden: throw MatchClientError.forbidden
            case .http(let status, let code): throw MatchClientError.http(status: status, code: code)
            case .invalidResponse: throw MatchClientError.invalidResponse
            default: throw failure
            }
        }
    }
}

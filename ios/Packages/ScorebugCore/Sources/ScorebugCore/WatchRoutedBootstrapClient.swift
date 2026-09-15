import Foundation

/// Chooses one bounded transport for each setup-coordinator attempt. Recovery
/// after uncertainty is a later coordinator invocation, never an inline retry.
public actor WatchRoutedBootstrapClient {
    public typealias Redemption = @Sendable (PendingWatchPairing) async throws -> WatchPairingRedeemed
    private enum Route {
        case direct, companion
        var alternate: Route { self == .direct ? .companion : .direct }
    }
    /// Routing history contains no capability, recovery key, or returned token.
    private struct Identity: Equatable {
        let scope: WatchRelayScope
        let redemption: WatchPairingRedeemRequest
        init(_ pending: PendingWatchPairing) throws {
            scope = WatchRelayScope(endpoint: pending.endpoint, gameId: pending.offer.gameId,
                watchDeviceId: pending.offer.watchDeviceId, pairingId: pending.offer.pairingId)
            try WatchRelayCodec.validateScope(scope)
            guard pending.request.deviceId == scope.watchDeviceId,
                  WatchRelayCodec.uuid(pending.request.redemptionId) else { throw WatchRelayCodecError.invalidMessage }
            redemption = pending.request
        }
    }
    private let direct: Redemption
    private let companion: Redemption
    private let companionAvailable: @Sendable () async -> Bool
    private var identity: Identity?
    private var preferred = Route.direct
    private var busy = false

    public init(direct: @escaping Redemption, companion: @escaping Redemption,
                companionAvailable: @escaping @Sendable () async -> Bool) {
        self.direct = direct; self.companion = companion; self.companionAvailable = companionAvailable
    }

    public func redeem(_ pending: PendingWatchPairing) async throws -> WatchPairingRedeemed {
        try Task.checkCancellation()
        guard !busy else { throw WatchRelayFailure.busy }
        busy = true
        defer { busy = false }
        let current = try Identity(pending)
        if identity != current { identity = current; preferred = .direct }
        var route = preferred
        if route == .companion {
            let available = await companionAvailable()
            try Task.checkCancellation()
            if !available { route = .direct }
        }
        try Task.checkCancellation()
        do {
            let response = try await (route == .direct ? direct : companion)(pending)
            try Task.checkCancellation()
            preferred = route
            return response
        } catch {
            // A cancelled owner cannot publish a routing hint from a late error.
            try Task.checkCancellation()
            // If availability selected direct instead of an old companion
            // preference, a terminal direct failure also retires that old hint.
            preferred = Self.canRecover(error, from: route) ? route.alternate : route
            throw error
        }
    }

    private static func canRecover(_ error: Error, from route: Route) -> Bool {
        // Local companion failures only describe the companion path. Direct
        // retry hints require the explicit networking URLError taxonomy.
        if error is WatchRelayFailure {
            return route == .companion && WatchRoutedScoringClient.isRecoverableTransportFailure(error)
        }
        return WatchRoutedScoringClient.isRecoverableTransportFailure(error)
    }
}

import Foundation

/// One pairing's route preference. Inject bounded clients; the coordinator still
/// owns command persistence, receipt-first recovery and all mutation retries.
public actor WatchRoutedScoringClient: MatchScoringClient {
    private enum Route { case direct, companion
        var alternate: Route { self == .direct ? .companion : .direct }
    }
    private let direct: any MatchScoringClient
    private let companion: any MatchScoringClient
    private let companionAvailable: @Sendable () async -> Bool
    private var preferred = Route.direct
    private var recovery: (commandId: String, route: Route)?
    private var busy = false

    public init(direct: any MatchScoringClient, companion: any MatchScoringClient,
                companionAvailable: @escaping @Sendable () async -> Bool) {
        self.direct = direct; self.companion = companion; self.companionAvailable = companionAvailable
    }

    public func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse {
        try await read(preferred, receiptId: nil) { try await $0.snapshot(credential: credential) }
    }

    public func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome? {
        let first = recovery?.commandId == commandId ? recovery!.route : preferred
        return try await read(first, receiptId: commandId) {
            try await $0.receipt(commandId: commandId, credential: credential)
        }
    }

    public func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome {
        try begin(); defer { busy = false }
        let route = try await availableRoute(preferred)
        do {
            let result = try await client(route).execute(command, credential: credential)
            try Task.checkCancellation()
            preferred = route; recovery = nil
            return result
        } catch {
            try Task.checkCancellation()
            if Self.canFallback(error, from: route) {
                recovery = (command.commandId, route.alternate)
            }
            // Do not retry this mutation, including on a pre-dispatch failure.
            throw error
        }
    }

    /// Shared with foreground model recovery. Server/domain, malformed response,
    /// TLS, cancellation and unknown failures are deliberately excluded.
    public nonisolated static func isRecoverableTransportFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return true
            default: return false
            }
        }
        if let error = error as? WatchRelayFailure {
            switch error {
            case .unavailable, .busy, .scopeMismatch: return true
            default: return false
            }
        }
        return false
    }

    private static func canFallback(_ error: Error, from route: Route) -> Bool {
        // These local failures describe the companion path, never a direct
        // server response. Direct networking failures are recognized URLErrors.
        if error is WatchRelayFailure { return route == .companion && isRecoverableTransportFailure(error) }
        return isRecoverableTransportFailure(error)
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !busy else { throw WatchRelayFailure.busy }
        busy = true
    }
    private func client(_ route: Route) -> any MatchScoringClient {
        route == .direct ? direct : companion
    }
    private func availableRoute(_ route: Route) async throws -> Route {
        try Task.checkCancellation()
        guard route == .companion else { return .direct }
        let available = await companionAvailable()
        try Task.checkCancellation()
        return available ? .companion : .direct
    }
    private func read<Value: Sendable>(_ requested: Route, receiptId: String?,
                                      operation: @Sendable (any MatchScoringClient) async throws -> Value) async throws -> Value {
        try begin(); defer { busy = false }
        let first = try await availableRoute(requested)
        do {
            let value = try await operation(client(first))
            try Task.checkCancellation()
            rememberSuccess(first, receiptId: receiptId)
            return value
        } catch {
            try Task.checkCancellation()
            guard Self.canFallback(error, from: first) else { throw error }
            let alternate = try await availableRoute(first.alternate)
            guard alternate != first else { throw error }
            // Only one alternate; its error propagates without another attempt.
            do {
                let value = try await operation(client(alternate))
                try Task.checkCancellation()
                rememberSuccess(alternate, receiptId: receiptId)
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
    }
    private func rememberSuccess(_ route: Route, receiptId: String?) {
        preferred = route
        if let receiptId, recovery?.commandId == receiptId { recovery = nil }
    }
}

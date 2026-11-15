import Foundation

/// One redemption authorized by a durably saved phone offer. Recovery preserves
/// the original Watch capability, redemption identity and recovery key. HTTP
/// success does not activate a scoring binding or persist returned credentials.
@MainActor
public final class WatchBootstrapPhoneForwarder {
    public typealias ClientFactory = @Sendable (ScoringEndpoint) -> MatchHTTPClient
    public typealias Scheduler = WatchRelayMessageTransport.Scheduler

    private struct Pending {
        let id: UUID
        let generation: UUID
        let start: TimeInterval
        let deadline: TimeInterval
        let task: Task<WatchBootstrapResult, Never>
        var failure: WatchRelayFailure?
        var cancelTimer: WatchRelayMessageTransport.ScheduledCancellation?
    }
    private let timeout: TimeInterval
    private let now: @MainActor @Sendable () -> TimeInterval
    private let schedule: Scheduler
    private let clientFactory: ClientFactory
    private var authority: WatchBootstrapAuthority?
    private var generation = UUID()
    private var pending: Pending?

    public init(timeout: TimeInterval = 3,
                now: @escaping @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: Scheduler? = nil, clientFactory: @escaping ClientFactory) {
        self.timeout = timeout; self.now = now
        self.schedule = schedule ?? Self.defaultScheduler; self.clientFactory = clientFactory
    }

    /// Each publication invalidates old ownership, including an explicit peer
    /// replacement with the same scope. Invalid syntax leaves forwarding closed.
    public func updateAuthority(_ value: WatchBootstrapAuthority?) throws {
        authority = nil
        generation = UUID()
        if let id = pending?.id { invalidate(id, failure: .scopeMismatch) }
        if let value {
            try WatchBootstrapCodec.validateAuthority(value)
            authority = value
        }
    }

    /// Invalid incoming bytes have no trusted request identity; an empty bounded
    /// response makes the typed caller fail decoding. Valid requests always get
    /// a correlated result or failure, including busy/timeout/cancellation.
    public func forward(_ data: Data) async -> Data {
        guard let request = try? WatchBootstrapCodec.decodeRequest(data) else { return Data() }
        if Task.isCancelled { return reply(.failure(.cancelled), for: request) }
        guard let authority, request.authority == authority else { return reply(.failure(.scopeMismatch), for: request) }
        guard pending == nil else { return reply(.failure(.busy), for: request) }
        let start = now(), deadline = start + timeout
        guard timeout.isFinite, timeout > 0, start.isFinite,
              deadline.isFinite, deadline > start else { return reply(.failure(.unavailable), for: request) }
        // Full scope and capability matched before constructing any HTTP client.
        // Do not reject by local expiry: committed redemption remains recoverable.
        guard let endpoint = try? ScoringEndpoint(authority.scope.endpoint) else { return reply(.failure(.scopeMismatch), for: request) }
        let currentGeneration = generation
        let client = clientFactory(endpoint)
        if Task.isCancelled { return reply(.failure(.cancelled), for: request) }
        guard generation == currentGeneration, self.authority == authority else { return reply(.failure(.scopeMismatch), for: request) }
        let id = UUID()
        let task = Task { @MainActor () -> WatchBootstrapResult in
            do {
                try Task.checkCancellation()
                return .redeemed(try await client.redeemWatchPairing(
                    gameId: authority.scope.gameId, pairingId: authority.scope.pairingId,
                    pairingToken: request.authority.pairingToken, recoveryKey: request.recoveryKey,
                    request: request.redemption))
            } catch { return .failure(Self.failure(error)) }
        }
        pending = Pending(id: id, generation: currentGeneration, start: start, deadline: deadline, task: task)
        armTimer(id)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { [weak self] in
            // Do not queue cancellation behind the child on MainActor. Cancel
            // its Sendable handle now, then publish the actor-owned failure.
            task.cancel()
            Task { @MainActor [weak self] in self?.invalidate(id, failure: .cancelled) }
        }
        // task.value has joined. Only now may another HTTP request be admitted.
        guard let current = pending, current.id == id else { return reply(.failure(.unavailable), for: request) }
        let completed: WatchBootstrapResult
        if current.generation != generation { completed = .failure(.scopeMismatch) }
        else if Task.isCancelled { completed = .failure(.cancelled) }
        else if let failure = current.failure { completed = .failure(failure) }
        else {
            let time = now()
            completed = time.isFinite && time >= current.start && time < current.deadline ? result : .failure(.unavailable)
        }
        pending = nil
        current.cancelTimer?()
        return reply(completed, for: request)
    }

    private func invalidate(_ id: UUID, failure: WatchRelayFailure) {
        guard var current = pending, current.id == id else { return }
        if current.failure == nil { current.failure = failure }
        let cancelTimer = current.cancelTimer
        current.cancelTimer = nil
        // Publish invalidation before synchronous cancellation handlers can run.
        pending = current
        current.task.cancel()
        cancelTimer?()
    }

    private func armTimer(_ id: UUID) {
        guard let current = pending, current.id == id, current.failure == nil else { return }
        let time = now()
        guard time.isFinite, time >= current.start, time < current.deadline else {
            invalidate(id, failure: .unavailable)
            return
        }
        pending?.cancelTimer = nil
        current.cancelTimer?()
        guard pending?.id == id, pending?.failure == nil else { return }
        let cancel = schedule(current.deadline - time) { [weak self] in self?.armTimer(id) }
        if pending?.id == id, pending?.failure == nil { pending?.cancelTimer = cancel }
        else { cancel() }
    }

    private func reply(_ result: WatchBootstrapResult, for request: WatchBootstrapRequest) -> Data {
        if let encoded = try? WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: result), for: request) { return encoded }
        // Malformed or oversized server models/error codes never leak into a
        // reply. The already validated request permits this small fallback.
        return (try? WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: .failure(.invalidResponse)), for: request)) ?? Data()
    }

    private static func failure(_ error: Error) -> WatchRelayFailure {
        if error is DecodingError { return .invalidResponse }
        if let error = error as? MatchClientError {
            switch error {
            case .unauthorized: return .unauthorized
            case .forbidden: return .forbidden
            case .http(let status, let code): return .http(status: status, code: code)
            case .invalidResponse: return .invalidResponse
            case .invalidIdentifier: return .invalidRequest
            }
        }
        if let error = error as? WatchRelayFailure { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if WatchRoutedScoringClient.isRecoverableTransportFailure(error) { return .unavailable }
        }
        // Preserve terminal transport failures across the wire. TLS and unknown
        // errors must not become permission for automatic route fallback.
        return .invalidResponse
    }

    private static let defaultScheduler: Scheduler = { delay, fire in
        let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            if !Task.isCancelled { fire() }
        }
        return { task.cancel() }
    }
}

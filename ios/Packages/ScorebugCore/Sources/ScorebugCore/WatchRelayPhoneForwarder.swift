import Foundation

/// One authorized phone-side scoring request. Binding publication must follow
/// durable pairing persistence. This owner never uses phone credentials, retries
/// a mutation, or releases busy ownership before its HTTP task has terminated.
@MainActor
public final class WatchRelayPhoneForwarder {
    public typealias ClientFactory = @Sendable (ScoringEndpoint) -> any MatchScoringClient
    public typealias Scheduler = WatchRelayMessageTransport.Scheduler

    private struct Pending {
        let id: UUID
        let generation: UUID
        let start: TimeInterval
        let deadline: TimeInterval
        let task: Task<WatchRelayResult, Never>
        var failure: WatchRelayFailure?
        var cancelTimer: WatchRelayMessageTransport.ScheduledCancellation?
    }
    private let timeout: TimeInterval
    private let now: @MainActor @Sendable () -> TimeInterval
    private let schedule: Scheduler
    private let clientFactory: ClientFactory
    private var binding: WatchRelayScope?
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
    public func updateBinding(_ scope: WatchRelayScope?) throws {
        binding = nil
        generation = UUID()
        if let id = pending?.id { invalidate(id, failure: .scopeMismatch) }
        if let scope {
            try WatchRelayCodec.validateScope(scope)
            binding = scope
        }
    }

    /// Invalid incoming bytes have no trusted request identity; an empty bounded
    /// response makes the typed caller fail decoding. Valid requests always get
    /// a correlated result or failure, including busy/timeout/cancellation.
    public func forward(_ data: Data) async -> Data {
        guard let request = try? WatchRelayCodec.decodeRequest(data) else { return Data() }
        if Task.isCancelled { return reply(.failure(.cancelled), for: request) }
        guard let binding, request.scope == binding else { return reply(.failure(.scopeMismatch), for: request) }
        guard pending == nil else { return reply(.failure(.busy), for: request) }
        let start = now(), deadline = start + timeout
        guard timeout.isFinite, timeout > 0, start.isFinite,
              deadline.isFinite, deadline > start else { return reply(.failure(.unavailable), for: request) }
        // Scope was validated and matched before constructing any HTTP client.
        guard let endpoint = try? ScoringEndpoint(binding.endpoint) else { return reply(.failure(.scopeMismatch), for: request) }
        let currentGeneration = generation
        let client = clientFactory(endpoint)
        if Task.isCancelled { return reply(.failure(.cancelled), for: request) }
        guard generation == currentGeneration, self.binding == binding else { return reply(.failure(.scopeMismatch), for: request) }
        let id = UUID()
        let task = Task { @MainActor () -> WatchRelayResult in
            do {
                try Task.checkCancellation()
                switch request.operation {
                case .snapshot: return .snapshot(try await client.snapshot(credential: request.credential))
                case .execute(let command): return .outcome(try await client.execute(command, credential: request.credential))
                case .receipt(let commandId):
                    let receipt = try await client.receipt(commandId: commandId, credential: request.credential)
                    return receipt.map(WatchRelayResult.receiptFound) ?? .receiptAbsent
                }
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
        let completed: WatchRelayResult
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

    private func reply(_ result: WatchRelayResult, for request: WatchRelayRequest) -> Data {
        if let encoded = try? WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: result), for: request) { return encoded }
        // Malformed or oversized server models/error codes never leak into a
        // reply. The already validated request permits this small fallback.
        return (try? WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: .failure(.invalidResponse)), for: request)) ?? Data()
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

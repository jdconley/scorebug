import Foundation

/// Owns one companion message attempt. Byte admission precedes actor Tasks;
/// typed reply correlation remains in the scoring and bootstrap clients. Canceling local
/// ownership cannot unsend a message or establish whether a mutation committed.
@MainActor
public final class WatchRelayMessageTransport {
    public typealias Callback = @Sendable (Result<Data, WatchRelayFailure>) -> Void
    public typealias Sender = @MainActor @Sendable (Data, @escaping Callback) throws -> Void
    public typealias ScheduledCancellation = @MainActor @Sendable () -> Void
    /// Schedule fire for a later actor turn, never inline. Cancellation must not
    /// invoke fire; an early or stale scheduled callback is otherwise tolerated.
    public typealias Scheduler = @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> ScheduledCancellation

    private struct Pending {
        let id: UUID
        let start: TimeInterval
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Data, Error>
        let gate: MessageCallbackGate
        var cancelTimer: ScheduledCancellation?
    }
    private let timeout: TimeInterval
    private let allowsBootstrap: Bool
    private let reachable: @MainActor @Sendable () -> Bool
    private let now: @MainActor @Sendable () -> TimeInterval
    private let schedule: Scheduler
    private let sender: Sender
    private var pending: Pending?

    public init(timeout: TimeInterval = 4,
                allowsBootstrap: Bool = false,
                isReachable: @escaping @MainActor @Sendable () -> Bool,
                now: @escaping @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: Scheduler? = nil, send: @escaping Sender) {
        self.timeout = timeout; self.allowsBootstrap = allowsBootstrap
        reachable = isReachable; self.now = now
        self.schedule = schedule ?? Self.defaultScheduler; sender = send
    }

    public func send(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard pending == nil else { throw WatchRelayFailure.busy }
        // The codec checks its byte ceiling before parsing. This also rejects
        // direct callers' malformed requests before any platform dispatch.
        // Explicit bootstrap opt-in still shares this one pending owner.
        if (try? WatchRelayCodec.decodeRequest(data)) == nil {
            guard allowsBootstrap, (try? WatchBootstrapCodec.decodeRequest(data)) != nil else {
                throw WatchRelayFailure.invalidRequest
            }
        }
        guard reachable(), timeout.isFinite, timeout > 0 else { throw WatchRelayFailure.unavailable }
        let start = now()
        let deadline = start + timeout
        guard start.isFinite, deadline.isFinite, deadline > start else { throw WatchRelayFailure.unavailable }
        let id = UUID()
        let reply: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Installing ownership and dispatching are one actor operation.
                guard pending == nil else {
                    continuation.resume(throwing: WatchRelayFailure.busy)
                    return
                }
                let gate = MessageCallbackGate()
                pending = Pending(id: id, start: start, deadline: deadline, continuation: continuation, gate: gate)
                armTimer(id)
                guard pending?.id == id else { return }
                if Task.isCancelled {
                    finish(id, .failure(CancellationError()))
                    return
                }
                do {
                    try sender(data) { [weak self, gate] result in
                        // At most one small callback is admitted, even if an
                        // adapter invokes this concurrently or after invalidation.
                        guard let admitted = gate.admit(result) else { return }
                        Task { @MainActor [weak self] in self?.receive(id, admitted) }
                    }
                } catch {
                    finish(id, .failure(WatchRelayFailure.unavailable))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return reply
    }

    /// Call before replacing peer/session identity. Old callbacks cannot settle
    /// a subsequent attempt, even if they arrive after the new peer is ready.
    public func invalidatePeer() {
        if let id = pending?.id { finish(id, .failure(WatchRelayFailure.unavailable)) }
    }

    private func receive(_ id: UUID, _ result: Result<Data, WatchRelayFailure>) {
        guard let pending, pending.id == id else { return }
        let time = now()
        guard time.isFinite, time >= pending.start, time < pending.deadline else {
            finish(id, .failure(WatchRelayFailure.unavailable))
            return
        }
        switch result {
        case .success(let data): finish(id, .success(data))
        case .failure(let failure): finish(id, .failure(failure))
        }
    }

    private func armTimer(_ id: UUID) {
        guard let current = pending, current.id == id else { return }
        let time = now()
        guard time.isFinite, time >= current.start, time < current.deadline else {
            finish(id, .failure(WatchRelayFailure.unavailable))
            return
        }
        pending?.cancelTimer = nil
        current.cancelTimer?()
        guard pending?.id == id else { return }
        let cancel = schedule(current.deadline - time) { [weak self] in self?.timerFired(id) }
        if pending?.id == id { pending?.cancelTimer = cancel }
        else { cancel() }
    }

    private func timerFired(_ id: UUID) {
        // Early callbacks and bounded default sleep chunks rearm against the
        // original deadline; neither extends the attempt nor dispatches again.
        armTimer(id)
    }

    private func finish(_ id: UUID, _ result: Result<Data, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.gate.close()
        current.cancelTimer?()
        current.continuation.resume(with: result)
    }

    private static let defaultScheduler: Scheduler = { delay, fire in
        // Chunk very large finite configurations without an overflowing integer
        // conversion; the owner rechecks/rearms until its absolute deadline.
        let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            if !Task.isCancelled { fire() }
        }
        return { task.cancel() }
    }
}

/// Callback threads share only this lock-protected terminal bit. No payload is
/// retained here; an oversized reply is replaced before creating an actor Task.
private final class MessageCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    func admit(_ result: Result<Data, WatchRelayFailure>) -> Result<Data, WatchRelayFailure>? {
        let bounded: Result<Data, WatchRelayFailure>
        switch result {
        case .success(let data) where data.isEmpty || data.count > WatchRelayCodec.maximumReplyBytes:
            bounded = .failure(.invalidResponse)
        case .failure(.http(let status, let code)):
            let validCode = code.map { value in
                !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                }
            } ?? true
            bounded = (100...599).contains(status) && validCode ? result : .failure(.invalidResponse)
        default: bounded = result
        }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        return bounded
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }
}

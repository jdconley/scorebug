import Foundation

/// One transport/encoder instance for one publishing attempt. Capture callbacks
/// never invoke these methods. start() returns only when publication is ready.
/// start/append/health must finish in bounded time or cooperate with cancellation.
/// stop() is terminal and safe concurrently with suspended operations: it must
/// unblock append/start/health and prevent a late startup from resurrecting publication.
/// Stop must finish even if its caller is cancelled. Destination credentials belong
/// in the injected publisher, never in session errors or diagnostic snapshots.
public protocol MediaPublisher: Sendable {
    func start() async throws
    func append(_ sample: CapturedMediaSample) async throws
    var isPublishing: Bool { get async }
    func stop() async
}

public enum PublishingSessionState: Sendable { case prepared, starting, publishing, stopping, stopped, failed }
public enum PublishingSessionError: Error, Equatable, Sendable {
    case invalidState, invalidHealthCheckInterval, cancelled, startFailed, appendFailed, publisherUnhealthy
}
public struct PublishingSessionSnapshot: Sendable {
    public let state: PublishingSessionState
    public let failure: PublishingSessionError?
    /// Number of successful publisher append returns; this does not measure
    /// encoded frames, network delivery, or remote playback.
    public let sentSamples: Int
    public let queue: BoundedMailbox<CapturedMediaSample>.Statistics
}

/// Strong owner of a single publishing attempt, independent of the offline archive.
/// Reconnect with a fresh instance. One consumer and one idle health monitor are
/// created after readiness; synchronous ingress never allocates tasks per sample.
/// Limits cover queued payload only, plus at most one in-flight sample of maxBytes.
/// SDK encoders, metadata and shared capture allocations require separate budgets.
///
/// Stopping discards stale pending media. All stop waiters join the same shutdown,
/// even when cancelled. Use cancel() for explicit failure. Releasing the public
/// owner schedules cleanup; worker tasks retain only its private core.
public final class PublishingSession: Sendable {
    private let core: PublishingCore
    public init(publisher: any MediaPublisher, maxItems: Int = 8,
                maxBytes: Int = 12 * 1024 * 1024,
                healthCheckInterval: Duration = .milliseconds(250)) throws {
        guard healthCheckInterval > .zero else { throw PublishingSessionError.invalidHealthCheckInterval }
        core = try PublishingCore(publisher: publisher, maxItems: maxItems, maxBytes: maxBytes,
                                  healthCheckInterval: healthCheckInterval)
    }
    deinit { core.cancel() }
    public var snapshot: PublishingSessionSnapshot { core.snapshot }
    public func start() async throws { try await core.start() }
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool { core.offer(sample) }
    public func stop() async { await core.stop() }
    public func cancel() { core.cancel() }
}

private final class PublishingCore: @unchecked Sendable {
    private let lock = NSLock()
    private let publisher: any MediaPublisher
    private let mailbox: BoundedMailbox<CapturedMediaSample>
    private let healthCheckInterval: Duration
    private var state = PublishingSessionState.prepared
    private var failure: PublishingSessionError?
    private var sentSamples = 0
    private var startup: Task<Void, Error>?
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    init(publisher: any MediaPublisher, maxItems: Int, maxBytes: Int, healthCheckInterval: Duration) throws {
        self.publisher = publisher; self.healthCheckInterval = healthCheckInterval
        mailbox = try BoundedMailbox(maxItems: maxItems, maxBytes: maxBytes, overflowPolicy: .dropOldest)
    }
    var snapshot: PublishingSessionSnapshot {
        lock.withLock { PublishingSessionSnapshot(state: state, failure: failure,
                                                  sentSamples: sentSamples, queue: mailbox.statistics) }
    }
    func start() async throws {
        let pending = try lock.withLock {
            guard state == .prepared else { throw PublishingSessionError.invalidState }
            state = .starting
            let pending = Task.detached { try await self.runStart() }
            startup = pending
            return pending
        }
        do { try await pending.value }
        catch {
            await requestStop().value
            throw error
        }
    }
    private func runStart() async throws {
        do {
            try Task.checkCancellation()
            try await publisher.start()
            guard await publisher.isPublishing else { throw PublishingSessionError.publisherUnhealthy }
            try lock.withLock {
                guard state == .starting else { throw failure ?? PublishingSessionError.cancelled }
                state = .publishing
                consumer = Task.detached { await self.consume() }
                monitor = Task.detached { await self.monitorHealth() }
            }
        } catch {
            let reason = lock.withLock { () -> PublishingSessionError in
                if state != .starting { return failure ?? .cancelled }
                return error as? PublishingSessionError == .publisherUnhealthy ? .publisherUnhealthy : .startFailed
            }
            // Never join shutdown from a worker it must itself join.
            _ = requestStop(failure: reason)
            throw reason
        }
    }
    func offer(_ sample: CapturedMediaSample) -> Bool {
        lock.withLock {
            guard state == .publishing else { return false }
            return mailbox.offer(sample, bytes: sample.retainedByteCount).acceptedCount == 1
        }
    }
    private func consume() async {
        do {
            while let sample = try await mailbox.next() {
                guard lock.withLock({ state == .publishing }) else { return }
                try Task.checkCancellation()
                try await publisher.append(sample)
                lock.withLock { if sentSamples < Int.max { sentSamples += 1 } }
            }
        } catch {
            if lock.withLock({ state == .publishing }) { _ = requestStop(failure: .appendFailed) }
        }
    }
    private func monitorHealth() async {
        do {
            while true {
                try await Task.sleep(for: healthCheckInterval)
                try Task.checkCancellation()
                let healthy = await publisher.isPublishing
                guard lock.withLock({ state == .publishing }) else { return }
                if !healthy { _ = requestStop(failure: .publisherUnhealthy); return }
            }
        } catch { /* Cancellation is shutdown, never a transport failure. */ }
    }
    private func requestStop(failure error: PublishingSessionError? = nil) -> Task<Void, Never> {
        lock.withLock {
            if let shutdown { return shutdown }
            if let error { failure = error; state = .failed }
            else { state = .stopping }
            mailbox.cancel()
            let startup = self.startup, consumer = self.consumer, monitor = self.monitor
            let pending = Task.detached {
                // Task cancellation handlers may call arbitrary publisher code;
                // invoke them outside locks and never on a capture callback.
                startup?.cancel(); consumer?.cancel(); monitor?.cancel()
                // Stop may unblock suspended start/append/health operations.
                await self.publisher.stop()
                _ = await startup?.result
                await consumer?.value
                await monitor?.value
                self.lock.withLock { if self.failure == nil { self.state = .stopped } }
            }
            shutdown = pending
            return pending
        }
    }
    func stop() async { await requestStop().value }
    func cancel() { _ = requestStop(failure: .cancelled) }
}

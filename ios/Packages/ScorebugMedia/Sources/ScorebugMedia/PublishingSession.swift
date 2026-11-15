import CoreMedia
import Foundation

/// One transport/encoder instance for one publishing attempt. Capture callbacks
/// never invoke these methods. start() returns only when publication is ready.
/// stop() is terminal and safe concurrently with suspended operations: it must
/// unblock append/start/health and prevent a late startup from resurrecting
/// publication. Destination credentials stay inside the publisher.
public protocol MediaPublisher: Sendable {
    func start() async throws
    func append(_ sample: CapturedMediaSample) async throws
    var isPublishing: Bool { get async }
    func stop() async
    /// Latest sender counters, or nil while unavailable.
    func transportStatistics() async -> PublishingTransportStatistics?
    /// Replaces the live encoder settings. A failure may be terminal.
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws
}

public extension MediaPublisher {
    func transportStatistics() async -> PublishingTransportStatistics? { nil }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws { throw PublishingSessionError.profileUpdateFailed }
}

public enum PublishingSessionState: Sendable { case prepared, starting, publishing, stopping, stopped, failed }
public enum PublishingSessionError: Error, Equatable, Sendable {
    case invalidState, invalidHealthCheckInterval, cancelled, startFailed, appendFailed, publisherUnhealthy
    case profileUpdateInProgress, profileUpdateFailed
}
public struct PublishingSessionSnapshot: Sendable {
    public let state: PublishingSessionState
    public let failure: PublishingSessionError?
    /// Number of successful publisher append returns.
    public let sentSamples: Int
    public let queue: BoundedMailbox<CapturedMediaSample>.Statistics
    /// Most recent sender counters from the health monitor.
    public let transportStatistics: PublishingTransportStatistics?
    public let profile: PublishingVideoProfile?
}

/// Strong owner of a single publishing attempt, independent of the local archive.
/// Reconnect with a fresh instance. One consumer and one health monitor run after
/// readiness; synchronous ingress never allocates tasks per sample, and a full
/// queue drops the oldest media so the recording is never back-pressured.
public final class PublishingSession: Sendable {
    private let core: PublishingCore
    public init(publisher: any MediaPublisher, profile: PublishingVideoProfile? = nil, maxItems: Int = 8,
                maxBytes: Int = 12 * 1024 * 1024, healthCheckInterval: Duration = .milliseconds(500)) throws {
        guard healthCheckInterval > .zero else { throw PublishingSessionError.invalidHealthCheckInterval }
        core = try PublishingCore(publisher: publisher, profile: profile, maxItems: maxItems, maxBytes: maxBytes,
                                  healthCheckInterval: healthCheckInterval)
    }
    deinit { core.cancel() }
    public var snapshot: PublishingSessionSnapshot { core.snapshot }
    public func start() async throws { try await core.start() }
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool { core.offer(sample) }
    public func stop() async { await core.stop() }
    public func cancel() { core.cancel() }
    /// One change at a time. A failed change ends this session.
    public func setVideoProfile(_ profile: PublishingVideoProfile) async throws { try await core.setVideoProfile(profile) }
}

private final class PublishingCore: @unchecked Sendable {
    private let lock = NSLock()
    private let publisher: any MediaPublisher
    private let mailbox: BoundedMailbox<CapturedMediaSample>
    private let healthCheckInterval: Duration
    private var state = PublishingSessionState.prepared
    private var failure: PublishingSessionError?
    private var sentSamples = 0
    private var statistics: PublishingTransportStatistics?
    private var profile: PublishingVideoProfile?
    private var profileChange: Task<Void, Error>?
    private var startup: Task<Void, Error>?
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    init(publisher: any MediaPublisher, profile: PublishingVideoProfile?, maxItems: Int, maxBytes: Int,
         healthCheckInterval: Duration) throws {
        self.publisher = publisher; self.profile = profile; self.healthCheckInterval = healthCheckInterval
        mailbox = try BoundedMailbox(maxItems: maxItems, maxBytes: maxBytes, overflowPolicy: .dropOldest)
    }
    var snapshot: PublishingSessionSnapshot {
        lock.withLock {
            PublishingSessionSnapshot(state: state, failure: failure, sentSamples: sentSamples,
                queue: mailbox.statistics, transportStatistics: statistics, profile: profile)
        }
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
            try Task.checkCancellation()
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
                let healthy = await publisher.isPublishing
                try Task.checkCancellation()
                guard lock.withLock({ state == .publishing }) else { return }
                if !healthy { _ = requestStop(failure: .publisherUnhealthy); return }
                let sample = await publisher.transportStatistics()
                try Task.checkCancellation()
                lock.withLock { if state == .publishing, let sample { statistics = sample } }
            }
        } catch { /* Cancellation is shutdown, never a transport failure. */ }
    }
    func setVideoProfile(_ requested: PublishingVideoProfile) async throws {
        let pending = try lock.withLock { () -> Task<Void, Error> in
            guard state == .publishing else { throw PublishingSessionError.invalidState }
            guard profileChange == nil else { throw PublishingSessionError.profileUpdateInProgress }
            let pending = Task.detached { try await self.publisher.setVideoProfile(requested) }
            profileChange = pending
            return pending
        }
        do {
            try await pending.value
            try lock.withLock {
                profileChange = nil
                guard state == .publishing else { throw failure ?? PublishingSessionError.cancelled }
                profile = requested
                // Counters from the previous encoder still describe this connection.
            }
        } catch {
            lock.withLock { profileChange = nil }
            await requestStop(failure: .profileUpdateFailed).value
            throw lock.withLock { failure ?? PublishingSessionError.profileUpdateFailed }
        }
    }
    private func requestStop(failure error: PublishingSessionError? = nil) -> Task<Void, Never> {
        lock.withLock { makeStopLocked(failure: error) }
    }
    /// Caller holds lock. Task cancellation and publisher calls happen outside it.
    private func makeStopLocked(failure error: PublishingSessionError?) -> Task<Void, Never> {
        if let shutdown { return shutdown }
        if let error { failure = error; state = .failed }
        else { state = .stopping }
        mailbox.cancel()
        let startup = self.startup, consumer = self.consumer, monitor = self.monitor, change = profileChange
        let pending = Task.detached {
            startup?.cancel(); consumer?.cancel(); monitor?.cancel(); change?.cancel()
            // Stop unblocks suspended operations before we join their tasks.
            await self.publisher.stop()
            _ = await startup?.result
            await consumer?.value
            await monitor?.value
            _ = await change?.result
            self.lock.withLock { if self.failure == nil { self.state = .stopped } }
        }
        shutdown = pending
        return pending
    }
    func stop() async { await requestStop().value }
    func cancel() { _ = requestStop(failure: .cancelled) }
}

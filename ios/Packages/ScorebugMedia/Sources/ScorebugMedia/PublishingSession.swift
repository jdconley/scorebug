import CoreMedia
import Foundation

/// One transport/encoder instance for one publishing attempt. Capture callbacks
/// never invoke these methods. start() returns only when publication is ready.
/// start/append/health/transportClock/transportStatistics must finish in bounded time or cooperate with cancellation.
/// stop() is terminal and safe concurrently with suspended operations: it must
/// unblock append/start/health/transportClock and prevent a late startup from resurrecting publication.
/// Stop must finish even if its caller is cancelled. Destination credentials belong
/// in the injected publisher, never in session errors or diagnostic snapshots.
public protocol MediaPublisher: Sendable {
    func start() async throws
    func append(_ sample: CapturedMediaSample) async throws
    var isPublishing: Bool { get async }
    func stop() async
    /// Optional diagnostic read; must be bounded or cooperate with cancellation.
    /// stop() must unblock suspended reads. Never owns shutdown or encoder settings.
    func transportClock() async -> PublishingTransportClock?
    func transportStatistics() async -> PublishingTransportStatistics?
}

public extension MediaPublisher {
    func transportClock() async -> PublishingTransportClock? { nil }
    func transportStatistics() async -> PublishingTransportStatistics? { nil }
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
    /// Last observed native mapping, retained after shutdown. This is historical
    /// evidence, not current readiness, transport receipt, or a profile revision.
    /// A contradictory mapping makes this unknown for the rest of this session.
    public let transportClock: PublishingTransportClock?
    public let transportStatistics: PublishingTransportStatisticsSnapshot
    public let ingressObservation: LiveIngressObservationSnapshot?
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
                healthCheckInterval: Duration = .milliseconds(250),
                ingressObservation: LiveIngressObservationConfiguration? = nil) throws {
        guard healthCheckInterval > .zero else { throw PublishingSessionError.invalidHealthCheckInterval }
        core = try PublishingCore(publisher: publisher, maxItems: maxItems, maxBytes: maxBytes,
                                  healthCheckInterval: healthCheckInterval, ingressObservation: ingressObservation)
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
    private var transportClock: PublishingTransportClock?
    private var transportClockQuarantined = false
    private var transportStatistics = PublishingTransportStatisticsTracker()
    private var startup: Task<Void, Error>?
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    init(publisher: any MediaPublisher, maxItems: Int, maxBytes: Int, healthCheckInterval: Duration,
         ingressObservation: LiveIngressObservationConfiguration?) throws {
        self.publisher = publisher; self.healthCheckInterval = healthCheckInterval
        // Readiness belongs to this session, regardless of the generic mailbox's
        // default admission phase. Configuration is immutable and diagnostic only.
        let configuration = ingressObservation.map {
            LiveIngressObservationConfiguration(scope: $0.scope, monotonicAnchor: $0.monotonicAnchor,
                windowDuration: $0.windowDuration, completedWindowLimit: $0.completedWindowLimit, initialPhase: .startup)
        }
        mailbox = try BoundedMailbox(maxItems: maxItems, maxBytes: maxBytes, overflowPolicy: .dropOldest,
                                     ingressObservation: configuration)
    }
    var snapshot: PublishingSessionSnapshot {
        lock.withLock {
            let measured = mailbox.snapshot
            return PublishingSessionSnapshot(state: state, failure: failure, sentSamples: sentSamples,
                queue: measured.statistics, transportClock: transportClock, transportStatistics: transportStatistics.snapshot, ingressObservation: measured.ingressObservation)
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
            try lock.withLock {
                guard state == .starting else { throw failure ?? PublishingSessionError.cancelled }
                mailbox.beginObservedAdmission()
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
            let metadata: LiveIngressSampleMetadata?
            if mailbox.hasIngressObservation {
                metadata = .init(kind: sample.kind == .video ? .video : .audio,
                                 sourcePTS: sample.sampleBuffer.presentationTimeStamp)
            } else { metadata = nil }
            return mailbox.offer(sample, bytes: sample.retainedByteCount, observation: metadata).acceptedCount == 1
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
                try Task.checkCancellation()
                guard lock.withLock({ state == .publishing }) else { return }
                if !healthy { _ = requestStop(failure: .publisherUnhealthy); return }
                let observedClock = await publisher.transportClock()
                try Task.checkCancellation()
                lock.withLock {
                    guard state == .publishing, !transportClockQuarantined,
                          let observedClock else { return }
                    if let transportClock, transportClock != observedClock {
                        self.transportClock = nil
                        transportClockQuarantined = true
                    } else {
                        transportClock = observedClock
                    }
                }
                let statistics = await publisher.transportStatistics()
                try Task.checkCancellation()
                lock.withLock {
                    guard state == .publishing else { return }
                    transportStatistics.observe(statistics)
                }
            }
        } catch { /* Cancellation is shutdown, never a transport failure. */ }
    }
    private func requestStop(failure error: PublishingSessionError? = nil) -> Task<Void, Never> {
        lock.withLock {
            if let shutdown { return shutdown }
            if let error { failure = error; state = .failed }
            else { state = .stopping }
            transportStatistics.close()
            mailbox.cancel()
            let startup = self.startup, consumer = self.consumer, monitor = self.monitor
            let pending = Task.detached {
                // Task cancellation handlers may call arbitrary publisher code;
                // invoke them outside locks and never on a capture callback.
                startup?.cancel(); consumer?.cancel(); monitor?.cancel()
                // Stop may unblock suspended start/append/health/clock operations.
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

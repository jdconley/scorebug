import CoreMedia
import Foundation

/// One transport/encoder instance for one publishing attempt. Capture callbacks
/// never invoke these methods. start() returns only when publication is ready.
/// start/append/health/transportClock/transportStatistics/setVideoBitRate must finish
/// in bounded time or cooperate with stop/cancellation.
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
    /// Mutation must be bounded or cooperate with stop. Returned settings must
    /// reflect verified native writes. A failed dispatched call may be terminal.
    func setVideoBitRate(_ bitsPerSecond: Int) async throws -> PublishingBitRateChange
}

public extension MediaPublisher {
    func transportClock() async -> PublishingTransportClock? { nil }
    func transportStatistics() async -> PublishingTransportStatistics? { nil }
    func setVideoBitRate(_ bitsPerSecond: Int) async throws -> PublishingBitRateChange { throw PublishingSessionError.bitRateUpdateFailed }
}

public enum PublishingSessionState: Sendable { case prepared, starting, publishing, stopping, stopped, failed }
public enum PublishingSessionError: Error, Equatable, Sendable {
    case invalidState, invalidHealthCheckInterval, cancelled, startFailed, appendFailed, publisherUnhealthy
    case invalidBitRate, invalidBitRateDeadline, bitRateUpdateInProgress, bitRateUpdateFailed, bitRateUpdateTimedOut
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
    /// Sampled OS thermal history owned by this attempt; closed history is not fresh.
    public let thermalObservation: PublishingThermalSnapshot
    public let ingressObservation: LiveIngressObservationSnapshot?
    /// Last accepted receipt, retained as historical evidence after terminal stop.
    public let lastBitRateChange: PublishingBitRateChange?
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
    // Internal clock seam for deterministic admission-expiry tests.
    init(publisher: any MediaPublisher, bitRateClock: @escaping @Sendable () -> Double) throws {
        core = try PublishingCore(publisher: publisher, maxItems: 8, maxBytes: 12 * 1024 * 1024,
            healthCheckInterval: .milliseconds(250), ingressObservation: nil, bitRateClock: bitRateClock)
    }
    // Internal synchronous sampler seam; production reads only Foundation scalars.
    init(publisher: any MediaPublisher, healthCheckInterval: Duration,
         thermalSampler: @escaping @Sendable () -> PublishingThermalSample) throws {
        guard healthCheckInterval > .zero else { throw PublishingSessionError.invalidHealthCheckInterval }
        core = try PublishingCore(publisher: publisher, maxItems: 8, maxBytes: 12 * 1024 * 1024,
            healthCheckInterval: healthCheckInterval, ingressObservation: nil, thermalSampler: thermalSampler)
    }
    deinit { core.cancel() }
    public var snapshot: PublishingSessionSnapshot { core.snapshot }
    public func start() async throws { try await core.start() }
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool { core.offer(sample) }
    public func stop() async { await core.stop() }
    public func cancel() { core.cancel() }
    /// System-uptime expiry; each admitted mutation is additionally capped at two seconds.
    public func setVideoBitRate(_ bitsPerSecond: Int, before deadline: Double? = nil) async throws -> PublishingBitRateChange {
        try await core.setVideoBitRate(bitsPerSecond, before: deadline)
    }
}

private final class PublishingCore: @unchecked Sendable {
    private let lock = NSLock()
    private let publisher: any MediaPublisher
    private let mailbox: BoundedMailbox<CapturedMediaSample>
    private let healthCheckInterval: Duration
    private let bitRateClock: @Sendable () -> Double
    private var state = PublishingSessionState.prepared
    private var failure: PublishingSessionError?
    private var sentSamples = 0
    private var lastBitRateChange: PublishingBitRateChange?
    private var rateRequestID: UUID?
    private var rateCommitted = false
    private var rateMutation: Task<PublishingBitRateChange, Error>?
    private var rateTimer: Task<Void, Never>?
    private var transportClock: PublishingTransportClock?
    private var transportClockQuarantined = false
    private var transportStatistics = PublishingTransportStatisticsTracker()
    private var thermalObservation = PublishingThermalTracker()
    private let thermalSampler: @Sendable () -> PublishingThermalSample
    private var startup: Task<Void, Error>?
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    init(publisher: any MediaPublisher, maxItems: Int, maxBytes: Int, healthCheckInterval: Duration,
         ingressObservation: LiveIngressObservationConfiguration?,
         bitRateClock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         thermalSampler: @escaping @Sendable () -> PublishingThermalSample = {
             let state = PublishingThermalState(ProcessInfo.processInfo.thermalState)
             return .init(state: state, sampledAt: ProcessInfo.processInfo.systemUptime)
         }) throws {
        self.publisher = publisher; self.healthCheckInterval = healthCheckInterval
        self.bitRateClock = bitRateClock; self.thermalSampler = thermalSampler
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
                queue: measured.statistics, transportClock: transportClock, transportStatistics: transportStatistics.snapshot, thermalObservation: thermalObservation.snapshot, ingressObservation: measured.ingressObservation, lastBitRateChange: lastBitRateChange)
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
            guard lock.withLock({ state == .starting }) else { throw PublishingSessionError.cancelled }
            let thermal = thermalSampler()
            try lock.withLock {
                guard state == .starting else { throw failure ?? PublishingSessionError.cancelled }
                thermalObservation.observe(thermal)
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
                // Read outside the lock and before awaited transport diagnostics.
                // Missing/stalled polls cannot extend the sampled history.
                let thermal = thermalSampler()
                guard lock.withLock({ () -> Bool in
                    guard state == .publishing else { return false }
                    thermalObservation.observe(thermal)
                    return true
                }) else { return }
                let healthy = await publisher.isPublishing
                try Task.checkCancellation()
                guard lock.withLock({ state == .publishing }) else { return }
                if !healthy { _ = requestStop(failure: .publisherUnhealthy); return }
                let observedClock = await publisher.transportClock()
                try Task.checkCancellation()
                lock.withLock {
                    guard state == .publishing, !transportClockQuarantined,
                          let observedClock else { return }
                    if (transportClock.map { $0 != observedClock } ?? false) ||
                        (lastBitRateChange.map { $0.publishingGeneration != observedClock.publishingGeneration } ?? false) {
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
        lock.withLock { makeStopLocked(failure: error) }
    }
    /// Caller holds lock. Task cancellation and publisher calls happen outside it.
    private func makeStopLocked(failure error: PublishingSessionError?) -> Task<Void, Never> {
        if let shutdown { return shutdown }
        if let error { failure = error; state = .failed }
        else { state = .stopping }
        transportStatistics.close()
        thermalObservation.close()
        mailbox.cancel()
        let startup = self.startup, consumer = self.consumer, monitor = self.monitor
        let mutation = rateMutation, timer = rateTimer
        let pending = Task.detached {
            startup?.cancel(); consumer?.cancel(); monitor?.cancel()
            mutation?.cancel(); timer?.cancel()
            // Stop unblocks suspended operations before we join their tasks.
            await self.publisher.stop()
            _ = await startup?.result
            await consumer?.value
            await monitor?.value
            _ = await mutation?.result
            await timer?.value
            self.lock.withLock { if self.failure == nil { self.state = .stopped } }
        }
        shutdown = pending
        return pending
    }
    func setVideoBitRate(_ bitsPerSecond: Int, before suppliedDeadline: Double?) async throws -> PublishingBitRateChange {
        let admittedAt = bitRateClock()
        let deadline = min(suppliedDeadline ?? admittedAt + 2, admittedAt + 2)
        let (id, operation) = try lock.withLock { () -> (UUID, Task<PublishingBitRateChange, Error>) in
            guard !Task.isCancelled else { throw PublishingSessionError.cancelled }
            guard state == .publishing else { throw PublishingSessionError.invalidState }
            guard bitsPerSecond > 0, bitsPerSecond <= Int32.max else { throw PublishingSessionError.invalidBitRate }
            guard suppliedDeadline.map({ $0.isFinite && $0 > admittedAt && $0 <= 1e12 }) ?? true,
                  deadline > bitRateClock() else {
                throw PublishingSessionError.invalidBitRateDeadline
            }
            guard rateRequestID == nil else { throw PublishingSessionError.bitRateUpdateInProgress }
            let id = UUID()
            rateRequestID = id; rateCommitted = false
            let operation = Task.detached {
                try await self.performBitRateUpdate(bitsPerSecond, id: id, admittedAt: admittedAt, deadline: deadline)
            }
            rateMutation = operation
            rateTimer = Task.detached {
                do { try await Task.sleep(for: .seconds(max(0, deadline - self.bitRateClock()))) }
                catch { return }
                self.lock.withLock {
                    guard self.rateRequestID == id, !self.rateCommitted, self.state == .publishing else { return }
                    _ = self.makeStopLocked(failure: .bitRateUpdateTimedOut)
                }
            }
            return (id, operation)
        }
        defer {
            lock.withLock {
                if rateRequestID == id { rateRequestID = nil; rateMutation = nil; rateTimer = nil; rateCommitted = false }
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let receipt = try await operation.value
                await cancelAndJoinRateTimer(id)
                try lock.withLock {
                    guard state == .publishing, rateRequestID == id, !Task.isCancelled else { throw PublishingSessionError.cancelled }
                }
                return receipt
            } catch {
                // This caller is not the mutation task joined by shutdown.
                await requestStop(failure: error as? PublishingSessionError ?? .bitRateUpdateFailed).value
                await cancelAndJoinRateTimer(id)
                throw lock.withLock { failure ?? .cancelled }
            }
        } onCancel: {
            self.lock.withLock {
                guard self.rateRequestID == id else { return }
                _ = self.makeStopLocked(failure: .cancelled)
            }
        }
    }
    private func cancelAndJoinRateTimer(_ id: UUID) async {
        let timer = lock.withLock { rateRequestID == id ? rateTimer : nil }
        timer?.cancel()
        await timer?.value
    }
    private func performBitRateUpdate(_ bitsPerSecond: Int, id: UUID,
                                      admittedAt: Double, deadline: Double) async throws -> PublishingBitRateChange {
        do {
            try Task.checkCancellation()
            try lock.withLock {
                guard state == .publishing, rateRequestID == id else { throw PublishingSessionError.cancelled }
                guard bitRateClock() < deadline else { throw PublishingSessionError.bitRateUpdateTimedOut }
            }
            let receipt = try await publisher.setVideoBitRate(bitsPerSecond)
            try Task.checkCancellation()
            let healthy = await publisher.isPublishing
            try Task.checkCancellation()
            try lock.withLock {
                guard state == .publishing, rateRequestID == id else { throw PublishingSessionError.cancelled }
                let now = bitRateClock()
                guard now <= deadline else { throw PublishingSessionError.bitRateUpdateTimedOut }
                guard healthy, !transportClockQuarantined, receipt.configuration.bitRate == bitsPerSecond,
                      receipt.acceptedAt >= admittedAt, receipt.acceptedAt <= now,
                      transportClock.map({ $0.publishingGeneration == receipt.publishingGeneration }) ?? true else {
                    throw PublishingSessionError.bitRateUpdateFailed
                }
                if let prior = lastBitRateChange {
                    guard prior.publishingGeneration == receipt.publishingGeneration,
                          prior.configuration.id != receipt.configuration.id,
                          prior.acceptedAt <= receipt.acceptedAt else { throw PublishingSessionError.bitRateUpdateFailed }
                    if prior.configuration.encoderSessionID == receipt.configuration.encoderSessionID,
                       let previousPTS = prior.lastSubmittedSourcePTS {
                        guard let nextPTS = receipt.lastSubmittedSourcePTS, CMTimeCompare(nextPTS, previousPTS) >= 0 else {
                            throw PublishingSessionError.bitRateUpdateFailed
                        }
                    }
                }
                lastBitRateChange = receipt; rateCommitted = true
            }
            return receipt
        } catch {
            let reason: PublishingSessionError = error is CancellationError ? .cancelled
                : (error as? PublishingSessionError ?? .bitRateUpdateFailed)
            // Never join shutdown from the mutation task shutdown itself joins.
            _ = requestStop(failure: reason)
            throw lock.withLock { failure ?? .cancelled }
        }
    }
    func stop() async { await requestStop().value }
    func cancel() { _ = requestStop(failure: .cancelled) }
}

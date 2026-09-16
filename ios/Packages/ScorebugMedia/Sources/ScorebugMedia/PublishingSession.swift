import CoreMedia
import Foundation

/// One transport/encoder instance for one publishing attempt. Capture callbacks
/// never invoke these methods. start() returns only when publication is ready.
/// start/append/health/transportClock/transportStatistics/encoder mutations must finish
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
    /// Replaces the live encoder and returns its first observed new format boundary.
    /// Stop must join native replacement, including its old-output drain.
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange
}

public extension MediaPublisher {
    func transportClock() async -> PublishingTransportClock? { nil }
    func transportStatistics() async -> PublishingTransportStatistics? { nil }
    func setVideoBitRate(_ bitsPerSecond: Int) async throws -> PublishingBitRateChange { throw PublishingSessionError.bitRateUpdateFailed }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange { throw PublishingSessionError.profileUpdateFailed }
}

public enum PublishingSessionState: Sendable { case prepared, starting, publishing, stopping, stopped, failed }
public enum PublishingSessionError: Error, Equatable, Sendable {
    case invalidState, invalidHealthCheckInterval, cancelled, startFailed, appendFailed, publisherUnhealthy
    case invalidBitRate, invalidBitRateDeadline, bitRateUpdateInProgress, bitRateUpdateFailed, bitRateUpdateTimedOut
    case invalidProfileDeadline, profileUpdateInProgress, profileUpdateFailed, profileUpdateTimedOut
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
    public let lastVideoProfileChange: PublishingVideoProfileChange?
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
    public func setVideoProfile(_ profile: PublishingVideoProfile, before deadline: Double? = nil) async throws -> PublishingVideoProfileChange {
        try await core.setVideoProfile(profile, before: deadline)
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
    private var lastVideoProfileChange: PublishingVideoProfileChange?
    private var mutationID: UUID?
    private var mutationCommitted = false
    private var mutationTask: Task<MutationReceipt, Error>?
    private var mutationTimer: Task<Void, Never>?
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
                queue: measured.statistics, transportClock: transportClock, transportStatistics: transportStatistics.snapshot, thermalObservation: thermalObservation.snapshot, ingressObservation: measured.ingressObservation, lastBitRateChange: lastBitRateChange, lastVideoProfileChange: lastVideoProfileChange)
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
                        (lastBitRateChange.map { $0.publishingGeneration != observedClock.publishingGeneration } ?? false) ||
                        (lastVideoProfileChange.map { $0.publishingGeneration != observedClock.publishingGeneration } ?? false) {
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
        let mutation = mutationTask, timer = mutationTimer
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
    private enum MutationRequest: Sendable {
        case bitRate(Int), profile(PublishingVideoProfile)
        var failed: PublishingSessionError { if case .bitRate = self { .bitRateUpdateFailed } else { .profileUpdateFailed } }
        var timedOut: PublishingSessionError { if case .bitRate = self { .bitRateUpdateTimedOut } else { .profileUpdateTimedOut } }
        var invalidDeadline: PublishingSessionError { if case .bitRate = self { .invalidBitRateDeadline } else { .invalidProfileDeadline } }
        var inProgress: PublishingSessionError { if case .bitRate = self { .bitRateUpdateInProgress } else { .profileUpdateInProgress } }
    }
    private enum MutationReceipt: Sendable {
        case bitRate(PublishingBitRateChange), profile(PublishingVideoProfileChange)
        var generation: UInt64 { switch self { case .bitRate(let value): value.publishingGeneration; case .profile(let value): value.publishingGeneration } }
        var acknowledgedAt: Double { switch self { case .bitRate(let value): value.acceptedAt; case .profile(let value): value.acknowledgedAt } }
    }
    func setVideoBitRate(_ bitsPerSecond: Int, before suppliedDeadline: Double?) async throws -> PublishingBitRateChange {
        guard case .bitRate(let receipt) = try await mutate(.bitRate(bitsPerSecond), before: suppliedDeadline) else {
            throw PublishingSessionError.bitRateUpdateFailed
        }
        return receipt
    }
    func setVideoProfile(_ profile: PublishingVideoProfile, before suppliedDeadline: Double?) async throws -> PublishingVideoProfileChange {
        guard case .profile(let receipt) = try await mutate(.profile(profile), before: suppliedDeadline) else {
            throw PublishingSessionError.profileUpdateFailed
        }
        return receipt
    }
    private func mutate(_ request: MutationRequest, before suppliedDeadline: Double?) async throws -> MutationReceipt {
        let admittedAt = bitRateClock()
        let deadline = min(suppliedDeadline ?? admittedAt + 2, admittedAt + 2)
        let (id, operation) = try lock.withLock { () -> (UUID, Task<MutationReceipt, Error>) in
            guard !Task.isCancelled else { throw PublishingSessionError.cancelled }
            guard state == .publishing else { throw PublishingSessionError.invalidState }
            if case .bitRate(let rate) = request {
                guard rate > 0, rate <= Int32.max else { throw PublishingSessionError.invalidBitRate }
            }
            guard suppliedDeadline.map({ $0.isFinite && $0 > admittedAt && $0 <= 1e12 }) ?? true,
                  deadline > bitRateClock() else { throw request.invalidDeadline }
            guard mutationID == nil else { throw request.inProgress }
            let id = UUID()
            mutationID = id; mutationCommitted = false
            let operation = Task.detached {
                try await self.performUpdate(request, id: id, admittedAt: admittedAt, deadline: deadline)
            }
            mutationTask = operation
            mutationTimer = Task.detached {
                do { try await Task.sleep(for: .seconds(max(0, deadline - self.bitRateClock()))) }
                catch { return }
                self.lock.withLock {
                    guard self.mutationID == id, !self.mutationCommitted, self.state == .publishing else { return }
                    _ = self.makeStopLocked(failure: request.timedOut)
                }
            }
            return (id, operation)
        }
        defer {
            lock.withLock {
                if mutationID == id { mutationID = nil; mutationTask = nil; mutationTimer = nil; mutationCommitted = false }
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let receipt = try await operation.value
                await cancelAndJoinMutationTimer(id)
                try lock.withLock {
                    guard state == .publishing, mutationID == id, !Task.isCancelled else { throw PublishingSessionError.cancelled }
                }
                return receipt
            } catch {
                // The caller is not the mutation task joined by shutdown.
                await requestStop(failure: error as? PublishingSessionError ?? request.failed).value
                await cancelAndJoinMutationTimer(id)
                throw lock.withLock { failure ?? .cancelled }
            }
        } onCancel: {
            self.lock.withLock {
                guard self.mutationID == id else { return }
                _ = self.makeStopLocked(failure: .cancelled)
            }
        }
    }
    private func cancelAndJoinMutationTimer(_ id: UUID) async {
        let timer = lock.withLock { mutationID == id ? mutationTimer : nil }
        timer?.cancel()
        await timer?.value
    }
    private func performUpdate(_ request: MutationRequest, id: UUID,
                               admittedAt: Double, deadline: Double) async throws -> MutationReceipt {
        do {
            try Task.checkCancellation()
            try lock.withLock {
                guard state == .publishing, mutationID == id else { throw PublishingSessionError.cancelled }
                guard bitRateClock() < deadline else { throw request.timedOut }
            }
            let receipt: MutationReceipt
            switch request {
            case .bitRate(let rate): receipt = .bitRate(try await publisher.setVideoBitRate(rate))
            case .profile(let profile): receipt = .profile(try await publisher.setVideoProfile(profile))
            }
            try Task.checkCancellation()
            let healthy = await publisher.isPublishing
            try Task.checkCancellation()
            try lock.withLock {
                guard state == .publishing, mutationID == id else { throw PublishingSessionError.cancelled }
                let now = bitRateClock()
                guard now <= deadline else { throw request.timedOut }
                guard healthy, !transportClockQuarantined,
                      receipt.acknowledgedAt >= admittedAt, receipt.acknowledgedAt <= now,
                      transportClock.map({ $0.publishingGeneration == receipt.generation }) ?? true else { throw request.failed }
                switch (request, receipt) {
                case (.bitRate(let rate), .bitRate(let receipt)):
                    try acceptBitRate(receipt, requested: rate)
                case (.profile(let profile), .profile(let receipt)):
                    try acceptProfile(receipt, requested: profile)
                default: throw request.failed
                }
                mutationCommitted = true
            }
            return receipt
        } catch {
            let reason: PublishingSessionError = error is CancellationError ? .cancelled
                : (error as? PublishingSessionError ?? request.failed)
            // Never join shutdown from the mutation task shutdown itself joins.
            _ = requestStop(failure: reason)
            throw lock.withLock { failure ?? .cancelled }
        }
    }
    /// Caller holds the state lock; these commit historical evidence atomically.
    private func acceptBitRate(_ receipt: PublishingBitRateChange, requested: Int) throws {
        guard receipt.configuration.bitRate == requested,
              lastVideoProfileChange.map({ $0.publishingGeneration == receipt.publishingGeneration }) ?? true else {
            throw PublishingSessionError.bitRateUpdateFailed
        }
        if let profile = lastVideoProfileChange {
            guard let pts = receipt.lastSubmittedSourcePTS,
                  CMTimeCompare(pts, profile.firstNewSourcePTS) >= 0,
                  receipt.configuration.encoderSessionID != profile.previousEncoderSessionID else {
                throw PublishingSessionError.bitRateUpdateFailed
            }
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
        lastBitRateChange = receipt
    }
    private func acceptProfile(_ receipt: PublishingVideoProfileChange, requested: PublishingVideoProfile) throws {
        guard receipt.profile == requested,
              lastBitRateChange.map({ $0.publishingGeneration == receipt.publishingGeneration &&
                  $0.configuration.encoderSessionID != receipt.encoderSessionID }) ?? true else {
            throw PublishingSessionError.profileUpdateFailed
        }
        if let prior = lastBitRateChange, let pts = prior.lastSubmittedSourcePTS {
            guard CMTimeCompare(receipt.lastOldSourcePTS, pts) >= 0 else { throw PublishingSessionError.profileUpdateFailed }
        }
        if let prior = lastVideoProfileChange {
            guard prior.publishingGeneration == receipt.publishingGeneration,
                  prior.encoderSessionID != receipt.encoderSessionID,
                  prior.previousEncoderSessionID != receipt.encoderSessionID,
                  prior.acknowledgedAt <= receipt.acknowledgedAt,
                  CMTimeCompare(receipt.lastOldSourcePTS, prior.firstNewSourcePTS) >= 0 else {
                throw PublishingSessionError.profileUpdateFailed
            }
        }
        lastVideoProfileChange = receipt
        lastBitRateChange = nil // A verified write to the old encoder cannot describe the replacement.
    }
    func stop() async { await requestStop().value }
    func cancel() { _ = requestStop(failure: .cancelled) }
}

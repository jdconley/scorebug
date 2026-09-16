import Foundation
import CoreMedia
import ScorebugCore
import ScorebugMedia

/// Opt-in application binding. The caller must qualify profiles and telemetry.
/// No capture model starts this owner until source/pressure alignment is qualified.
actor PublishingQualitySession {
    enum Failure: Error, Equatable { case notReady, busy, closed, staleAdvice, unsupportedProfile, invalidReceipt }
    struct Snapshot: Sendable {
        let applied: QualityController.Settings?
        let revision: UInt64?
        let receipt: PublishingBitRateChange?
        let acknowledgedAt: Double?
        let isClosed: Bool
        let isBusy: Bool
    }
    struct Operations: Sendable {
        let setBitRate: @Sendable (Int, Double) async throws -> PublishingBitRateChange
        let stop: @Sendable () async -> Void
        var isPublishing: @Sendable () -> Bool = { true }
    }
    private let operations: Operations
    private let profiles: [QualityController.Profile]
    private let attemptID: UUID
    private let initial: QualityController.Settings
    private let strategy: QualityController.RecoveryStrategy
    private let uptime: @Sendable () -> Double
    private var policy: QualityController?
    private var receipt: PublishingBitRateChange?
    private var acknowledgedAt: Double?
    private var pending: QualityController.Recommendation?
    private var busy = false
    private var closed = false
    private var shutdown: Task<Void, Never>?
    private var lastNow: Double
    private var lastPolicySequence: UInt64 = 0
    private struct SourceScope: Equatable {
        let workerId: String
        let epoch: String
        let attempt: Int
        let publication: WorkerPublication
        let processingScope: String?
        init(_ source: WorkerSourceIntervalObservation) {
            workerId = source.workerId; epoch = source.workerEpoch; attempt = source.workerAttempt
            publication = source.publication; processingScope = source.processing?.scopeID
        }
    }
    private var lastSource: (scope: SourceScope, sequence: Int64)?

    init(session: PublishingSession, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials) throws {
        try self.init(operations: .init(setBitRate: { try await session.setVideoBitRate($0, before: $1) },
            stop: { await session.stop() }, isPublishing: { session.snapshot.state == .publishing }),
            profiles: profiles, attemptID: attemptID, initial: initial, strategy: strategy,
            uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(operations: Operations, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials,
         uptime: @escaping @Sendable () -> Double) throws {
        let now = uptime()
        _ = try QualityController(profiles: profiles, attemptID: attemptID, applied: initial, at: now, recoveryStrategy: strategy)
        guard now <= 1e12 else { throw QualityController.ValidationError.invalidTime }
        self.operations = operations; self.profiles = profiles; self.attemptID = attemptID
        self.initial = initial; self.strategy = strategy; self.uptime = uptime; self.lastNow = now
    }
    var snapshot: Snapshot { .init(applied: policy?.applied, revision: policy?.appliedRevision,
        receipt: receipt, acknowledgedAt: acknowledgedAt, isClosed: closed, isBusy: busy) }

    /// Call only after the native encoder exists. No initial setting is claimed
    /// from configuration intent alone, and repeated bootstrap never dispatches.
    func bootstrap() async throws {
        try admit()
        guard policy == nil else { throw Failure.staleAdvice }
        let start = try time(), deadline = start + 2
        busy = true
        defer { busy = false }
        do {
            let result = try await operations.setBitRate(initial.videoBitrate, deadline)
            try afterWrite()
            let now = try time()
            try validate(result, rate: initial.videoBitrate, start: start, deadline: deadline, now: now)
            policy = try QualityController(profiles: profiles, attemptID: attemptID, applied: initial,
                at: now, recoveryStrategy: strategy)
            receipt = result; acknowledgedAt = now
        } catch { await stop(); throw error }
    }
    func evaluate(_ window: QualityController.Window) throws -> QualityController.Decision {
        try admit()
        guard var policy else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let decision = try policy.evaluate(window, at: time())
            pending = decision.recommendation
            lastPolicySequence = window.sequence
            return decision
        } catch { policy.invalidateTelemetry(); pending = nil; throw error }
    }
    func evaluate(source: WorkerSourceIntervalObservation, diagnostics: PublishingQualityTelemetry.Diagnostics,
                  workerLimits: PublishingQualityTelemetry.WorkerLimits?, transportLimits: PublishingQualityTelemetry.TransportLimits?,
                  instant: ContinuousClock.Instant? = nil) throws -> QualityController.Decision {
        try admit()
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time()
            // Sample age after uptime so elapsed work cannot make a remote
            // completion's conservative lower bound appear newer than it is.
            let sampledInstant = instant ?? .now
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            let sourceScope = SourceScope(source)
            if let lastSource, lastSource.scope == sourceScope, source.sequence <= lastSource.sequence {
                throw QualityController.ValidationError.outOfOrder
            }
            let window = try PublishingQualityTelemetry.window(source: source,
                applied: .init(attemptID: attemptID, revision: policy.appliedRevision,
                    settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt),
                diagnostics: diagnostics, workerLimits: workerLimits, transportLimits: transportLimits,
                sequence: lastPolicySequence + 1, at: now, instant: sampledInstant)
            if let lastSource, lastSource.scope != sourceScope { policy.invalidateTelemetry() }
            let decision = try policy.evaluate(window, at: now)
            lastSource = (sourceScope, source.sequence)
            pending = decision.recommendation
            lastPolicySequence = window.sequence
            return decision
        } catch { policy.invalidateTelemetry(); pending = nil; throw error }
    }
    func checkTrialDeadline() throws -> QualityController.Recommendation? {
        try admit()
        guard var policy else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let advice = try policy.checkTrialDeadline(at: time())
            // No due rollback does not revoke an existing trial/increase/decrease.
            if let advice { pending = advice }
            return advice
        } catch { policy.invalidateTelemetry(); pending = nil; throw error }
    }
    func apply(_ advice: QualityController.Recommendation) async throws {
        try admit()
        guard var policy else { throw Failure.notReady }
        let start: Double
        do { start = try time() }
        catch { policy.invalidateTelemetry(); self.policy = policy; pending = nil; throw error }
        guard pending == advice, advice.attemptID == attemptID,
              advice.appliedRevision == policy.appliedRevision, start <= advice.validUntil else { throw Failure.staleAdvice }
        guard advice.settings.profileID == policy.applied.profileID else { throw Failure.unsupportedProfile }
        let deadline = min(advice.validUntil, start + 2)
        guard deadline > start else { throw Failure.staleAdvice }
        busy = true
        defer { busy = false }
        do {
            let result = try await operations.setBitRate(advice.settings.videoBitrate, deadline)
            try afterWrite()
            let now = try time()
            try validate(result, rate: advice.settings.videoBitrate, start: start, deadline: deadline, now: now)
            // Commit both policy and native receipt without another actor suspension.
            try policy.acknowledge(advice, applied: advice.settings, at: now)
            self.policy = policy; receipt = result; acknowledgedAt = now; pending = nil
        } catch { await stop(); throw error }
    }
    /// All callers join one shielded stop, even if their own task is cancelled.
    func stop() async {
        closed = true; pending = nil
        let task: Task<Void, Never>
        if let shutdown { task = shutdown }
        else {
            let stop = operations.stop
            task = Task.detached { await stop() }
            shutdown = task
        }
        await task.value
    }
    private func admit() throws {
        guard !closed else { throw Failure.closed }
        guard !busy else { throw Failure.busy }
        try Task.checkCancellation()
        guard operations.isPublishing() else { throw Failure.notReady }
    }
    private func afterWrite() throws {
        guard !closed else { throw Failure.closed }
        try Task.checkCancellation()
        guard operations.isPublishing() else { throw Failure.notReady }
    }
    private func time() throws -> Double {
        let now = uptime()
        guard now.isFinite, now >= lastNow, now <= 1e12 else { throw QualityController.ValidationError.invalidTime }
        lastNow = now
        return now
    }
    private func validate(_ result: PublishingBitRateChange, rate: Int, start: Double, deadline: Double, now: Double) throws {
        guard now <= deadline, result.acceptedAt >= start, result.acceptedAt <= now,
              result.configuration.bitRate == rate else { throw Failure.invalidReceipt }
        if let receipt {
            guard result.publishingGeneration == receipt.publishingGeneration,
                  result.configuration.id != receipt.configuration.id,
                  result.acceptedAt >= receipt.acceptedAt else { throw Failure.invalidReceipt }
            if result.configuration.encoderSessionID == receipt.configuration.encoderSessionID,
               let previous = receipt.lastSubmittedSourcePTS {
                guard let next = result.lastSubmittedSourcePTS, CMTimeCompare(next, previous) >= 0 else {
                    throw Failure.invalidReceipt
                }
            }
        }
    }
}

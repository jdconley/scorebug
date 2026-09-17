import Foundation
import CoreMedia
import ScorebugCore
import ScorebugMedia

/// Opt-in application binding. The caller must qualify profiles and telemetry.
/// No capture model starts this owner until source/pressure alignment is qualified.
actor PublishingQualitySession {
    enum Failure: Error, Equatable { case notReady, busy, closed, staleAdvice, unsupportedProfile, invalidReceipt, startupPending }
    struct Snapshot: Sendable {
        let applied: QualityController.Settings?
        let revision: UInt64?
        let receipt: PublishingBitRateChange?
        let profileReceipt: PublishingVideoProfileChange?
        let application: QualityController.Application?
        let acknowledgedAt: Double?
        let lastWindow: QualityController.Window?
        let lastDecoderStall: QualityController.DecoderStall?
        let evaluatedAt: Double?
        let isClosed: Bool
        let isBusy: Bool
    }
    struct Operations: Sendable {
        let setBitRate: @Sendable (Int, Double) async throws -> PublishingBitRateChange
        let stop: @Sendable () async -> Void
        var isPublishing: @Sendable () -> Bool = { true }
        var videoStartup: @Sendable () -> PublishingVideoStartup? = { nil }
        var setProfile: (@Sendable (PublishingVideoProfile, Double) async throws -> PublishingVideoProfileChange)? = nil
    }
    private let operations: Operations
    private let profiles: [QualityController.Profile]
    private let attemptID: UUID
    private let initial: QualityController.Settings
    private let behavior: QualityController.Behavior
    private let strategy: QualityController.RecoveryStrategy
    private let uptime: @Sendable () -> Double
    private var policy: QualityController?
    private var receipt: PublishingBitRateChange?
    private var profileReceipt: PublishingVideoProfileChange?
    private var application: QualityController.Application?
    private var acknowledgedAt: Double?
    private var lastWindow: QualityController.Window?
    private var lastDecoderStall: QualityController.DecoderStall?
    private var evaluatedAt: Double?
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
    private struct DecoderScope: Equatable {
        let gameID: String
        let generation: Int
        let workerID: String
        let epoch: String
        let attempt: Int
        let publication: WorkerPublication
        let scopeID: String
        init(_ value: WorkerDecoderCadenceFreshness) {
            gameID = value.gameId; generation = value.generation; workerID = value.workerId
            epoch = value.workerEpoch; attempt = value.attempt; publication = value.publication
            scopeID = value.snapshot.scopeID
        }
    }
    private var decoderScope: DecoderScope?
    private var decoderProgress: Int64?
    private var consumedStallPTS: Int64?
    var usesDecoderStallPolicy: Bool { behavior == .progressive }

    init(session: PublishingSession, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials,
         behavior: QualityController.Behavior = .legacy) throws {
        try self.init(operations: .init(setBitRate: { try await session.setVideoBitRate($0, before: $1) },
            stop: { await session.stop() }, isPublishing: { session.snapshot.state == .publishing },
            videoStartup: { session.videoStartup },
            setProfile: { try await session.setVideoProfile($0, before: $1) }),
            profiles: profiles, attemptID: attemptID, initial: initial, strategy: strategy, behavior: behavior,
            uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(operations: Operations, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials,
         behavior: QualityController.Behavior = .legacy,
         uptime: @escaping @Sendable () -> Double) throws {
        let now = uptime()
        _ = try QualityController(profiles: profiles, attemptID: attemptID, applied: initial, at: now, recoveryStrategy: strategy, behavior: behavior)
        guard now <= 1e12 else { throw QualityController.ValidationError.invalidTime }
        self.operations = operations; self.profiles = profiles; self.attemptID = attemptID
        self.initial = initial; self.strategy = strategy; self.behavior = behavior; self.uptime = uptime; self.lastNow = now
    }
    var snapshot: Snapshot { .init(applied: policy?.applied, revision: policy?.appliedRevision,
        receipt: receipt, profileReceipt: profileReceipt, application: application, acknowledgedAt: acknowledgedAt,
        lastWindow: lastWindow, lastDecoderStall: lastDecoderStall, evaluatedAt: evaluatedAt, isClosed: closed, isBusy: busy) }

    /// Call only after the native encoder exists. No initial setting is claimed
    /// from configuration intent alone, and repeated bootstrap never dispatches.
    func bootstrap() async throws {
        try admit()
        guard policy == nil else { throw Failure.staleAdvice }
        let start = try time(), deadline = start + 2
        let startup = behavior == .progressive ? operations.videoStartup() : nil
        if behavior == .progressive && startup == nil { throw Failure.startupPending }
        busy = true
        defer { busy = false }
        do {
            if let startup {
                guard startup.profile.rawValue == initial.profileID,
                      let profile = profiles.first(where: { $0.id == initial.profileID }),
                      startup.width == profile.width, startup.height == profile.height,
                      startup.observedAt <= start else { throw Failure.invalidReceipt }
            }
            let result = try await operations.setBitRate(initial.videoBitrate, deadline)
            try afterWrite()
            let now = try time()
            try validate(result, rate: initial.videoBitrate, start: start, deadline: deadline, now: now)
            if let startup {
                guard operations.videoStartup() == startup,
                      result.publishingGeneration == startup.publishingGeneration,
                      result.configuration.encoderSessionID == startup.encoderSessionID,
                      let pts = result.lastSubmittedSourcePTS,
                      CMTimeCompare(pts, startup.firstSourcePTS) >= 0 else { throw Failure.invalidReceipt }
            }
            policy = try QualityController(profiles: profiles, attemptID: attemptID, applied: initial,
                at: now, recoveryStrategy: strategy, behavior: behavior)
            receipt = result; acknowledgedAt = now
        } catch { await stop(); throw error }
    }
    func evaluate(_ window: QualityController.Window) throws -> QualityController.Decision {
        try admit()
        guard var policy else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time()
            let decision = try policy.evaluate(window, at: now)
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
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
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); pending = nil; throw error }
    }
    /// Uses the same ordinal/watermark as matched receiver windows. A valid nil
    /// probe consumes no evidence and preserves the current pending decision.
    func evaluateLocalPressure(diagnostics: PublishingQualityTelemetry.Diagnostics,
                               transportLimits: PublishingQualityTelemetry.TransportLimits?) throws -> QualityController.Decision? {
        try admit()
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time()
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            guard let window = try PublishingQualityTelemetry.localPressureWindow(
                applied: .init(attemptID: attemptID, revision: policy.appliedRevision,
                    settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt),
                diagnostics: diagnostics, transportLimits: transportLimits, sequence: lastPolicySequence + 1,
                after: lastWindow?.end, at: now) else { return nil }
            let decision = try policy.evaluateLocalPressure(window, at: now)
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); pending = nil; throw error }
    }
    func evaluateDecoderStall(cadence: WorkerDecoderCadenceFreshness, diagnostics: PublishingQualityTelemetry.Diagnostics,
                              instant: ContinuousClock.Instant? = nil) throws -> QualityController.Decision? {
        try admit()
        guard behavior == .progressive else { return nil }
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time(), sampledInstant = instant ?? .now
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            let signal = try PublishingQualityTelemetry.decoderStall(cadence: cadence,
                applied: .init(attemptID: attemptID, revision: policy.appliedRevision,
                    settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt),
                diagnostics: diagnostics, sequence: lastPolicySequence + 1, at: now, instant: sampledInstant)
            let scope = DecoderScope(cadence), progress = cadence.snapshot.progress!.lastFreshPTS
            if let decoderScope, decoderScope != scope {
                policy.invalidateTelemetry(); pending = nil
                decoderProgress = nil; consumedStallPTS = nil
            }
            if let decoderProgress, progress < decoderProgress { throw QualityController.ValidationError.outOfOrder }
            decoderScope = scope; decoderProgress = progress
            guard let signal, consumedStallPTS != progress else { return nil }
            let decision = try policy.evaluateDecoderStall(signal, at: now)
            consumedStallPTS = progress; lastPolicySequence = signal.sequence; lastDecoderStall = signal
            pending = decision.recommendation; evaluatedAt = now
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
        let profile: PublishingVideoProfile?
        if advice.settings.profileID == policy.applied.profileID {
            profile = nil
        } else {
            guard operations.setProfile != nil,
                  let native = PublishingVideoProfile(rawValue: advice.settings.profileID),
                  let descriptor = profiles.first(where: { $0.id == native.rawValue }),
                  descriptor.width == native.width, descriptor.height == native.height,
                  descriptor.targetFPS == 30 else { throw Failure.unsupportedProfile }
            profile = native
        }
        let admitted = try policy.beginApplication(advice, at: start)
        let deadline = admitted.completionDeadline
        busy = true
        defer { busy = false }
        do {
            var format: PublishingVideoProfileChange?
            var rateStart = start
            if let profile, let setProfile = operations.setProfile {
                let result = try await setProfile(profile, deadline)
                try afterWrite()
                rateStart = try time()
                try validate(result, profile: profile, start: start, deadline: deadline, now: rateStart)
                guard rateStart < deadline else { throw Failure.invalidReceipt }
                format = result
            }
            let result = try await operations.setBitRate(advice.settings.videoBitrate, deadline)
            try afterWrite()
            let now = try time()
            try validate(result, rate: advice.settings.videoBitrate, start: rateStart, deadline: deadline, now: now)
            if let format {
                guard result.configuration.encoderSessionID == format.encoderSessionID,
                      result.publishingGeneration == format.publishingGeneration,
                      let pts = result.lastSubmittedSourcePTS,
                      CMTimeCompare(pts, format.firstNewSourcePTS) >= 0 else { throw Failure.invalidReceipt }
            }
            // The profile's default bitrate is configuration intent. A verified
            // write on that exact new encoder must precede the single policy ack.
            try policy.acknowledge(admitted, applied: advice.settings, at: now)
            self.policy = policy; receipt = result; acknowledgedAt = now; pending = nil; application = admitted
            if let format { profileReceipt = format }
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
    private func validate(_ result: PublishingVideoProfileChange, profile: PublishingVideoProfile,
                          start: Double, deadline: Double, now: Double) throws {
        guard let receipt, now <= deadline, result.profile == profile,
              result.acknowledgedAt >= start, result.acknowledgedAt <= now,
              result.publishingGeneration == receipt.publishingGeneration,
              result.encoderSessionID != receipt.configuration.encoderSessionID else { throw Failure.invalidReceipt }
        if let previous = receipt.lastSubmittedSourcePTS {
            guard CMTimeCompare(result.lastOldSourcePTS, previous) >= 0 else { throw Failure.invalidReceipt }
        }
        if let prior = profileReceipt {
            guard result.encoderSessionID != prior.encoderSessionID,
                  result.encoderSessionID != prior.previousEncoderSessionID,
                  result.acknowledgedAt >= prior.acknowledgedAt,
                  CMTimeCompare(result.lastOldSourcePTS, prior.firstNewSourcePTS) >= 0 else { throw Failure.invalidReceipt }
        }
    }
}

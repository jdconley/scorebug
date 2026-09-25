import Foundation
import CoreMedia
import ScorebugCore
import ScorebugMedia

/// Opt-in application binding. The caller must qualify profiles and telemetry.
/// No capture model starts this owner until source/pressure alignment is qualified.
actor PublishingQualitySession {
    enum Failure: Error, Equatable { case notReady, busy, closed, staleAdvice, unsupportedProfile, invalidReceipt, startupPending }
    struct Snapshot: Sendable {
        let attemptID: UUID
        let applied: QualityController.Settings?
        let revision: UInt64?
        let receipt: PublishingBitRateChange?
        let profileReceipt: PublishingVideoProfileChange?
        let application: QualityController.Application?
        let acknowledgedAt: Double?
        let lastWindow: QualityController.Window?
        let lastDecoderStall: QualityController.DecoderStall?
        let lastDeliveryFailure: QualityController.DeliveryFailure?
        let evaluatedAt: Double?
        let isClosed: Bool
        let isBusy: Bool
    }
    /// Observational only: these scalars cannot authorize a policy action. Each
    /// callback receives its own immutable record, including early failures that
    /// never reached the existing evaluation-clock sample.
    struct EvaluationDiagnostic: Sendable {
        struct SourceKey: Sendable, Equatable {
            let workerEpoch: String
            let workerAttempt: Int
            let readerID: String
            let sequence: Int64
            init(_ source: WorkerSourceIntervalObservation) {
                workerEpoch = source.workerEpoch; workerAttempt = source.workerAttempt
                readerID = source.publication.readerId; sequence = source.sequence
            }
        }
        enum Input: Sendable, Equatable {
            case cadence(receiptID: UUID)
            case source(SourceKey)
        }
        let input: Input
        let evaluatedAt: Double?
        let sampleAgeSeconds: Double?
        let sourceAgeSeconds: Double?
        fileprivate static func seconds(_ duration: Duration?) -> Double? {
            duration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        }
    }
    /// Advisory work request only. Re-read after suspension; it cannot authorize
    /// a quality increase or keep measurement authority alive after invalidation.
    struct CandidateMeasurementContext: Sendable {
        let readiness: QualityController.CandidateMeasurementReadiness
        let applied: PublishingQualityTelemetry.Applied
        let scope: VideoFrameObservationScope
        let clock: PublishingTransportClock
    }
    /// Explicit capability: rejection promises that the individual native call
    /// had no effect and its cleanup has joined before returning.
    struct GuardedMutations: Sendable {
        let setBitRate: @Sendable (Int, PublishingVideoMutationExpectation, Double) async throws -> PublishingBitRateChange
        let setProfile: @Sendable (PublishingVideoProfile, PublishingBitRateChange, Double) async throws -> PublishingVideoProfileChange
    }
    struct Operations: Sendable {
        let setBitRate: @Sendable (Int, Double) async throws -> PublishingBitRateChange
        let stop: @Sendable () async -> Void
        var guarded: GuardedMutations? = nil
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
    private let sampleInstant: @Sendable () -> ContinuousClock.Instant
    private var policy: QualityController?
    private var receipt: PublishingBitRateChange?
    private var profileReceipt: PublishingVideoProfileChange?
    private var application: QualityController.Application?
    private struct ApplicationOwner {
        let application: QualityController.Application
        var changedProfile = false
    }
    private var applicationOwner: ApplicationOwner?
    private var acknowledgedAt: Double?
    private var lastWindow: QualityController.Window?
    private var lastDecoderStall: QualityController.DecoderStall?
    private var lastDeliveryFailure: QualityController.DeliveryFailure?
    private var deliveryAuthority: PublishingDeliveryAuthority?
    private var deliveryRevision: UInt64?
    private var deliveryEnds: [Int: Double] = [:]
    private var evaluatedAt: Double?
    private var pendingCandidate: PublishingCandidateAdmission?
    private nonisolated let candidateRecovery: PublishingCandidateRecoveryCoverage?
    private var recoveryDelivery: PublishingDeliveryObservation?
    private var candidateHealthSource: SourceScope? {
        didSet { if candidateHealthSource == nil { candidateRecovery?.invalidate(); recoveryDelivery = nil } }
    }
    nonisolated func invalidateCandidateRecovery() { candidateRecovery?.invalidate() }
    private var requiresCadenceFreshnessValidation = false
    private var pending: QualityController.Recommendation? {
        didSet {
            if pending?.candidateID != pendingCandidate?.value.id { pendingCandidate = nil }
        }
    }
    private var busy = false
    private var closed = false
    private var shutdown: Task<Void, Never>?
    private var lastNow: Double
    private var lastPolicySequence: UInt64 = 0
    private struct SourceScope: Equatable {
        let observationScope: VideoFrameObservationScope
        let clock: PublishingTransportClock
        let gameID: String
        let generation: Int
        let workerId: String
        let epoch: String
        let attempt: Int
        let publication: WorkerPublication
        let processingScope: String?
        init(_ source: WorkerSourceIntervalObservation) {
            observationScope = source.interval.scope; clock = source.nativeClock
            gameID = source.interval.scope.matchID; generation = source.interval.scope.broadcastGeneration
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
    private var consumedCadenceReceipt: UUID?
    var usesDecoderStallPolicy: Bool { behavior == .progressive }

    init(session: PublishingSession, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials,
         behavior: QualityController.Behavior = .legacy, requiresSharedCandidateRecovery: Bool = false,
         usesGuardedMutations: Bool = false) throws {
        try self.init(operations: .init(setBitRate: { try await session.setVideoBitRate($0, before: $1) },
            stop: { await session.stop() },
            guarded: usesGuardedMutations ? .init(setBitRate: {
                try await session.setVideoBitRate($0, expecting: $1, before: $2)
            }, setProfile: {
                try await session.setVideoProfile($0, expecting: $1, before: $2)
            }) : nil,
            isPublishing: { session.snapshot.state == .publishing },
            videoStartup: { session.videoStartup },
            setProfile: { try await session.setVideoProfile($0, before: $1) }),
            profiles: profiles, attemptID: attemptID, initial: initial, strategy: strategy, behavior: behavior,
            requiresSharedCandidateRecovery: requiresSharedCandidateRecovery, uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(operations: Operations, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials,
         behavior: QualityController.Behavior = .legacy, requiresSharedCandidateRecovery: Bool = false,
         uptime: @escaping @Sendable () -> Double,
         instant: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        let now = uptime()
        _ = try QualityController(profiles: profiles, attemptID: attemptID, applied: initial, at: now, recoveryStrategy: strategy, behavior: behavior)
        guard now <= 1e12 else { throw QualityController.ValidationError.invalidTime }
        self.operations = operations; self.profiles = profiles; self.attemptID = attemptID
        self.initial = initial; self.strategy = strategy; self.behavior = behavior; self.uptime = uptime; self.lastNow = now
        self.sampleInstant = instant
        self.candidateRecovery = requiresSharedCandidateRecovery ? PublishingCandidateRecoveryCoverage() : nil
    }
    var snapshot: Snapshot { .init(attemptID: attemptID, applied: policy?.applied, revision: policy?.appliedRevision,
        receipt: receipt, profileReceipt: profileReceipt, application: application, acknowledgedAt: acknowledgedAt,
        lastWindow: lastWindow, lastDecoderStall: lastDecoderStall, lastDeliveryFailure: lastDeliveryFailure,
        evaluatedAt: evaluatedAt, isClosed: closed, isBusy: busy) }

    /// Derive scheduling readiness from the current policy and acknowledged
    /// encoder, never from the immutable first-frame startup receipt. This query
    /// neither changes policy state nor performs native work.
    func candidateMeasurementContext(diagnostics: PublishingQualityTelemetry.Diagnostics) -> CandidateMeasurementContext? {
        guard !closed, !busy, !Task.isCancelled, operations.isPublishing(),
              let policy, let receipt, let acknowledgedAt, let source = candidateHealthSource else { return nil }
        let now = uptime()
        guard now.isFinite, now >= lastNow, now <= 1e12,
              let readiness = policy.candidateMeasurementReadiness(at: now),
              diagnostics.isPublishing, let current = diagnostics.receipt,
              current.publishingGeneration == receipt.publishingGeneration,
              current.configuration == receipt.configuration,
              current.acceptedAt == receipt.acceptedAt,
              current.lastSubmittedSourcePTS == receipt.lastSubmittedSourcePTS,
              let clock = diagnostics.clock, clock == source.clock,
              clock.publishingGeneration == receipt.publishingGeneration,
              let ingress = diagnostics.ingress, !ingress.isClosed,
              ingress.scope == source.observationScope,
              ingress.scope.publishingAttemptID == attemptID,
              ingress.scope.matchID == source.gameID,
              ingress.scope.broadcastGeneration == source.generation,
              source.publication.publishingAttemptId == attemptID.uuidString.lowercased(),
              receipt.configuration.bitRate == readiness.baseline.videoBitrate,
              acknowledgedAt.isFinite, acknowledgedAt >= receipt.acceptedAt, acknowledgedAt <= now else { return nil }
        if let candidateRecovery, readiness.appliedRevision > 0 {
            guard let delivery = recoveryDelivery, let authority = deliveryAuthority,
                  delivery.authority === authority, authority.permits(delivery.delivery),
                  delivery.appliedRevision == readiness.appliedRevision,
                  delivery.source.scope == source.observationScope,
                  delivery.source.publishingGeneration == receipt.publishingGeneration,
                  delivery.source.configuration == receipt.configuration,
                  delivery.delivery.context.gameId == source.gameID,
                  delivery.delivery.context.generation == source.generation,
                  delivery.delivery.context.workerId == source.workerId,
                  delivery.delivery.context.workerEpoch == source.epoch,
                  delivery.delivery.context.attempt == source.attempt,
                  delivery.delivery.context.publication == source.publication,
                  let decoderScope, decoderScope.gameID == source.gameID,
                  decoderScope.generation == source.generation, decoderScope.workerID == source.workerId,
                  decoderScope.epoch == source.epoch, decoderScope.attempt == source.attempt,
                  decoderScope.publication == source.publication
            else { candidateRecovery.invalidate(); return nil }
            guard candidateRecovery.permits(healthySince: readiness.healthySince,
                healthyThrough: readiness.healthyThrough, healthSequence: readiness.healthSequence) else { return nil }
        }
        return .init(readiness: readiness,
            applied: .init(attemptID: attemptID, revision: readiness.appliedRevision, settings: readiness.baseline,
                receipt: receipt, acknowledgedAt: acknowledgedAt), scope: ingress.scope, clock: clock)
    }

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
    /// The caller may discover a completed candidate between worker windows.
    /// Defer its one-shot policy event until a current overlapping source is
    /// available. Readiness and consumption share one actor turn; provider
    /// suspension can neither freeze an old window nor bypass invalidation.
    func evaluateCandidateWhenSourceReady(_ admission: PublishingCandidateAdmission) throws -> QualityController.Decision? {
        try admit()
        guard let policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        let now = try time(), instant = sampleInstant()
        let applied = PublishingQualityTelemetry.Applied(attemptID: attemptID, revision: policy.appliedRevision,
            settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt)
        // Revoked or changed owners retain the existing rejection behavior;
        // deferral is solely for absent/incompatible temporal source coverage.
        guard admission.permits(applied: applied, at: now, instant: instant) else {
            return try evaluateCandidate(admission, instant: instant)
        }
        let receiver = admission.receiver
        guard let source = candidateHealthSource,
              source.gameID == receiver.expected.gameId, source.generation == receiver.expected.generation,
              source.workerId == receiver.expected.workerId, source.epoch == receiver.workerEpoch,
              source.attempt == receiver.workerAttempt, source.publication == receiver.publication,
              let window = lastWindow, let observedReceiver = window.receiver,
              window.attemptID == attemptID, window.appliedRevision == policy.appliedRevision,
              window.end <= now, now - window.end <= 2,
              observedReceiver.observedAt <= now, now - observedReceiver.observedAt <= 2,
              window.end > admission.value.measuredStart, window.start < admission.value.measuredEnd else { return nil }
        return try evaluateCandidate(admission, instant: instant)
    }

    /// Recheck caller-owned authority after actor scheduling. This event consumes
    /// no source sequence and cannot manufacture health from candidate duration.
    func evaluateCandidate(_ admission: PublishingCandidateAdmission,
                           instant: ContinuousClock.Instant? = nil) throws -> QualityController.Decision {
        try admit()
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time()
            let applied = PublishingQualityTelemetry.Applied(attemptID: attemptID, revision: policy.appliedRevision,
                settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt)
            let receiver = admission.receiver
            guard let source = candidateHealthSource,
                  source.gameID == receiver.expected.gameId, source.generation == receiver.expected.generation,
                  source.workerId == receiver.expected.workerId, source.epoch == receiver.workerEpoch,
                  source.attempt == receiver.workerAttempt, source.publication == receiver.publication,
                  admission.permits(applied: applied, at: now, instant: instant ?? sampleInstant()) else {
                throw Failure.staleAdvice
            }
            let decision = try policy.evaluateCandidate(admission.value, at: now)
            pendingCandidate = decision.recommendation?.candidateID == admission.value.id ? admission : nil
            // A candidate no-op revokes earlier candidate advice, but Core keeps
            // a known downward/reset recommendation until applied or superseded.
            if let advice = decision.recommendation { pending = advice }
            else if pending?.candidateID != nil { pending = nil }
            evaluatedAt = now
            return decision
        } catch {
            // Gate revocation is not a contradictory source observation. It must
            // not displace an already owned downward action. Malformed Core
            // candidate inputs retain Core's normal invalidation behavior.
            let preserveDownward = (error as? Failure) == .staleAdvice && pending.map {
                $0.kind == .decrease || $0.kind == .reset || $0.kind == .rollback
            } == true
            if !preserveDownward { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil }
            throw error
        }
    }
    func evaluate(_ window: QualityController.Window) throws -> QualityController.Decision {
        try admit()
        candidateHealthSource = nil
        guard var policy else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time()
            let decision = try policy.evaluate(window, at: now)
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil; throw error }
    }
    func evaluate(source: WorkerSourceIntervalObservation, diagnostics: PublishingQualityTelemetry.Diagnostics,
                  workerLimits: PublishingQualityTelemetry.WorkerLimits?, transportLimits: PublishingQualityTelemetry.TransportLimits?,
                  instant: ContinuousClock.Instant? = nil,
                  observeEvaluation: (@Sendable (EvaluationDiagnostic) -> Void)? = nil) throws -> QualityController.Decision {
        var evaluationAt: Double?, evaluationInstant: ContinuousClock.Instant?
        defer {
            if let observeEvaluation {
                observeEvaluation(.init(input: .source(.init(source)), evaluatedAt: evaluationAt,
                    sampleAgeSeconds: EvaluationDiagnostic.seconds(evaluationInstant.flatMap { source.freshness.ageUpperBound(at: $0) }),
                    sourceAgeSeconds: evaluationAt.map { $0 - source.interval.captureBoundaryEndTime }))
            }
        }
        try admit()
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time()
            // Sample age after uptime so elapsed work cannot make a remote
            // completion's conservative lower bound appear newer than it is.
            let sampledInstant = instant ?? .now
            evaluationAt = now; evaluationInstant = sampledInstant
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
            if let lastSource, lastSource.scope != sourceScope { policy.invalidateTelemetry(); candidateHealthSource = nil }
            let decision = try policy.evaluate(window, at: now)
            candidateHealthSource = sourceScope
            candidateRecovery?.recordSource(start: window.start, end: window.end, sequence: window.sequence)
            lastSource = (sourceScope, source.sequence)
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil; throw error }
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
            candidateHealthSource = nil
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil; throw error }
    }
    /// A current publisher with absent cadence supplies unknown evidence, never
    /// a healthy sample. Only an already justified downward action is preserved.
    func noteUnavailableCadence(diagnostics: PublishingQualityTelemetry.Diagnostics) throws {
        try admit()
        guard behavior == .progressive, var policy, let receipt, let acknowledgedAt else { return }
        defer { self.policy = policy }
        candidateHealthSource = nil
        // Preserve identity/progress/stall watermarks, but a reappearing receipt
        // must validate freshness again before the consumed-receipt fast path.
        requiresCadenceFreshnessValidation = true
        let preserveDownward = pending.map { $0.kind == .decrease || $0.kind == .reset || $0.kind == .rollback } == true
        do {
            let now = try time()
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            _ = try PublishingQualityTelemetry.localPressureWindow(
                applied: .init(attemptID: attemptID, revision: policy.appliedRevision,
                    settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt),
                diagnostics: diagnostics, transportLimits: nil, sequence: lastPolicySequence + 1,
                after: lastWindow?.end, at: now)
        } catch {
            if !preserveDownward { policy.invalidateTelemetry(); pending = nil }
            throw error
        }
        if !preserveDownward { policy.invalidateTelemetry(); pending = nil }
    }

    func evaluateDecoderStall(cadence: WorkerDecoderCadenceFreshness, diagnostics: PublishingQualityTelemetry.Diagnostics,
                              instant: ContinuousClock.Instant? = nil,
                              observeEvaluation: (@Sendable (EvaluationDiagnostic) -> Void)? = nil) throws -> QualityController.Decision? {
        var evaluationAt: Double?, evaluationInstant: ContinuousClock.Instant?
        defer {
            if let observeEvaluation {
                observeEvaluation(.init(input: .cadence(receiptID: cadence.receiptID), evaluatedAt: evaluationAt,
                    sampleAgeSeconds: EvaluationDiagnostic.seconds(evaluationInstant.flatMap { cadence.sampleAgeUpperBound(at: $0) }),
                    sourceAgeSeconds: nil))
            }
        }
        try admit()
        guard behavior == .progressive else { return nil }
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time(), sampledInstant = instant ?? .now
            evaluationAt = now; evaluationInstant = sampledInstant
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            let applied = PublishingQualityTelemetry.Applied(attemptID: attemptID, revision: policy.appliedRevision,
                settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt)
            try PublishingQualityTelemetry.validateDecoderContext(cadence: cadence, applied: applied,
                diagnostics: diagnostics, sequence: lastPolicySequence + 1, at: now)
            // A consumed downward-only sample cannot acquire new meaning merely
            // by aging in a local cache. A newly received stale report still rejects.
            guard requiresCadenceFreshnessValidation || consumedCadenceReceipt != cadence.receiptID else { return nil }
            let signal = try PublishingQualityTelemetry.decoderStall(cadence: cadence, applied: applied,
                diagnostics: diagnostics, sequence: lastPolicySequence + 1, at: now, instant: sampledInstant)
            let scope = DecoderScope(cadence), progress = cadence.snapshot.progress!.lastFreshPTS
            if let decoderScope, decoderScope != scope {
                policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil
                decoderProgress = nil; consumedStallPTS = nil
            }
            if let decoderProgress, progress < decoderProgress { throw QualityController.ValidationError.outOfOrder }
            decoderScope = scope; decoderProgress = progress; consumedCadenceReceipt = cadence.receiptID
            requiresCadenceFreshnessValidation = false
            if cadence.snapshot.progress?.stalled == false { candidateRecovery?.resume(at: now) }
            guard let signal, consumedStallPTS != progress else { return nil }
            let decision = try policy.evaluateDecoderStall(signal, at: now)
            candidateHealthSource = nil
            consumedStallPTS = progress; lastPolicySequence = signal.sequence; lastDecoderStall = signal
            pending = decision.recommendation; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil; throw error }
    }
    /// Classification occurred synchronously at the current-input boundary.
    /// Retirement is checked again here after actor scheduling, before the
    /// known failure may latch a reset. No await occurs during admission.
    func evaluateDeliveryFailure(_ observation: PublishingDeliveryObservation,
                                 authority: PublishingDeliveryAuthority,
                                 recordCandidateRecovery: Bool = true,
                                 instant: ContinuousClock.Instant? = nil) throws -> QualityController.Decision? {
        try admit()
        guard behavior == .progressive else { return nil }
        guard var policy, let receipt, let acknowledgedAt else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let now = try time(), source = observation.source
            guard observation.authority === authority, authority.permits(observation.delivery),
                  source.scope.publishingAttemptID == attemptID,
                  observation.delivery.context.publication.publishingAttemptId == attemptID.uuidString.lowercased(),
                  observation.appliedRevision == policy.appliedRevision,
                  source.publishingGeneration == receipt.publishingGeneration,
                  source.configuration == receipt.configuration,
                  source.configuration.bitRate == policy.applied.videoBitrate,
                  source.windowStart >= acknowledgedAt else { throw PublishingQualityTelemetry.Failure.ownership }
            let duration = source.windowEnd - source.windowStart
            guard [1.0, 2.0].contains(duration) else { throw QualityController.ValidationError.invalidWindow }
            let lane = Int(duration)
            if deliveryAuthority === authority, deliveryRevision == policy.appliedRevision,
               let end = deliveryEnds[lane], source.windowStart < end { return nil }
            // Status TTL can expire while work is queued, before the model's
            // next health poll revokes its context authority.
            guard let currentAge = observation.delivery.sampleAgeUpperBound(at: instant ?? .now),
                  currentAge >= .zero,
                  currentAge <= .seconds(ProgressiveStreamingPolicy.maximumDecoderStallSampleAge),
                  observation.observedAtLowerBound.isFinite, observation.observedAtLowerBound <= now,
                  source.windowEnd <= observation.observedAtLowerBound,
                  now - observation.observedAtLowerBound <= ProgressiveStreamingPolicy.maximumDecoderStallSampleAge,
                  now - source.windowEnd <= 2 else { throw PublishingQualityTelemetry.Failure.freshness }
            if deliveryAuthority !== authority || deliveryRevision != policy.appliedRevision {
                if deliveryAuthority != nil { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil }
                deliveryAuthority = authority; deliveryRevision = policy.appliedRevision; deliveryEnds = [:]
            }
            deliveryEnds[lane] = source.windowEnd
            if let candidateRecovery, recordCandidateRecovery {
                candidateRecovery.recordDelivery(start: source.windowStart, end: source.windowEnd, result: observation.result)
                recoveryDelivery = observation
            }
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            guard let signal = observation.failureSignal(sequence: lastPolicySequence + 1) else {
                if observation.result.uncertainFrames > 0 { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil }
                return nil
            }
            let decision = try policy.evaluateDeliveryFailure(signal, at: now)
            candidateHealthSource = nil
            lastPolicySequence = signal.sequence; lastDeliveryFailure = signal
            pending = decision.recommendation; evaluatedAt = now
            return decision
        } catch { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil; throw error }
    }
    func checkTrialDeadline() throws -> QualityController.Recommendation? {
        try admit()
        guard var policy else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            let advice = try policy.checkTrialDeadline(at: time())
            // No due rollback does not revoke an existing trial/increase/decrease.
            if let advice { candidateHealthSource = nil; pending = advice }
            return advice
        } catch { policy.invalidateTelemetry(); candidateHealthSource = nil; pending = nil; throw error }
    }
    func apply(_ advice: QualityController.Recommendation) async throws {
        try admit()
        guard var policy else { throw Failure.notReady }
        let start: Double
        do { start = try time() }
        catch { policy.invalidateTelemetry(); self.policy = policy; candidateHealthSource = nil; pending = nil; throw error }
        guard pending == advice, advice.attemptID == attemptID,
              advice.appliedRevision == policy.appliedRevision, start <= advice.validUntil else { throw Failure.staleAdvice }
        let profile: PublishingVideoProfile?
        if advice.settings.profileID == policy.applied.profileID {
            profile = nil
        } else {
            guard operations.guarded != nil || operations.setProfile != nil,
                  let native = PublishingVideoProfile(rawValue: advice.settings.profileID),
                  let descriptor = profiles.first(where: { $0.id == native.rawValue }),
                  descriptor.width == native.width, descriptor.height == native.height,
                  descriptor.targetFPS == 30 else { throw Failure.unsupportedProfile }
            profile = native
        }
        if let candidateID = advice.candidateID {
            guard let witness = pendingCandidate, witness.value.id == candidateID,
                  let receipt, let acknowledgedAt,
                  witness.permits(applied: .init(attemptID: attemptID, revision: policy.appliedRevision,
                      settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt),
                      at: start, instant: sampleInstant()) else {
                policy.invalidateTelemetry(); self.policy = policy; candidateHealthSource = nil; pending = nil
                throw Failure.staleAdvice
            }
        }
        let admitted = try policy.beginApplication(advice, at: start)
        // Publish authoritative policy and private ownership before native work
        // suspends. A selector is never proof that this application changed it.
        self.policy = policy
        applicationOwner = .init(application: admitted)
        // Once admitted, the owned native application has its independent two-
        // second deadline. Native changes normally retire the probe authority.
        pendingCandidate = nil; candidateHealthSource = nil
        let deadline = admitted.completionDeadline
        busy = true
        defer {
            if applicationOwner?.application == admitted {
                applicationOwner = nil
                busy = false
            }
        }
        do {
            var format: PublishingVideoProfileChange?
            var rateStart = start
            if let profile {
                let result: PublishingVideoProfileChange
                if let guarded = operations.guarded {
                    guard let receipt else { throw Failure.notReady }
                    result = try await guarded.setProfile(profile, receipt, deadline)
                } else if let setProfile = operations.setProfile {
                    result = try await setProfile(profile, deadline)
                } else { throw Failure.unsupportedProfile }
                guard applicationOwner?.application == admitted else { throw Failure.closed }
                applicationOwner?.changedProfile = true
                try afterWrite()
                rateStart = try time()
                try validate(result, profile: profile, start: start, deadline: deadline, now: rateStart)
                guard rateStart < deadline else { throw Failure.invalidReceipt }
                format = result
            }
            let result: PublishingBitRateChange
            if let guarded = operations.guarded {
                guard let receipt else { throw Failure.notReady }
                let expected: PublishingVideoMutationExpectation = format.map { .replacement($0) } ?? .verified(receipt)
                result = try await guarded.setBitRate(advice.settings.videoBitrate, expected, deadline)
            } else {
                result = try await operations.setBitRate(advice.settings.videoBitrate, deadline)
            }
            guard applicationOwner?.application == admitted else { throw Failure.closed }
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
            guard var current = self.policy else { throw Failure.notReady }
            defer { self.policy = current }
            try current.acknowledge(admitted, applied: advice.settings, at: now)
            receipt = result; acknowledgedAt = now; pending = nil; application = admitted
            // This revision change is our acknowledged write, not replacement
            // of the receiver context. Keep its revocable identity while new
            // source/configuration windows start their own delivery watermarks.
            deliveryRevision = current.appliedRevision; deliveryEnds = [:]
            if let format { profileReceipt = format }
        } catch {
            guard let owner = applicationOwner, owner.application == admitted else {
                // stop() already retired this owner. Join its existing shutdown;
                // a late completion cannot request shutdown of newer native work.
                await shutdown?.value
                throw error
            }
            if operations.guarded != nil, error is PublishingVideoMutationAdmissionError,
               !owner.changedProfile, !Task.isCancelled, operations.isPublishing() {
                // This compatibility path has no owned measurement to settle.
                // The guarded call has joined its cleanup; retire only this
                // application using the current authoritative policy.
                if var current = self.policy {
                    do { try current.acknowledge(admitted, applied: nil, at: time()) }
                    catch { current.invalidateTelemetry() }
                    self.policy = current
                }
                if pending == advice { pending = nil }
            } else {
                // A successful profile replacement is an application effect,
                // even when its following guarded bitrate call had no effect.
                await stop()
            }
            throw error
        }
    }
    /// All callers join one shielded stop, even if their own task is cancelled.
    func stop() async {
        closed = true; pending = nil; pendingCandidate = nil; candidateHealthSource = nil
        applicationOwner = nil; busy = false
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

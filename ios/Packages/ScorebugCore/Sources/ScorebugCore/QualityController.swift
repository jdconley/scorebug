import Foundation

/// Pure live-video policy. Callers supply monotonic seconds and independently
/// measured telemetry; this type never configures capture, encoding, or archives.
/// Thresholds are initial qualification values, not a reliability guarantee.
public struct QualityController: Sendable {
    /// Measured source spans may exceed nominal five-second decoder windows.
    /// This ingestion allowance never changes actual elapsed-time rate calculations.
    public static let maximumWindowDuration: Double = 5.25
    /// Candidate measurement includes bounded source admission, final output,
    /// and drain/join time; it is not a regular source health window.
    public static let maximumCandidateMeasurementDuration: Double = 7
    public static let minimumTrialCoverage: Double = 10
    public static let maximumApplicationDuration: Double = 2
    /// One initial transition, required actual coverage, one complete-window
    /// overshoot, and the unchanged two-second evidence arrival allowance.
    public static let maximumTrialDuration = minimumTrialCoverage + 2 * maximumWindowDuration + 2
    public struct Profile: Equatable, Sendable {
        public let id: String
        public let width: Int
        public let height: Int
        public let targetFPS: Int
        public let minimumBitrate: Int
        public let maximumBitrate: Int
        public init(id: String, width: Int, height: Int, targetFPS: Int = 30, minimumBitrate: Int, maximumBitrate: Int) {
            self.id = id; self.width = width; self.height = height; self.targetFPS = targetFPS
            self.minimumBitrate = minimumBitrate; self.maximumBitrate = maximumBitrate
        }
    }
    public struct Settings: Equatable, Sendable {
        public let profileID: String
        public let videoBitrate: Int
        public init(profileID: String, videoBitrate: Int) { self.profileID = profileID; self.videoBitrate = videoBitrate }
    }
    /// Progressive remains explicit until source timing and native transitions
    /// qualify it. `applied` must always describe actual settings, including startup.
    public enum Behavior: Sendable { case legacy, progressive }
    public enum RecoveryStrategy: Sendable {
        case capacityQualified, receiverValidatedTrials
        /// Explicit opt-in for qualified native profiles. Unlike bitrate trials,
        /// a next-profile probe may exceed a 10% rate step; probation and rollback
        /// still apply, and callers must support owned native profile replacement.
        case receiverValidatedProfileTrials
        /// Only independently measured, exact-next candidate admissions can
        /// authorize recovery. Ordinary health windows accumulate credit only.
        case measuredCandidateTrials
    }
    /// Advisory snapshot for scheduling fresh candidate measurements. This is
    /// neither an admission nor permission to apply settings; final candidate
    /// evidence must independently pass `evaluateCandidate` and probation.
    public struct CandidateMeasurementReadiness: Equatable, Sendable {
        public let attemptID: UUID
        public let appliedRevision: UInt64
        public let baseline: Settings
        public let settings: Settings
        public let healthSequence: UInt64
        public let healthySince: Double
        public let healthyThrough: Double
        public let validUntil: Double
    }
    /// Controller-issued ownership of one measurement. Registration freshness
    /// authorizes the start, not the lifetime of its independently bounded work.
    public struct CandidateMeasurementAttempt: Equatable, Sendable {
        fileprivate let controllerID: UUID
        fileprivate let id: UUID
        public let readiness: CandidateMeasurementReadiness
        public let registeredAt: Double
        fileprivate init(controllerID: UUID, readiness: CandidateMeasurementReadiness, registeredAt: Double) {
            self.controllerID = controllerID; self.id = UUID()
            self.readiness = readiness; self.registeredAt = registeredAt
        }
    }
    /// Read-only policy diagnostics. These values never grant measurement or application authority.
    public struct CandidateMeasurementDiagnostic: Equatable, Sendable {
        public let consecutiveFailures: Int
        public let healthyNotBefore: Double
        public let requiredHealthyDuration: Double
        public let failureEpisodeActive: Bool
        public let recoveryStart: Double?
        public let strongHealthSequence: UInt64?
        public let strongHealthStart: Double?
        public let strongHealthEnd: Double?
    }
    public var candidateMeasurementDiagnostic: CandidateMeasurementDiagnostic {
        .init(consecutiveFailures: consecutiveFailures, healthyNotBefore: healthyNotBefore,
            requiredHealthyDuration: requiredHealthyDuration, failureEpisodeActive: failureEpisodeActive,
            recoveryStart: recoveryStart, strongHealthSequence: latestStrongHealth?.sequence,
            strongHealthStart: latestStrongHealth?.start, strongHealthEnd: latestStrongHealth?.end)
    }
    /// Actual candidate transport cost and delivered probe padding, qualified
    /// independently by the caller and bound to one publication and exact target.
    public struct CandidateAdmission: Sendable {
        public let id: UUID
        public let attemptID: UUID
        public let appliedRevision: UInt64
        public let baseline: Settings
        public let settings: Settings
        public let measuredStart: Double
        public let measuredEnd: Double
        public let evaluatedAt: Double
        public let validUntil: Double
        public let candidateTransportBitsPerSecond: Double
        public let deliveredPaddingBitsPerSecond: Double
        public init(id: UUID, attemptID: UUID, appliedRevision: UInt64, baseline: Settings, settings: Settings,
                    measuredStart: Double, measuredEnd: Double, evaluatedAt: Double, validUntil: Double,
                    candidateTransportBitsPerSecond: Double, deliveredPaddingBitsPerSecond: Double) {
            self.id = id; self.attemptID = attemptID; self.appliedRevision = appliedRevision
            self.baseline = baseline; self.settings = settings
            self.measuredStart = measuredStart; self.measuredEnd = measuredEnd
            self.evaluatedAt = evaluatedAt; self.validUntil = validUntil
            self.candidateTransportBitsPerSecond = candidateTransportBitsPerSecond
            self.deliveredPaddingBitsPerSecond = deliveredPaddingBitsPerSecond
        }
    }
    public enum Connectivity: Sendable { case connected, disconnected, unknown }
    public enum Pressure: Sendable { case nominal, elevated, unknown }
    public struct Receiver: Sendable {
        /// Unique source frames received in this window, never muxed/duplicated frames.
        public let freshFrames: Int
        /// Caller-normalized monotonic observation time for the completed window.
        public let observedAt: Double
        public init(freshFrames: Int, observedAt: Double) { self.freshFrames = freshFrames; self.observedAt = observedAt }
    }
    public struct SourceLoss: Sendable {
        public let expectedFrames: Int
        public let lostFrames: Int
        public init(expectedFrames: Int, lostFrames: Int) { self.expectedFrames = expectedFrames; self.lostFrames = lostFrames }
    }
    public struct Window: Sendable {
        public let attemptID: UUID
        public let sequence: UInt64
        public let appliedRevision: UInt64
        public let start: Double
        public let end: Double
        public let capturedFreshFrames: Int?
        public let encodedFreshFrames: Int?
        public let receiver: Receiver?
        public let sourceLoss: SourceLoss?
        /// Time-weighted mean fraction of the bounded live ingress queue occupied.
        public let meanQueueOccupancy: Double?
        /// Usable VIDEO bits/second after reserving audio and transport overhead.
        /// A configured bitrate or historical send throughput is not capacity evidence.
        public let usableVideoCapacity: Double?
        public let connectivity: Connectivity
        public let thermalPressure: Pressure
        public let workerPressure: Pressure
        public let transportPressure: Pressure
        public init(attemptID: UUID, sequence: UInt64, appliedRevision: UInt64, start: Double, end: Double,
                    capturedFreshFrames: Int?, encodedFreshFrames: Int?, receiver: Receiver?, sourceLoss: SourceLoss?,
                    meanQueueOccupancy: Double?, usableVideoCapacity: Double?, connectivity: Connectivity,
                    thermalPressure: Pressure, workerPressure: Pressure, transportPressure: Pressure = .unknown) {
            self.attemptID = attemptID; self.sequence = sequence; self.appliedRevision = appliedRevision
            self.start = start; self.end = end; self.capturedFreshFrames = capturedFreshFrames
            self.encodedFreshFrames = encodedFreshFrames; self.receiver = receiver; self.sourceLoss = sourceLoss
            self.meanQueueOccupancy = meanQueueOccupancy; self.usableVideoCapacity = usableVideoCapacity
            self.connectivity = connectivity; self.thermalPressure = thermalPressure; self.workerPressure = workerPressure
            self.transportPressure = transportPressure
        }
    }
    /// Downward-only worker observation, not an inferred source-frame window.
    /// The caller must bind an explicit one-second no-progress report to the
    /// current publication and normalize its conservative sample-time lower bound.
    public struct DecoderStall: Sendable {
        public let attemptID: UUID
        public let appliedRevision: UInt64
        public let sequence: UInt64
        public let observedAtLowerBound: Double
        public init(attemptID: UUID, appliedRevision: UInt64, sequence: UInt64, observedAtLowerBound: Double) {
            self.attemptID = attemptID; self.appliedRevision = appliedRevision
            self.sequence = sequence; self.observedAtLowerBound = observedAtLowerBound
        }
    }
    /// Fully classified source delivery failure. One- and two-second windows
    /// have separate overlap watermarks and can never contribute healthy credit.
    public struct DeliveryFailure: Sendable {
        public let attemptID: UUID
        public let appliedRevision: UInt64
        public let sequence: UInt64
        public let start: Double
        public let end: Double
        public let expectedFrames: Int
        public let onTimeFrames: Int
        public let lateFrames: Int
        public let missingFrames: Int
        public let observedAtLowerBound: Double
        public init(attemptID: UUID, appliedRevision: UInt64, sequence: UInt64,
                    start: Double, end: Double, expectedFrames: Int, onTimeFrames: Int,
                    lateFrames: Int, missingFrames: Int, observedAtLowerBound: Double) {
            self.attemptID = attemptID; self.appliedRevision = appliedRevision; self.sequence = sequence
            self.start = start; self.end = end; self.expectedFrames = expectedFrames
            self.onTimeFrames = onTimeFrames; self.lateFrames = lateFrames; self.missingFrames = missingFrames
            self.observedAtLowerBound = observedAtLowerBound
        }
    }
    public enum State: Equatable, Sendable { case unknown, healthy, degraded, disconnected, stalled, insufficient, probing }
    public enum Reason: Equatable, Sendable {
        case missingCapture, missingEncoded, missingReceiver, staleReceiver, missingSourceLoss, missingQueue, missingCapacity
        case unknownConnectivity, unknownPressure, freshFrameFloor, sourceLoss, queuePressure, capacityHeadroom
        case thermalPressure, workerPressure, disconnected, stalled, minimumProfileInsufficient, recoveryQualified, telemetryGap
        case trialRecommended, trialConfirmed, trialRollback, trialTimedOut
        case transportPressure, unknownTransportPressure
    }
    public struct Recommendation: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case decrease, increase, trial, rollback, reset }
        public let kind: Kind
        public let attemptID: UUID
        public let windowSequence: UInt64
        public let appliedRevision: UInt64
        /// Advice expires with its telemetry, even if no newer window arrives.
        public let validUntil: Double
        public let settings: Settings
        public let candidateID: UUID?
        public init(kind: Kind, attemptID: UUID, windowSequence: UInt64, appliedRevision: UInt64,
                    validUntil: Double, settings: Settings, candidateID: UUID? = nil) {
            self.kind = kind; self.attemptID = attemptID; self.windowSequence = windowSequence
            self.appliedRevision = appliedRevision; self.validUntil = validUntil
            self.settings = settings; self.candidateID = candidateID
        }
    }
    /// Single-use permission to finish native work admitted on fresh advice.
    /// This never extends the lifetime of advice that has not been admitted.
    public struct Application: Equatable, Sendable {
        public let id: UUID
        public let recommendation: Recommendation
        public let admittedAt: Double
        public let completionDeadline: Double
    }
    public struct Decision: Equatable, Sendable {
        public let state: State
        public let reasons: [Reason]
        public let recommendation: Recommendation?
    }
    public enum ValidationError: Error, Equatable {
        case invalidProfiles, invalidSettings, invalidTime, wrongAttempt, wrongAppliedRevision
        case invalidWindow, staleWindow, outOfOrder, staleRecommendation, invalidRecoveryStrategy
        case measurementInProgress, staleMeasurement
    }

    public let profiles: [Profile]
    public let attemptID: UUID
    public private(set) var applied: Settings
    public private(set) var appliedRevision: UInt64 = 0
    private let controllerID = UUID()
    private struct OwnedMeasurement: Sendable {
        let attempt: CandidateMeasurementAttempt
        var admissionConsumed = false
        var recommendation: Recommendation?
    }
    private var ownedMeasurement: OwnedMeasurement?
    // Cleanup ownership survives telemetry revoking the active application slot.
    // The measurement and its resulting application/probation share one episode.
    private struct TransferredMeasurement: Sendable {
        let attempt: CandidateMeasurementAttempt
        let application: Application
        var rejectionRecorded = false
    }
    private var transferredMeasurement: TransferredMeasurement?
    private var lastNow: Double
    private var appliedAt: Double
    private var lastEnd: Double?
    private var lastSequence: UInt64?
    private var deliveryFailureEnds: [Int: (revision: UInt64, end: Double)] = [:]
    private var recoveryStart: Double?
    private var latestStrongHealth: Window?
    // Constant-memory replay protection survives telemetry invalidation and
    // application changes. New candidates must advance and never overlap.
    private var candidateMeasurementEnd: Double?
    private var lastCandidateID: UUID?
    private var healthyNotBefore = 0.0
    private var pending: Recommendation?
    private var application: Application?
    private let behavior: Behavior
    private var minimumResetRequired = false
    private var failureEpisodeActive = false
    private var consecutiveFailures = 0
    private var minimumSettings: Settings {
        .init(profileID: profiles[0].id, videoBitrate: profiles[0].minimumBitrate)
    }
    private var requiredHealthyDuration: Double {
        guard behavior == .progressive else { return 30 }
        return consecutiveFailures == 0 ? ProgressiveStreamingPolicy.healthyIncreaseDuration
            : ProgressiveStreamingPolicy.recoveryDurations[consecutiveFailures - 1]
    }
    private let recoveryStrategy: RecoveryStrategy
    private struct Trial: Sendable {
        let baseline: Settings
        let deadline: Double
        var healthyStart: Double?
        var healthyEnd: Double?
        var rollbackRequired = false
    }
    private var trial: Trial?
    private var trialCooldownUntil = 0.0

    public init(profiles: [Profile], attemptID: UUID, applied: Settings, at now: Double, recoveryStrategy: RecoveryStrategy = .capacityQualified, behavior: Behavior = .legacy) throws {
        guard recoveryStrategy != .measuredCandidateTrials || behavior == .progressive else {
            throw ValidationError.invalidRecoveryStrategy
        }
        guard now.isFinite, now >= 0 else { throw ValidationError.invalidTime }
        guard !profiles.isEmpty, Set(profiles.map(\.id)).count == profiles.count else { throw ValidationError.invalidProfiles }
        for (index, profile) in profiles.enumerated() {
            guard !profile.id.isEmpty, profile.id.utf8.count <= 64,
                  profile.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  profile.width > 0, profile.height > 0, profile.width <= Int32.max, profile.height <= Int32.max,
                  profile.width.isMultiple(of: 2), profile.height.isMultiple(of: 2), profile.targetFPS == 30,
                  profile.minimumBitrate > 0, profile.maximumBitrate >= profile.minimumBitrate,
                  profile.maximumBitrate <= Int32.max else { throw ValidationError.invalidProfiles }
            if index > 0 {
                let prior = profiles[index - 1]
                guard profile.width >= prior.width, profile.height >= prior.height,
                      profile.width > prior.width || profile.height > prior.height,
                      profile.minimumBitrate >= prior.minimumBitrate, profile.maximumBitrate >= prior.maximumBitrate else {
                    throw ValidationError.invalidProfiles
                }
            }
        }
        guard Self.valid(applied, in: profiles) else { throw ValidationError.invalidSettings }
        self.profiles = profiles; self.attemptID = attemptID; self.applied = applied
        self.recoveryStrategy = recoveryStrategy; self.behavior = behavior
        lastNow = now; appliedAt = now
    }

    /// Invalidate evidence rejected by an outer adapter without inventing a window
    /// or advancing clocks/revisions. Actual settings remain historical; active
    /// trials require rollback and recovery must accumulate again from scratch.
    public mutating func invalidateTelemetry() {
        latestStrongHealth = nil
        if behavior == .progressive && (trial != nil || upwardApplicationInFlight) {
            latchMinimumReset(forceApplication: upwardApplicationInFlight)
        } else {
            recoveryStart = nil; pending = nil; application = nil; trial?.rollbackRequired = true
        }
    }
    private var upwardApplicationInFlight: Bool {
        application.map { $0.recommendation.kind == .trial || $0.recommendation.kind == .increase } ?? false
    }

    /// Read existing recovery readiness without advancing time, accumulating
    /// health, consuming evidence, or changing outstanding native work.
    public func candidateMeasurementReadiness(at now: Double) -> CandidateMeasurementReadiness? {
        guard recoveryStrategy == .measuredCandidateTrials, behavior == .progressive,
              now.isFinite, now >= lastNow, now <= 1e12,
              application == nil, trial == nil, pending == nil, !minimumResetRequired,
              let health = latestStrongHealth, let receiver = health.receiver,
              health.end <= now, now - health.end <= 2,
              receiver.observedAt <= now, now - receiver.observedAt <= 2,
              let recoveryStart, health.end - recoveryStart >= requiredHealthyDuration,
              now >= trialCooldownUntil,
              let index = profiles.firstIndex(where: { $0.id == applied.profileID }),
              let settings = higherSettings(profileIndex: index) else { return nil }
        return .init(attemptID: attemptID, appliedRevision: appliedRevision,
                     baseline: applied, settings: settings, healthSequence: health.sequence,
                     healthySince: recoveryStart, healthyThrough: health.end,
                     validUntil: min(health.end + 2, receiver.observedAt + 2))
    }

    /// Register only from actual current readiness. Advisory reads remain available
    /// while owned work runs; another registration cannot replace that work.
    public mutating func beginCandidateMeasurement(at now: Double) throws -> CandidateMeasurementAttempt {
        guard ownedMeasurement == nil, transferredMeasurement == nil else { throw ValidationError.measurementInProgress }
        guard let readiness = candidateMeasurementReadiness(at: now) else { throw ValidationError.staleMeasurement }
        try recordTime(now)
        let attempt = CandidateMeasurementAttempt(controllerID: controllerID, readiness: readiness, registeredAt: now)
        ownedMeasurement = .init(attempt: attempt)
        failureEpisodeActive = false
        return attempt
    }

    private func currentMeasurement(_ attempt: CandidateMeasurementAttempt) throws -> OwnedMeasurement {
        guard attempt.controllerID == controllerID, let owned = ownedMeasurement, owned.attempt == attempt,
              attempt.readiness.attemptID == attemptID, attempt.readiness.appliedRevision == appliedRevision,
              attempt.readiness.baseline == applied else { throw ValidationError.staleMeasurement }
        return owned
    }

    /// Session calls this only after its exact native work has retired and joined.
    /// Cancellation of the same owner is an unsuccessful measurement, not a reset
    /// or an encoder application. Other owned downward work remains available.
    public mutating func settleCandidateMeasurementFailure(_ attempt: CandidateMeasurementAttempt, at now: Double) throws {
        let owned = try currentMeasurement(attempt)
        guard now.isFinite, (0...1e12).contains(now) else { throw ValidationError.invalidTime }
        try recordTime(now)
        ownedMeasurement = nil
        countFailureEpisodeOnce()
        latestStrongHealth = nil; recoveryStart = nil
        healthyNotBefore = max(healthyNotBefore, now)
        if let recommendation = owned.recommendation, pending == recommendation { pending = nil }
    }

    /// Record the exact guarded rejection after its native call has proved no
    /// effect. Measurement cleanup remains outstanding: retain its transfer and
    /// failure episode until joined settlement, but stop treating the write as
    /// an uncertain in-flight effect when fresh telemetry arrives.
    public mutating func noteCandidateApplicationRejection(_ admitted: Application,
        for attempt: CandidateMeasurementAttempt) throws {
        guard attempt.controllerID == controllerID, var transferred = transferredMeasurement,
              transferred.attempt == attempt, transferred.application == admitted,
              !transferred.rejectionRecorded, attempt.readiness.attemptID == attemptID,
              attempt.readiness.appliedRevision == appliedRevision,
              attempt.readiness.baseline == applied else { throw ValidationError.staleMeasurement }
        transferred.rejectionRecorded = true
        transferredMeasurement = transferred
        if application == admitted { application = nil }
        if pending == admitted.recommendation { pending = nil }
    }

    /// Session calls this only after a guarded rejection with no earlier native
    /// effect in this application, and after joining its exact native cleanup.
    /// A retained transfer remains settleable when telemetry revoked its active
    /// application. Uncertain or partially applied changes use the existing
    /// failure acknowledgment/shutdown contract instead.
    public mutating func settleCandidateApplicationRejection(_ admitted: Application,
        for attempt: CandidateMeasurementAttempt, at now: Double) throws {
        guard attempt.controllerID == controllerID,
              let transferred = transferredMeasurement,
              transferred.attempt == attempt, transferred.application == admitted,
              attempt.readiness.attemptID == attemptID,
              attempt.readiness.appliedRevision == appliedRevision,
              attempt.readiness.baseline == applied else { throw ValidationError.staleMeasurement }
        guard now.isFinite, (0...1e12).contains(now) else { throw ValidationError.invalidTime }
        try recordTime(now)
        transferredMeasurement = nil
        countFailureEpisodeOnce()
        latestStrongHealth = nil; recoveryStart = nil
        healthyNotBefore = max(healthyNotBefore, now)
        if application == admitted { application = nil }
        if pending == admitted.recommendation { pending = nil }
    }

    /// Non-counting retirement is permitted only after an actual applied revision
    /// change. It removes the exact measurement or transferred-application
    /// bookkeeping without touching the new scope.
    public mutating func retireObsoleteCandidateMeasurement(_ attempt: CandidateMeasurementAttempt) throws {
        guard attempt.controllerID == controllerID,
              ownedMeasurement?.attempt == attempt || transferredMeasurement?.attempt == attempt,
              attempt.readiness.appliedRevision != appliedRevision else { throw ValidationError.staleMeasurement }
        if ownedMeasurement?.attempt == attempt { ownedMeasurement = nil }
        if transferredMeasurement?.attempt == attempt { transferredMeasurement = nil }
    }

    /// Bind one candidate to this issued measurement. Foreign, obsolete and
    /// repeated calls are rejected before the policy clock or health can change.
    public mutating func evaluateCandidate(_ admission: CandidateAdmission, for attempt: CandidateMeasurementAttempt,
                                          at now: Double) throws -> Decision {
        var owned = try currentMeasurement(attempt)
        guard !owned.admissionConsumed else { throw ValidationError.staleMeasurement }
        guard admission.attemptID == attemptID,
              admission.appliedRevision == attempt.readiness.appliedRevision,
              admission.baseline == attempt.readiness.baseline,
              admission.settings == attempt.readiness.settings,
              admission.measuredStart >= attempt.registeredAt else { throw ValidationError.staleMeasurement }
        guard admission.id != lastCandidateID else { throw ValidationError.outOfOrder }
        if let priorEnd = candidateMeasurementEnd {
            guard admission.measuredEnd > priorEnd, admission.measuredStart >= priorEnd else { throw ValidationError.outOfOrder }
        }
        // Owned malformed evidence is transactional: even an otherwise finite
        // future clock cannot expire independent downward work on rejection.
        var evaluated = self
        let decision = try evaluated.evaluateCandidate(admission, at: now, invalidateOnError: false)
        owned.admissionConsumed = true
        owned.recommendation = decision.recommendation
        evaluated.ownedMeasurement = owned
        self = evaluated
        return decision
    }

    /// Transfer the exact bound advice to an encoder application. Native ownership
    /// remains the Session's responsibility; no caller assertion proves a join.
    public mutating func beginApplication(_ recommendation: Recommendation, for attempt: CandidateMeasurementAttempt,
                                         at now: Double) throws -> Application {
        let owned = try currentMeasurement(attempt)
        guard owned.admissionConsumed, owned.recommendation == recommendation, pending == recommendation,
              application == nil else { throw ValidationError.staleMeasurement }
        guard now.isFinite, (0...1e12).contains(now) else { throw ValidationError.invalidTime }
        let admitted = try beginApplication(recommendation, at: now, preserveFailureEpisode: true)
        transferredMeasurement = .init(attempt: attempt, application: admitted)
        ownedMeasurement = nil
        return admitted
    }

    /// Consume independently qualified candidate evidence without re-consuming a
    /// health sequence or crediting its duration. A candidate is one-shot even
    /// when health, padding, or recovery duration cannot authorize a trial.
    public mutating func evaluateCandidate(_ admission: CandidateAdmission, at now: Double) throws -> Decision {
        guard ownedMeasurement == nil, transferredMeasurement == nil else { throw ValidationError.measurementInProgress }
        return try evaluateCandidate(admission, at: now, invalidateOnError: true)
    }
    private mutating func evaluateCandidate(_ admission: CandidateAdmission, at now: Double,
                                           invalidateOnError: Bool) throws -> Decision {
        do {
            guard now.isFinite, (0...1e12).contains(now) else { throw ValidationError.invalidTime }
            try recordTime(now)
            guard recoveryStrategy == .measuredCandidateTrials, behavior == .progressive else {
                throw ValidationError.invalidRecoveryStrategy
            }
            guard admission.attemptID == attemptID else { throw ValidationError.wrongAttempt }
            guard admission.appliedRevision == appliedRevision else { throw ValidationError.wrongAppliedRevision }
            let index = profiles.firstIndex { $0.id == applied.profileID }!
            guard admission.baseline == applied, admission.settings == higherSettings(profileIndex: index) else {
                throw ValidationError.invalidSettings
            }
            guard [admission.measuredStart, admission.measuredEnd, admission.evaluatedAt, admission.validUntil]
                .allSatisfy({ $0.isFinite && (0...1e12).contains($0) }),
                  admission.measuredStart >= appliedAt,
                  admission.measuredEnd > admission.measuredStart,
                  admission.measuredEnd - admission.measuredStart <= Self.maximumCandidateMeasurementDuration,
                  admission.measuredEnd <= admission.evaluatedAt, admission.evaluatedAt <= now,
                  admission.validUntil > admission.evaluatedAt,
                  admission.validUntil <= min(admission.measuredEnd + 2, admission.evaluatedAt + 1.5),
                  admission.candidateTransportBitsPerSecond.isFinite, admission.candidateTransportBitsPerSecond > 0,
                  admission.deliveredPaddingBitsPerSecond.isFinite, admission.deliveredPaddingBitsPerSecond >= 0
            else { throw ValidationError.invalidWindow }
            guard now - admission.measuredEnd <= 2, now <= admission.validUntil else {
                throw ValidationError.staleWindow
            }
            guard admission.id != lastCandidateID else { throw ValidationError.outOfOrder }
            if let priorEnd = candidateMeasurementEnd {
                guard admission.measuredEnd > priorEnd, admission.measuredStart >= priorEnd else {
                    throw ValidationError.outOfOrder
                }
            }
        } catch { if invalidateOnError { invalidateTelemetry() }; throw error }
        candidateMeasurementEnd = admission.measuredEnd
        lastCandidateID = admission.id
        // Preserve owned native work until its own deadline. Candidates cannot
        // renew it, displace downward advice, or change active probation.
        guard application == nil, trial == nil, !minimumResetRequired else {
            return .init(state: trial == nil ? .unknown : .probing, reasons: [], recommendation: nil)
        }
        if pending?.candidateID != nil { pending = nil }
        guard let health = latestStrongHealth, let receiver = health.receiver,
              now - health.end <= 2, now - receiver.observedAt <= 2,
              health.end > admission.measuredStart, health.start < admission.measuredEnd,
              let recoveryStart, health.end - recoveryStart >= requiredHealthyDuration,
              now >= trialCooldownUntil else {
            return .init(state: .unknown, reasons: [], recommendation: nil)
        }
        guard admission.deliveredPaddingBitsPerSecond >= admission.candidateTransportBitsPerSecond * 1.25 else {
            return .init(state: .healthy, reasons: [.capacityHeadroom], recommendation: nil)
        }
        pending = .init(kind: .trial, attemptID: attemptID, windowSequence: health.sequence,
                        appliedRevision: appliedRevision,
                        validUntil: min(admission.validUntil, health.end + 2, receiver.observedAt + 2),
                        settings: admission.settings, candidateID: admission.id)
        return .init(state: .healthy, reasons: [.trialRecommended], recommendation: pending)
    }

    public mutating func evaluateDecoderStall(_ signal: DecoderStall, at now: Double) throws -> Decision {
        do {
            try recordTime(now)
            guard behavior == .progressive else { throw ValidationError.invalidWindow }
            guard signal.attemptID == attemptID else { throw ValidationError.wrongAttempt }
            guard signal.appliedRevision == appliedRevision else { throw ValidationError.wrongAppliedRevision }
            guard signal.sequence > 0, lastSequence.map({ signal.sequence > $0 }) ?? true
            else { throw ValidationError.outOfOrder }
            guard signal.observedAtLowerBound.isFinite, (0...1e12).contains(signal.observedAtLowerBound),
                  signal.observedAtLowerBound <= now,
                  signal.observedAtLowerBound >= appliedAt + ProgressiveStreamingPolicy.minimumDecoderStallDuration
            else { throw ValidationError.invalidWindow }
            guard now - signal.observedAtLowerBound <= ProgressiveStreamingPolicy.maximumDecoderStallSampleAge
            else { throw ValidationError.staleWindow }
        } catch { invalidateTelemetry(); throw error }
        lastSequence = signal.sequence
        healthyNotBefore = now
        // This is a negative progress observation, not a source frame window.
        // Preserve lastEnd and never add healthy coverage from an arrival count.
        latchMinimumReset(forceApplication: upwardApplicationInFlight)
        if minimumResetRequired {
            pending = .init(kind: .reset, attemptID: attemptID, windowSequence: signal.sequence,
                appliedRevision: appliedRevision,
                validUntil: signal.observedAtLowerBound + ProgressiveStreamingPolicy.maximumDecoderStallSampleAge,
                settings: minimumSettings)
        }
        return .init(state: .stalled,
            reasons: minimumResetRequired ? [.stalled] : [.stalled, .minimumProfileInsufficient],
            recommendation: pending)
    }

    /// Failure-only admission from completed deadline classifications. It shares
    /// global decision ordering while preserving regular-window recovery coverage.
    public mutating func evaluateDeliveryFailure(_ signal: DeliveryFailure, at now: Double) throws -> Decision {
        let duration = signal.end - signal.start
        do {
            guard now.isFinite, (0...1e12).contains(now) else { throw ValidationError.invalidTime }
            try recordTime(now)
            guard behavior == .progressive else { throw ValidationError.invalidWindow }
            guard signal.attemptID == attemptID else { throw ValidationError.wrongAttempt }
            guard signal.appliedRevision == appliedRevision else { throw ValidationError.wrongAppliedRevision }
            guard signal.sequence > 0, lastSequence.map({ signal.sequence > $0 }) ?? true
            else { throw ValidationError.outOfOrder }
            guard [signal.start, signal.end, signal.observedAtLowerBound].allSatisfy({ $0.isFinite && (0...1e12).contains($0) }),
                  signal.start >= appliedAt, duration == 1 || duration == 2,
                  signal.end <= signal.observedAtLowerBound, signal.observedAtLowerBound <= now
            else { throw ValidationError.invalidWindow }
            guard now - signal.end <= 2,
                  now - signal.observedAtLowerBound <= ProgressiveStreamingPolicy.maximumDecoderStallSampleAge
            else { throw ValidationError.staleWindow }
            guard (1...240).contains(signal.expectedFrames),
                  [signal.onTimeFrames, signal.lateFrames, signal.missingFrames].allSatisfy({ (0...240).contains($0) }),
                  signal.onTimeFrames + signal.lateFrames + signal.missingFrames == signal.expectedFrames
            else { throw ValidationError.invalidWindow }
            if let previous = deliveryFailureEnds[Int(duration)], previous.revision == appliedRevision,
               signal.start < previous.end { throw ValidationError.outOfOrder }
            let triggered = duration == 1
                ? Double(signal.onTimeFrames) < ProgressiveStreamingPolicy.freshFrameFloor
                : Double(signal.lateFrames + signal.missingFrames) / Double(signal.expectedFrames) > ProgressiveStreamingPolicy.maximumLossFraction
            guard triggered else { throw ValidationError.invalidWindow }
        } catch { invalidateTelemetry(); throw error }
        deliveryFailureEnds[Int(duration)] = (appliedRevision, signal.end)
        lastSequence = signal.sequence
        healthyNotBefore = now
        latchMinimumReset(forceApplication: upwardApplicationInFlight)
        if minimumResetRequired {
            pending = .init(kind: .reset, attemptID: attemptID, windowSequence: signal.sequence,
                appliedRevision: appliedRevision,
                validUntil: min(signal.end + 2, signal.observedAtLowerBound + ProgressiveStreamingPolicy.maximumDecoderStallSampleAge),
                settings: minimumSettings)
        }
        var reasons: [Reason] = [duration == 1 ? .freshFrameFloor : .sourceLoss]
        if signal.onTimeFrames == 0 { reasons.append(.stalled) }
        if applied == minimumSettings { reasons.append(.minimumProfileInsufficient) }
        return .init(state: signal.onTimeFrames == 0 ? .stalled : .degraded, reasons: reasons, recommendation: pending)
    }

    /// Short local observations can only decrease or roll back. They must not
    /// carry delivery/capacity claims or contribute to qualified recovery.
    public mutating func evaluateLocalPressure(_ window: Window, at now: Double) throws -> Decision {
        try evaluate(window, at: now, localPressure: true)
    }

    /// Windows must be complete, nonoverlapping, 1–5.25 seconds long and received
    /// within 2 seconds of their end. Consecutive windows share exact boundaries.
    /// Invalid input clears recovery and pending recommendations; callers must
    /// treat rejected telemetry as unknown rather than retaining a healthy claim.
    public mutating func evaluate(_ window: Window, at now: Double) throws -> Decision {
        try evaluate(window, at: now, localPressure: false)
    }
    private mutating func evaluate(_ window: Window, at now: Double, localPressure: Bool) throws -> Decision {
        latestStrongHealth = nil
        do {
            try recordTime(now)
            if localPressure {
                guard window.capturedFreshFrames == nil, window.encodedFreshFrames == nil,
                      window.receiver == nil, window.sourceLoss == nil, window.usableVideoCapacity == nil,
                      window.connectivity == .unknown, window.workerPressure == .unknown,
                      window.thermalPressure == .elevated || window.transportPressure == .elevated
                        || (window.meanQueueOccupancy.map { $0 >= 0.75 } ?? false)
                else { throw ValidationError.invalidWindow }
            }
            try validate(window, at: now, minimumDuration: localPressure ? 0.25 : 1)
        }
        catch { invalidateTelemetry(); throw error }
        var reasons: [Reason] = []
        if let lastEnd, window.start != lastEnd {
            recoveryStart = nil
            reasons.append(.telemetryGap)
        }
        lastNow = now; lastEnd = window.end; lastSequence = window.sequence
        // A superseded upward native write may have changed hardware even though
        // no acknowledgment arrived. Restore minimum before accumulating health.
        if behavior == .progressive && upwardApplicationInFlight { latchMinimumReset(forceApplication: true) }
        // Every new window supersedes earlier advice, even if it cannot establish health.
        pending = nil; application = nil
        if window.connectivity == .disconnected && trial == nil && !minimumResetRequired {
            recoveryStart = nil
            return .init(state: .disconnected, reasons: reasons + [.disconnected], recommendation: nil)
        }
        var unknown = false, otherUnknown = false
        func missing(_ reason: Reason) {
            unknown = true
            if reason != .missingCapacity { otherUnknown = true }
            reasons.append(reason)
        }
        if window.connectivity == .unknown { missing(.unknownConnectivity) }
        if window.capturedFreshFrames == nil { missing(.missingCapture) }
        if window.encodedFreshFrames == nil { missing(.missingEncoded) }
        var received: Int?
        if let receiver = window.receiver {
            if receiver.observedAt < window.end || now - receiver.observedAt > 2 { missing(.staleReceiver) }
            else { received = receiver.freshFrames }
        } else { missing(.missingReceiver) }
        if window.sourceLoss == nil { missing(.missingSourceLoss) }
        if window.meanQueueOccupancy == nil { missing(.missingQueue) }
        if window.usableVideoCapacity == nil { missing(.missingCapacity) }
        if window.thermalPressure == .unknown || window.workerPressure == .unknown { missing(.unknownPressure) }
        if (recoveryStrategy != .capacityQualified || behavior == .progressive) && window.transportPressure == .unknown {
            missing(.unknownTransportPressure)
        }
        let duration = window.end - window.start
        let observedFPS = [window.capturedFreshFrames, window.encodedFreshFrames, received].compactMap { $0 }.map { Double($0) / duration }
        let stalled = observedFPS.contains(0)
        var unhealthy = false
        func decrease(_ reason: Reason) { unhealthy = true; reasons.append(reason) }
        if observedFPS.contains(where: { $0 < ProgressiveStreamingPolicy.freshFrameFloor }) { decrease(.freshFrameFloor) }
        if let loss = window.sourceLoss {
            let eligible = behavior == .legacy || duration >= ProgressiveStreamingPolicy.minimumLossWindowDuration
            let limit = behavior == .progressive ? ProgressiveStreamingPolicy.maximumLossFraction : 0.01
            if eligible && Double(loss.lostFrames) / Double(loss.expectedFrames) > limit { decrease(.sourceLoss) }
        }
        if let queue = window.meanQueueOccupancy, queue >= 0.75 { decrease(.queuePressure) }
        if let capacity = window.usableVideoCapacity, capacity < Double(applied.videoBitrate) * 1.25 { decrease(.capacityHeadroom) }
        if window.thermalPressure == .elevated { decrease(.thermalPressure) }
        if window.workerPressure == .elevated { decrease(.workerPressure) }
        if window.transportPressure == .elevated { decrease(.transportPressure) }
        if stalled { reasons.append(.stalled) }
        let profileIndex = profiles.firstIndex { $0.id == applied.profileID }!
        let healthyLoss = window.sourceLoss.map {
            Double($0.lostFrames) / Double($0.expectedFrames) <= ProgressiveStreamingPolicy.maximumHealthyLossFraction
        } ?? false
        let strongObservations = window.start >= healthyNotBefore && !otherUnknown && window.connectivity == .connected && !unhealthy && healthyLoss
            && observedFPS.allSatisfy { $0 >= ProgressiveStreamingPolicy.healthyFrameRate }
            && (window.meanQueueOccupancy.map { $0 < 0.5 } ?? false)
        if behavior == .progressive && (reasons.contains(.freshFrameFloor) || reasons.contains(.sourceLoss)) {
            latchMinimumReset()
        }
        if minimumResetRequired {
            pending = recommendation(minimumSettings, for: window, kind: .reset)
            recoveryStart = nil
            return .init(state: window.connectivity == .disconnected ? .disconnected
                : stalled ? .stalled : unknown ? .unknown : .degraded,
                reasons: reasons, recommendation: pending)
        }
        if var active = trial {
            if now >= active.deadline {
                active.rollbackRequired = true
                reasons.append(.trialTimedOut)
            }
            if active.healthyStart == nil, window.start > appliedAt + Self.maximumWindowDuration {
                active.rollbackRequired = true
                if !reasons.contains(.telemetryGap) { reasons.append(.telemetryGap) }
            }
            if let end = active.healthyEnd, window.start != end { active.rollbackRequired = true }
            if !strongObservations { active.rollbackRequired = true }
            if active.rollbackRequired {
                trial = active
                recoveryStart = nil
                if behavior == .progressive {
                    latchMinimumReset()
                    pending = recommendation(minimumSettings, for: window, kind: .reset)
                } else { pending = recommendation(active.baseline, for: window, kind: .rollback) }
                let state: State = window.connectivity == .disconnected ? .disconnected
                    : stalled ? .stalled : unknown ? .unknown : .degraded
                if window.connectivity == .disconnected { reasons.append(.disconnected) }
                return .init(state: state, reasons: reasons + [.trialRollback], recommendation: pending)
            }
            active.healthyStart = active.healthyStart ?? window.start
            active.healthyEnd = window.end
            if window.end - active.healthyStart! >= Self.minimumTrialCoverage {
                trial = nil; recoveryStart = nil
                if behavior == .progressive { consecutiveFailures = 0; failureEpisodeActive = false }
                return .init(state: unknown ? .unknown : .healthy,
                             reasons: reasons + [.trialConfirmed], recommendation: nil)
            }
            trial = active
            return .init(state: .probing, reasons: reasons, recommendation: nil)
        }
        if unhealthy {
            recoveryStart = nil
            let reduced = lowerSettings(profileIndex: profileIndex, capacity: window.usableVideoCapacity)
            if let reduced { pending = recommendation(reduced, for: window) }
            else { reasons.append(.minimumProfileInsufficient) }
            let state: State = stalled ? .stalled : unknown ? .unknown : reduced == nil ? .insufficient : .degraded
            return .init(state: state, reasons: reasons, recommendation: pending)
        }
        if recoveryStrategy == .measuredCandidateTrials {
            if strongObservations {
                if recoveryStart == nil { recoveryStart = window.start }
                latestStrongHealth = window
            } else { recoveryStart = nil }
            return .init(state: otherUnknown ? .unknown : .healthy, reasons: reasons, recommendation: nil)
        }
        if recoveryStrategy != .capacityQualified {
            // Integer division rounds the <=10% step down. Bound the addition
            // before doing it, including on arm64_32. No minimum +1 may exceed10%.
            let profile = profiles[profileIndex]
            let step = min(applied.videoBitrate / 10, profile.maximumBitrate - applied.videoBitrate)
            var candidate: Settings? = step > 0
                ? .init(profileID: applied.profileID, videoBitrate: applied.videoBitrate + step) : nil
            if recoveryStrategy == .receiverValidatedProfileTrials,
               applied.videoBitrate == profile.maximumBitrate {
                candidate = higherSettings(profileIndex: profileIndex)
            }
            let fitsKnownCapacity = candidate.map { settings in
                window.usableVideoCapacity.map { $0 >= Double(settings.videoBitrate) * 1.25 } ?? true
            } ?? false
            if strongObservations && fitsKnownCapacity {
                if recoveryStart == nil { recoveryStart = window.start }
                if window.end - recoveryStart! >= requiredHealthyDuration, now >= trialCooldownUntil, let candidate {
                    pending = recommendation(candidate, for: window, kind: .trial)
                    reasons.append(.trialRecommended)
                }
            } else { recoveryStart = nil }
            return .init(state: unknown ? .unknown : .healthy, reasons: reasons, recommendation: pending)
        }
        guard !unknown else {
            recoveryStart = nil
            return .init(state: .unknown, reasons: reasons, recommendation: nil)
        }
        // Recovery is stronger than the 24 fps floor: target cadence within 1%,
        // low queue occupancy, and headroom for the PROPOSED rate in every window.
        let higher = higherSettings(profileIndex: profileIndex)
        let qualified = strongObservations
            && higher.map { window.usableVideoCapacity! >= Double($0.videoBitrate) * 1.25 } == true
        if qualified {
            if recoveryStart == nil { recoveryStart = window.start }
            if window.end - recoveryStart! >= requiredHealthyDuration, let higher {
                pending = recommendation(higher, for: window, kind: behavior == .progressive ? .trial : .increase)
                reasons.append(.recoveryQualified)
            }
        } else { recoveryStart = nil }
        return .init(state: .healthy, reasons: reasons, recommendation: pending)
    }

    /// Admit exactly the pending advice before its original freshness deadline.
    /// An in-flight authorization cannot be renewed by admitting the same advice.
    public mutating func beginApplication(_ recommendation: Recommendation, at now: Double) throws -> Application {
        if (ownedMeasurement != nil || transferredMeasurement != nil) && Self.isUpward(recommendation) {
            throw ValidationError.measurementInProgress
        }
        return try beginApplication(recommendation, at: now, preserveFailureEpisode: false)
    }
    private mutating func beginApplication(_ recommendation: Recommendation, at now: Double,
                                          preserveFailureEpisode: Bool) throws -> Application {
        try recordTime(now)
        guard application == nil, pending == recommendation,
              recommendation.attemptID == attemptID, recommendation.appliedRevision == appliedRevision,
              now <= recommendation.validUntil else { throw ValidationError.staleRecommendation }
        let deadline = now + Self.maximumApplicationDuration
        guard deadline.isFinite, deadline > now else { throw ValidationError.invalidTime }
        let admitted = Application(id: UUID(), recommendation: recommendation, admittedAt: now, completionDeadline: deadline)
        application = admitted
        latestStrongHealth = nil
        if behavior == .progressive && Self.isUpward(recommendation) && !preserveFailureEpisode {
            failureEpisodeActive = false
        }
        return admitted
    }

    /// Complete only the issued authorization. Revocation, completion or failure
    /// makes it unusable; new telemetry and explicit invalidation revoke it too.
    public mutating func acknowledge(_ admitted: Application, applied actual: Settings?, at now: Double) throws {
        if ownedMeasurement != nil && Self.isUpward(admitted.recommendation) { throw ValidationError.measurementInProgress }
        if let transferred = transferredMeasurement, Self.isUpward(admitted.recommendation) {
            guard transferred.application == admitted, application == admitted,
                  transferred.attempt.readiness.appliedRevision == appliedRevision,
                  transferred.attempt.readiness.baseline == applied else { throw ValidationError.staleMeasurement }
        }
        guard application == admitted else {
            try recordTime(now)
            throw ValidationError.staleRecommendation
        }
        defer { application = nil; pending = nil; recoveryStart = nil }
        try acknowledge(admitted.recommendation, applied: actual, at: now, before: admitted.completionDeadline)
        if actual != nil, transferredMeasurement?.application == admitted { transferredMeasurement = nil }
    }

    /// Acknowledge only the latest recommendation. Pass nil for a failed change.
    /// Report actual supported settings, including platform clamping; recommendations
    /// never become truth merely because they were emitted. Successful application
    /// increments the revision, and subsequent windows must start after this time.
    public mutating func acknowledge(_ recommendation: Recommendation, applied actual: Settings?, at now: Double) throws {
        if (ownedMeasurement != nil || transferredMeasurement != nil) && Self.isUpward(recommendation) {
            throw ValidationError.measurementInProgress
        }
        if application != nil {
            try recordTime(now)
            throw ValidationError.staleRecommendation
        }
        try acknowledge(recommendation, applied: actual, at: now, before: recommendation.validUntil)
    }
    private mutating func acknowledge(_ recommendation: Recommendation, applied actual: Settings?, at now: Double, before deadline: Double) throws {
        latestStrongHealth = nil
        let owned = pending == recommendation && recommendation.attemptID == attemptID
            && recommendation.appliedRevision == appliedRevision
        let upward = recommendation.kind == .trial || recommendation.kind == .increase
        // The compatibility acknowledgment API admits/completes in one call.
        // Each actual upward attempt starts a new failure episode, not each poll.
        if owned && upward && application == nil && behavior == .progressive { failureEpisodeActive = false }
        do {
            try finishAcknowledgment(recommendation, applied: actual, at: now, before: deadline)
        } catch {
            if owned && upward && behavior == .progressive { latchMinimumReset(forceApplication: true) }
            throw error
        }
        if owned && upward && actual == nil && behavior == .progressive { latchMinimumReset() }
    }
    private mutating func finishAcknowledgment(_ recommendation: Recommendation, applied actual: Settings?, at now: Double, before deadline: Double) throws {
        try recordTime(now)
        guard recommendation.attemptID == attemptID, recommendation.appliedRevision == appliedRevision,
              pending == recommendation else { throw ValidationError.staleRecommendation }
        guard now <= deadline else {
            recoveryStart = nil; pending = nil
            throw ValidationError.staleRecommendation
        }
        if let actual {
            guard Self.valid(actual, in: profiles), appliedRevision < UInt64.max else { throw ValidationError.invalidSettings }
            if recommendation.kind == .trial || recommendation.kind == .rollback || recommendation.kind == .reset {
                guard actual == recommendation.settings else {
                    recoveryStart = nil; pending = nil
                    throw ValidationError.invalidSettings
                }
            }
            if recommendation.kind == .trial {
                trial = .init(baseline: applied, deadline: now + Self.maximumTrialDuration)
                if behavior == .progressive && (transferredMeasurement == nil || application != transferredMeasurement?.application) {
                    failureEpisodeActive = false
                }
            } else if recommendation.kind == .rollback {
                trial = nil
                trialCooldownUntil = now + 60
            }
            if recommendation.kind == .reset { minimumResetRequired = false }
            applied = actual; appliedRevision += 1; appliedAt = now
        }
        lastNow = now; recoveryStart = nil; pending = nil
    }

    private static func isUpward(_ recommendation: Recommendation) -> Bool {
        recommendation.kind == .trial || recommendation.kind == .increase
    }
    private mutating func countFailureEpisodeOnce() {
        if !failureEpisodeActive {
            consecutiveFailures = min(consecutiveFailures + 1, ProgressiveStreamingPolicy.recoveryDurations.count)
            failureEpisodeActive = true
        }
    }
    private mutating func latchMinimumReset(forceApplication: Bool = false) {
        latestStrongHealth = nil
        countFailureEpisodeOnce()
        minimumResetRequired = minimumResetRequired || applied != minimumSettings || forceApplication
        trial = nil; pending = nil; application = nil; recoveryStart = nil
    }

    private static func valid(_ settings: Settings, in profiles: [Profile]) -> Bool {
        profiles.contains { $0.id == settings.profileID && ($0.minimumBitrate...$0.maximumBitrate).contains(settings.videoBitrate) }
    }
    /// Finite caller time advances even when the rest of an input is rejected.
    /// Invalid clock values cannot change the watermark.
    private mutating func recordTime(_ now: Double) throws {
        guard now.isFinite, now >= lastNow else { throw ValidationError.invalidTime }
        lastNow = now
    }
    private func validate(_ window: Window, at now: Double, minimumDuration: Double) throws {
        guard window.attemptID == attemptID else { throw ValidationError.wrongAttempt }
        guard window.appliedRevision == appliedRevision else { throw ValidationError.wrongAppliedRevision }
        guard window.start.isFinite, window.end.isFinite, window.start >= appliedAt,
              (minimumDuration...Self.maximumWindowDuration).contains(window.end - window.start), window.end <= now else { throw ValidationError.invalidWindow }
        guard now - window.end <= 2 else { throw ValidationError.staleWindow }
        if let lastEnd, window.start < lastEnd { throw ValidationError.outOfOrder }
        if let lastSequence, window.sequence <= lastSequence { throw ValidationError.outOfOrder }
        guard [window.capturedFreshFrames, window.encodedFreshFrames, window.receiver?.freshFrames].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw ValidationError.invalidWindow
        }
        if let receiver = window.receiver {
            guard receiver.observedAt.isFinite, receiver.observedAt >= 0, receiver.observedAt <= now else { throw ValidationError.invalidWindow }
        }
        if let loss = window.sourceLoss {
            guard loss.expectedFrames > 0, loss.lostFrames >= 0, loss.lostFrames <= loss.expectedFrames else { throw ValidationError.invalidWindow }
        }
        if let queue = window.meanQueueOccupancy {
            guard queue.isFinite, (0...1).contains(queue) else { throw ValidationError.invalidWindow }
        }
        if let capacity = window.usableVideoCapacity {
            guard capacity.isFinite, capacity >= 0 else { throw ValidationError.invalidWindow }
        }
    }
    /// Must be polled from the caller's bounded health loop even when receiver
    /// evidence is absent. Rollback intent survives failed/expired applications.
    public mutating func checkTrialDeadline(at now: Double) throws -> Recommendation? {
        do { try recordTime(now) }
        catch { invalidateTelemetry(); throw error }
        if behavior == .progressive {
            if let application {
                // Polling must join admitted native work, even after the advice
                // that authorized it expires. Never extend its original deadline.
                if now <= application.completionDeadline { return nil }
                if upwardApplicationInFlight { latchMinimumReset(forceApplication: true) }
                else { self.application = nil }
            }
            if let trial, trial.rollbackRequired || now >= trial.deadline { latchMinimumReset() }
            if minimumResetRequired {
                recoveryStart = nil
                if let pending, pending.kind == .reset, now <= pending.validUntil { return pending }
                let deadline = now + 2
                guard deadline.isFinite, deadline > now else { throw ValidationError.invalidTime }
                pending = .init(kind: .reset, attemptID: attemptID, windowSequence: lastSequence ?? 0,
                                appliedRevision: appliedRevision, validUntil: deadline, settings: minimumSettings)
                return pending
            }
            return nil
        }
        guard var active = trial else { return nil }
        if now >= active.deadline { active.rollbackRequired = true }
        trial = active
        guard active.rollbackRequired else { return nil }
        recoveryStart = nil
        if let pending, pending.kind == .rollback, now <= pending.validUntil { return pending }
        application = nil
        pending = .init(kind: .rollback, attemptID: attemptID, windowSequence: lastSequence ?? 0,
                        appliedRevision: appliedRevision, validUntil: now + 2, settings: active.baseline)
        return pending
    }

    private func recommendation(_ settings: Settings, for window: Window,
                                kind: Recommendation.Kind = .decrease) -> Recommendation {
        .init(kind: kind, attemptID: attemptID, windowSequence: window.sequence, appliedRevision: appliedRevision,
              validUntil: window.end + 2, settings: settings)
    }
    private func lowerSettings(profileIndex: Int, capacity: Double?) -> Settings? {
        let profile = profiles[profileIndex]
        if applied.videoBitrate > profile.minimumBitrate {
            // Target a 20% reduction, clamped to the profile minimum below.
            // Capacity is already net of audio/transport costs.
            let rate = min(Double(applied.videoBitrate) * 0.8, capacity.map { $0 / 1.25 } ?? .greatestFiniteMagnitude)
            return .init(profileID: profile.id, videoBitrate: max(profile.minimumBitrate, Int(rate)))
        }
        guard profileIndex > 0 else { return nil }
        let lower = profiles[profileIndex - 1]
        let rate = min(Double(lower.maximumBitrate), Double(applied.videoBitrate) * 0.8,
                       capacity.map { $0 / 1.25 } ?? .greatestFiniteMagnitude)
        return .init(profileID: lower.id, videoBitrate: max(lower.minimumBitrate, Int(rate)))
    }
    private func higherSettings(profileIndex: Int) -> Settings? {
        let profile = profiles[profileIndex]
        if applied.videoBitrate < profile.maximumBitrate {
            if behavior == .progressive {
                let step = min(applied.videoBitrate / 10, profile.maximumBitrate - applied.videoBitrate)
                return step > 0 ? .init(profileID: profile.id, videoBitrate: applied.videoBitrate + step) : nil
            }
            return .init(profileID: profile.id, videoBitrate: Int(min(Double(profile.maximumBitrate), (Double(applied.videoBitrate) * 1.1).rounded(.up))))
        }
        guard profileIndex + 1 < profiles.count else { return nil }
        let higher = profiles[profileIndex + 1]
        return .init(profileID: higher.id, videoBitrate: higher.minimumBitrate)
    }
}

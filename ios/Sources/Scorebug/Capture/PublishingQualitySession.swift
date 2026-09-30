import Foundation
import CoreMedia
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming
#if DEBUG
import CryptoKit
#endif

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
        var measuredCost: Double? = nil
    }
    /// One scheduling hint, never admission evidence or a retained candidate.
    struct CandidateProbeDemand: Sendable {
        let baseline: QualityController.Settings
        let revision: UInt64
        let target: QualityController.Settings
        let measuredCost: Double
        func cost(for readiness: QualityController.CandidateMeasurementReadiness) -> Double? {
            baseline == readiness.baseline && revision == readiness.appliedRevision && target == readiness.settings ? measuredCost : nil
        }
    }
    private var candidateProbeDemand: CandidateProbeDemand?
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
    private let timingProfile: StreamingTimingProfile
    private let behavior: QualityController.Behavior
    private let strategy: QualityController.RecoveryStrategy
    private let uptime: @Sendable () -> Double
    private let sampleInstant: @Sendable () -> ContinuousClock.Instant
    private var policy: QualityController? {
        didSet {
            if let demand = candidateProbeDemand,
               policy?.applied != demand.baseline || policy?.appliedRevision != demand.revision { candidateProbeDemand = nil }
            #if DEBUG
            if let policy, oldValue?.candidateMeasurementDiagnostic != policy.candidateMeasurementDiagnostic {
                ownedMeasurement?.record("policyState", fields: ["policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(policy.candidateMeasurementDiagnostic)])
            }
            #endif
        }
    }
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
    private var ownedLaboratoryAttempts = 0
    private var ownedPublisher: NativeOwnedCandidatePublisher?
    private var ownedMeasurement: PublishingOwnedMeasurementLease?
    #if DEBUG
    /// At most one pending cause, one latched rollback cause, and one applied
    /// witness. None is policy authority. The applied witness changes only at ACK.
    private var transitionCause: (advice: QualityController.Recommendation, fields: [String: String])?
    private var invalidationCause: (revision: UInt64, fields: [String: String], auditFields: [String: String])?
    private var appliedTransition: String?
    private var appliedTransitionAudit: PublishingAppliedTransitionAudit?
    private let appliedTransitionExport: (@Sendable (Data) async -> Void)?

    private func recordDecision(_ decision: QualityController.Decision, input: String, at now: Double,
                                window: QualityController.Window? = nil,
                                transportLimits: PublishingQualityTelemetry.TransportLimits? = nil,
                                diagnostics: PublishingQualityTelemetry.Diagnostics? = nil,
                                processing: WorkerProcessingReport? = nil,
                                workerLimits: PublishingQualityTelemetry.WorkerLimits? = nil,
                                extra: [String: String] = [:]) {
        guard let advice = decision.recommendation else { return }
        if transitionCause?.advice == advice { return }
        // Core refreshes minimum-reset advice even on a later healthy window.
        // Keep the episode's origin only while that same revision still owns
        // the reset/rollback latch; the new recommendation identity is retained.
        if let prior = transitionCause, prior.advice.appliedRevision == advice.appliedRevision,
           prior.advice.kind == advice.kind, let state = policy?.currentDiagnostic,
           state.appliedRevision == advice.appliedRevision,
           (advice.kind == .reset && state.minimumResetRequired)
            || (advice.kind == .rollback && state.trial?.rollbackRequired == true) {
            transitionCause = (advice, prior.fields)
            return
        }
        var fields = ["input": input, "at": String(now), "causeSequence": String(advice.windowSequence),
            "reasons": decision.reasons.map { String(describing: $0) }.joined(separator: ",")]
        fields.merge(extra) { _, new in new }
        if decision.reasons.contains(.queuePressure) {
            fields["queueLimit"] = String(QualityController.queuePressureThreshold)
        }
        if decision.reasons.contains(.sourceLoss) {
            fields["lossLimit"] = String(behavior == .progressive
                ? ProgressiveStreamingPolicy.maximumLossFraction : QualityController.legacyMaximumLossFraction)
        }
        if decision.reasons.contains(.freshFrameFloor) {
            fields["freshFrameFloor"] = String(ProgressiveStreamingPolicy.freshFrameFloor)
        }
        if let window {
            fields["start"] = String(window.start); fields["end"] = String(window.end)
            fields["queue"] = window.meanQueueOccupancy.map { String($0) }
            fields["thermal"] = String(describing: window.thermalPressure)
            fields["transport"] = String(describing: window.transportPressure)
            fields["worker"] = String(describing: window.workerPressure)
            if window.workerPressure == .elevated, let processing, let limits = workerLimits {
                fields["workerOmitted"] = String(processing.interval.omittedBeforeEncoderFrames)
                fields["workerFilterMs"] = processing.interval.filterDuration.map { String($0.maximumMs) }
                fields["workerProcessingMs"] = processing.interval.processingDuration.map { String($0.maximumMs) }
                fields["maxFilterMs"] = String(limits.maximumFilterMs)
                fields["maxProcessingMs"] = String(limits.maximumProcessingMs)
            }
            fields["captured"] = window.capturedFreshFrames.map { String($0) }
            fields["encoded"] = window.encodedFreshFrames.map { String($0) }
            fields["received"] = window.receiver.map { String($0.freshFrames) }
            fields["expected"] = window.sourceLoss.map { String($0.expectedFrames) }
            fields["lost"] = window.sourceLoss.map { String($0.lostFrames) }
            fields["capacity"] = window.usableVideoCapacity.map { String($0) }
            // Preserve why an unknown reading caused a rollback: fair OS state,
            // stale sampling and missing interval coverage need different fixes.
            if let history = diagnostics?.thermal {
                fields["thermalFresh"] = String(history.freshSample(at: now) != nil)
                fields["thermalClosed"] = String(history.isClosed)
                fields["thermalQuarantined"] = String(history.isQuarantined)
                fields["thermalLastAt"] = history.samples.last.map { String($0.sampledAt) }
                fields["thermalLastState"] = history.samples.last.map { String(describing: $0.state) }
                if let sample = history.interval(from: window.start, to: window.end) {
                    fields["thermalState"] = String(describing: sample.enclosingMaximumState)
                    fields["thermalStart"] = String(sample.enclosingStart)
                    fields["thermalEnd"] = String(sample.enclosingEnd)
                }
            }
            if window.transportPressure == .elevated, let history = diagnostics?.transport, let limits = transportLimits,
               let interval = history.interval(from: window.start, to: window.end) {
                // Journal-only recent gauges distinguish sustained retention from an
                // isolated burst without expanding the UI diagnostic or policy input.
                let recent = history.samples.filter { $0.sampledAt <= interval.enclosingEnd }.suffix(12)
                let gauges: [[Double]] = recent.map {
                    [$0.sampledAt, Double($0.senderBufferMilliseconds), Double($0.senderBufferedBytes),
                     Double($0.sentBytes), Double($0.retransmittedBytes), $0.rttMilliseconds,
                     $0.senderMaximumBandwidthMbps ?? -1, $0.packetSendPeriodMicroseconds ?? -1]
                }
                fields["transportRecentSamples"] = (try? JSONSerialization.data(withJSONObject: gauges))
                    .flatMap { String(data: $0, encoding: .utf8) }
                fields["transportStart"] = String(interval.enclosingStart)
                fields["transportEnd"] = String(interval.enclosingEnd)
                fields["drops"] = String(interval.enclosingDroppedPackets)
                fields["bufferMs"] = String(interval.enclosingMaximumBufferMilliseconds)
                fields["rttMs"] = String(interval.enclosingMaximumRTTMilliseconds)
                fields["sentBytes"] = String(interval.enclosingSentBytes)
                fields["retransBytes"] = String(interval.enclosingRetransmittedBytes)
                // Preserve paired gauges from the same enclosing points the
                // classifier uses. Max RTT alone cannot identify a delay limit.
                if limits.policy != .legacyThreshold {
                    let points = history.samples.filter {
                        $0.sampledAt >= interval.enclosingStart && $0.sampledAt <= interval.enclosingEnd
                            && ($0.senderDeliveryDelayMilliseconds ?? 0) > 0
                    }
                    func rttLimit(_ point: PublishingTransportStatistics) -> Double {
                        min(limits.maximumRTTMs, Double(point.senderDeliveryDelayMilliseconds!) / 4)
                    }
                    if let point = points.max(by: { $0.rttMilliseconds / rttLimit($0) < $1.rttMilliseconds / rttLimit($1) }) {
                        fields["delayRTTMs"] = String(point.rttMilliseconds)
                        fields["delayRTTLimitMs"] = String(rttLimit(point))
                        fields["rttDelayMs"] = String(point.senderDeliveryDelayMilliseconds!)
                    }
                    if limits.policy == .recoveryBudget {
                        func bufferLimit(_ point: PublishingTransportStatistics) -> Double {
                            min(limits.maximumBufferMs, Double(point.senderDeliveryDelayMilliseconds!) / 2)
                        }
                        if let point = points.max(by: { Double($0.senderBufferMilliseconds) / bufferLimit($0) < Double($1.senderBufferMilliseconds) / bufferLimit($1) }) {
                            fields["delayBufferMs"] = String(point.senderBufferMilliseconds)
                            fields["delayBufferLimitMs"] = String(bufferLimit(point))
                            fields["bufferDelayMs"] = String(point.senderDeliveryDelayMilliseconds!)
                        }
                    }
                }
            }
        }
        if let limits = transportLimits {
            fields["transportPolicy"] = limits.policy.rawValue
            fields["maxBufferMs"] = String(limits.maximumBufferMs)
            fields["maxRTTMs"] = String(limits.maximumRTTMs)
            if limits.policy != .recoveryBudget { fields["maxRetransmitFraction"] = String(limits.maximumRetransmittedFraction) }
        }
        if (advice.kind == .reset || advice.kind == .rollback),
           let cause = invalidationCause, cause.revision == advice.appliedRevision { fields = cause.fields }
        transitionCause = (advice, fields)
    }
    #endif
    /// Preserve the exact first invalidation that latched this trial's rollback.
    /// The same policy invalidation executes in Release, with no retained witness.
    private func invalidateTelemetry(_ current: inout QualityController, input: String,
                                     error: Error? = nil, start: Double? = nil, end: Double? = nil) {
        #if DEBUG
        latchInvalidationCause(current, input: input, error: error, start: start, end: end)
        #endif
        current.invalidateTelemetry()
    }
    #if DEBUG
    private func latchInvalidationCause(_ current: QualityController, input: String, error: Error? = nil,
                                       start: Double? = nil, end: Double? = nil, auditFields: [String: String] = [:]) {
        // Core may already have invalidated its local copy before throwing.
        // The session still owns the pre-evaluation policy until its defer runs.
        let state = self.policy?.currentDiagnostic ?? current.currentDiagnostic
        if invalidationCause?.revision != current.appliedRevision,
           state.trial != nil || state.application?.recommendation.kind == .trial || state.application?.recommendation.kind == .increase,
           !state.minimumResetRequired, state.trial?.rollbackRequired != true {
            var fields = ["input": input, "at": String(lastNow), "reasons": "telemetryInvalidated"]
            fields["error"] = error.map { String(String(describing: $0).prefix(80)) }
            fields["start"] = start.map { String($0) }; fields["end"] = end.map { String($0) }
            invalidationCause = (current.appliedRevision, fields, auditFields)
        }
    }
    #endif
    #if DEBUG
    private var lastMeasurementDiagnostic: [String: String] = [:]
    private var candidateSourceDiagnostic: [String: String] = [:]
    private var cadenceRejectionTiming: String?
    #endif
    private var ownedPredecessor: PublishingBandwidthProbeRetirement?
    private var ownedSource: SourceScope?
    private var ownedDiagnostics: (@Sendable () -> PublishingQualityTelemetry.Diagnostics)?
    private var ownedAcknowledged: PublishingOwnedMeasurementLease?
    private var ownedTransferred: QualityController.Application?
    private var ownedRejected: QualityController.Application?
    private var ownedSettlement: Task<Void, Never>?
    private var ownedProbePolicy: PublishingBandwidthProbeSnapshot.Policy = .localZeroLoss

    func installOwnedMeasurementPublisher(_ publisher: NativeOwnedCandidatePublisher,
        policy: PublishingBandwidthProbeSnapshot.Policy = .localZeroLoss,
        diagnostics: (@Sendable () -> PublishingQualityTelemetry.Diagnostics)? = nil) throws {
        guard !closed, ownedPublisher == nil, ownedMeasurement == nil, publisher.probes != nil,
              publisher.scope.publishingAttemptID == attemptID else { throw Failure.staleAdvice }
        ownedPublisher = publisher; ownedProbePolicy = policy; ownedDiagnostics = diagnostics
    }
    @discardableResult func startOwnedMeasurement(diagnostics: PublishingQualityTelemetry.Diagnostics) async throws -> Bool {
        guard ownedMeasurement == nil, let publisher = ownedPublisher, let probes = publisher.probes,
              publisher.maximumAttempts.map({ ownedLaboratoryAttempts < $0 }) ?? true,
              let context = candidateMeasurementContext(diagnostics: diagnostics),
              context.scope == publisher.scope, var current = policy else { return false }
        // Unsupported measured demand must not terminate the live baseline.
        // Nominal unsupported-plan behavior remains unchanged.
        if context.measuredCost != nil, (try? publisher.stagePlanSelection.resolve(context)) == nil { return false }
        let token: QualityController.CandidateMeasurementAttempt
        do { token = try current.beginCandidateMeasurement(at: time()) }
        catch QualityController.ValidationError.staleMeasurement { return false }
        let lease = try PublishingOwnedMeasurementLease(token: token, context: context,
            publisher: publisher, probes: probes, predecessor: ownedPredecessor,
            diagnostic: current.candidateMeasurementDiagnostic,
            sourceCoverage: { [weak self] token in await self?.ownedCandidateSourceCoverage(for: token) })
        if publisher.maximumAttempts != nil { ownedLaboratoryAttempts += 1 }
        policy = current; ownedMeasurement = lease; ownedSource = candidateHealthSource
        await lease.start(policy: ownedProbePolicy) { [weak self] lease in await self?.ownedMeasurementFinished(lease) }
        return true
    }
    private func ownedCandidateSourceCoverage(for token: QualityController.CandidateMeasurementAttempt) -> PublishingOwnedMeasurementLease.SourceCoverage? {
        guard !closed, !busy, operations.isPublishing(), let lease = ownedMeasurement,
              lease.token == token, lease.isActive, candidateHealthSource == ownedSource,
              let policy, policy.appliedRevision == token.readiness.appliedRevision,
              policy.applied == token.readiness.baseline,
              let window = lastWindow, let receiver = window.receiver,
              window.sequence > token.readiness.healthSequence,
              window.end > token.readiness.healthyThrough,
              policy.candidateMeasurementDiagnostic.strongHealthSequence == window.sequence else { return nil }
        let now = uptime()
        guard now.isFinite, now >= window.end, now - window.end <= timingProfile.maximumCaptureWindowEvaluationAge,
              receiver.observedAt <= now, now - receiver.observedAt <= 2 else { return nil }
        return .init(sequence: window.sequence, start: window.start, end: window.end, observedAt: receiver.observedAt)
    }
    func joinOwnedMeasurement() async {
        await ownedMeasurement?.join()
        await ownedSettlement?.value
    }
    private func scheduleOwnedSettlement(_ lease: PublishingOwnedMeasurementLease) {
        ownedSettlement = Task { [weak self] in
            await lease.join()
            await self?.ownedMeasurementFinished(lease)
        }
    }
    func ownedCandidateSnapshot() async -> NativeCandidateSnapshot? {
        guard let ownedMeasurement else { return nil }
        return await ownedMeasurement.snapshot()
    }
    func ownedProbeObservation() async -> PublishingProbeObservation? {
        await ownedMeasurement?.probeObservation()
    }
    private func ownedMeasurementFinished(_ lease: PublishingOwnedMeasurementLease) async {
        let (joined, predecessor) = await lease.joinedRetirement()
        #if DEBUG
        let diagnostic = await lease.currentOutcomeDiagnostic()
        #endif
        guard joined, ownedMeasurement === lease, !closed,
              ownedTransferred == nil || (ownedRejected != nil && ownedTransferred == ownedRejected),
              var current = policy else { return }
        #if DEBUG
        let settlement = ownedAcknowledged === lease ? "acknowledged" : current.appliedRevision != lease.token.readiness.appliedRevision
            ? "obsolete" : ownedRejected != nil ? "applicationRejected" : "unapplied"
        #endif
        do {
            if ownedAcknowledged === lease {
                ownedAcknowledged = nil
                #if DEBUG
                lease.record("settledAcknowledged", fields: ["policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(current.candidateMeasurementDiagnostic)])
                #endif
            } else if current.appliedRevision != lease.token.readiness.appliedRevision {
                try current.retireObsoleteCandidateMeasurement(lease.token)
                #if DEBUG
                lease.record("retiredObsolete", fields: ["currentAppliedRevision": String(current.appliedRevision),
                    "policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(current.candidateMeasurementDiagnostic)])
                #endif
            } else if let rejected = ownedRejected {
                try current.settleCandidateApplicationRejection(rejected, for: lease.token, at: time())
                #if DEBUG
                lease.record("settledApplicationRejection", fields: ["applicationID": rejected.id.uuidString.lowercased(),
                    "policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(current.candidateMeasurementDiagnostic)])
                #endif
                candidateHealthSource = nil
            } else {
                try current.settleCandidateMeasurementFailure(lease.token, at: time())
                #if DEBUG
                lease.record("settledFailure", fields: ["policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(current.candidateMeasurementDiagnostic)])
                #endif
                candidateHealthSource = nil
            }
            policy = current; ownedPredecessor = predecessor
            #if DEBUG
            lastMeasurementDiagnostic = diagnostic.fields(settlement: settlement, at: ProcessInfo.processInfo.systemUptime)
            #endif
            ownedMeasurement = nil; ownedSource = nil; ownedTransferred = nil; ownedRejected = nil
        } catch { /* Retain an unsettled exact owner; it cannot authorize another allocation. */ }
    }
    private var pendingCandidate: PublishingCandidateAdmission?
    private nonisolated let candidateRecovery: PublishingCandidateRecoveryCoverage?
    private var recoveryDelivery: PublishingDeliveryObservation?
    private var candidateHealthSource: SourceScope? {
        didSet {
            if candidateHealthSource == nil { candidateRecovery?.invalidate(); recoveryDelivery = nil }
            #if DEBUG
            if candidateHealthSource == nil { acceptedSourceMapping = nil }
            #endif
            if ownedTransferred == nil, candidateHealthSource != ownedSource { ownedMeasurement?.revoke() }
        }
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
    #if DEBUG
    /// One atomic copy of the exact accepted input, never joined to a newer status.
    private struct AcceptedSourceMapping {
        let scope: SourceScope
        let sequence: Int64
        let windowEnd: Double
        let interval: PublishingSourceInterval
        let pipelineReadKey: String?
        let previousPTS: Int64
        let firstPTS: Int64
        let lastPTS: Int64
        let frames: Int
        init(source: WorkerSourceIntervalObservation, scope: SourceScope, windowEnd: Double) {
            self.scope = scope; sequence = source.sequence; self.windowEnd = windowEnd
            interval = source.interval; pipelineReadKey = source.publication.pipelineReadKey
            previousPTS = source.previousDecodedPTS; firstPTS = source.firstDecodedPTS
            lastPTS = source.lastDecodedPTS; frames = source.interval.decodedFrames
        }
    }
    private var acceptedSourceMapping: AcceptedSourceMapping?
    #endif
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
         usesGuardedMutations: Bool = false, timingProfile: StreamingTimingProfile = .strict1500,
         appliedTransitionExport: (@Sendable (Data) async -> Void)? = nil) throws {
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
            requiresSharedCandidateRecovery: requiresSharedCandidateRecovery, timingProfile: timingProfile, uptime: { ProcessInfo.processInfo.systemUptime },
            appliedTransitionExport: appliedTransitionExport)
    }
    init(operations: Operations, profiles: [QualityController.Profile], attemptID: UUID,
         initial: QualityController.Settings, strategy: QualityController.RecoveryStrategy = .receiverValidatedTrials,
         behavior: QualityController.Behavior = .legacy, requiresSharedCandidateRecovery: Bool = false,
         timingProfile: StreamingTimingProfile = .strict1500,
         uptime: @escaping @Sendable () -> Double,
         instant: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         appliedTransitionExport: (@Sendable (Data) async -> Void)? = nil) throws {
        let now = uptime()
        _ = try QualityController(profiles: profiles, attemptID: attemptID, applied: initial, at: now, recoveryStrategy: strategy, behavior: behavior, timingProfile: timingProfile)
        guard now <= 1e12 else { throw QualityController.ValidationError.invalidTime }
        self.operations = operations; self.profiles = profiles; self.attemptID = attemptID
        self.initial = initial; self.strategy = strategy; self.behavior = behavior; self.uptime = uptime; self.lastNow = now
        self.sampleInstant = instant; self.timingProfile = timingProfile
        self.candidateRecovery = requiresSharedCandidateRecovery ? PublishingCandidateRecoveryCoverage() : nil
        #if DEBUG
        self.appliedTransitionExport = appliedTransitionExport
        self.appliedTransitionAudit = appliedTransitionExport == nil ? nil : .init(attemptID: attemptID, timingProfile: timingProfile)
        #endif
    }
    var snapshot: Snapshot { .init(attemptID: attemptID, applied: policy?.applied, revision: policy?.appliedRevision,
        receipt: receipt, profileReceipt: profileReceipt, application: application, acknowledgedAt: acknowledgedAt,
        lastWindow: lastWindow, lastDecoderStall: lastDecoderStall, lastDeliveryFailure: lastDeliveryFailure,
        evaluatedAt: evaluatedAt, isClosed: closed, isBusy: busy) }

    #if DEBUG
    /// Current scalars only; reading this neither grants nor revokes authority.
    func currentDiagnostic() -> [String: String] {
        let now = uptime()
        let readiness = policy?.candidateMeasurementReadiness(at: now)
        let health = policy?.candidateMeasurementDiagnostic
        var result = ["sessionObservedAtUptimeSeconds": String(now), "sessionClosed": String(closed), "sessionBusy": String(busy),
            "measurementActive": String(ownedMeasurement?.isActive ?? false),
            "measurementPublisherPresent": String(ownedPublisher != nil),
            "candidateHealthSourcePresent": String(candidateHealthSource != nil),
            "policyReady": String(readiness != nil), "recoveryDeliveryPresent": String(recoveryDelivery != nil)]
        if let health {
            result["candidateConsecutiveFailures"] = String(health.consecutiveFailures)
            result["requiredHealthyDurationSeconds"] = String(health.requiredHealthyDuration)
            result["strongHealthDurationSeconds"] = health.strongHealthStart.flatMap { start in health.strongHealthEnd.map { String($0 - start) } }
            result["recoveryCoverageSeconds"] = health.recoveryStart.flatMap { start in health.strongHealthEnd.map { String($0 - start) } }
        }
        if let readiness {
            result["sharedRecoveryReady"] = String(candidateRecovery?.permits(healthySince: readiness.healthySince,
                healthyThrough: readiness.healthyThrough, healthSequence: readiness.healthSequence) ?? true)
        }
        result["cadenceRejectionTiming"] = cadenceRejectionTiming
        result["candidateProbeDemandBitsPerSecond"] = candidateProbeDemand.map { String($0.measuredCost) }
        result["appliedTransition"] = appliedTransition
        result.merge(lastMeasurementDiagnostic) { _, latest in latest }
        result.merge(candidateSourceDiagnostic) { _, latest in latest }
        result["lastAcceptedSourceAgeSeconds"] = lastWindow.map { String(now - $0.end) }
        result["lastRecoveryDeliveryWindowAgeSeconds"] = recoveryDelivery.map { String(now - $0.source.windowEnd) }
        if !closed, let policy {
            let current = policy.currentDiagnostic
            if let receipt, let acknowledgedAt, acknowledgedAt.isFinite,
               acknowledgedAt >= receipt.acceptedAt, acknowledgedAt <= now,
               receipt.configuration.bitRate == current.applied.videoBitrate {
                result["policyAttemptID"] = attemptID.uuidString.lowercased()
                result["policyAcknowledgedAtUptimeSeconds"] = String(acknowledgedAt)
            }
            result["policyAppliedProfile"] = current.applied.profileID
            result["policyAppliedBitrate"] = String(current.applied.videoBitrate)
            result["policyAppliedRevision"] = String(current.appliedRevision)
            result["policyRecommendationPending"] = String(current.pendingRecommendation != nil)
            result["policyPendingKind"] = current.pendingRecommendation.map { String(describing: $0.kind) }
            result["policyPendingProfile"] = current.pendingRecommendation?.settings.profileID
            result["policyPendingBitrate"] = current.pendingRecommendation.map { String($0.settings.videoBitrate) }
            result["policyApplicationPending"] = String(current.application != nil)
            result["policyApplicationKind"] = current.application.map { String(describing: $0.recommendation.kind) }
            result["policyApplicationProfile"] = current.application?.recommendation.settings.profileID
            result["policyApplicationBitrate"] = current.application.map { String($0.recommendation.settings.videoBitrate) }
            result["policyTrialActive"] = String(current.trial != nil)
            result["policyTrialHealthyCoverageSeconds"] = current.trial.map { String($0.healthyCoverage) }
            result["policyTrialRollbackRequired"] = current.trial.map { String($0.rollbackRequired) }
            result["policyMinimumResetRequired"] = String(current.minimumResetRequired)
            result["policyOwnerKey"] = currentPolicyOwnerKey(policy: policy, now: now)
            if result["policyOwnerKey"] != nil, let source = candidateHealthSource,
               let mapping = acceptedSourceMapping, mapping.scope == source, mapping.sequence == lastSource?.sequence,
               mapping.windowEnd == lastWindow?.end {
                var scope = currentSourceIdentity(source)
                var observation = NativeCandidateFixture.scope(source.observationScope)
                observation.removeValue(forKey: "appliedProfileRevision")
                scope["observationScope"] = observation
                if let data = try? JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys]) {
                    result["policySourceScopeKey"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                result["policySourceStartPTSSeconds"] = String(CMTimeGetSeconds(mapping.interval.sourceStartExclusive))
                result["policySourceEndPTSSeconds"] = String(CMTimeGetSeconds(mapping.interval.sourceEndInclusive))
                result["policyCaptureStartUptimeSeconds"] = String(mapping.interval.captureBoundaryStartTime)
                result["policyCaptureEndUptimeSeconds"] = String(mapping.interval.captureBoundaryEndTime)
                result["policyPipelineReadKey"] = mapping.pipelineReadKey
                result["policyDecodedPreviousPTS"] = String(mapping.previousPTS)
                result["policyDecodedFirstPTS"] = String(mapping.firstPTS)
                result["policyDecodedLastPTS"] = String(mapping.lastPTS)
                result["policyDecodedFrameCount"] = String(mapping.frames)
            }
            if candidateHealthSource != nil {
                result["policyAcceptedSourceSequence"] = lastSource.map { String($0.sequence) }
                result["policyAcceptedSourceWindowEnd"] = lastWindow.map { String($0.end) }
            }
        }
        return result
    }
    private func currentSourceIdentity(_ source: SourceScope) -> [String: Any] {
        var result: [String: Any] = ["observationScope": NativeCandidateFixture.scope(source.observationScope),
                "clock": ["sourceOrigin": NativeCandidateFixture.time(source.clock.sourceOrigin),
                    "publishingGeneration": String(source.clock.publishingGeneration)],
                "gameID": source.gameID, "generation": source.generation,
                "workerID": source.workerId, "epoch": source.epoch, "attempt": source.attempt,
                "publication": ["readerId": source.publication.readerId, "publisherId": source.publication.publisherId,
                    "publishingAttemptId": source.publication.publishingAttemptId,
                    "clock": ["convention": source.publication.clock.convention, "originPTS": source.publication.clock.originPTS]],
                "processingScope": source.processingScope as Any? ?? NSNull()]
        // Omission preserves the exact legacy digest input.
        if let key = source.publication.pipelineReadKey { result["pipelineReadKey"] = key }
        return result
    }
    /// Correlation only: no retained confirmation, authority, or source watermark
    /// participates in this identity. A new accepted window keeps the same key.
    private func currentPolicyOwnerKey(policy: QualityController, now: Double) -> String? {
        guard let source = candidateHealthSource, lastSource?.scope == source,
              let receipt, let acknowledgedAt, let window = lastWindow,
              policy.attemptID == attemptID, window.attemptID == attemptID,
              window.appliedRevision == policy.appliedRevision,
              receipt.configuration.bitRate == policy.applied.videoBitrate,
              acknowledgedAt.isFinite, acknowledgedAt >= receipt.acceptedAt, acknowledgedAt <= now,
              source.clock.publishingGeneration == receipt.publishingGeneration,
              source.observationScope.publishingAttemptID == attemptID,
              source.observationScope.matchID == source.gameID,
              source.observationScope.broadcastGeneration == source.generation,
              source.publication.publishingAttemptId == attemptID.uuidString.lowercased() else { return nil }
        var profile: Any = NSNull()
        if let value = profileReceipt {
            guard value.profile.rawValue == policy.applied.profileID,
                  value.publishingGeneration == receipt.publishingGeneration,
                  value.encoderSessionID == receipt.configuration.encoderSessionID else { return nil }
            profile = ["profile": value.profile.rawValue, "publishingGeneration": String(value.publishingGeneration),
                "previousEncoderSessionID": value.previousEncoderSessionID.uuidString,
                "encoderSessionID": value.encoderSessionID.uuidString,
                "lastOldSourcePTS": NativeCandidateFixture.time(value.lastOldSourcePTS),
                "firstNewSourcePTS": NativeCandidateFixture.time(value.firstNewSourcePTS),
                "width": value.width, "height": value.height,
                "rawVideoFramesDropped": String(value.rawVideoFramesDropped), "acknowledgedAt": value.acknowledgedAt] as [String: Any]
        }
        let fields: [String: Any] = ["attempt": attemptID.uuidString, "revision": String(policy.appliedRevision),
            "settings": ["profile": policy.applied.profileID, "bitrate": policy.applied.videoBitrate],
            "receipt": PublishingOwnedMeasurementAudit.receipt(receipt), "profileReceipt": profile,
            "source": currentSourceIdentity(source)]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    #endif

    /// Derive scheduling readiness from the current policy and acknowledged
    /// encoder, never from the immutable first-frame startup receipt. This query
    /// neither changes policy state nor performs native work.
    func candidateMeasurementContext(diagnostics: PublishingQualityTelemetry.Diagnostics) -> CandidateMeasurementContext? {
        guard !closed, !busy, !Task.isCancelled, operations.isPublishing(),
              let policy, let receipt, let acknowledgedAt, let source = candidateHealthSource else { return nil }
        let now = uptime()
        #if DEBUG
        candidateSourceDiagnostic["measurementContextGate"] =
            !diagnostics.isPublishing ? "not-publishing" :
            diagnostics.receipt?.configuration != receipt.configuration ? "receipt-configuration" :
            diagnostics.receipt?.acceptedAt != receipt.acceptedAt ? "receipt-time" :
            diagnostics.receipt?.lastSubmittedSourcePTS != receipt.lastSubmittedSourcePTS ? "receipt-pts" :
            diagnostics.clock != source.clock ? "clock-mismatch" :
            diagnostics.ingress == nil ? "ingress-absent" :
            diagnostics.ingress?.isClosed == true ? "ingress-closed" :
            diagnostics.ingress?.scope != source.observationScope ? "ingress-scope" :
            "policy-or-authority"
        #endif
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
        #if DEBUG
        candidateSourceDiagnostic["measurementContextGate"] = "ready"
        #endif
        return .init(readiness: readiness,
            applied: .init(attemptID: attemptID, revision: readiness.appliedRevision, settings: readiness.baseline,
                receipt: receipt, acknowledgedAt: acknowledgedAt), scope: ingress.scope, clock: clock,
            measuredCost: candidateProbeDemand?.cost(for: readiness))
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
                at: now, recoveryStrategy: strategy, behavior: behavior, timingProfile: timingProfile)
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
        func note(_ gate: String) {
            #if DEBUG
            candidateSourceDiagnostic = ["lastCandidateSourceGate": gate, "lastCandidateSourceObservedAtUptimeSeconds": String(now)]
            candidateSourceDiagnostic["lastCandidateSourceMaximumWindowAgeSeconds"] = String(timingProfile.maximumCaptureWindowEvaluationAge)
            candidateSourceDiagnostic["lastCandidateSourceWindowAgeSeconds"] = lastWindow.map { String(now - $0.end) }
            candidateSourceDiagnostic["lastCandidateSourceReceiverAgeSeconds"] = lastWindow?.receiver.map { String(now - $0.observedAt) }
            candidateSourceDiagnostic["lastCandidateSourceOverlapsMeasurement"] = lastWindow.map {
                String($0.end > admission.value.measuredStart && $0.start < admission.value.measuredEnd)
            }
            #endif
        }
        let applied = PublishingQualityTelemetry.Applied(attemptID: attemptID, revision: policy.appliedRevision,
            settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt)
        // Revoked or changed owners retain the existing rejection behavior;
        // deferral is solely for absent/incompatible temporal source coverage.
        guard admission.permits(applied: applied, at: now, instant: instant) else {
            note("authority-rejected")
            return try evaluateCandidate(admission, instant: instant)
        }
        let receiver = admission.receiver
        guard let source = candidateHealthSource,
              source.gameID == receiver.expected.gameId, source.generation == receiver.expected.generation,
              source.workerId == receiver.expected.workerId, source.epoch == receiver.workerEpoch,
              source.attempt == receiver.workerAttempt, source.publication == receiver.publication else { note("source-scope"); return nil }
        guard let window = lastWindow, let observedReceiver = window.receiver,
              window.attemptID == attemptID, window.appliedRevision == policy.appliedRevision,
              window.end <= now, now - window.end <= timingProfile.maximumCaptureWindowEvaluationAge else { note("source-window-age"); return nil }
        guard observedReceiver.observedAt <= now, now - observedReceiver.observedAt <= 2 else { note("source-receiver-age"); return nil }
        guard window.end > admission.value.measuredStart, window.start < admission.value.measuredEnd else { note("source-candidate-overlap"); return nil }
        note("ready")
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
            let decision: QualityController.Decision
            if ownedPublisher != nil {
                guard let lease = ownedMeasurement, lease.isActive, lease.permits(admission), candidateHealthSource == ownedSource else { throw Failure.staleAdvice }
                decision = try policy.evaluateCandidate(admission.value, for: lease.token, at: now)
            } else {
                decision = try policy.evaluateCandidate(admission.value, at: now)
            }
            if decision.recommendation == nil, decision.reasons.contains(.capacityHeadroom),
               ownedPublisher?.stagePlanSelection.isProductionSRT == true, admission.isProductionSRT, !Task.isCancelled,
               let lease = ownedMeasurement, lease.isActive, lease.permits(admission),
               admission.value.candidateTransportBitsPerSecond.isFinite, admission.value.candidateTransportBitsPerSecond > 0 {
                candidateProbeDemand = .init(baseline: policy.applied, revision: policy.appliedRevision,
                    target: admission.value.settings, measuredCost: admission.value.candidateTransportBitsPerSecond)
            }
            #if DEBUG
            recordDecision(decision, input: "candidate", at: now,
                extra: ["start": String(admission.value.measuredStart), "end": String(admission.value.measuredEnd),
                    "cost": String(admission.value.candidateTransportBitsPerSecond),
                    "padding": String(admission.value.deliveredPaddingBitsPerSecond)])
            #endif
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
            if !preserveDownward { invalidateTelemetry(&policy, input: "candidateRejected"); candidateHealthSource = nil; pending = nil }
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
            #if DEBUG
            recordDecision(decision, input: "window", at: now, window: window)
            #endif
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { invalidateTelemetry(&policy, input: "windowRejected", error: error); candidateHealthSource = nil; pending = nil; throw error }
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
                sequence: lastPolicySequence + 1, at: now, instant: sampledInstant, timingProfile: timingProfile)
            if let lastSource, lastSource.scope != sourceScope { invalidateTelemetry(&policy, input: "sourceScopeChanged", start: window.start, end: window.end); candidateHealthSource = nil }
            let decision = try policy.evaluate(window, at: now)
            #if DEBUG
            recordDecision(decision, input: "source", at: now, window: window, transportLimits: transportLimits,
                diagnostics: diagnostics, processing: source.processing, workerLimits: workerLimits)
            #endif
            candidateHealthSource = sourceScope
            candidateRecovery?.recordSource(start: window.start, end: window.end, sequence: window.sequence)
            lastSource = (sourceScope, source.sequence)
            #if DEBUG
            acceptedSourceMapping = .init(source: source, scope: sourceScope, windowEnd: window.end)
            #endif
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { invalidateTelemetry(&policy, input: "sourceRejected", error: error, start: source.interval.captureBoundaryStartTime, end: source.interval.captureBoundaryEndTime); candidateHealthSource = nil; pending = nil; throw error }
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
            #if DEBUG
            recordDecision(decision, input: "localPressure", at: now, window: window, transportLimits: transportLimits, diagnostics: diagnostics)
            #endif
            candidateHealthSource = nil
            pending = decision.recommendation
            lastPolicySequence = window.sequence; lastWindow = window; evaluatedAt = now
            return decision
        } catch { invalidateTelemetry(&policy, input: "localRejected", error: error); candidateHealthSource = nil; pending = nil; throw error }
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
            if !preserveDownward { invalidateTelemetry(&policy, input: "cadenceUnavailable", error: error); pending = nil }
            throw error
        }
        if !preserveDownward { invalidateTelemetry(&policy, input: "cadenceUnavailable"); pending = nil }
    }

    func evaluateDecoderStall(cadence: WorkerDecoderCadenceFreshness, diagnostics: PublishingQualityTelemetry.Diagnostics,
                              instant: ContinuousClock.Instant? = nil,
                              observeEvaluation: (@Sendable (EvaluationDiagnostic) -> Void)? = nil) throws -> QualityController.Decision? {
        var evaluationAt: Double?, evaluationInstant: ContinuousClock.Instant?
        #if DEBUG
        var evaluationConsumed = false, evaluationRequiresRevalidation = false
        #endif
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
            #if DEBUG
            evaluationConsumed = consumedCadenceReceipt == cadence.receiptID
            evaluationRequiresRevalidation = requiresCadenceFreshnessValidation
            #endif
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            let applied = PublishingQualityTelemetry.Applied(attemptID: attemptID, revision: policy.appliedRevision,
                settings: policy.applied, receipt: receipt, acknowledgedAt: acknowledgedAt)
            try PublishingQualityTelemetry.validateDecoderContext(cadence: cadence, applied: applied,
                diagnostics: diagnostics, sequence: lastPolicySequence + 1, at: now)
            // A consumed downward-only sample cannot acquire new meaning merely
            // by aging in a local cache. A newly received stale report still rejects.
            guard requiresCadenceFreshnessValidation || consumedCadenceReceipt != cadence.receiptID else { return nil }
            let signal = try PublishingQualityTelemetry.decoderStall(cadence: cadence, applied: applied,
                diagnostics: diagnostics, sequence: lastPolicySequence + 1, at: now, instant: sampledInstant, timingProfile: timingProfile)
            let scope = DecoderScope(cadence), progress = cadence.snapshot.progress!.lastFreshPTS
            if let decoderScope, decoderScope != scope {
                invalidateTelemetry(&policy, input: "cadenceScopeChanged"); candidateHealthSource = nil; pending = nil
                decoderProgress = nil; consumedStallPTS = nil
            }
            if let decoderProgress, progress < decoderProgress { throw QualityController.ValidationError.outOfOrder }
            decoderScope = scope; decoderProgress = progress; consumedCadenceReceipt = cadence.receiptID
            requiresCadenceFreshnessValidation = false
            if cadence.snapshot.progress?.stalled == false { candidateRecovery?.resume(at: now) }
            guard let signal, consumedStallPTS != progress else { return nil }
            let decision = try policy.evaluateDecoderStall(signal, at: now)
            #if DEBUG
            recordDecision(decision, input: "decoderStall", at: now, extra: ["observedAtLowerBound": String(signal.observedAtLowerBound)])
            #endif
            candidateHealthSource = nil
            consumedStallPTS = progress; lastPolicySequence = signal.sequence; lastDecoderStall = signal
            pending = decision.recommendation; evaluatedAt = now
            return decision
        } catch {
            #if DEBUG
            if let evaluationAt, let evaluationInstant {
                let age = cadence.ageDiagnostic(at: evaluationInstant)
                // One bounded latest rejection, including failures outside a trial.
                // The ordinary UI used to retain only the later current sample age,
                // which cannot identify the stage that caused this rejection.
                let timing = ["at": evaluationAt,
                    "server": EvaluationDiagnostic.seconds(age.serverAge),
                    "request": EvaluationDiagnostic.seconds(age.requestDuration),
                    "residence": EvaluationDiagnostic.seconds(age.residence),
                    "total": EvaluationDiagnostic.seconds(age.total)].compactMapValues { $0 }
                if let data = try? JSONSerialization.data(withJSONObject: timing, options: [.sortedKeys]) {
                    cadenceRejectionTiming = String(data: data, encoding: .utf8)
                }
                var witness = ["cadenceReceiptID": cadence.receiptID.uuidString.lowercased(),
                    "cadenceEvaluatedAt": String(evaluationAt), "cadenceAgeState": age.state.rawValue,
                    "cadenceMaximumSampleAgeSeconds": String(timingProfile.maximumCadenceDeliveryReportAge),
                    "cadenceServerAgeSeconds": String(EvaluationDiagnostic.seconds(age.serverAge)!),
                    "cadenceRequestSeconds": String(EvaluationDiagnostic.seconds(age.requestDuration)!),
                    "cadenceReceiptPreviouslyConsumed": String(evaluationConsumed),
                    "cadenceRequiresRevalidation": String(evaluationRequiresRevalidation)]
                witness["cadenceSampleAgeSeconds"] = EvaluationDiagnostic.seconds(age.total).map { String($0) }
                witness["cadenceResidenceSeconds"] = EvaluationDiagnostic.seconds(age.residence).map { String($0) }
                witness["cadenceStalled"] = cadence.snapshot.progress.map { String($0.stalled) }
                witness["cadenceProgressAgeMs"] = cadence.snapshot.progress.map { String($0.ageMs) }
                witness["cadenceLastFreshPTS"] = cadence.snapshot.progress.map { String($0.lastFreshPTS) }
                // Freeze the receipt before the deferred observer runs. The same
                // first-cause guard owns both ordinary and audit-only fields.
                latchInvalidationCause(policy, input: "cadenceRejected", error: error, auditFields: witness)
            }
            #endif
            invalidateTelemetry(&policy, input: "cadenceRejected", error: error)
            candidateHealthSource = nil; pending = nil; throw error
        }
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
                  currentAge <= .seconds(timingProfile.maximumCadenceDeliveryReportAge),
                  observation.observedAtLowerBound.isFinite, observation.observedAtLowerBound <= now,
                  source.windowEnd <= observation.observedAtLowerBound,
                  now - observation.observedAtLowerBound <= timingProfile.maximumCadenceDeliveryReportAge,
                  now - source.windowEnd <= timingProfile.maximumCaptureWindowEvaluationAge else { throw PublishingQualityTelemetry.Failure.freshness }
            if deliveryAuthority !== authority || deliveryRevision != policy.appliedRevision {
                if deliveryAuthority != nil { invalidateTelemetry(&policy, input: "deliveryAuthorityChanged"); candidateHealthSource = nil; pending = nil }
                deliveryAuthority = authority; deliveryRevision = policy.appliedRevision; deliveryEnds = [:]
            }
            deliveryEnds[lane] = source.windowEnd
            if let candidateRecovery, recordCandidateRecovery {
                candidateRecovery.recordDelivery(start: source.windowStart, end: source.windowEnd, result: observation.result)
                recoveryDelivery = observation
            }
            guard lastPolicySequence < .max else { throw QualityController.ValidationError.invalidWindow }
            guard let signal = observation.failureSignal(sequence: lastPolicySequence + 1) else {
                if observation.result.uncertainFrames > 0 { invalidateTelemetry(&policy, input: "deliveryUncertain", start: source.windowStart, end: source.windowEnd); candidateHealthSource = nil; pending = nil }
                return nil
            }
            let decision = try policy.evaluateDeliveryFailure(signal, at: now)
            #if DEBUG
            recordDecision(decision, input: "deliveryFailure", at: now, extra: ["start": String(signal.start), "end": String(signal.end), "expected": String(signal.expectedFrames), "onTime": String(signal.onTimeFrames), "late": String(signal.lateFrames), "missing": String(signal.missingFrames)])
            #endif
            candidateHealthSource = nil
            lastPolicySequence = signal.sequence; lastDeliveryFailure = signal
            pending = decision.recommendation; evaluatedAt = now
            return decision
        } catch { invalidateTelemetry(&policy, input: "deliveryRejected", error: error, start: observation.source.windowStart, end: observation.source.windowEnd); candidateHealthSource = nil; pending = nil; throw error }
    }
    func checkTrialDeadline() throws -> QualityController.Recommendation? {
        try admit()
        guard var policy else { throw Failure.notReady }
        defer { self.policy = policy }
        do {
            #if DEBUG
            let priorTrial = policy.currentDiagnostic.trial
            #endif
            let advice = try policy.checkTrialDeadline(at: time())
            #if DEBUG
            if let advice, transitionCause?.advice != advice {
                // Deadline may refresh an expired reset recommendation. Preserve
                // its original cause rather than attributing it to the timer.
                if let prior = transitionCause, prior.advice.appliedRevision == advice.appliedRevision,
                   prior.advice.kind == advice.kind {
                    transitionCause = (advice, prior.fields)
                } else {
                    var fields = ["input": "trialDeadline", "at": String(lastNow), "reasons": "trialTimedOut"]
                    fields["deadline"] = priorTrial.map { String($0.deadline) }
                    if let cause = invalidationCause, cause.revision == advice.appliedRevision { fields = cause.fields }
                    transitionCause = (advice, fields)
                }
            }
            #endif
            // No due rollback does not revoke an existing trial/increase/decrease.
            if let advice { candidateHealthSource = nil; pending = advice }
            return advice
        } catch { invalidateTelemetry(&policy, input: "deadlineRejected", error: error); candidateHealthSource = nil; pending = nil; throw error }
    }
    func apply(_ advice: QualityController.Recommendation) async throws {
        let measurement = advice.candidateID == nil ? nil : ownedMeasurement
        if let measurement {
            do { try await measurement.validateForApplication() }
            catch {
                // Validation precedes the Core transfer and every native write.
                // A retired context only invalidates this measurement.
                if ownedMeasurement === measurement { measurement.revoke() }
                throw Failure.staleAdvice
            }
            guard ownedMeasurement === measurement, measurement.isActive,
                  candidateHealthSource == ownedSource, let witness = pendingCandidate, measurement.permits(witness), operations.guarded != nil,
                  let diagnostics = ownedDiagnostics?(), let currentReceipt = receipt,
                  diagnostics.isPublishing, diagnostics.receipt?.configuration == currentReceipt.configuration,
                  diagnostics.receipt?.acceptedAt == currentReceipt.acceptedAt,
                  diagnostics.receipt?.publishingGeneration == currentReceipt.publishingGeneration,
                  diagnostics.receipt?.lastSubmittedSourcePTS == currentReceipt.lastSubmittedSourcePTS,
                  diagnostics.clock == measurement.context.clock,
                  diagnostics.ingress?.scope == measurement.context.scope,
                  diagnostics.ingress?.isClosed == false else { throw Failure.staleAdvice }
        }
        try admit()
        guard var policy else { throw Failure.notReady }
        let start: Double
        do { start = try time() }
        catch { invalidateTelemetry(&policy, input: "applicationRejected", error: error); self.policy = policy; candidateHealthSource = nil; pending = nil; throw error }
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
                invalidateTelemetry(&policy, input: "applicationRejected"); self.policy = policy; candidateHealthSource = nil; pending = nil
                throw Failure.staleAdvice
            }
        }
        let admitted: QualityController.Application
        if let measurement {
            admitted = try policy.beginApplication(advice, for: measurement.token, at: start)
            ownedTransferred = admitted
            #if DEBUG
            measurement.record("applicationTransferred", fields: ["applicationID": admitted.id.uuidString.lowercased(),
                "candidateID": advice.candidateID!.uuidString.lowercased(), "admittedAt": admitted.admittedAt,
                "completionDeadline": admitted.completionDeadline])
            #endif
        } else { admitted = try policy.beginApplication(advice, at: start) }
        // Publish authoritative policy and private ownership before native work
        // suspends. A selector is never proof that this application changed it.
        #if DEBUG
        let admittedCause = transitionCause.flatMap { $0.advice == advice ? $0.fields : nil }
        let admittedAuditCause = invalidationCause.flatMap { cause in
            cause.revision == advice.appliedRevision && admittedCause == cause.fields &&
                (advice.kind == .reset || advice.kind == .rollback) ? cause.auditFields : nil
        }
        #endif
        self.policy = policy
        applicationOwner = .init(application: admitted)
        if advice.candidateID == nil { ownedMeasurement?.revoke() }
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
            #if DEBUG
            var profileRequestedAt: Double?
            #endif
            if let profile {
                #if DEBUG
                if appliedTransitionAudit != nil { profileRequestedAt = uptime() }
                #endif
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
            #if DEBUG
            let rateRequestedAt = appliedTransitionAudit == nil ? nil : uptime()
            #endif
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
            #if DEBUG
            var fields = admittedCause ?? ["input": "unavailable", "reasons": "causeUnavailable"]
            fields["applicationID"] = admitted.id.uuidString.lowercased()
            fields["attemptID"] = advice.attemptID.uuidString.lowercased()
            fields["fromRevision"] = String(advice.appliedRevision)
            fields["sequence"] = String(advice.windowSequence)
            fields["kind"] = String(describing: advice.kind)
            fields["profile"] = advice.settings.profileID; fields["bitrate"] = String(advice.settings.videoBitrate)
            fields["validUntil"] = String(advice.validUntil)
            fields["candidateID"] = advice.candidateID?.uuidString.lowercased()
            fields["revision"] = String(current.appliedRevision)
            fields["ackAt"] = String(now); fields["nativeAt"] = String(result.acceptedAt)
            fields["profileNativeAt"] = format.map { String($0.acknowledgedAt) }
            // Receipt-derived coded geometry and exact source coordinates only.
            // This is emitted after both native receipts and Core ACK succeed.
            func exactPTS(_ pts: CMTime?) -> String? {
                guard let pts, pts.isNumeric, pts.epoch == 0, pts.timescale > 0 else { return nil }
                return "\(pts.value)/\(pts.timescale)"
            }
            if let format {
                fields["formatWidth"] = String(format.width); fields["formatHeight"] = String(format.height)
                fields["profileGeneration"] = String(format.publishingGeneration)
                fields["oldEncoder"] = format.previousEncoderSessionID.uuidString.lowercased()
                fields["newEncoder"] = format.encoderSessionID.uuidString.lowercased()
                fields["oldPTS"] = exactPTS(format.lastOldSourcePTS)
                fields["newPTS"] = exactPTS(format.firstNewSourcePTS)
            }
            fields["rateEncoder"] = result.configuration.encoderSessionID.uuidString.lowercased()
            fields["rateGeneration"] = String(result.publishingGeneration)
            fields["nativeBitrate"] = String(result.configuration.bitRate)
            fields["ratePTS"] = exactPTS(result.lastSubmittedSourcePTS)
            var uiFields = fields
            uiFields.removeValue(forKey: "transportRecentSamples")
            appliedTransition = (try? JSONSerialization.data(withJSONObject: uiFields, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
            if appliedTransitionAudit != nil {
                var auditFields = fields
                auditFields.merge(admittedAuditCause ?? [:]) { original, _ in original }
                auditFields["admittedAt"] = String(admitted.admittedAt)
                auditFields["completionDeadline"] = String(admitted.completionDeadline)
                auditFields["profileRequestedAt"] = profileRequestedAt.map { String($0) }
                auditFields["rateRequestedAt"] = rateRequestedAt.map { String($0) }
                appliedTransitionAudit?.append(auditFields)
            }
            transitionCause = nil; invalidationCause = nil
            #endif
            // This revision change is our acknowledged write, not replacement
            // of the receiver context. Keep its revocable identity while new
            // source/configuration windows start their own delivery watermarks.
            deliveryRevision = current.appliedRevision; deliveryEnds = [:]
            if let format { profileReceipt = format }
            if let measurement {
                measurement.revoke()
                ownedTransferred = nil; ownedAcknowledged = measurement
                #if DEBUG
                measurement.record("acknowledged", fields: ["applicationID": admitted.id.uuidString.lowercased(),
                    "receipt": PublishingOwnedMeasurementAudit.receipt(result), "currentAppliedRevision": String(current.appliedRevision),
                    "policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(current.candidateMeasurementDiagnostic)])
                #endif
                scheduleOwnedSettlement(measurement)
            }
        } catch {
            guard let owner = applicationOwner, owner.application == admitted else {
                // stop() already retired this owner. Join its existing shutdown;
                // a late completion cannot request shutdown of newer native work.
                await shutdown?.value
                throw error
            }
            if operations.guarded != nil, error is PublishingVideoMutationAdmissionError,
               !owner.changedProfile, !Task.isCancelled, operations.isPublishing() {
                // The guarded call has joined its cleanup. Settle the exact
                // application against the current authoritative policy after
                // its measurement cleanup also joins.
                var retainedOwnedRejection = false
                if let measurement, var current = self.policy {
                    try current.noteCandidateApplicationRejection(admitted, for: measurement.token)
                    self.policy = current
                    ownedRejected = admitted
                    #if DEBUG
                    measurement.record("applicationRejected", fields: ["applicationID": admitted.id.uuidString.lowercased()])
                    #endif
                    measurement.revoke()
                    // The native call has joined. Track the measurement join
                    // separately so Driver telemetry remains available, including
                    // when native cleanup finished before its rejection returned.
                    scheduleOwnedSettlement(measurement)
                    retainedOwnedRejection = true
                }
                if !retainedOwnedRejection, var current = self.policy {
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
        let measurement = ownedMeasurement, settlement = ownedSettlement
        measurement?.revoke()
        closed = true; pending = nil; pendingCandidate = nil; candidateHealthSource = nil; candidateProbeDemand = nil
        #if DEBUG
        lastMeasurementDiagnostic = [:]; candidateSourceDiagnostic = [:]
        transitionCause = nil; invalidationCause = nil; appliedTransition = nil
        #endif
        applicationOwner = nil; busy = false
        let task: Task<Void, Never>
        if let shutdown { task = shutdown }
        else {
            let stop = operations.stop
            #if DEBUG
            // Close before the first suspension. Retired native completions can
            // neither append nor change the immutable snapshot captured here.
            let auditData = try? appliedTransitionAudit?.close()
            let export = appliedTransitionExport
            appliedTransitionAudit = nil
            #endif
            task = Task.detached {
                await stop()
                await measurement?.join()
                await settlement?.value
                #if DEBUG
                if let auditData, let export { await export(auditData) }
                #endif
            }
            shutdown = task
        }
        await task.value
        #if DEBUG
        if let audit = ownedPublisher?.audit { audit.close(); await audit.persist() }
        #endif
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

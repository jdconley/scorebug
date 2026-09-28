import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Coalesces the existing health loop; never runs on capture callbacks.
@MainActor final class PublishingQualityDriver {
    /// Current acknowledged settings only; presentation grants no admission.
    var appliedSettingsDidChange: ((QualityController.Settings) -> Void)?
    #if DEBUG
    var currentDiagnosticDidChange: ((String) -> Void)?
    var candidateInputDiagnosticProvider: (() -> [String: String])?
    private var currentCandidateDiagnostic: [String: String] = [:]
    private var currentEvent = "starting", currentReason: String?, sourceRejection: String?
    private var currentDeliveryDiagnostic: [String: String] = [:]
    #endif
    /// Wake measurement scheduling after a source decision; this grants no admission.
    var sourceEvaluationDidComplete: (() -> Void)?
    var candidateInputProvider: ((PublishingQualitySession.Snapshot) async -> PublishingCandidateAdmission?)?
    var deliveryInputProvider: (() -> PublishingDeliveryMonitor.Input?)?
    struct CadenceInput {
        let cadence: WorkerDecoderCadenceFreshness?
        let diagnostics: PublishingQualityTelemetry.Diagnostics
    }
    var cadenceInputProvider: (() -> CadenceInput?)?
    private let enableDeliveryFailures: Bool
    private let enableMeasuredSourceEvaluation: Bool
    private let deliveryConsumer: PublishingDeliveryMonitor.Consumer?
    private let deliveryExport: ((Data) async -> Void)?
    let timingProfile: StreamingTimingProfile
    private let owner: PublishingQualitySession
    private let retainsDiagnosticHistory: Bool
    private let workerLimitsProvider: ((WorkerSourceIntervalObservation) -> PublishingQualityTelemetry.WorkerLimits?)?
    private let workerLimits: PublishingQualityTelemetry.WorkerLimits?
    private let transportLimits: PublishingQualityTelemetry.TransportLimits?
    private let uptime: () -> Double
    private var task: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private let export: ((Data) async -> Void)?
    private let liveExport: ((Data) async -> Void)?
    private var pendingLiveCheckpoint: [String: Any]?
    private var liveDrain: Task<Void, Never>?
    private var events: [[String: Any]] = []
    private let evidenceDictionary: QualityEvidenceDictionary?
    private var overflow = false
    private var consumed: String?
    private var consumedCandidateID: UUID?
    private var noted: String?
    private var localRejection: String?
    private var cadenceRejection: String?
    private var startupWaitStartedAt: Double?
    private(set) var isClosed = false
    private(set) var bootstrapCount = 0
    init(owner: PublishingQualitySession, timingProfile: StreamingTimingProfile = .strict1500, workerLimits: PublishingQualityTelemetry.WorkerLimits?,
         workerLimitsProvider: ((WorkerSourceIntervalObservation) -> PublishingQualityTelemetry.WorkerLimits?)? = nil,
         transportLimits: PublishingQualityTelemetry.TransportLimits?, uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         retainsDiagnosticHistory: Bool = true, deliveryAudit: PublishingDeliveryMonitor.Audit? = nil, deliveryConsumer: PublishingDeliveryMonitor.Consumer? = nil, deliveryExport: ((Data) async -> Void)? = nil, enableDeliveryFailures: Bool = false, enableMeasuredSourceEvaluation: Bool = false, liveExport: ((Data) async -> Void)? = nil, export: ((Data) async -> Void)? = nil) {
        self.retainsDiagnosticHistory = retainsDiagnosticHistory
        self.evidenceDictionary = retainsDiagnosticHistory ? QualityEvidenceDictionary() : nil
        self.workerLimitsProvider = workerLimitsProvider
        self.timingProfile = timingProfile
        self.liveExport = liveExport
        self.enableDeliveryFailures = enableDeliveryFailures
        self.enableMeasuredSourceEvaluation = enableMeasuredSourceEvaluation
        precondition(deliveryAudit == nil || deliveryConsumer == nil, "Choose one delivery consumer")
        self.deliveryConsumer = deliveryAudit.map { .audited($0) } ?? deliveryConsumer
        self.deliveryExport = deliveryExport
        self.owner = owner; self.workerLimits = workerLimits; self.transportLimits = transportLimits; self.uptime = uptime; self.export = export
    }
    func installOwnedMeasurementPublisher(_ publisher: NativeOwnedCandidatePublisher, session: PublishingSession,
        policy: PublishingBandwidthProbeSnapshot.Policy) async throws {
        try await owner.installOwnedMeasurementPublisher(publisher, policy: policy,
            diagnostics: { .init(snapshot: session.snapshot) })
        guard publisher.installReaders(candidate: { [weak owner] in await owner?.ownedCandidateSnapshot() },
            probe: { [weak owner] in await owner?.ownedProbeObservation() },
            pressure: { [weak session] in NativeCandidatePressure(session?.snapshot) }) else { throw PublishingQualitySession.Failure.staleAdvice }
    }
    func candidateMeasurementContext(diagnostics: PublishingQualityTelemetry.Diagnostics) async -> PublishingQualitySession.CandidateMeasurementContext? {
        guard !isClosed, !Task.isCancelled else { return nil }
        let context = await owner.candidateMeasurementContext(diagnostics: diagnostics)
        guard !isClosed, !Task.isCancelled else { return nil }
        return context
    }
    @discardableResult func tick(encoderReady: Bool, source: WorkerSourceIntervalObservation?, cadence: WorkerDecoderCadenceFreshness? = nil, diagnostics: PublishingQualityTelemetry.Diagnostics) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        if let task { return task }
        let selectedAt = diagnosticUptime()
        task = Task { [self] in
            defer { task = nil }
            await cycle(encoderReady: encoderReady, source: source, cadence: cadence, diagnostics: diagnostics, selectedAt: selectedAt)
            #if DEBUG
            await publishCurrentDiagnostic(source: source)
            #endif
        }
        return task
    }
    private func cycle(encoderReady: Bool, source: WorkerSourceIntervalObservation?, cadence: WorkerDecoderCadenceFreshness?, diagnostics: PublishingQualityTelemetry.Diagnostics, selectedAt: Double?) async {
        do {
            let state = await owner.snapshot
            try Task.checkCancellation()
            guard !isClosed else { return }
            if state.applied == nil {
                guard encoderReady else { return }
                if let start = startupWaitStartedAt {
                    let now = uptime()
                    guard now.isFinite, now >= start, now - start < 2 else { throw PublishingQualitySession.Failure.invalidReceipt }
                }
                do { try await owner.bootstrap() }
                catch PublishingQualitySession.Failure.startupPending {
                    let now = uptime()
                    guard now.isFinite, (0...1e12).contains(now) else { throw PublishingQualitySession.Failure.invalidReceipt }
                    let start = startupWaitStartedAt ?? now
                    startupWaitStartedAt = start
                    guard now >= start, now - start < 2 else { throw PublishingQualitySession.Failure.invalidReceipt }
                    return
                }
                startupWaitStartedAt = nil
                try Task.checkCancellation()
                guard !isClosed else { return }
                bootstrapCount += 1
                await publishAppliedSettings()
                await record("bootstrap")
                return
            }
            // Read current caller-owned evidence only after the actor await.
            // No asynchronous work occurs between this read and classification.
            let currentDelivery = deliveryInputProvider?()
            var deliveryObservations: [PublishingDeliveryObservation] = []
            var deliveryUnavailable = false
            if let settings = state.applied, let revision = state.revision, let receipt = state.receipt,
               let acknowledgedAt = state.acknowledgedAt, !state.isBusy, !state.isClosed {
                let now = uptime(), instant = ContinuousClock.now
                deliveryObservations = deliveryConsumer?.record(input: currentDelivery,
                    applied: .init(attemptID: state.attemptID, revision: revision, settings: settings,
                        receipt: receipt, acknowledgedAt: acknowledgedAt), at: now, instant: instant,
                    onUnavailable: {
                        deliveryUnavailable = true
                        self.owner.invalidateCandidateRecovery()
                    }) ?? []
            }
            if enableDeliveryFailures {
                for observation in deliveryObservations {
                    #if DEBUG
                    currentDeliveryDiagnostic = ["deliveryObservedAtUptimeSeconds": String(uptime()),
                        "deliveryWindowSeconds": String(observation.result.duration),
                        "deliveryExpectedFrames": String(observation.result.expectedFrames),
                        "deliveryOnTimeFrames": String(observation.result.onTimeFrames),
                        "deliveryLateFrames": String(observation.result.lateFrames),
                        "deliveryMissingFrames": String(observation.result.missingFrames),
                        "deliveryUncertainFrames": String(observation.result.uncertainFrames)]
                    #endif
                    guard let authority = observation.authority else { continue }
                    let decision: QualityController.Decision?
                    do {
                        decision = try await owner.evaluateDeliveryFailure(observation, authority: authority,
                            recordCandidateRecovery: !deliveryUnavailable)
                    } catch {
                        await record("rejected", reason: "delivery-" + Self.reason(error))
                        continue
                    }
                    try Task.checkCancellation()
                    guard !isClosed else { return }
                    if let decision {
                        await record("deliveryFailure", decision: decision, delivery: observation,
                            advice: decision.recommendation)
                        if let advice = decision.recommendation { try await apply(advice) }
                        return
                    }
                }
            }
            // This fixture qualifies downward deadline actions only. Unknown,
            // uncertain and overlapping windows cannot grant recovery credit.
            var canEvaluateSource = !enableDeliveryFailures || enableMeasuredSourceEvaluation
            var canEvaluateCandidate = true
            var currentDiagnostics: PublishingQualityTelemetry.Diagnostics? = diagnostics
            if canEvaluateSource, await owner.usesDecoderStallPolicy {
                try Task.checkCancellation()
                guard !isClosed else { return }
                var currentCadence = cadence
                var cadenceSelectedAt = selectedAt
                if let provider = cadenceInputProvider {
                    cadenceSelectedAt = diagnosticUptime()
                    let input = provider()
                    currentCadence = input?.cadence
                    currentDiagnostics = input?.diagnostics
                    if currentCadence == nil {
                        // No fallback to the tick's captured proof. Owner loss
                        // supplies no diagnostics; valid ownership with absent
                        // cadence invalidates probation without inventing health.
                        canEvaluateSource = false; canEvaluateCandidate = false
                        if let input {
                            do { try await owner.noteUnavailableCadence(diagnostics: input.diagnostics) }
                            catch { await record("rejected", reason: "cadence-" + Self.reason(error)) }
                        }
                    }
                }
                if let cadence = currentCadence, let cadenceDiagnostics = currentDiagnostics {
                    let decision: QualityController.Decision?
                    let evaluation = evaluationCapture(selectedAt: cadenceSelectedAt)
                    do {
                        decision = try await owner.evaluateDecoderStall(cadence: cadence, diagnostics: cadenceDiagnostics,
                            observeEvaluation: evaluation?.observer)
                        cadenceRejection = nil
                    } catch {
                        let evaluationDiagnostic = evaluation?.rejected(at: diagnosticUptime())
                        decision = nil; canEvaluateSource = false; canEvaluateCandidate = false
                        let reason = Self.reason(error), key = "\(state.revision ?? 0)/\(reason)"
                        if cadenceRejection != key {
                            cadenceRejection = key
                            await record("rejected", reason: "cadence-" + reason, evaluationDiagnostic: evaluationDiagnostic)
                        }
                    }
                    try Task.checkCancellation()
                    guard !isClosed else { return }
                    if let decision {
                        await record("decoderStall", decision: decision, cadence: cadence)
                        if let advice = decision.recommendation { try await apply(advice) }
                        return
                    }
                    // A repeated fresh stall cannot give an old source window healthy
                    // recovery credit. It also need not dispatch the same reset twice.
                    if cadence.observedStall(maximumSampleAge: .seconds(timingProfile.maximumCadenceDeliveryReportAge)) == true {
                        canEvaluateSource = false; canEvaluateCandidate = false
                    }
                }
            }
            if let rollback = try await owner.checkTrialDeadline() {
                try await apply(rollback)
                return
            }
            guard let currentDiagnostics else { return }
            if canEvaluateSource, let source, try await evaluateSource(source, state: state, diagnostics: currentDiagnostics, selectedAt: selectedAt) { return }
            let decision: QualityController.Decision?
            do {
                decision = try await owner.evaluateLocalPressure(diagnostics: currentDiagnostics, transportLimits: transportLimits)
                localRejection = nil
            } catch {
                let reason = Self.reason(error), key = "\(state.revision ?? 0)/\(reason)"
                if !isClosed, !Task.isCancelled, localRejection != key {
                    localRejection = key
                    await record("rejected", reason: "local-" + reason)
                }
                return
            }
            try Task.checkCancellation()
            guard !isClosed else { return }
            if let decision {
                await record("localPressure", decision: decision, diagnostics: currentDiagnostics)
                if let advice = decision.recommendation { try await apply(advice) }
                return
            }
            if canEvaluateCandidate {
                _ = try await owner.startOwnedMeasurement(diagnostics: currentDiagnostics)
                try await evaluateCandidateInput()
            }
        } catch {
            guard !isClosed, !Task.isCancelled else { return }
            deliveryConsumer?.cancel()
            owner.invalidateCandidateRecovery()
            isClosed = true
            await owner.stop()
            await record("failed", reason: "native-change-failed", allowClosed: true)
        }
    }
    /// Read the latest provider after all downward/deadline checks and a fresh
    /// actor snapshot. It also runs when no candidate exists, allowing the model
    /// to refresh its independently owned probe without inventing policy evidence.
    private func evaluateCandidateInput() async throws {
        guard candidateInputProvider != nil else { return }
        let state = await owner.snapshot
        try Task.checkCancellation()
        guard !isClosed, !state.isClosed, !state.isBusy, let provider = candidateInputProvider else { return }
        let candidate = await provider(state)
        try Task.checkCancellation()
        guard !isClosed, let candidate, candidate.value.id != consumedCandidateID else { return }
        let decision: QualityController.Decision
        do {
            #if DEBUG
            currentCandidateDiagnostic = ["lastCandidateObservedAtUptimeSeconds": String(uptime()),
                "lastCandidateCostBitsPerSecond": String(candidate.value.candidateTransportBitsPerSecond),
                "lastCandidatePaddingBitsPerSecond": String(candidate.value.deliveredPaddingBitsPerSecond)]
            #endif
            guard let evaluated = try await owner.evaluateCandidateWhenSourceReady(candidate) else {
                #if DEBUG
                currentCandidateDiagnostic["lastCandidateGate"] = "source-deferred"
                #endif
                return
            }
            consumedCandidateID = candidate.value.id
            decision = evaluated
            #if DEBUG
            currentCandidateDiagnostic["lastCandidateGate"] = "evaluated"
            currentCandidateDiagnostic["lastCandidateReasons"] = evaluated.reasons.map { String(describing: $0) }.joined(separator: ",")
            currentCandidateDiagnostic["lastCandidateAdvice"] = evaluated.recommendation.map { String(describing: $0.kind) } ?? "none"
            #endif
        } catch {
            consumedCandidateID = candidate.value.id
            guard !isClosed, !Task.isCancelled else { return }
            #if DEBUG
            currentCandidateDiagnostic["lastCandidateGate"] = "rejected"
            currentCandidateDiagnostic["lastCandidateRejection"] = Self.reason(error)
            #endif
            await record("rejected", candidate: candidate, reason: "candidate-" + Self.reason(error))
            return
        }
        try Task.checkCancellation()
        guard !isClosed else { return }
        // The probe lease may be only 300ms. No audit actor await may precede
        // the session's final synchronous authority check and application admission.
        if let advice = decision.recommendation { try await apply(advice) }
        await record("candidate", decision: decision, candidate: candidate, advice: decision.recommendation)
    }
    private func evaluateSource(_ source: WorkerSourceIntervalObservation, state: PublishingQualitySession.Snapshot,
                                diagnostics: PublishingQualityTelemetry.Diagnostics, selectedAt: Double?) async throws -> Bool {
        let key = "\(source.workerEpoch)/\(source.workerAttempt)/\(source.publication.readerId)/\(source.sequence)"
        guard consumed != key else { return false }
        guard case .verified(let config) = source.interval.encodingCoverage,
              config == state.receipt?.configuration,
              let acknowledgedAt = state.acknowledgedAt,
              source.interval.captureBoundaryStartTime >= acknowledgedAt,
              state.lastWindow.map({ source.interval.captureBoundaryStartTime >= $0.end }) ?? true else {
            if noted != key + "/transition" { noted = key + "/transition"; await record("transition", source: source) }
            return false
        }
        // Decoder windows can arrive before their matching processing report.
        // Leave the sequence available for the tracker's next poll, just as for
        // incomplete processing; the original capture deadline still bounds waiting.
        let processingPending = source.processing.map { $0.interval.pendingFrames > 0 } ?? true
        if processingPending,
           uptime() - source.interval.captureBoundaryEndTime < timingProfile.maximumCaptureWindowEvaluationAge { return false }
        consumed = key
        let decision: QualityController.Decision
        let evaluation = evaluationCapture(selectedAt: selectedAt)
        do {
            decision = try await owner.evaluate(source: source, diagnostics: diagnostics,
                workerLimits: workerLimitsProvider.map { $0(source) } ?? workerLimits, transportLimits: transportLimits, observeEvaluation: evaluation?.observer)
        } catch {
            let evaluationDiagnostic = evaluation?.rejected(at: diagnosticUptime())
            if !isClosed && !Task.isCancelled {
                await record("rejected", source: source, reason: Self.reason(error), evaluationDiagnostic: evaluationDiagnostic)
            }
            return false
        }
        try Task.checkCancellation()
        guard !isClosed else { return true }
        sourceEvaluationDidComplete?()
        localRejection = nil
        await record("evaluated", source: source, decision: decision, diagnostics: diagnostics)
        if let advice = decision.recommendation {
            try await apply(advice, source: source)
            return true
        }
        // Measured admission can use this newly completed health window in the
        // same tick, after the remaining downward checks. Legacy routing keeps
        // its original one-source-event-per-cycle behavior.
        return candidateInputProvider == nil
    }
    func apply(_ advice: QualityController.Recommendation, source: WorkerSourceIntervalObservation? = nil) async throws {
        do {
            try await owner.apply(advice)
            await publishAppliedSettings()
            await record("applied", source: source, advice: advice)
        } catch let error as PublishingVideoMutationAdmissionError {
            guard !(await owner.snapshot).isClosed else { throw error }
            await record("skipped", source: source, advice: advice, reason: "guarded-" + String(describing: error))
        } catch PublishingQualitySession.Failure.staleAdvice {
            // Rejected before dispatch: a late recommendation must not retire live.
            await record("skipped", source: source, advice: advice, reason: "staleAdvice")
        }
    }
    private func publishAppliedSettings() async {
        let state = await owner.snapshot
        guard !isClosed, !Task.isCancelled, !state.isClosed, let settings = state.applied else { return }
        appliedSettingsDidChange?(settings)
    }
    #if DEBUG
    private func publishCurrentDiagnostic(source: WorkerSourceIntervalObservation?) async {
        guard currentDiagnosticDidChange != nil, !Task.isCancelled else { return }
        var fields = await owner.currentDiagnostic()
        guard currentDiagnosticDidChange != nil, !Task.isCancelled else { return }
        let now = uptime(), instant = ContinuousClock.now
        fields.merge(currentDeliveryDiagnostic) { _, newest in newest }
        fields.merge(candidateInputDiagnosticProvider?() ?? [:]) { _, newest in newest }
        fields.merge(currentCandidateDiagnostic) { _, newest in newest }
        fields["timingProfileID"] = timingProfile.rawValue
        fields["decoderBudgetMilliseconds"] = String(timingProfile.decoderBudgetMs)
        fields["reportMaximumAgeMilliseconds"] = String(timingProfile.maximumCadenceDeliveryReportAgeMs)
        fields["captureWindowMaximumAgeMilliseconds"] = String(timingProfile.maximumCaptureWindowEvaluationAgeMs)
        fields["observedAtUptimeSeconds"] = String(now)
        fields["driverClosed"] = String(isClosed)
        fields["event"] = currentEvent; fields["reason"] = currentReason
        fields["sourceRejection"] = sourceRejection
        fields["cadenceRejection"] = cadenceRejection; fields["localRejection"] = localRejection
        fields["cycleInputSourceCaptureAgeSeconds"] = source.map { String(now - $0.interval.captureBoundaryEndTime) }
        func seconds(_ age: Duration?) -> String? {
            age.map { String(Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) }
        }
        fields["cycleInputSourceSampleAgeUpperBoundSeconds"] = seconds(source?.freshness.ageUpperBound(at: instant))
        fields["cadenceSampleAgeUpperBoundSeconds"] = seconds(cadenceInputProvider?()?.cadence?.sampleAgeUpperBound(at: instant))
        fields["deliverySampleAgeUpperBoundSeconds"] = seconds(deliveryInputProvider?()?.delivery.sampleAgeUpperBound(at: instant))
        // Keep current policy ownership, phase, source mapping and the latest
        // applied cause. Historical candidate detail yields first; a fuller
        // payload must not silently leave the UI displaying an older revision.
        func encode() -> Data? { try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) }
        var data = encode()
        if let size = data?.count, size > 4096 {
            fields["diagnosticCompacted"] = "true"
            let protected = Set(["appliedTransition", "observedAtUptimeSeconds", "sessionObservedAtUptimeSeconds",
                "sessionClosed", "sessionBusy", "driverClosed", "diagnosticCompacted",
                "timingProfileID", "decoderBudgetMilliseconds", "captureWindowMaximumAgeMilliseconds",
                "cadenceRejectionTiming", "recoveryCoverageSeconds", "reportMaximumAgeMilliseconds"])
            let removable = fields.keys.filter { !$0.hasPrefix("policy") && !protected.contains($0) }.sorted {
                let lhsHistory = $0.hasPrefix("lastCandidate") || $0.hasPrefix("lastMeasurement")
                let rhsHistory = $1.hasPrefix("lastCandidate") || $1.hasPrefix("lastMeasurement")
                if lhsHistory != rhsHistory { return lhsHistory }
                let lhsSize = $0.utf8.count + (fields[$0]?.utf8.count ?? 0)
                let rhsSize = $1.utf8.count + (fields[$1]?.utf8.count ?? 0)
                return lhsSize == rhsSize ? $0 < $1 : lhsSize > rhsSize
            }
            for key in removable {
                fields.removeValue(forKey: key)
                data = encode()
                if let size = data?.count, size <= 4096 { break }
            }
        }
        if let data, data.count <= 4096, let value = String(data: data, encoding: .utf8) {
            currentDiagnosticDidChange?(value)
        }
    }
    #endif
    /// Scheduling closes synchronously before joined actor/session teardown. All
    /// stop callers share the shielded task; an in-flight write cannot revive it.
    func cancel() {
        #if DEBUG
        currentDiagnosticDidChange = nil; candidateInputDiagnosticProvider = nil; currentCandidateDiagnostic = [:]; currentDeliveryDiagnostic = [:]; currentEvent = "stopped"; currentReason = nil; sourceRejection = nil
        #endif
        deliveryConsumer?.cancel(); owner.invalidateCandidateRecovery(); isClosed = true; appliedSettingsDidChange = nil; sourceEvaluationDidComplete = nil; deliveryInputProvider = nil; cadenceInputProvider = nil; candidateInputProvider = nil; task?.cancel() }
    func stop() async {
        if let shutdown { await shutdown.value; return }
        cancel()
        let work = task
        let finish = Task { [self] in
            await owner.stop()
            await work?.value
            await record("stopped", allowClosed: true)
            await liveDrain?.value
            deliveryConsumer?.close()
            if let deliveryExport, let data = try? deliveryConsumer?.auditData() { await deliveryExport(data) }
            if let export, let data = try? JSONSerialization.data(withJSONObject: qualityObject, options: [.sortedKeys]) {
                await export(data)
            }
        }
        shutdown = finish
        await finish.value
    }
    /// Live checkpoints and final export share the original policy-versioned object.
    private var qualityObject: [String: Any] {
        let recovery = transportLimits?.policy == .recoveryBudget
        var object: [String: Any] = ["formatVersion": recovery ? 6 : 4, "overflow": overflow,
            "deadlineFailuresEnabled": enableDeliveryFailures,
            "decoderStallEnabled": !enableDeliveryFailures || enableMeasuredSourceEvaluation,
            "measuredSourceEvaluationEnabled": enableMeasuredSourceEvaluation, "events": events]
        object["timingContract"] = timingProfile.evidence
        if recovery {
            object["transportPolicy"] = "recovery-budget-v1"
            object["evidenceDictionary"] = evidenceDictionary?.dictionary
        }
        return object
    }
    /// Retain only one in-flight write and the newest complete original prefix.
    /// In particular, disk I/O must never delay the short reset/candidate lease.
    /// The dictionaries contain immutable captured values; later appends use
    /// Array's value semantics without rewriting an earlier exported prefix.
    private func enqueueLiveCheckpoint(attemptID: UUID, closed: Bool) {
        guard let liveExport else { return }
        pendingLiveCheckpoint = ["formatVersion": 1, "mode": "repeated",
            "publishingAttemptID": attemptID.uuidString.lowercased(),
            "eventCount": events.count, "closed": closed, "quality": qualityObject]
        pendingLiveCheckpoint?["timingContract"] = timingProfile.evidence
        guard liveDrain == nil else { return }
        liveDrain = Task { [self] in
            while let checkpoint = pendingLiveCheckpoint {
                pendingLiveCheckpoint = nil
                if let data = try? JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys]) {
                    await liveExport(data)
                }
            }
            // No await separates the empty check and clearing the drain, so a
            // reentrant enqueue cannot lose its pending snapshot here.
            liveDrain = nil
        }
    }
    /// Scalar tracing is debug-only and adds no actor or I/O await. Source
    /// selectedAt is threaded from tick; cadence uses the current-provider read.
    private func diagnosticUptime() -> Double? {
        guard retainsDiagnosticHistory else { return nil }
        #if DEBUG
        return uptime()
        #else
        return nil
        #endif
    }
    private func evaluationCapture(selectedAt: Double?) -> EvaluationCapture? {
        guard retainsDiagnosticHistory else { return nil }
        #if DEBUG
        return .init(selectedAt: selectedAt, dispatchedAt: diagnosticUptime())
        #else
        return nil
        #endif
    }
    /// One invocation owns one slot, so a rejected call cannot borrow an older
    /// successful evaluation. The callback runs synchronously on the owner actor.
    private final class EvaluationCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PublishingQualitySession.EvaluationDiagnostic?
        private let selectedAt: Double?
        private let dispatchedAt: Double?
        init(selectedAt: Double?, dispatchedAt: Double?) {
            self.selectedAt = selectedAt; self.dispatchedAt = dispatchedAt
        }
        var observer: @Sendable (PublishingQualitySession.EvaluationDiagnostic) -> Void {
            { [self] value in lock.withLock { self.value = value } }
        }
        func rejected(at caughtAt: Double?) -> [String: Any] {
            let value = lock.withLock { self.value }
            var session: [String: Any]?
            if let value {
                var fields: [String: Any] = ["evaluatedAt": Self.scalar(value.evaluatedAt),
                    "sampleAgeSeconds": Self.scalar(value.sampleAgeSeconds), "sourceAgeSeconds": Self.scalar(value.sourceAgeSeconds),
                    "cadenceReceiptID": NSNull(), "sourceKey": NSNull()]
                switch value.input {
                case .cadence(let receiptID):
                    fields["kind"] = "cadence"; fields["cadenceReceiptID"] = receiptID.uuidString.lowercased()
                case .source(let key):
                    fields["kind"] = "source"
                    fields["sourceKey"] = ["workerEpoch": key.workerEpoch, "workerAttempt": key.workerAttempt,
                        "readerID": key.readerID, "sequence": String(key.sequence)]
                }
                session = fields
            }
            return ["selectedAt": Self.scalar(selectedAt), "dispatchedAt": Self.scalar(dispatchedAt),
                "caughtAt": Self.scalar(caughtAt), "session": session as Any? ?? NSNull()]
        }
        private static func scalar(_ value: Double?) -> Any {
            value.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull()
        }
    }
    private static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func reason(_ error: Error) -> String {
        if let error = error as? PublishingQualityTelemetry.Failure { return String(describing: error) }
        if let error = error as? QualityController.ValidationError { return String(describing: error) }
        if let error = error as? PublishingQualitySession.Failure { return String(describing: error) }
        return "unavailable"
    }
    private func record(_ kind: String, source: WorkerSourceIntervalObservation? = nil,
                        decision: QualityController.Decision? = nil, delivery: PublishingDeliveryObservation? = nil, cadence: WorkerDecoderCadenceFreshness? = nil, diagnostics: PublishingQualityTelemetry.Diagnostics? = nil,
                        candidate: PublishingCandidateAdmission? = nil,
                        advice: QualityController.Recommendation? = nil, reason: String? = nil, allowClosed: Bool = false,
                        evaluationDiagnostic: [String: Any]? = nil) async {
        #if DEBUG
        currentEvent = kind; currentReason = reason
        if source != nil { sourceRejection = kind == "rejected" ? reason : (kind == "transition" ? "transition" : nil) }
        #endif
        guard retainsDiagnosticHistory else { return }
        let state = await owner.snapshot
        guard allowClosed || (!isClosed && !Task.isCancelled) else { return }
        guard events.count < 512 else {
            overflow = true
            enqueueLiveCheckpoint(attemptID: state.attemptID, closed: kind == "stopped")
            return
        }
        var row: [String: Any] = ["kind": kind, "at": uptime(), "closed": state.isClosed]
        row["reason"] = reason
        row["evaluationDiagnostic"] = evaluationDiagnostic
        row["revision"] = state.revision.map(String.init)
        row["acknowledgedAt"] = state.acknowledgedAt
        row["profileID"] = state.applied?.profileID
        if let receipt = state.receipt { row["receipt"] = Self.receiptJSON(receipt) }
        if let receipt = state.profileReceipt { row["profileReceipt"] = Self.profileReceiptJSON(receipt) }
        if let application = state.application {
            row["application"] = ["id": application.id.uuidString, "admittedAt": application.admittedAt,
                "completionDeadline": application.completionDeadline,
                "attemptID": application.recommendation.attemptID.uuidString,
                "fromRevision": String(application.recommendation.appliedRevision),
                "windowSequence": String(application.recommendation.windowSequence),
                "candidateID": Self.optional(application.recommendation.candidateID?.uuidString)]
        }
        if let source {
            row["source"] = ["workerEpoch": source.workerEpoch, "workerAttempt": source.workerAttempt,
                "sequence": String(source.sequence), "previousSequence": String(source.previousSequence),
                "start": source.interval.captureBoundaryStartTime, "end": source.interval.captureBoundaryEndTime,
                "attemptID": source.interval.scope.publishingAttemptID.uuidString,
                "workerID": source.workerId, "readerID": source.publication.readerId, "processingScopeID": Self.optional(source.processing?.scopeID)]
        }
        if let cadence, let signal = state.lastDecoderStall {
            row["decoderStall"] = ["scopeID": cadence.snapshot.scopeID, "workerEpoch": cadence.workerEpoch,
                "workerID": cadence.workerId, "workerAttempt": cadence.attempt,
                "readerID": cadence.publication.readerId, "publishingAttemptID": cadence.publication.publishingAttemptId,
                "lastFreshPTS": String(cadence.snapshot.progress!.lastFreshPTS),
                "sequence": String(signal.sequence), "revision": String(signal.appliedRevision),
                "observedAtLowerBound": signal.observedAtLowerBound]
        }
        if let delivery, let signal = state.lastDeliveryFailure {
            let context = delivery.delivery.context
            let publication = (try? JSONEncoder().encode(context.publication))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            row["deliveryFailure"] = ["classifiedAt": delivery.classifiedAt,
                "deliveryReceiptID": delivery.delivery.receiptID.uuidString.lowercased(),
                "scopeID": delivery.delivery.snapshot.scopeID,
                "context": ["gameId": context.gameId, "generation": context.generation,
                    "workerId": context.workerId, "workerEpoch": context.workerEpoch, "attempt": context.attempt,
                    "publication": Self.optional(publication)],
                "publishingAttemptID": signal.attemptID.uuidString.lowercased(),
                "sequence": String(signal.sequence), "revision": String(signal.appliedRevision),
                "start": signal.start, "end": signal.end, "expectedFrames": signal.expectedFrames,
                "onTimeFrames": signal.onTimeFrames, "lateFrames": signal.lateFrames,
                "missingFrames": signal.missingFrames, "observedAtLowerBound": signal.observedAtLowerBound]
        }
        if let diagnostics, let window = state.lastWindow {
            row["evidence"] = Self.evidence(diagnostics, source: source, window: window)
        }
        if let candidate {
            #if DEBUG
            if let data = try? candidate.auditData(), let witness = try? JSONSerialization.jsonObject(with: data) {
                row["candidateAdmission"] = witness
            }
            #endif
            let value = candidate.value
            row["candidate"] = ["id": value.id.uuidString, "attemptID": value.attemptID.uuidString,
                "appliedRevision": String(value.appliedRevision), "baselineProfileID": value.baseline.profileID,
                "baselineVideoBitrate": value.baseline.videoBitrate, "profileID": value.settings.profileID,
                "videoBitrate": value.settings.videoBitrate, "measuredStart": value.measuredStart,
                "measuredEnd": value.measuredEnd, "evaluatedAt": value.evaluatedAt, "validUntil": value.validUntil,
                "candidateTransportBitsPerSecond": value.candidateTransportBitsPerSecond,
                "deliveredPaddingBitsPerSecond": value.deliveredPaddingBitsPerSecond]
        }
        if let decision {
            row["evaluatedAt"] = state.evaluatedAt
            row["state"] = String(describing: decision.state)
            row["reasons"] = decision.reasons.map { String(describing: $0) }
            if cadence == nil, delivery == nil, candidate == nil, let w = state.lastWindow {
                row["window"] = ["sequence": String(w.sequence), "revision": String(w.appliedRevision),
                    "start": w.start, "end": w.end, "captured": Self.optional(w.capturedFreshFrames),
                    "encoded": Self.optional(w.encodedFreshFrames), "received": Self.optional(w.receiver?.freshFrames),
                    "observedAt": Self.optional(w.receiver?.observedAt), "expected": Self.optional(w.sourceLoss?.expectedFrames),
                    "lost": Self.optional(w.sourceLoss?.lostFrames), "queue": Self.optional(w.meanQueueOccupancy),
                    "capacity": Self.optional(w.usableVideoCapacity), "connectivity": String(describing: w.connectivity),
                    "thermal": String(describing: w.thermalPressure),
                    "worker": String(describing: w.workerPressure), "transport": String(describing: w.transportPressure)]
            }
        }
        if let advice { row["action"] = ["kind": String(describing: advice.kind), "bitRate": advice.settings.videoBitrate,
            "profileID": advice.settings.profileID,
            "fromRevision": String(advice.appliedRevision), "validUntil": advice.validUntil,
            "candidateID": Self.optional(advice.candidateID?.uuidString)] }
        if transportLimits?.policy == .recoveryBudget {
            guard let encoded = evidenceDictionary?.encode(row) else {
                overflow = true
                enqueueLiveCheckpoint(attemptID: state.attemptID, closed: kind == "stopped")
                return
            }
            events.append(encoded)
        } else { events.append(row) }
        enqueueLiveCheckpoint(attemptID: state.attemptID, closed: kind == "stopped")
    }
    private static func profileReceiptJSON(_ receipt: PublishingVideoProfileChange) -> [String: Any] {
        func time(_ pts: CMTime) -> [String: Any] {
            ["value": String(pts.value), "timescale": pts.timescale, "epoch": String(pts.epoch), "flags": pts.flags.rawValue]
        }
        return ["profile": receipt.profile.rawValue, "publishingGeneration": String(receipt.publishingGeneration),
            "previousEncoderSessionID": receipt.previousEncoderSessionID.uuidString, "encoderSessionID": receipt.encoderSessionID.uuidString,
            "lastOldSourcePTS": time(receipt.lastOldSourcePTS), "firstNewSourcePTS": time(receipt.firstNewSourcePTS),
            "width": receipt.width, "height": receipt.height, "rawVideoFramesDropped": String(receipt.rawVideoFramesDropped),
            "acknowledgedAt": receipt.acknowledgedAt]
    }
    private static func receiptJSON(_ receipt: PublishingBitRateChange) -> [String: Any] {
        ["generation": String(receipt.publishingGeneration), "configurationID": receipt.configuration.id.uuidString,
         "encoderSessionID": receipt.configuration.encoderSessionID.uuidString, "bitRate": receipt.configuration.bitRate,
         "acceptedAt": receipt.acceptedAt,
         "lastSubmittedPTS": optional(receipt.lastSubmittedSourcePTS.map { ["value": String($0.value), "timescale": $0.timescale, "epoch": String($0.epoch), "flags": $0.flags.rawValue] as [String: Any] })]
    }
    static func transportEvidence(_ transport: PublishingTransportStatisticsSnapshot) -> [String: Any] {
        ["isClosed": transport.isClosed, "isQuarantined": transport.isQuarantined,
                "samples": transport.samples.map { s in ["sampledAt": s.sampledAt, "generation": String(s.publishingGeneration),
                    "elapsedMilliseconds": String(s.elapsedMilliseconds), "sentBytes": String(s.sentBytes),
                    "retransmittedBytes": String(s.retransmittedBytes), "droppedPackets": s.droppedPackets,
                    "rttMilliseconds": s.rttMilliseconds, "senderBufferMilliseconds": s.senderBufferMilliseconds,
                    "senderBufferedBytes": s.senderBufferedBytes,
                    "estimatedBandwidthMbps": s.estimatedBandwidthMbps,
                    "senderDeliveryDelayMilliseconds": optional(s.senderDeliveryDelayMilliseconds),
                    "senderMaximumBandwidthMbps": optional(s.senderMaximumBandwidthMbps),
                    "packetSendPeriodMicroseconds": optional(s.packetSendPeriodMicroseconds)] as [String: Any] }]
    }
    private static func evidence(_ d: PublishingQualityTelemetry.Diagnostics, source: WorkerSourceIntervalObservation?, window: QualityController.Window) -> [String: Any] {
        var result: [String: Any] = [
            "thermal": ["isClosed": d.thermal.isClosed, "isQuarantined": d.thermal.isQuarantined,
                "samples": d.thermal.samples.map { ["sampledAt": $0.sampledAt, "state": $0.state.rawValue] as [String: Any] }],
            "transport": transportEvidence(d.transport),
            "processing": NSNull(), "queue": NSNull()]
        if let processing = source?.processing, let data = try? JSONEncoder().encode(processing),
           let json = try? JSONSerialization.jsonObject(with: data) { result["processing"] = json }
        if let ingress = d.ingress {
            let scope = ingress.scope, p = ingress.pressure
            let first = source == nil ? 0 : p.states.lastIndex(where: { $0.at <= window.start }) ?? 0
            let states = p.states.dropFirst(first).prefix(while: { source == nil || $0.at < window.end })
            result["queue"] = ["isClosed": ingress.isClosed || p.isClosed, "isQuarantined": p.isQuarantined,
                "coveredThrough": p.coveredThrough,
                "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                    "broadcastGeneration": scope.broadcastGeneration, "publishingAttemptID": scope.publishingAttemptID.uuidString,
                    "appliedProfileRevision": String(scope.appliedProfileRevision)],
                "states": states.map { ["at": $0.at, "itemFraction": $0.itemFraction, "byteFraction": $0.byteFraction, "phase": $0.phase.rawValue] as [String: Any] }]
        }
        if source == nil {
            result["local"] = ["isPublishing": d.isPublishing, "clockGeneration": optional(d.clock.map { String($0.publishingGeneration) }),
                "receipt": optional(d.receipt.map(receiptJSON)), "ingressClosed": d.ingress?.isClosed ?? true]
        }
        return result
    }
    #if DEBUG
    static func repeatedLiveExportRequested(environment: [String: String]) throws -> Bool {
        guard environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] == "repeated" else { return false }
        guard try NativeMeasuredTrialFixture.requested(environment: environment),
              try NativeBandwidthProbePublisher.requested(environment: environment) == .repeated else {
            throw VideoObservationFixture.UplinkError.invalidFixtureRoute
        }
        return true
    }
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private static func persistLiveCheckpoint(_ data: Data) async {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("quality-control-live.json"), options: .atomic)
            } catch { /* Missing evidence cannot qualify or own recording. */ }
        }.value
    }
    #endif
    /// Initial qualification ladder; larger profiles use the same measured path
    /// once separately qualified. No 4K support is inferred from this definition.
    nonisolated static let productionProfiles: [QualityController.Profile] = [
        .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
        .init(id: "360p30", width: 640, height: 360, minimumBitrate: 600_000, maximumBitrate: 600_000),
        .init(id: "720p30", width: 1280, height: 720, minimumBitrate: 3_000_000, maximumBitrate: 3_000_000),
        .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
    ]
    nonisolated static let productionUHDProfiles = productionProfiles + [
        QualityController.Profile(id: "2160p30", width: 3840, height: 2160,
            minimumBitrate: 24_000_000, maximumBitrate: 24_000_000)
    ]
    static func productionWorkerLimits(_ source: WorkerSourceIntervalObservation) -> PublishingQualityTelemetry.WorkerLimits? {
        guard let encoder = source.processing?.encoder else { return nil }
        // The telemetry evaluator still validates the authenticated publication,
        // processing scope, sequences and completed frame interval.
        return .init(encoder: encoder, maximumFilterMs: 250, maximumProcessingMs: 1000)
    }
    static func production(session: PublishingSession, attemptID: UUID,
        profiles: [QualityController.Profile] = productionProfiles) throws -> PublishingQualityDriver? {
        guard session.snapshot.ingressObservation != nil else { return nil }
        // Broadcast recovery needs room for encoder, SRT and worker buffering.
        // This is a deadline allowance, not an inserted delay. Report freshness,
        // stall detection and local transport pressure remain independent.
        let timing: StreamingTimingProfile = .broadcastReliability3000V3
        let appliedTransitionExport: (@Sendable (Data) async -> Void)?
        #if DEBUG
        appliedTransitionExport = { data in PublishingAppliedTransitionAudit.persist(data, attemptID: attemptID) }
        #else
        appliedTransitionExport = nil
        #endif
        let owner = try PublishingQualitySession(session: session, profiles: profiles, attemptID: attemptID,
            initial: .init(profileID: "240p30", videoBitrate: 350_000), strategy: .measuredCandidateTrials,
            behavior: .progressive, requiresSharedCandidateRecovery: true, usesGuardedMutations: true, timingProfile: timing,
            appliedTransitionExport: appliedTransitionExport)
        return .init(owner: owner, timingProfile: timing, workerLimits: nil,
            workerLimitsProvider: productionWorkerLimits,
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500,
                maximumRetransmittedFraction: 0.01, policy: .recoveryBudget),
            retainsDiagnosticHistory: false,
            deliveryConsumer: .continuous(try .init(latencyBudget: timing.decoderBudget,
                maximumSampleAge: timing.maximumCadenceDeliveryReportAge, usesRequestTiming: true)),
            enableDeliveryFailures: true, enableMeasuredSourceEvaluation: true)
    }
    static func standard(session: PublishingSession, attemptID: UUID) throws -> PublishingQualityDriver? {
        #if DEBUG && targetEnvironment(simulator)
        let fixture = try fixture(session: session, attemptID: attemptID)
        if VideoObservationFixture.requested(environment: ProcessInfo.processInfo.environment) { return fixture }
        #endif
        return try production(session: session, attemptID: attemptID)
    }

    static func fixture(session: PublishingSession, attemptID: UUID) throws -> PublishingQualityDriver? {
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        let timingProfile = try VideoObservationFixture.timingProfile(environment: environment)
        let measured = try NativeMeasuredTrialFixture.requested(environment: environment)
        let probePolicy = try NativeMeasuredTrialFixture.probePolicy(environment: environment)
        let ownedMeasurement = try NativeOwnedCandidatePublisher.requested(environment: environment)
        let liveCheckpoint = try repeatedLiveExportRequested(environment: environment) || ownedMeasurement
        let deliveryLatencyBudget = try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: environment)
        let requestedDeliveryFailures = try PublishingDeliveryMonitor.fixtureResetsRequested(environment: environment)
        let enableDeliveryFailures = measured || requestedDeliveryFailures
        let resetStall = environment["SCOREBUG_TEST_DECODER_STALL"] == "reset540"
        let minimumStall = (environment["SCOREBUG_TEST_DECODER_STALL"] == "1" || resetStall)
            && WorkerCadenceReportAudit.requested(environment: environment)
        guard measured || environment["SCOREBUG_TEST_NATIVE_QUALITY"] == "1" || minimumStall,
              VideoObservationFixture.requested(environment: environment) else { return nil }
        let adaptive = try NativeProfileTransitionEvidence.adaptiveRequested(environment: environment)
        let profiles: [QualityController.Profile] = measured ? [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "360p30", width: 640, height: 360, minimumBitrate: 600_000, maximumBitrate: 600_000)
        ] : resetStall ? [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000)
        ] : minimumStall ? [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000)
        ] : adaptive ? [
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
        ] : [.init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)]
        let owner = try PublishingQualitySession(session: session,
            profiles: profiles, attemptID: attemptID,
            initial: .init(profileID: resetStall ? "540p30" : (minimumStall || measured) ? "240p30" : "1080p30", videoBitrate: resetStall ? 1_500_000 : (minimumStall || measured) ? 350_000 : 6_000_000),
            strategy: measured ? .measuredCandidateTrials : adaptive ? .receiverValidatedProfileTrials : .receiverValidatedTrials,
            behavior: (minimumStall || measured) ? .progressive : .legacy,
            requiresSharedCandidateRecovery: liveCheckpoint,
            usesGuardedMutations: ownedMeasurement, timingProfile: timingProfile)
        return .init(owner: owner, timingProfile: timingProfile,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01, policy: probePolicy == .recoveryBudget ? .recoveryBudget : .senderDelay),
            deliveryAudit: (minimumStall || measured) ? try PublishingDeliveryMonitor.Audit(latencyBudget: deliveryLatencyBudget, maximumSampleAge: timingProfile.maximumCadenceDeliveryReportAge, usesRequestTiming: true, environment: environment, timingProfile: timingProfile) : nil,
            deliveryExport: (minimumStall || measured) ? { await PublishingDeliveryMonitor.Audit.persist($0) } : nil,
            enableDeliveryFailures: enableDeliveryFailures, enableMeasuredSourceEvaluation: measured,
            liveExport: liveCheckpoint ? { await Self.persistLiveCheckpoint($0) } : nil,
            export: { data in
                await Task.detached {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Scorebug/QA", isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: directory.appendingPathComponent("quality-control.json"), options: .atomic)
                }.value
            })
        #else
        return nil
        #endif
    }

}

import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// One Session-issued measurement. This object never changes policy or starts a
/// successor; its terminal callback follows actual native and candidate joins.
actor PublishingOwnedMeasurementLease {
    struct SourceCoverage: Sendable {
        let sequence: UInt64
        let start: Double, end: Double, observedAt: Double
        #if DEBUG
        var object: [String: Any] { ["sequence": String(sequence), "start": start, "end": end, "observedAt": observedAt] }
        #endif
    }
    private let sourceCoverage: @Sendable (QualityController.CandidateMeasurementAttempt) async -> SourceCoverage?
    private let sourceDeadline = ProcessInfo.processInfo.systemUptime + QualityController.maximumWindowDuration + 2
    nonisolated let id = UUID()
    #if DEBUG
    private nonisolated let audit: PublishingOwnedMeasurementAudit?
    #endif
    nonisolated let token: QualityController.CandidateMeasurementAttempt
    nonisolated let context: PublishingQualitySession.CandidateMeasurementContext
    private let publisher: NativeOwnedCandidatePublisher
    private let probes: NativeOwnedCandidatePublisher.Probes
    private let diagnostic: QualityController.CandidateMeasurementDiagnostic
    private let predecessor: PublishingBandwidthProbeRetirement?
    private let candidate: NativeCandidateAttempt
    private nonisolated let authority = Authority()
    private var work: Task<Void, Never>?
    private var allocation: Task<PublishingBandwidthProbeOperation, Error>?
    private var operation: PublishingBandwidthProbeOperation?
    private var nativeContext: PublishingBandwidthProbeContext?
    private var sample: PublishingBandwidthProbeSnapshot?
    private var binding: PublishingProbeObservation?
    private var boundAt: Double?
    private var completedAt: Double?
    private var cost: PublishingCandidateCost?
    private var keeper: Task<Void, Never>?
    private var retirement: PublishingBandwidthProbeRetirement?
    private var joined = false
    private var pressure: NativeCandidatePressure?
    #if DEBUG
    nonisolated func record(_ kind: String, fields: @autoclosure () -> [String: Any] = [:]) {
        guard let audit else { return }
        audit.record(kind, owner: id, registeredAt: token.registeredAt, revision: token.readiness.appliedRevision, fields: fields())
    }
    #endif

    private final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        private var candidateID: UUID?, probeID: UUID?
        func bind(candidate: UUID, probe: UUID) { lock.withLock { if !revoked { candidateID = candidate; probeID = probe } } }
        func permits(candidate: UUID, probe: UUID) -> Bool { lock.withLock { !revoked && candidateID == candidate && probeID == probe } }
        private var work: Task<Void, Never>?
        var active: Bool { lock.withLock { !revoked } }
        func install(_ work: Task<Void, Never>) {
            let cancelled = lock.withLock { self.work = work; return revoked }
            if cancelled { work.cancel() }
        }
        func revoke() {
            let work = lock.withLock { revoked = true; return self.work }
            work?.cancel()
        }
    }
    init(token: QualityController.CandidateMeasurementAttempt, context: PublishingQualitySession.CandidateMeasurementContext,
         publisher: NativeOwnedCandidatePublisher, probes: NativeOwnedCandidatePublisher.Probes,
         predecessor: PublishingBandwidthProbeRetirement?, diagnostic: QualityController.CandidateMeasurementDiagnostic,
         sourceCoverage: @escaping @Sendable (QualityController.CandidateMeasurementAttempt) async -> SourceCoverage?) throws {
        guard let target = PublishingVideoProfile(rawValue: context.readiness.settings.profileID),
              target.bitRate == context.readiness.settings.videoBitrate else { throw PublishingQualitySession.Failure.unsupportedProfile }
        self.token = token; self.context = context; self.publisher = publisher; self.probes = probes; self.predecessor = predecessor; self.retirement = predecessor
        #if DEBUG
        self.audit = publisher.audit
        #endif
        self.diagnostic = diagnostic; self.sourceCoverage = sourceCoverage
        let owner = publisher.campaignOwner, generation = context.applied.receipt.publishingGeneration, scope = context.scope
        candidate = NativeCandidateAttempt(operations: .init(begin: { _ in
            try await owner.begin(scope: scope, profile: target, publishingGeneration: generation).id
        }, offer: { owner.offer($0, id: $1) }, cancel: { owner.cancel(id: $0, reason: $1) },
        result: { await owner.result(id: $0) }, retire: { await owner.retire(id: $0, reason: $1) }))
    }
    nonisolated func permits(_ admission: PublishingCandidateAdmission) -> Bool {
        authority.permits(candidate: admission.value.id, probe: admission.probe.id)
    }
    nonisolated var isActive: Bool { authority.active }
    nonisolated func revoke() { authority.revoke(); candidate.cancel(.ownerChanged) }
    func start(policy: PublishingBandwidthProbeSnapshot.Policy,
               completed: @escaping @Sendable (PublishingOwnedMeasurementLease) async -> Void) {
        guard work == nil else { return }
        #if DEBUG
        record("registered", fields: ["baselineProfile": context.applied.settings.profileID,
            "baselineBitRate": context.applied.settings.videoBitrate, "targetProfile": context.readiness.settings.profileID,
            "targetBitRate": context.readiness.settings.videoBitrate, "receipt": PublishingOwnedMeasurementAudit.receipt(context.applied.receipt),
            "healthySince": context.readiness.healthySince, "healthyThrough": context.readiness.healthyThrough,
            "healthSequence": String(context.readiness.healthSequence), "readinessValidUntil": context.readiness.validUntil,
            "policy": policy.rawValue, "policyDiagnostic": PublishingOwnedMeasurementAudit.diagnostic(diagnostic)])
        #endif
        let task = Task { [self] in
            do { try await run(policy: policy) } catch {
                #if DEBUG
                record("failed", fields: ["reason": String(describing: error)])
                #endif
                revoke()
            }
            await cleanup()
            await completed(self)
        }
        work = task; authority.install(task)
    }
    func join() async { await work?.value }
    func joinedRetirement() -> (Bool, PublishingBandwidthProbeRetirement?) { (joined, retirement) }
    private func check() throws {
        try Task.checkCancellation()
        guard isActive else { throw PublishingQualitySession.Failure.staleAdvice }
    }
    private func allocate(in context: PublishingBandwidthProbeContext, after prior: PublishingBandwidthProbeRetirement?,
                          rate: Int, policy: PublishingBandwidthProbeSnapshot.Policy, replacement: Bool) async throws {
        #if DEBUG
        record("allocationRequested", fields: ["kindOfAllocation": replacement ? "replace" : prior == nil ? "begin" : "restart", "bitRate": rate,
            "predecessor": prior?.terminalSnapshot.map(PublishingOwnedMeasurementAudit.snapshot) as Any? ?? NSNull()])
        #endif
        let task = Task { [probes] in
            if let prior {
                return try await replacement ? probes.replace(prior, context, rate) : probes.restart(prior, context, rate)
            }
            return try await probes.begin(context, rate, policy)
        }
        allocation = task
        let returned: PublishingBandwidthProbeOperation
        do { returned = try await task.value }
        catch {
            #if DEBUG
            record("allocationRejected", fields: ["reason": String(describing: error)])
            #endif
            throw error
        }
        operation = returned // Retain the exact handle before cancellation or validation.
        allocation = nil
        try check()
        sample = try await returned.value()
        #if DEBUG
        record("allocated", fields: ["snapshot": PublishingOwnedMeasurementAudit.snapshot(sample!)])
        #endif
        try check()
    }
    private func renew() async throws {
        try check()
        guard let operation else { throw PublishingQualitySession.Failure.notReady }
        #if DEBUG
        record("renewalRequested", fields: ["snapshot": sample.map(PublishingOwnedMeasurementAudit.snapshot) as Any? ?? NSNull()])
        #endif
        let renewed: PublishingBandwidthProbeSnapshot
        do { renewed = try await operation.renew() }
        catch {
            #if DEBUG
            record("renewalRejected", fields: ["reason": String(describing: error)])
            #endif
            throw error
        }
        sample = renewed
        let currentPressure = pressure == nil ? nil : publisher.pressure
        #if DEBUG
        record("renewed", fields: ["snapshot": PublishingOwnedMeasurementAudit.snapshot(renewed),
            "pressure": currentPressure?.object as Any? ?? NSNull()])
        #endif
        try check()
        if let pressure {
            guard let current = currentPressure, current.valid, current.dropped == pressure.dropped,
                  current.rejected == pressure.rejected, current.observedAt >= pressure.observedAt else {
                throw PublishingQualitySession.Failure.staleAdvice
            }
        }
    }
    private func hold(for duration: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
            try await renew()
        }
    }
    // Use observed source progress to schedule collection from the lower-rate
    // stage. This grants no admission authority and does not extend evidence age.
    private func awaitNextSourceCoverage() async throws {
        #if DEBUG
        record("sourceWaitStarted", fields: ["deadline": sourceDeadline])
        #endif
        while true {
            try check()
            guard ProcessInfo.processInfo.systemUptime < sourceDeadline else {
                #if DEBUG
                record("sourceWaitTimedOut")
                #endif
                throw PublishingQualitySession.Failure.staleAdvice
            }
            if let coverage = await sourceCoverage(token) {
                try check()
                guard ProcessInfo.processInfo.systemUptime < sourceDeadline else {
                    #if DEBUG
                    record("sourceWaitTimedOut")
                    #endif
                    throw PublishingQualitySession.Failure.staleAdvice
                }
                #if DEBUG
                record("sourceReady", fields: ["source": coverage.object])
                #endif
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            try await renew()
        }
    }
    private func run(policy: PublishingBandwidthProbeSnapshot.Policy) async throws {
        #if DEBUG
        record("contextRequested")
        #endif
        let selected = try await probes.capture(context.applied.receipt)
        #if DEBUG
        record("contextCaptured", fields: ["receipt": PublishingOwnedMeasurementAudit.receipt(context.applied.receipt),
            "scope": NativeCandidateFixture.scope(context.scope), "publishingGeneration": String(context.clock.publishingGeneration)])
        #endif
        nativeContext = selected
        try check()
        let plan = publisher.stagePlan
        try await allocate(in: selected, after: predecessor, rate: plan.bitRates[0], policy: policy, replacement: false)
        for index in 1..<plan.bitRates.count {
            try await hold(for: plan.holds[index - 1])
            if index == plan.bitRates.count - 1 { try await awaitNextSourceCoverage() }
            let rate = plan.bitRates[index]
            guard let operation else { throw PublishingQualitySession.Failure.notReady }
            #if DEBUG
            record("retirementRequested", fields: ["snapshot": sample.map(PublishingOwnedMeasurementAudit.snapshot) as Any? ?? NSNull()])
            #endif
            let retired = try await operation.retire()
            retirement = retired
            #if DEBUG
            record("retired", fields: ["snapshot": retired.terminalSnapshot.map(PublishingOwnedMeasurementAudit.snapshot) as Any? ?? NSNull()])
            #endif
            try check()
            try await allocate(in: selected, after: retired, rate: rate, policy: policy, replacement: true)
        }
        if plan.bitRates.count == 1 { try await awaitNextSourceCoverage() }
        try await hold(for: plan.holds[plan.holds.count - 1])
        guard let sample else { throw PublishingQualitySession.Failure.notReady }
        binding = PublishingProbeObservation(sample); boundAt = ProcessInfo.processInfo.systemUptime
        guard let pressure = publisher.pressure, pressure.valid else { throw PublishingQualitySession.Failure.notReady }
        self.pressure = pressure
        #if DEBUG
        record("candidateBound", fields: ["snapshot": PublishingOwnedMeasurementAudit.snapshot(sample), "boundAt": boundAt!, "pressure": pressure.object])
        #endif
        publisher.installCandidate(candidate)
        // No stage replacement is reachable after the binding above.
        keeper = Task { [self] in
            do { try await hold(for: 9) } catch { revoke() }
        }
        #if DEBUG
        record("candidateStartRequested")
        #endif
        try await candidate.start()
        #if DEBUG
        record("candidateStarted")
        #endif
        let result = await candidate.result()
        let finalPressure = publisher.pressure
        #if DEBUG
        if audit != nil, let result, let object = try? JSONSerialization.jsonObject(with: NativeCandidateFixture.data(result)) {
            record("candidateJoined", fields: ["measurement": object, "pressure": finalPressure?.object as Any? ?? NSNull()])
        }
        #endif
        try check()
        guard let finalPressure, finalPressure.valid, finalPressure.dropped == pressure.dropped,
              finalPressure.rejected == pressure.rejected, finalPressure.observedAt >= pressure.observedAt else {
            throw PublishingQualitySession.Failure.staleAdvice
        }
        guard let result, let value = PublishingCandidateCost(result), value.startedAt >= boundAt!,
              value.endedAt <= ProcessInfo.processInfo.systemUptime else { throw PublishingQualitySession.Failure.staleAdvice }
        cost = value; completedAt = ProcessInfo.processInfo.systemUptime
        authority.bind(candidate: value.id, probe: sample.id)
        try await Task.sleep(for: .seconds(2))
        revoke()
    }
    func validateForApplication() async throws {
        try check()
        guard let nativeContext else { throw PublishingQualitySession.Failure.notReady }
        try await probes.validate(nativeContext)
        try check()
    }
    func snapshot() -> NativeCandidateSnapshot? {
        guard isActive, let cost, let binding, let sample, let boundAt, let completedAt,
              sample.id == binding.id, sample.stage == publisher.stagePlan.finalStage,
              ProcessInfo.processInfo.systemUptime - cost.endedAt <= 2 else { return nil }
        let current = PublishingProbeObservation(sample), authority = authority
        guard current.isActive(at: ProcessInfo.processInfo.systemUptime) else { return nil }
        return .init(cost: cost, binding: binding, probe: current, boundAt: boundAt, completedAt: completedAt,
            permitsCurrentCandidate: { id in id == cost.id && authority.active })
    }
    func probeObservation() -> PublishingProbeObservation? {
        guard isActive, let sample else { return nil }
        return PublishingProbeObservation(sample)
    }
    private func cleanup() async {
        revoke()
        keeper?.cancel(); await keeper?.value
        if let allocation, let returned = try? await allocation.value { operation = returned }
        candidate.cancel(.ownerChanged)
        await candidate.retire()
        #if DEBUG
        record("candidateRetired")
        #endif
        publisher.removeCandidate(candidate)
        if let operation {
            #if DEBUG
            record("retirementRequested", fields: ["snapshot": sample.map(PublishingOwnedMeasurementAudit.snapshot) as Any? ?? NSNull()])
            #endif
            do {
                retirement = try await operation.retire(); joined = true
                #if DEBUG
                record("retired", fields: ["snapshot": retirement?.terminalSnapshot.map(PublishingOwnedMeasurementAudit.snapshot) as Any? ?? NSNull()])
                #endif
            } catch {
                joined = false
                #if DEBUG
                record("cleanupFailed", fields: ["reason": String(describing: error)])
                #endif
            }
        } else { joined = true }
        #if DEBUG
        if joined { record("cleanupJoined") }
        #endif
    }
}

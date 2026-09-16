import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia

/// Coalesces the existing health loop; never runs on capture callbacks.
@MainActor final class PublishingQualityDriver {
    private let owner: PublishingQualitySession
    private let workerLimits: PublishingQualityTelemetry.WorkerLimits?
    private let transportLimits: PublishingQualityTelemetry.TransportLimits?
    private let uptime: () -> Double
    private var task: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private let export: ((Data) async -> Void)?
    private var events: [[String: Any]] = []
    private var overflow = false
    private var consumed: String?
    private var noted: String?
    private var localRejection: String?
    private(set) var isClosed = false
    private(set) var bootstrapCount = 0
    init(owner: PublishingQualitySession, workerLimits: PublishingQualityTelemetry.WorkerLimits?,
         transportLimits: PublishingQualityTelemetry.TransportLimits?, uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, export: ((Data) async -> Void)? = nil) {
        self.owner = owner; self.workerLimits = workerLimits; self.transportLimits = transportLimits; self.uptime = uptime; self.export = export
    }
    @discardableResult func tick(encoderReady: Bool, source: WorkerSourceIntervalObservation?, diagnostics: PublishingQualityTelemetry.Diagnostics) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        if let task { return task }
        task = Task { [self] in
            defer { task = nil }
            await cycle(encoderReady: encoderReady, source: source, diagnostics: diagnostics)
        }
        return task
    }
    private func cycle(encoderReady: Bool, source: WorkerSourceIntervalObservation?, diagnostics: PublishingQualityTelemetry.Diagnostics) async {
        do {
            let state = await owner.snapshot
            try Task.checkCancellation()
            guard !isClosed else { return }
            if state.applied == nil {
                guard encoderReady else { return }
                try await owner.bootstrap()
                try Task.checkCancellation()
                guard !isClosed else { return }
                bootstrapCount += 1
                await record("bootstrap")
                return
            }
            if let rollback = try await owner.checkTrialDeadline() {
                try await apply(rollback)
                return
            }
            if let source, try await evaluateSource(source, state: state, diagnostics: diagnostics) { return }
            let decision: QualityController.Decision?
            do {
                decision = try await owner.evaluateLocalPressure(diagnostics: diagnostics, transportLimits: transportLimits)
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
            guard !isClosed, let decision else { return }
            await record("localPressure", decision: decision, diagnostics: diagnostics)
            if let advice = decision.recommendation { try await apply(advice) }
        } catch {
            guard !isClosed, !Task.isCancelled else { return }
            isClosed = true
            await owner.stop()
            await record("failed", reason: "native-change-failed", allowClosed: true)
        }
    }
    private func evaluateSource(_ source: WorkerSourceIntervalObservation, state: PublishingQualitySession.Snapshot,
                                diagnostics: PublishingQualityTelemetry.Diagnostics) async throws -> Bool {
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
        if let processing = source.processing, processing.interval.pendingFrames > 0,
           uptime() - source.interval.captureBoundaryEndTime < 2 { return false }
        consumed = key
        let decision: QualityController.Decision
        do {
            decision = try await owner.evaluate(source: source, diagnostics: diagnostics,
                workerLimits: workerLimits, transportLimits: transportLimits)
        } catch {
            if !isClosed && !Task.isCancelled { await record("rejected", source: source, reason: Self.reason(error)) }
            return false
        }
        try Task.checkCancellation()
        guard !isClosed else { return true }
        localRejection = nil
        await record("evaluated", source: source, decision: decision, diagnostics: diagnostics)
        if let advice = decision.recommendation { try await apply(advice, source: source) }
        return true
    }
    func apply(_ advice: QualityController.Recommendation, source: WorkerSourceIntervalObservation? = nil) async throws {
        do {
            try await owner.apply(advice)
            await record("applied", source: source, advice: advice)
        } catch PublishingQualitySession.Failure.staleAdvice {
            // Rejected before dispatch: a late recommendation must not retire live.
            await record("skipped", source: source, advice: advice, reason: "staleAdvice")
        }
    }
    /// Scheduling closes synchronously before joined actor/session teardown. All
    /// stop callers share the shielded task; an in-flight write cannot revive it.
    func cancel() { isClosed = true; task?.cancel() }
    func stop() async {
        if let shutdown { await shutdown.value; return }
        cancel()
        let work = task
        let finish = Task { [self] in
            await owner.stop()
            await work?.value
            await record("stopped", allowClosed: true)
            if let export, let data = try? JSONSerialization.data(withJSONObject:
                ["formatVersion": 2, "overflow": overflow, "events": events], options: [.sortedKeys]) {
                await export(data)
            }
        }
        shutdown = finish
        await finish.value
    }
    private static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func reason(_ error: Error) -> String {
        if let error = error as? PublishingQualityTelemetry.Failure { return String(describing: error) }
        if let error = error as? QualityController.ValidationError { return String(describing: error) }
        return "unavailable"
    }
    private func record(_ kind: String, source: WorkerSourceIntervalObservation? = nil,
                        decision: QualityController.Decision? = nil, diagnostics: PublishingQualityTelemetry.Diagnostics? = nil,
                        advice: QualityController.Recommendation? = nil, reason: String? = nil, allowClosed: Bool = false) async {
        let state = await owner.snapshot
        guard allowClosed || (!isClosed && !Task.isCancelled) else { return }
        guard events.count < 512 else { overflow = true; return }
        var row: [String: Any] = ["kind": kind, "at": uptime(), "closed": state.isClosed]
        row["reason"] = reason
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
                "windowSequence": String(application.recommendation.windowSequence)]
        }
        if let source {
            row["source"] = ["workerEpoch": source.workerEpoch, "workerAttempt": source.workerAttempt,
                "sequence": String(source.sequence), "previousSequence": String(source.previousSequence),
                "start": source.interval.captureBoundaryStartTime, "end": source.interval.captureBoundaryEndTime,
                "attemptID": source.interval.scope.publishingAttemptID.uuidString,
                "workerID": source.workerId, "readerID": source.publication.readerId, "processingScopeID": Self.optional(source.processing?.scopeID)]
        }
        if let diagnostics, let window = state.lastWindow {
            row["evidence"] = Self.evidence(diagnostics, source: source, window: window)
        }
        if let decision {
            row["evaluatedAt"] = state.evaluatedAt
            row["state"] = String(describing: decision.state)
            row["reasons"] = decision.reasons.map { String(describing: $0) }
            if let w = state.lastWindow {
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
            "fromRevision": String(advice.appliedRevision), "validUntil": advice.validUntil] }
        events.append(row)
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
         "lastSubmittedPTS": optional(receipt.lastSubmittedSourcePTS.map { ["value": String($0.value), "timescale": $0.timescale] as [String: Any] })]
    }
    private static func evidence(_ d: PublishingQualityTelemetry.Diagnostics, source: WorkerSourceIntervalObservation?, window: QualityController.Window) -> [String: Any] {
        var result: [String: Any] = [
            "thermal": ["isClosed": d.thermal.isClosed, "isQuarantined": d.thermal.isQuarantined,
                "samples": d.thermal.samples.map { ["sampledAt": $0.sampledAt, "state": $0.state.rawValue] as [String: Any] }],
            "transport": ["isClosed": d.transport.isClosed, "isQuarantined": d.transport.isQuarantined,
                "samples": d.transport.samples.map { s in ["sampledAt": s.sampledAt, "generation": String(s.publishingGeneration),
                    "elapsedMilliseconds": String(s.elapsedMilliseconds), "sentBytes": String(s.sentBytes),
                    "retransmittedBytes": String(s.retransmittedBytes), "droppedPackets": s.droppedPackets,
                    "rttMilliseconds": s.rttMilliseconds, "senderBufferMilliseconds": s.senderBufferMilliseconds] as [String: Any] }],
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
    static func fixture(session: PublishingSession, attemptID: UUID) throws -> PublishingQualityDriver? {
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCOREBUG_TEST_NATIVE_QUALITY"] == "1",
              VideoObservationFixture.requested(environment: environment) else { return nil }
        let adaptive = try NativeProfileTransitionEvidence.adaptiveRequested(environment: environment)
        let profiles: [QualityController.Profile] = adaptive ? [
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
        ] : [.init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)]
        let owner = try PublishingQualitySession(session: session,
            profiles: profiles, attemptID: attemptID, initial: .init(profileID: "1080p30", videoBitrate: 6_000_000),
            strategy: adaptive ? .receiverValidatedProfileTrials : .receiverValidatedTrials)
        return .init(owner: owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
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

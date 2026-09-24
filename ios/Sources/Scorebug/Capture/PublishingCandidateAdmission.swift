import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Revocable identity of the authenticated receiver publication/probe. The model
/// retires this token when coverage or its locally selected owner changes.
final class PublishingCandidateAuthority: @unchecked Sendable {
    let expected: WorkerReceiverProbeExpectation
    let publication: WorkerPublication
    let workerEpoch: String
    let workerAttempt: Int
    private let lock = NSLock()
    private var active = true
    init(_ evidence: WorkerReceiverProbeFreshness) {
        expected = evidence.expected; publication = evidence.publication
        workerEpoch = evidence.workerEpoch; workerAttempt = evidence.workerAttempt
    }
    func revoke() { lock.withLock { active = false } }
    func permits(_ evidence: WorkerReceiverProbeFreshness) -> Bool {
        lock.withLock {
            active && expected == evidence.expected && publication == evidence.publication &&
                workerEpoch == evidence.workerEpoch && workerAttempt == evidence.workerAttempt
        }
    }
}

/// A current join of independently measured load, delivered padding, and native
/// ownership. Core separately qualifies healthy media coverage and recovery time.
struct PublishingCandidateAdmission: Sendable {
    struct Measurement: Sendable {
        let id: UUID
        let scope: VideoFrameObservationScope
        let profile: PublishingVideoProfile
        let publishingGeneration: UInt64
        let startedAt: Double
        let endedAt: Double
        let firstInputAt: Double
        let lastInputAt: Double
        let sourceDuration: Double
        let submissionDuration: Double
        let transportBytes: Int
        let transportMessageCount: Int
    }
    /// Uptime reads bracket a ContinuousClock sample; neither clock is treated as
    /// wall time and cached remote evidence never receives a new observation time.
    struct Clock: Sendable {
        let before: Double
        let instant: ContinuousClock.Instant
        let after: Double
        func bounds(_ value: ClosedRange<ContinuousClock.Instant>) -> ClosedRange<Double> {
            let lower = before + Self.seconds(instant.duration(to: value.lowerBound))
            let upper = after + Self.seconds(instant.duration(to: value.upperBound))
            return lower...upper
        }
        static func seconds(_ value: Duration) -> Double {
            let parts = value.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        static func sample() -> Self {
            let before = ProcessInfo.processInfo.systemUptime
            let instant = ContinuousClock.now
            return .init(before: before, instant: instant, after: ProcessInfo.processInfo.systemUptime)
        }
    }
    let value: QualityController.CandidateAdmission
    let applied: PublishingQualityTelemetry.Applied
    let authority: PublishingCandidateAuthority
    let receiver: WorkerReceiverProbeFreshness
    let probe: PublishingProbeObservation
    private let currentReceipt: @Sendable () -> PublishingBitRateChange?
    private let candidateIsCurrent: @Sendable () -> Bool
    #if DEBUG
    private struct AuditWitness: Sendable {
        let measurement: Measurement
        let binding: PublishingProbeObservation
        let boundAt: Double
        let completedAt: Double
        let pair: WorkerReceiverProbeIntervalPair
        let clock: Clock
    }
    private var auditWitness: AuditWitness? = nil
    #endif

    // An explicit IPv4 laboratory convention. This is not a generic estimate for
    // cellular, IPv6, encapsulated routes, or a production admission default.
    static func laboratoryIPv4(measurement m: Measurement, applied: PublishingQualityTelemetry.Applied,
        binding: PublishingProbeObservation, boundAt: Double, completedAt: Double,
        probe: PublishingProbeObservation, pair: WorkerReceiverProbeIntervalPair,
        authority: PublishingCandidateAuthority, clock: Clock,
        currentReceipt: @escaping @Sendable () -> PublishingBitRateChange?,
        candidateIsCurrent: @escaping @Sendable () -> Bool) -> Self? {
        func time(_ value: Double) -> Bool { value.isFinite && (0...1e12).contains(value) }
        let now = clock.after, receiver = pair.newer.end, expected = receiver.expected
        guard time(clock.before), time(now), clock.before <= now, now - clock.before <= 0.1,
              [m.startedAt, m.endedAt, m.firstInputAt, m.lastInputAt, boundAt, completedAt].allSatisfy(time),
              applied.acknowledgedAt <= m.startedAt, applied.receipt.acceptedAt <= applied.acknowledgedAt,
              m.startedAt <= m.firstInputAt, m.firstInputAt < m.lastInputAt, m.lastInputAt <= m.endedAt,
              m.endedAt - m.startedAt <= 7, m.endedAt <= completedAt, completedAt <= now,
              now - m.endedAt <= 2, (4...4.25).contains(m.sourceDuration),
              m.submissionDuration.isFinite, m.submissionDuration > 0, m.submissionDuration < 5,
              (1...40 * 1024 * 1024).contains(m.transportBytes), m.transportBytes % 188 == 0,
              (1...250_000).contains(m.transportMessageCount),
              m.transportMessageCount * 188 <= m.transportBytes, m.transportBytes <= m.transportMessageCount * 1316,
              m.scope.publishingAttemptID == applied.attemptID, m.scope.matchID == expected.gameId,
              m.scope.broadcastGeneration == expected.generation,
              expected.publishingAttemptId == applied.attemptID.uuidString.lowercased(),
              m.publishingGeneration == applied.receipt.publishingGeneration,
              m.publishingGeneration == expected.publishingGeneration,
              applied.settings.videoBitrate == applied.receipt.configuration.bitRate,
              Self.sameReceipt(currentReceipt(), applied.receipt),
              candidateIsCurrent(), authority.permits(receiver), authority.permits(pair.older.end),
              pair.older.end.snapshot == pair.newer.start,
              binding.id == probe.id, binding.publishingGeneration == probe.publishingGeneration,
              binding.policy == probe.policy, binding.stage == probe.stage, binding.campaign == probe.campaign, binding.bitRate == probe.bitRate, binding.startedAt == probe.startedAt,
              binding.startedAt + 0.5 <= boundAt, boundAt <= m.startedAt, binding.isActive(at: boundAt),
              probe.id.uuidString.lowercased() == expected.probeId, probe.publishingGeneration == expected.publishingGeneration,
              probe.stage == expected.stage, probe.campaign == expected.campaign, probe.bitRate == expected.bitRate, probe.stage != nil,
              probe.acceptedPayloadBytes >= binding.acceptedPayloadBytes, probe.leaseDeadline >= binding.leaseDeadline,
              probe.isActive(at: now), probe.leaseDeadline - now <= 0.300001,
              let receiverBytes = UInt64(receiver.snapshot.deliveredPayloadBytes), receiverBytes <= probe.acceptedPayloadBytes,
              let age = receiver.snapshotAgeUpperBound(at: clock.instant),
              let deliveryAge = receiver.lastDeliveryAgeUpperBound(at: clock.instant),
              age <= .milliseconds(1500), deliveryAge <= .milliseconds(1500) else { return nil }
        // The newer intersection is at least as tight as the older interval's
        // bounds. Apply one offset to both intervals rather than splice clocks.
        let offset = pair.newer.receiverClockOffsetBounds
        func bounds(_ text: String) -> ClosedRange<Double>? {
            guard let ns = Int64(text), (0...86_400_000_000_000).contains(ns) else { return nil }
            return clock.bounds((offset.lowerBound + .nanoseconds(ns))...(offset.upperBound + .nanoseconds(ns)))
        }
        guard let firstStart = bounds(pair.older.start.observedAtNanoseconds),
              let firstEnd = bounds(pair.older.end.snapshot.observedAtNanoseconds),
              let lastEnd = bounds(receiver.snapshot.observedAtNanoseconds),
              firstStart.lowerBound >= max(m.firstInputAt, now - 5),
              firstEnd.lowerBound > m.firstInputAt, firstStart.upperBound < m.lastInputAt,
              lastEnd.lowerBound > m.endedAt, lastEnd.upperBound <= now else { return nil }
        let cost = Double(m.transportBytes + 44 * m.transportMessageCount) * 8 / min(m.sourceDuration, m.submissionDuration)
        let padding = min(pair.older.payloadBitsPerSecondLowerBound, pair.newer.payloadBitsPerSecondLowerBound)
        guard cost.isFinite, cost > 0, padding.isFinite, padding > 0 else { return nil }
        let deadline = min(m.endedAt + 2, probe.leaseDeadline,
            clock.before + 1.5 - Clock.seconds(age), clock.before + 1.5 - Clock.seconds(deliveryAge))
        guard deadline > now else { return nil }
        let value = QualityController.CandidateAdmission(id: m.id, attemptID: applied.attemptID,
            appliedRevision: applied.revision, baseline: applied.settings,
            settings: .init(profileID: m.profile.rawValue, videoBitrate: m.profile.bitRate),
            measuredStart: m.startedAt, measuredEnd: m.endedAt, evaluatedAt: now, validUntil: deadline,
            candidateTransportBitsPerSecond: cost, deliveredPaddingBitsPerSecond: padding)
        var admission = Self(value: value, applied: applied, authority: authority, receiver: receiver,
            probe: probe, currentReceipt: currentReceipt, candidateIsCurrent: candidateIsCurrent)
        #if DEBUG
        admission.auditWitness = .init(measurement: m, binding: binding, boundAt: boundAt,
            completedAt: completedAt, pair: pair, clock: clock)
        #endif
        return admission
    }
    func permits(applied: PublishingQualityTelemetry.Applied, at now: Double,
                 instant: ContinuousClock.Instant) -> Bool {
        now.isFinite && now >= value.evaluatedAt && now <= value.validUntil &&
            applied.attemptID == self.applied.attemptID && applied.revision == self.applied.revision &&
            applied.settings == self.applied.settings && applied.acknowledgedAt == self.applied.acknowledgedAt &&
            Self.sameReceipt(applied.receipt, self.applied.receipt) && Self.sameReceipt(currentReceipt(), self.applied.receipt) &&
            candidateIsCurrent() && authority.permits(receiver) && probe.isActive(at: now) &&
            receiver.snapshotAgeUpperBound(at: instant).map { $0 <= .milliseconds(1500) } == true &&
            receiver.lastDeliveryAgeUpperBound(at: instant).map { $0 <= .milliseconds(1500) } == true
    }
    private static func sameReceipt(_ lhs: PublishingBitRateChange?, _ rhs: PublishingBitRateChange) -> Bool {
        guard let lhs, lhs.configuration == rhs.configuration, lhs.publishingGeneration == rhs.publishingGeneration,
              lhs.acceptedAt == rhs.acceptedAt else { return false }
        switch (lhs.lastSubmittedSourcePTS, rhs.lastSubmittedSourcePTS) {
        case (nil, nil): return true
        case let (a?, b?): return CMTimeCompare(a, b) == 0
        default: return false
        }
    }
}

extension PublishingCandidateAdmission.Measurement {
    init(_ cost: PublishingCandidateCost) {
        self.init(id: cost.id, scope: cost.scope, profile: cost.profile,
            publishingGeneration: cost.publishingGeneration, startedAt: cost.startedAt, endedAt: cost.endedAt,
            firstInputAt: cost.firstInputAt, lastInputAt: cost.lastInputAt,
            sourceDuration: cost.sourceDuration, submissionDuration: cost.submissionDuration,
            transportBytes: cost.transportBytes, transportMessageCount: cost.transportMessageCount)
    }
}

#if DEBUG
extension PublishingCandidateAdmission {
    /// Frozen admission inputs, independent of later receipt/probe changes. This
    /// bounded export owns no media and never reads a later receiver observation.
    func auditData() throws -> Data {
        guard let w = auditWitness else { throw CocoaError(.coderValueNotFound) }
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        func bounds(_ range: ClosedRange<ContinuousClock.Instant>) -> [Double] {
            let projected = w.clock.bounds(range)
            return [projected.lowerBound, projected.upperBound]
        }
        func point(_ instant: ContinuousClock.Instant) -> [Double] { bounds(instant...instant) }
        func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        func time(_ pts: CMTime) -> [String: Any] {
            ["value": String(pts.value), "timescale": pts.timescale, "epoch": String(pts.epoch), "flags": pts.flags.rawValue]
        }
        func probeObject(_ p: PublishingProbeObservation) -> [String: Any] {
            var object: [String: Any] = ["id": p.id.uuidString.lowercased(), "publishingGeneration": String(p.publishingGeneration),
             "stage": optional(p.stage), "bitRate": p.bitRate, "startedAt": p.startedAt,
             "leaseDeadline": p.leaseDeadline, "acceptedPayloadBytes": String(p.acceptedPayloadBytes),
             "lastAcceptedAt": optional(p.lastAcceptedAt), "reason": optional(p.reason)]
            if p.policy == .recoveryBudget {
                object["policy"] = p.policy.rawValue
                object["recoveryObservation"] = p.recoveryObservation?.auditObject ?? NSNull()
            }
            if let campaign = p.campaign { object["campaign"] = String(campaign) }
            return object
        }
        func interval(_ i: WorkerReceiverProbeInterval) throws -> [String: Any] {
            let end = i.end, e = end.expected, duration = i.duration.components
            var expected: [String: Any] = ["gameId": e.gameId, "generation": e.generation, "workerId": e.workerId,
                "publishingAttemptId": e.publishingAttemptId, "publishingGeneration": String(e.publishingGeneration),
                "probeId": e.probeId, "stage": optional(e.stage), "bitRate": e.bitRate]
            if let campaign = e.campaign { expected["campaign"] = String(campaign) }
            return ["start": try object(i.start),
                "end": ["snapshot": try object(end.snapshot), "publication": try object(end.publication),
                    "workerEpoch": end.workerEpoch, "workerAttempt": end.workerAttempt,
                    "expected": expected,
                    "serverAgeUpperBoundMs": end.serverAgeUpperBoundMs,
                    "receivedAtUptimeBounds": point(end.receivedAt),
                    "requestStartedAtUptimeBounds": point(end.requestStartedAt),
                    "requestDurationSeconds": Clock.seconds(end.requestStartedAt.duration(to: end.receivedAt)),
                    "snapshotAgeUpperBoundSeconds": optional(end.snapshotAgeUpperBound(at: w.clock.instant).map(Clock.seconds)),
                    "lastDeliveryAgeUpperBoundSeconds": optional(end.lastDeliveryAgeUpperBound(at: w.clock.instant).map(Clock.seconds))],
                "receiverClockOffsetUptimeBounds": bounds(i.receiverClockOffsetBounds),
                "startUptimeBounds": bounds(i.startBounds), "endUptimeBounds": bounds(i.endBounds),
                "durationNanoseconds": String(duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000),
                "deliveredMessages": String(i.deliveredMessages),
                "deliveredPayloadBytesLowerBound": String(i.deliveredPayloadBytesLowerBound),
                "payloadBitsPerSecondLowerBound": i.payloadBitsPerSecondLowerBound]
        }
        let m = w.measurement, receipt = applied.receipt
        let recovery = probe.policy == .recoveryBudget
        let result: [String: Any] = ["formatVersion": recovery ? 2 : 1,
            "convention": recovery ? "measured-candidate-ipv4-recovery-v1" : "measured-candidate-ipv4-v1",
            "evaluatedAt": value.evaluatedAt, "validUntil": value.validUntil,
            "measurement": ["id": m.id.uuidString.lowercased(),
                "scope": ["recordingID": m.scope.recordingID, "matchID": m.scope.matchID,
                    "broadcastGeneration": m.scope.broadcastGeneration,
                    "publishingAttemptID": m.scope.publishingAttemptID.uuidString,
                    "appliedProfileRevision": String(m.scope.appliedProfileRevision)],
                "profile": m.profile.rawValue, "publishingGeneration": String(m.publishingGeneration),
                "startedAt": m.startedAt, "endedAt": m.endedAt, "firstInputAt": m.firstInputAt,
                "lastInputAt": m.lastInputAt, "sourceDuration": m.sourceDuration, "submissionDuration": m.submissionDuration,
                "transportBytes": m.transportBytes, "transportMessageCount": m.transportMessageCount],
            "applied": ["attemptID": applied.attemptID.uuidString.lowercased(), "revision": String(applied.revision),
                "profileID": applied.settings.profileID, "videoBitrate": applied.settings.videoBitrate,
                "acknowledgedAt": applied.acknowledgedAt,
                "receipt": ["generation": String(receipt.publishingGeneration),
                    "configurationID": receipt.configuration.id.uuidString.lowercased(),
                    "encoderSessionID": receipt.configuration.encoderSessionID.uuidString.lowercased(),
                    "bitRate": receipt.configuration.bitRate, "acceptedAt": receipt.acceptedAt,
                    "lastSubmittedPTS": optional(receipt.lastSubmittedSourcePTS.map(time))]],
            "binding": probeObject(w.binding), "boundAt": w.boundAt, "completedAt": w.completedAt,
            "probe": probeObject(probe),
            "clock": ["before": w.clock.before, "after": w.clock.after,
                "receiverClockOffsetUptimeBounds": bounds(w.pair.newer.receiverClockOffsetBounds)],
            "intervals": try [interval(w.pair.older), interval(w.pair.newer)],
            "candidateTransportBitsPerSecond": value.candidateTransportBitsPerSecond,
            "deliveredPaddingBitsPerSecond": value.deliveredPaddingBitsPerSecond]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
}
#endif

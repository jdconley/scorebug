import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia

/// App-layer conversion of bounded, matched observations. Limits must be qualified
/// by the caller; no default turns an unfamiliar worker/network into nominal load.
enum PublishingQualityTelemetry {
    enum Failure: Error, Equatable { case ownership, configuration, time, freshness }
    struct Applied: Sendable {
        var attemptID: UUID
        var revision: UInt64
        var settings: QualityController.Settings
        var receipt: PublishingBitRateChange
        var acknowledgedAt: Double
    }
    struct Diagnostics: Sendable {
        var isPublishing: Bool
        var clock: PublishingTransportClock?
        var receipt: PublishingBitRateChange?
        var ingress: LiveIngressObservationSnapshot?
        var transport: PublishingTransportStatisticsSnapshot
        var thermal: PublishingThermalSnapshot
        init(snapshot: PublishingSessionSnapshot) {
            isPublishing = snapshot.state == .publishing && snapshot.failure == nil
            clock = snapshot.transportClock; receipt = snapshot.lastBitRateChange
            ingress = snapshot.ingressObservation; transport = snapshot.transportStatistics
            thermal = snapshot.thermalObservation
        }
        init(isPublishing: Bool, clock: PublishingTransportClock?, receipt: PublishingBitRateChange?,
             ingress: LiveIngressObservationSnapshot?, transport: PublishingTransportStatisticsSnapshot,
             thermal: PublishingThermalSnapshot) {
            self.isPublishing = isPublishing; self.clock = clock; self.receipt = receipt
            self.ingress = ingress; self.transport = transport; self.thermal = thermal
        }
    }
    struct WorkerLimits: Sendable {
        let encoder: String
        let maximumFilterMs: Double
        let maximumProcessingMs: Double
        init?(encoder: String, maximumFilterMs: Double, maximumProcessingMs: Double) {
            guard ["software", "videotoolbox", "nvenc"].contains(encoder),
                  maximumFilterMs.isFinite, maximumFilterMs > 0,
                  maximumProcessingMs.isFinite, maximumProcessingMs > 0 else { return nil }
            self.encoder = encoder; self.maximumFilterMs = maximumFilterMs; self.maximumProcessingMs = maximumProcessingMs
        }
    }
    struct TransportLimits: Sendable {
        let maximumBufferMs: Double
        let maximumRTTMs: Double
        let maximumRetransmittedFraction: Double
        enum Policy: String, Sendable {
            case legacyThreshold = "legacy-threshold-v1"
            case senderDelay = "sender-delay-v1"
            case recoveryBudget = "recovery-budget-v1"
        }
        let policy: Policy
        init?(maximumBufferMs: Double, maximumRTTMs: Double, maximumRetransmittedFraction: Double, policy: Policy = .legacyThreshold) {
            guard maximumBufferMs.isFinite, maximumBufferMs > 0, maximumRTTMs.isFinite, maximumRTTMs > 0,
                  maximumRetransmittedFraction.isFinite, (0..<1).contains(maximumRetransmittedFraction) else { return nil }
            self.maximumBufferMs = maximumBufferMs; self.maximumRTTMs = maximumRTTMs
            self.maximumRetransmittedFraction = maximumRetransmittedFraction
            self.policy = policy
        }
    }
    static func decoderStall(cadence: WorkerDecoderCadenceFreshness, applied: Applied, diagnostics: Diagnostics,
                             sequence: UInt64, at now: Double, instant: ContinuousClock.Instant) throws -> QualityController.DecoderStall? {
        try validateDecoderContext(cadence: cadence, applied: applied, diagnostics: diagnostics, sequence: sequence, at: now)
        guard let age = cadence.sampleAgeUpperBound(at: instant), age >= .zero,
              age <= .seconds(ProgressiveStreamingPolicy.maximumDecoderStallSampleAge)
        else { throw Failure.freshness }
        guard cadence.snapshot.progress?.stalled == true else { return nil }
        let seconds = Double(age.components.seconds) + Double(age.components.attoseconds) / 1e18
        let lowerBound = now - seconds
        // The complete one-second no-progress interval must follow the current
        // native acknowledgment, even at the oldest possible sample time.
        guard lowerBound >= applied.acknowledgedAt + ProgressiveStreamingPolicy.minimumDecoderStallDuration else { return nil }
        return .init(attemptID: applied.attemptID, appliedRevision: applied.revision,
                     sequence: sequence, observedAtLowerBound: lowerBound)
    }
    /// Current native ownership is checked even when a previously consumed
    /// receipt is re-read by the local health loop.
    static func validateDecoderContext(cadence: WorkerDecoderCadenceFreshness, applied: Applied, diagnostics: Diagnostics,
                                       sequence: UInt64, at now: Double) throws {
        let receipt = applied.receipt
        guard diagnostics.isPublishing,
              let current = diagnostics.receipt, sameReceipt(current, receipt),
              diagnostics.clock?.publishingGeneration == receipt.publishingGeneration,
              let ingress = diagnostics.ingress, !ingress.isClosed,
              ingress.scope.publishingAttemptID == applied.attemptID,
              ingress.scope.matchID == cadence.gameId,
              ingress.scope.broadcastGeneration == cadence.generation,
              cadence.publication.publishingAttemptId == applied.attemptID.uuidString.lowercased()
        else { throw Failure.ownership }
        guard receipt.configuration.bitRate == applied.settings.videoBitrate else { throw Failure.configuration }
        guard now.isFinite, (0...1e12).contains(now), applied.acknowledgedAt.isFinite,
              applied.acknowledgedAt >= receipt.acceptedAt, applied.acknowledgedAt <= now, sequence > 0
        else { throw Failure.time }
    }
    static func window(source: WorkerSourceIntervalObservation, applied: Applied, diagnostics: Diagnostics,
                       workerLimits: WorkerLimits?, transportLimits: TransportLimits?,
                       sequence: UInt64? = nil, at now: Double, instant: ContinuousClock.Instant) throws -> QualityController.Window {
        let interval = source.interval, receipt = applied.receipt
        guard diagnostics.isPublishing, interval.scope.publishingAttemptID == applied.attemptID,
              diagnostics.clock == source.nativeClock,
              interval.publishingGeneration == receipt.publishingGeneration,
              source.nativeClock.publishingGeneration == receipt.publishingGeneration,
              source.publication.publishingAttemptId == applied.attemptID.uuidString.lowercased(),
              source.freshness.gameId == interval.scope.matchID,
              source.freshness.generation == interval.scope.broadcastGeneration,
              source.freshness.workerId == source.workerId, source.freshness.attempt == source.workerAttempt,
              let current = diagnostics.receipt, sameReceipt(current, receipt) else { throw Failure.ownership }
        guard case .verified(let configuration) = interval.encodingCoverage,
              configuration == receipt.configuration, configuration.bitRate == applied.settings.videoBitrate,
              receipt.lastSubmittedSourcePTS.map({ CMTimeCompare(interval.sourceStartExclusive, $0) >= 0 }) ?? true
        else { throw Failure.configuration }
        let start = interval.captureBoundaryStartTime, end = interval.captureBoundaryEndTime
        guard now.isFinite, (0...1e12).contains(now), applied.acknowledgedAt.isFinite,
              applied.acknowledgedAt >= receipt.acceptedAt, start >= applied.acknowledgedAt,
              start.isFinite, end.isFinite, (1...QualityController.maximumWindowDuration).contains(end - start),
              end <= now, now - end <= 2, source.sequence > 0 else { throw Failure.time }
        guard let age = source.freshness.ageUpperBound(at: instant), age >= .zero, age <= .seconds(2) else { throw Failure.freshness }
        let ageSeconds = Double(age.components.seconds) + Double(age.components.attoseconds) / 1e18
        let observedAt = max(end, now - ageSeconds)
        var queue: Double?
        if let ingress = diagnostics.ingress, !ingress.isClosed, !ingress.pressure.isClosed,
           ingress.pressure.coveredThrough <= now, now - ingress.pressure.coveredThrough <= 2 {
            queue = interval.ingressPressure(in: ingress)?.meanMaxPressure
        }
        let thermal = thermalPressure(diagnostics.thermal, from: start, to: end, at: now)
        let transport = transportPressure(diagnostics.transport, generation: receipt.publishingGeneration,
            limits: transportLimits, from: start, to: end, at: now)
        return .init(attemptID: applied.attemptID, sequence: sequence ?? UInt64(source.sequence), appliedRevision: applied.revision,
            start: start, end: end, capturedFreshFrames: interval.capturedFrames, encodedFreshFrames: interval.encodedFrames,
            receiver: .init(freshFrames: interval.decodedFrames, observedAt: observedAt),
            sourceLoss: .init(expectedFrames: interval.capturedFrames, lostFrames: interval.capturedFrames - interval.decodedFrames),
            meanQueueOccupancy: queue, usableVideoCapacity: nil, connectivity: .connected,
            thermalPressure: thermal, workerPressure: workerPressure(source, limits: workerLimits), transportPressure: transport)
    }
    /// Independent local pressure may justify a reduction, never receiver health.
    /// The owner supplies the shared watermark for source and local decisions.
    static func localPressureWindow(applied: Applied, diagnostics: Diagnostics,
                                    transportLimits: TransportLimits?, sequence: UInt64,
                                    after previousEnd: Double?, at now: Double) throws -> QualityController.Window? {
        let receipt = applied.receipt
        guard diagnostics.isPublishing,
              let current = diagnostics.receipt, sameReceipt(current, receipt),
              diagnostics.clock?.publishingGeneration == receipt.publishingGeneration,
              let ingress = diagnostics.ingress, !ingress.isClosed,
              ingress.scope.publishingAttemptID == applied.attemptID else { throw Failure.ownership }
        guard receipt.configuration.bitRate == applied.settings.videoBitrate else { throw Failure.configuration }
        guard now.isFinite, (0...1e12).contains(now), applied.acknowledgedAt.isFinite,
              applied.acknowledgedAt >= receipt.acceptedAt, applied.acknowledgedAt <= now, sequence > 0,
              previousEnd.map({ $0.isFinite && (0...now).contains($0) }) ?? true else { throw Failure.time }
        let boundary = max(applied.acknowledgedAt, previousEnd ?? applied.acknowledgedAt)
        // Fast local evidence can reduce or roll back, never establish receiver
        // health. Keep the receiver path at its longer duration while congestion grows.
        let duration = 0.25
        func thermal(_ end: Double) -> QualityController.Pressure {
            thermalPressure(diagnostics.thermal, from: end - duration, to: end, at: now,
                minimumSampleStart: applied.acknowledgedAt)
        }
        func transport(_ end: Double) -> QualityController.Pressure {
            transportPressure(diagnostics.transport, generation: receipt.publishingGeneration,
                limits: transportLimits, from: end - duration, to: end, at: now,
                minimumSampleStart: applied.acknowledgedAt)
        }
        func queue(_ end: Double) -> Double? {
            let p = ingress.pressure
            guard !p.isClosed, p.coveredThrough <= now, now - p.coveredThrough <= 2 else { return nil }
            return p.interval(from: end - duration, to: end)?.meanMaxPressure
        }
        // Only independently covered metrics select an endpoint. An unavailable
        // metric cannot move another metric's evidence into an uncovered interval.
        var ends: [Double] = []
        if let sample = diagnostics.thermal.freshSample(at: now), sample.sampledAt - duration >= boundary,
           thermal(sample.sampledAt) != .unknown { ends.append(sample.sampledAt) }
        if let sample = diagnostics.transport.freshSample(at: now), sample.sampledAt - duration >= boundary,
           transport(sample.sampledAt) != .unknown { ends.append(sample.sampledAt) }
        let queueEnd = ingress.pressure.coveredThrough
        if queueEnd - duration >= boundary, queue(queueEnd) != nil { ends.append(queueEnd) }
        for end in Set(ends).sorted(by: >) {
            guard end <= now, now - end <= 2, end - duration >= boundary else { continue }
            let localThermal = thermal(end), localTransport = transport(end), localQueue = queue(end)
            guard localThermal == .elevated || localTransport == .elevated || (localQueue.map { $0 >= 0.75 } ?? false) else { continue }
            return .init(attemptID: applied.attemptID, sequence: sequence, appliedRevision: applied.revision,
                start: end - duration, end: end, capturedFreshFrames: nil, encodedFreshFrames: nil,
                receiver: nil, sourceLoss: nil, meanQueueOccupancy: localQueue, usableVideoCapacity: nil,
                connectivity: .unknown, thermalPressure: localThermal, workerPressure: .unknown, transportPressure: localTransport)
        }
        return nil
    }
    private static func thermalPressure(_ history: PublishingThermalSnapshot, from start: Double, to end: Double,
                                        at now: Double, minimumSampleStart: Double? = nil) -> QualityController.Pressure {
        guard history.freshSample(at: now) != nil, let sample = history.interval(from: start, to: end),
              minimumSampleStart.map({ sample.enclosingStart >= $0 }) ?? true else { return .unknown }
        switch sample.enclosingMaximumState {
        case .nominal: return .nominal
        case .serious, .critical: return .elevated
        case .fair, .unknown: return .unknown
        }
    }
    private static func transportPressure(_ history: PublishingTransportStatisticsSnapshot, generation: UInt64,
                                          limits: TransportLimits?, from start: Double, to end: Double,
                                          at now: Double, minimumSampleStart: Double? = nil) -> QualityController.Pressure {
        guard let limits, history.freshSample(at: now) != nil,
              let sample = history.interval(from: start, to: end), sample.publishingGeneration == generation,
              minimumSampleStart.map({ sample.enclosingStart >= $0 }) ?? true else { return .unknown }
        let excessive = sample.enclosingDroppedPackets > 0
            || Double(sample.enclosingMaximumBufferMilliseconds) > limits.maximumBufferMs
            || sample.enclosingMaximumRTTMilliseconds > limits.maximumRTTMs
            || (limits.policy != .recoveryBudget && sample.enclosingSentBytes > 0 && Double(sample.enclosingRetransmittedBytes) / Double(sample.enclosingSentBytes) > limits.maximumRetransmittedFraction)
        if excessive { return .elevated }
        if limits.policy != .legacyThreshold {
            // Compare each RTT to the delay collected with that same sample.
            // The enclosing points, including boundary gauges, remain unchanged.
            let points = history.samples.filter { $0.sampledAt >= sample.enclosingStart && $0.sampledAt <= sample.enclosingEnd }
            if points.contains(where: { point in
                guard let delay = point.senderDeliveryDelayMilliseconds, delay > 0 else { return false }
                return point.rttMilliseconds > min(limits.maximumRTTMs, Double(delay) / 4)
                    || (limits.policy == .recoveryBudget && Double(point.senderBufferMilliseconds) > min(limits.maximumBufferMs, Double(delay) / 2))
            }) { return .elevated }
            guard points.allSatisfy({ ($0.senderDeliveryDelayMilliseconds ?? 0) > 0 }) else { return .unknown }
        }
        return sample.enclosingSentBytes > 0 ? .nominal : .unknown
    }
    private static func sameReceipt(_ a: PublishingBitRateChange, _ b: PublishingBitRateChange) -> Bool {
        a.publishingGeneration == b.publishingGeneration && a.configuration == b.configuration
            && a.acceptedAt == b.acceptedAt && a.lastSubmittedSourcePTS == b.lastSubmittedSourcePTS
    }
    private static func workerPressure(_ source: WorkerSourceIntervalObservation, limits: WorkerLimits?) -> QualityController.Pressure {
        guard let limits, let report = source.processing, report.encoder == limits.encoder, report.scopeID.utf8.count == 36,
              report.scopeID.range(of: "^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              report.sequence == source.sequence, report.previousSequence == source.previousSequence,
              report.firstPTS == source.firstDecodedPTS else { return .unknown }
        let i = report.interval, maximum: Int64 = 9_007_199_254_740_991
        guard i.sourceStartExclusive == source.previousDecodedPTS, i.sourceEndInclusive == source.lastDecodedPTS,
              i.decodedFrames == Int64(source.interval.decodedFrames),
              [i.decodedFrames, i.submittedFrames, i.completedFrames, i.pendingFrames, i.omittedBeforeEncoderFrames].allSatisfy({ (0...maximum).contains($0) }),
              i.completedFrames <= i.submittedFrames, i.submittedFrames <= i.decodedFrames,
              i.pendingFrames == i.submittedFrames - i.completedFrames,
              i.omittedBeforeEncoderFrames == i.decodedFrames - i.submittedFrames,
              i.pendingFrames == 0 || i.processingDuration == nil,
              i.submittedFrames > 0 || (i.filterDuration == nil && i.processingDuration == nil) else { return .unknown }
        for duration in [i.filterDuration, i.processingDuration].compactMap({ $0 }) {
            guard duration.meanMs.isFinite, duration.maximumMs.isFinite, duration.meanMs >= 0,
                  duration.meanMs <= duration.maximumMs, duration.maximumMs <= Double(maximum) else { return .unknown }
        }
        if i.omittedBeforeEncoderFrames > 0 { return .elevated }
        if let filter = i.filterDuration, filter.maximumMs > limits.maximumFilterMs { return .elevated }
        if let processing = i.processingDuration, processing.maximumMs > limits.maximumProcessingMs { return .elevated }
        guard i.submittedFrames > 0, i.pendingFrames == 0, i.filterDuration != nil, i.processingDuration != nil else { return .unknown }
        return .nominal
    }
}

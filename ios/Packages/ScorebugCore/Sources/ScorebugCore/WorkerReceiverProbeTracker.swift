import Foundation

/// Delivered optional payload across receiver read-time boundaries. This is not
/// spare capacity or a permission to change media settings.
public struct WorkerReceiverProbeInterval: Sendable {
    public let start: ReceiverProbeSnapshot
    public let end: WorkerReceiverProbeFreshness
    /// Receiver clock zero mapped into the local monotonic clock by intersecting
    /// every accepted request envelope. Values are frozen when this interval forms.
    public let receiverClockOffsetBounds: ClosedRange<ContinuousClock.Instant>
    public let startBounds: ClosedRange<ContinuousClock.Instant>
    public let endBounds: ClosedRange<ContinuousClock.Instant>
    public let duration: Duration
    public let deliveredMessages: UInt64
    public let deliveredPayloadBytesLowerBound: UInt64
    public var payloadBitsPerSecondLowerBound: Double {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return Double(deliveredPayloadBytesLowerBound) * 8 / seconds
    }
}

/// The two newest distinct, contiguous intervals from one publication/probe/stage.
/// The older interval is historical coverage; freshness belongs to the newer end.
public struct WorkerReceiverProbeIntervalPair: Sendable {
    public let older: WorkerReceiverProbeInterval
    public let newer: WorkerReceiverProbeInterval
}

/// Bounded causal accounting. Missing evidence breaks coverage but cannot wash
/// contradictions or counter high-water marks. Reset only when the local owner ends.
public struct WorkerReceiverProbeTracker: Sendable {
    public static let maximumAge: Duration = .milliseconds(1500)
    public private(set) var latest: WorkerReceiverProbeInterval?
    /// Subsecond observations returning the same latest interval do not duplicate
    /// it or refresh this pair. Missing evidence and expired coverage clear it.
    public private(set) var latestPair: WorkerReceiverProbeIntervalPair?
    public private(set) var isQuarantined = false
    private struct Scope: Equatable, Sendable {
        let expected: WorkerReceiverProbeExpectation
        let epoch: String
        let attempt: Int
        let publication: WorkerPublication
        init(_ e: WorkerReceiverProbeFreshness) {
            expected = e.expected; epoch = e.workerEpoch; attempt = e.workerAttempt; publication = e.publication
        }
        func matchesPublication(_ other: Self) -> Bool {
            expected.gameId == other.expected.gameId && expected.generation == other.expected.generation &&
            expected.workerId == other.expected.workerId &&
            expected.publishingAttemptId == other.expected.publishingAttemptId &&
            expected.publishingGeneration == other.expected.publishingGeneration &&
            epoch == other.epoch && attempt == other.attempt && publication == other.publication
        }
    }
    private var scope: Scope?
    private var previous: WorkerReceiverProbeFreshness?
    private var previousAccepted: UInt64?
    private var baseline: WorkerReceiverProbeFreshness?
    // One historical interval may outlive public freshness while awaiting its
    // contiguous successor. Coverage breaks still discard this bounded history.
    private var previousProduced: WorkerReceiverProbeInterval?
    private var offset: ClosedRange<ContinuousClock.Instant>?
    private var evaluatedAt: ContinuousClock.Instant?
    public init() {}

    @discardableResult public mutating func observe(_ evidence: WorkerReceiverProbeFreshness?,
        acceptedPayloadBytes: UInt64, senderActive: Bool, at instant: ContinuousClock.Instant = .now) -> WorkerReceiverProbeInterval? {
        guard let evidence else { suspend(); return nil }
        let nextScope = Scope(evidence)
        if let scope, !scope.matchesPublication(nextScope) ||
            // Preserve v1's independently owned single-probe replacement behavior.
            (scope.expected.stage == nil && nextScope.expected.stage == nil && scope != nextScope) {
            reset()
        }
        guard !isQuarantined else { return nil }
        if let scope {
            switch (scope.expected.stage, nextScope.expected.stage) {
            case (nil, nil): break
            case let (oldStage?, newStage?):
                guard newStage >= oldStage,
                      newStage != oldStage || scope.expected == nextScope.expected,
                      newStage == oldStage || scope.expected.probeId != nextScope.expected.probeId else {
                    quarantine(); return nil
                }
                if newStage > oldStage {
                    // A local stage replacement breaks coverage, never clock or
                    // cumulative history. No history array is needed (at most 32 stages).
                    suspend(); previousAccepted = nil
                }
            default: quarantine(); return nil
            }
        }
        scope = nextScope
        guard evaluatedAt.map({ instant >= $0 }) ?? true else { quarantine(); return nil }
        evaluatedAt = instant
        expire(at: instant)
        guard senderActive, Self.fresh(evidence, at: instant) else { suspend(); return nil }
        let p = evidence.snapshot
        // Freshness validation has already bounded these canonical strings.
        guard let messages = UInt64(p.deliveredMessages), let observed = UInt64(p.observedAtNanoseconds),
              acceptedPayloadBytes <= 16 * 1024 * 1024, acceptedPayloadBytes % 1316 == 0,
              (messages + (p.pendingPackets > 0 ? 1 : 0)) * 1316 <= acceptedPayloadBytes,
              previousAccepted.map({ acceptedPayloadBytes >= $0 }) ?? true else { quarantine(); return nil }
        let receiverElapsed = Duration.nanoseconds(Int64(observed))
        let bounds = (evidence.receivedAt - evidence.ageAtReceipt - receiverElapsed)...(evidence.receivedAt - receiverElapsed)
        if let offset {
            let lower = max(offset.lowerBound, bounds.lowerBound), upper = min(offset.upperBound, bounds.upperBound)
            guard lower <= upper else { quarantine(); return nil }
            self.offset = lower...upper
        } else { offset = bounds }
        if let previous {
            let old = previous.snapshot
            let oldMessages = UInt64(old.deliveredMessages)!, oldObserved = UInt64(old.observedAtNanoseconds)!
            guard evidence.requestStartedAt >= previous.receivedAt, observed >= oldObserved else {
                quarantine(); return nil
            }
            if p.stage != old.stage {
                // Prior pending packets reserve a whole message even if their
                // completion was not observed before replacing the probe.
                let required = UInt64(old.totalDeliveredPayloadBytes!)! +
                    (old.pendingPackets > 0 ? 1316 : 0) + messages * 1316
                guard UInt64(p.totalDeliveredPayloadBytes!)! >= required,
                      messages == 0 || (p.firstDeliveredAtNanoseconds.flatMap(UInt64.init).map { $0 >= oldObserved } ?? false) else {
                    quarantine(); return nil
                }
            } else {
                guard messages >= oldMessages,
                      messages * 7 + UInt64(p.pendingPackets) >= oldMessages * 7 + UInt64(old.pendingPackets) else {
                    quarantine(); return nil
                }
                if let totalText = p.totalDeliveredPayloadBytes {
                    let total = UInt64(totalText)!, oldTotal = UInt64(old.totalDeliveredPayloadBytes!)!
                    guard total >= oldTotal, total - oldTotal == (messages - oldMessages) * 1316 else {
                        quarantine(); return nil
                    }
                }
                if let first = old.firstDeliveredAtNanoseconds {
                    guard p.firstDeliveredAtNanoseconds == first else { quarantine(); return nil }
                }
                if messages == oldMessages {
                    guard p.lastDeliveredAtNanoseconds == old.lastDeliveredAtNanoseconds else { quarantine(); return nil }
                } else {
                    guard let last = p.lastDeliveredAtNanoseconds.flatMap(UInt64.init), last >= oldObserved,
                          oldMessages != 0 || (p.firstDeliveredAtNanoseconds.flatMap(UInt64.init).map { $0 >= oldObserved } ?? false) else {
                        quarantine(); return nil
                    }
                }
            }
        }
        previous = evidence; previousAccepted = acceptedPayloadBytes
        guard let baseline else { self.baseline = evidence; return latest }
        let elapsed = observed - UInt64(baseline.snapshot.observedAtNanoseconds)!
        if elapsed > 5_000_000_000 { self.baseline = evidence; latest = nil; latestPair = nil; previousProduced = nil; return nil }
        guard elapsed >= 1_000_000_000 else { return latest }
        self.baseline = evidence
        let count = messages - UInt64(baseline.snapshot.deliveredMessages)!
        let alreadySeen = UInt64(baseline.snapshot.pendingPackets) * 188
        guard count * 1316 > alreadySeen else { latest = nil; latestPair = nil; previousProduced = nil; return nil }
        let reconciledOffset = offset!
        let startElapsed = Duration.nanoseconds(Int64(baseline.snapshot.observedAtNanoseconds)!)
        let interval = WorkerReceiverProbeInterval(start: baseline.snapshot, end: evidence,
            receiverClockOffsetBounds: reconciledOffset,
            startBounds: (reconciledOffset.lowerBound + startElapsed)...(reconciledOffset.upperBound + startElapsed),
            endBounds: (reconciledOffset.lowerBound + receiverElapsed)...(reconciledOffset.upperBound + receiverElapsed),
            duration: .nanoseconds(Int64(elapsed)), deliveredMessages: count,
            deliveredPayloadBytesLowerBound: count * 1316 - alreadySeen)
        if let previousProduced, previousProduced.end.snapshot == interval.start, Scope(previousProduced.end) == Scope(evidence) {
            latestPair = .init(older: previousProduced, newer: interval)
        } else { latestPair = nil }
        previousProduced = interval
        latest = interval
        return interval
    }

    public mutating func expire(at instant: ContinuousClock.Instant = .now) {
        if let latest, !Self.fresh(latest.end, at: instant) { self.latest = nil; latestPair = nil }
        if let baseline, instant < baseline.receivedAt || instant - baseline.receivedAt > .seconds(5) {
            self.baseline = nil; latestPair = nil; previousProduced = nil
        }
    }
    public mutating func reset() { self = Self() }
    private mutating func suspend() { baseline = nil; latest = nil; latestPair = nil; previousProduced = nil }
    private mutating func quarantine() { isQuarantined = true; suspend() }
    private static func fresh(_ evidence: WorkerReceiverProbeFreshness, at instant: ContinuousClock.Instant) -> Bool {
        guard let age = evidence.snapshotAgeUpperBound(at: instant), age <= maximumAge else { return false }
        if evidence.snapshot.deliveredMessages == "0" { return true }
        return evidence.lastDeliveryAgeUpperBound(at: instant).map { $0 <= maximumAge } ?? false
    }
}

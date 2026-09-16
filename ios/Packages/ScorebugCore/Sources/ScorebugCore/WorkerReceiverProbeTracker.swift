import Foundation

/// Delivered optional payload across receiver read-time boundaries. This is not
/// spare capacity or a permission to change media settings.
public struct WorkerReceiverProbeInterval: Sendable {
    public let start: ReceiverProbeSnapshot
    public let end: WorkerReceiverProbeFreshness
    public let duration: Duration
    public let deliveredMessages: UInt64
    public let deliveredPayloadBytesLowerBound: UInt64
    public var payloadBitsPerSecondLowerBound: Double {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return Double(deliveredPayloadBytesLowerBound) * 8 / seconds
    }
}

/// Bounded causal accounting. Missing evidence breaks coverage but cannot wash
/// contradictions or counter high-water marks. Reset only when the local owner ends.
public struct WorkerReceiverProbeTracker: Sendable {
    public static let maximumAge: Duration = .milliseconds(1500)
    public private(set) var latest: WorkerReceiverProbeInterval?
    public private(set) var isQuarantined = false
    private struct Scope: Equatable, Sendable {
        let expected: WorkerReceiverProbeExpectation
        let epoch: String
        let attempt: Int
        let publication: WorkerPublication
        init(_ e: WorkerReceiverProbeFreshness) {
            expected = e.expected; epoch = e.workerEpoch; attempt = e.workerAttempt; publication = e.publication
        }
    }
    private var scope: Scope?
    private var previous: WorkerReceiverProbeFreshness?
    private var previousAccepted: UInt64?
    private var baseline: WorkerReceiverProbeFreshness?
    private var offset: ClosedRange<ContinuousClock.Instant>?
    private var evaluatedAt: ContinuousClock.Instant?
    public init() {}

    @discardableResult public mutating func observe(_ evidence: WorkerReceiverProbeFreshness?,
        acceptedPayloadBytes: UInt64, senderActive: Bool, at instant: ContinuousClock.Instant = .now) -> WorkerReceiverProbeInterval? {
        guard let evidence else { suspend(); return nil }
        let nextScope = Scope(evidence)
        if scope != nextScope { reset(); scope = nextScope }
        guard !isQuarantined else { return nil }
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
            guard evidence.requestStartedAt >= previous.receivedAt, observed >= oldObserved,
                  messages >= oldMessages,
                  messages * 7 + UInt64(p.pendingPackets) >= oldMessages * 7 + UInt64(old.pendingPackets) else {
                quarantine(); return nil
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
        previous = evidence; previousAccepted = acceptedPayloadBytes
        guard let baseline else { self.baseline = evidence; return latest }
        let elapsed = observed - UInt64(baseline.snapshot.observedAtNanoseconds)!
        if elapsed > 5_000_000_000 { self.baseline = evidence; latest = nil; return nil }
        guard elapsed >= 1_000_000_000 else { return latest }
        self.baseline = evidence
        let count = messages - UInt64(baseline.snapshot.deliveredMessages)!
        let alreadySeen = UInt64(baseline.snapshot.pendingPackets) * 188
        guard count * 1316 > alreadySeen else { latest = nil; return nil }
        latest = WorkerReceiverProbeInterval(start: baseline.snapshot, end: evidence,
            duration: .nanoseconds(Int64(elapsed)), deliveredMessages: count,
            deliveredPayloadBytesLowerBound: count * 1316 - alreadySeen)
        return latest
    }

    public mutating func expire(at instant: ContinuousClock.Instant = .now) {
        if let latest, !Self.fresh(latest.end, at: instant) { self.latest = nil }
        if let baseline, instant < baseline.receivedAt || instant - baseline.receivedAt > .seconds(5) {
            self.baseline = nil
        }
    }
    public mutating func reset() { self = Self() }
    private mutating func suspend() { baseline = nil; latest = nil }
    private mutating func quarantine() { isQuarantined = true; suspend() }
    private static func fresh(_ evidence: WorkerReceiverProbeFreshness, at instant: ContinuousClock.Instant) -> Bool {
        guard let age = evidence.snapshotAgeUpperBound(at: instant), age <= maximumAge else { return false }
        if evidence.snapshot.deliveredMessages == "0" { return true }
        return evidence.lastDeliveryAgeUpperBound(at: instant).map { $0 <= maximumAge } ?? false
    }
}

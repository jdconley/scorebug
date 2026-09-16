import Foundation

public enum SRTBandwidthProbeError: Error, Equatable, Sendable {
    case disabled, notPublishing, alreadyStarted, invalidConfiguration, unavailableStatistics, obsolete
}

/// Local transport acceptance only. Never receiver delivery or usable bandwidth.
public struct SRTBandwidthProbeSnapshot: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case leaseExpired, timeLimit, byteLimit, invalidClock, unavailableStatistics, transportPressure
        case transportBackpressure, transportFailed, cancelled, finished, closed, replaced
    }
    public let id: UUID
    public let publishingGeneration: UInt64
    public let bitRate: Int
    public let startedAt: Double
    public let leaseDeadline: Double
    public let acceptedPayloadBytes: UInt64
    public let lastAcceptedAt: Double?
    public let reason: Reason?
}

/// One publication-owned attempt. Revocation is synchronous across actor hops.
/// The lock serializes revocation with one nonblocking native send; its closure
/// must not suspend, perform I/O other than that send, or reenter this object.
final class SRTBandwidthProbe: @unchecked Sendable {
    let id = UUID()
    let generation: UInt64
    private let lock = NSLock()
    private let bitRate: Int
    private let startedAt: Double
    private let retransmitted: UInt64
    private let dropped: Int32
    private var deadline: Double
    private var lastTime: Double
    private var tokenAt: Double
    private var statisticsAt: Double
    private var tokens: Double = 0
    private var bytes: UInt64 = 0
    private var lastAcceptedAt: Double?
    private var reason: SRTBandwidthProbeSnapshot.Reason?

    init(bitRate: Int, generation: UInt64, statistics: SRTPerformanceData, at: Double) throws {
        guard (1...2_000_000).contains(bitRate), at.isFinite, at >= 0 else {
            throw SRTBandwidthProbeError.invalidConfiguration
        }
        guard let sampled = statistics.sampledAt, sampled.isFinite, sampled >= 0,
              sampled <= at, at - sampled <= 0.1, statistics.msRTT.isFinite,
              (0...50).contains(statistics.msRTT), (0...50).contains(statistics.msSndBuf),
              statistics.pktSndDropTotal >= 0 else { throw SRTBandwidthProbeError.unavailableStatistics }
        self.bitRate = bitRate; self.generation = generation; startedAt = at
        deadline = at + 0.3; lastTime = at; tokenAt = at; statisticsAt = sampled
        retransmitted = statistics.byteRetransTotal; dropped = statistics.pktSndDropTotal
    }

    @discardableResult private func stop(_ next: SRTBandwidthProbeSnapshot.Reason) -> Bool {
        reason = reason ?? next; tokens = 0; return false
    }
    private func check(_ at: Double) -> Bool {
        guard reason == nil else { return false }
        guard at.isFinite, at >= lastTime else { return stop(.invalidClock) }
        lastTime = at
        guard at - startedAt < 60 else { return stop(.timeLimit) }
        guard at < deadline else { return stop(.leaseExpired) }
        guard bytes + 1316 <= 16 * 1024 * 1024 else { return stop(.byteLimit) }
        return true
    }
    private func eligible(_ at: Double) -> Bool {
        guard check(at) else { return false }
        tokens = min(1360, tokens + (at - tokenAt) * Double(bitRate) / 8)
        tokenAt = at
        return tokens >= 1360
    }
    /// A wake is only an opportunity. The same token cap and permit are checked
    /// again at native submission, so delayed timers never accumulate a burst.
    func nextOpportunityDelay(now: () -> Double) -> Double? {
        lock.withLock {
            let at = now()
            guard check(at) else { return nil }
            _ = eligible(at)
            return max(0, (1360 - tokens) * 8 / Double(bitRate))
        }
    }
    func isEligible(now: () -> Double) -> Bool { lock.withLock { eligible(now()) } }
    @discardableResult func renew(now: () -> Double) -> Bool {
        lock.withLock {
            let at = now()
            guard check(at) else { return false }
            deadline = at + 0.3; return true
        }
    }
    func cancel(_ reason: SRTBandwidthProbeSnapshot.Reason) { lock.withLock { _ = stop(reason) } }

    @discardableResult func offer(statistics: SRTPerformanceData?, now: () -> Double,
                                  send: (Data) throws -> Bool) throws -> Bool {
        try lock.withLock {
            let at = now()
            guard eligible(at) else { return false }
            guard let statistics, let sampled = statistics.sampledAt, sampled.isFinite,
                  sampled >= statisticsAt, sampled <= at, at - sampled <= 0.1,
                  statistics.msRTT.isFinite, statistics.msRTT >= 0, statistics.msSndBuf >= 0,
                  statistics.byteRetransTotal >= retransmitted, statistics.pktSndDropTotal >= dropped else {
                return stop(.unavailableStatistics)
            }
            statisticsAt = sampled
            guard statistics.msRTT <= 50, statistics.msSndBuf <= 50,
                  statistics.byteRetransTotal == retransmitted, statistics.pktSndDropTotal == dropped else {
                return stop(.transportPressure)
            }
            do {
                guard try send(SRTProbeMessage.encode(id: id, generation: generation, sequence: bytes / 1316, bitRate: bitRate)) else { return stop(.transportBackpressure) }
            } catch {
                if let restoration = error as? SRTNonblockingSend.RestorationFailure,
                   let completed = restoration.acceptedAt {
                    bytes += 1316
                    lastAcceptedAt = completed.isFinite && completed >= 0 ? completed : nil
                }
                stop(.transportFailed); throw error
            }
            // Count actual acceptance even if preempted across a deadline. A
            // receiver proof must reject such a late completion, never conceal it.
            tokens -= 1360; bytes += 1316
            let completed = now()
            lastAcceptedAt = completed.isFinite && completed >= 0 ? completed : nil
            _ = check(completed)
            return true
        }
    }
    func snapshot(now: () -> Double) -> SRTBandwidthProbeSnapshot {
        lock.withLock {
            _ = check(now())
            return .init(id: id, publishingGeneration: generation, bitRate: bitRate, startedAt: startedAt,
                leaseDeadline: deadline, acceptedPayloadBytes: bytes, lastAcceptedAt: lastAcceptedAt, reason: reason)
        }
    }
}

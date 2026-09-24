import Foundation

public enum SRTBandwidthProbeError: Error, Equatable, Sendable {
    case disabled, notPublishing, alreadyStarted, invalidConfiguration, unavailableStatistics, obsolete
}

/// Native-owner identity, revoked synchronously on every terminal probe path.
/// This is time-blind ownership only; consumers must also validate snapshot age
/// and lease. Reports and copied scalar values cannot construct an authority.
public final class SRTBandwidthProbeAuthority: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private let id: UUID
    private let generation: UInt64
    private let stage: UInt32?
    private let policy: SRTBandwidthProbePolicy
    private var revoked = false
    init(id: UUID, generation: UInt64, stage: UInt32? = nil, policy: SRTBandwidthProbePolicy = .localZeroLoss) {
        self.id = id; self.generation = generation; self.stage = stage; self.policy = policy
    }
    public func permits(id: UUID, generation: UInt64, stage: UInt32?, policy: SRTBandwidthProbePolicy = .localZeroLoss) -> Bool {
        lock.withLock { !revoked && self.id == id && self.generation == generation && self.stage == stage && self.policy == policy }
    }
    func revoke() { lock.withLock { revoked = true } }
    public static func == (lhs: SRTBandwidthProbeAuthority, rhs: SRTBandwidthProbeAuthority) -> Bool { lhs === rhs }
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
    public internal(set) var stage: UInt32? = nil
    public internal(set) var campaign: UInt32? = nil
    public internal(set) var authority: SRTBandwidthProbeAuthority? = nil
    public internal(set) var campaignStartedAt: Double? = nil
    public internal(set) var totalAcceptedPayloadBytes: UInt64? = nil
    public internal(set) var policy: SRTBandwidthProbePolicy = .localZeroLoss
}

/// One publication-owned attempt. Revocation is synchronous across actor hops.
/// The lock serializes revocation with one nonblocking native send; its closure
/// must not suspend, perform I/O other than that send, or reenter this object.
final class SRTBandwidthProbe: @unchecked Sendable {
    let id: UUID
    let generation: UInt64
    private let authority: SRTBandwidthProbeAuthority
    private let policy: SRTBandwidthProbePolicy
    private let lock = NSLock()
    private let bitRate: Int
    private let startedAt: Double
    private let stage: UInt32?
    private let campaign: UInt32?
    private let campaignStartedAt: Double?
    private let previouslyAcceptedPayloadBytes: UInt64
    private let retransmitted: UInt64
    private let dropped: Int32
    private var deadline: Double
    private var lastTime: Double
    private var tokenAt: Double
    private var statisticsAt: Double
    private var recoveryGuard: SRTProbeTransportGuard?
    private var tokens: Double = 0
    private var bytes: UInt64 = 0
    private var lastAcceptedAt: Double?
    private var reason: SRTBandwidthProbeSnapshot.Reason?

    init(bitRate: Int, generation: UInt64, statistics: SRTPerformanceData, at: Double,
         stage: UInt32? = nil, campaign: UInt32? = nil, campaignStartedAt: Double? = nil,
         previouslyAcceptedPayloadBytes: UInt64 = 0, policy: SRTBandwidthProbePolicy = .localZeroLoss) throws {
        guard policy == .localZeroLoss || stage != nil else { throw SRTBandwidthProbeError.invalidConfiguration }
        self.policy = policy
        let maximumBitRate = stage == nil ? 2_000_000 : 12_000_000
        guard (1...maximumBitRate).contains(bitRate), at.isFinite, at >= 0 else {
            throw SRTBandwidthProbeError.invalidConfiguration
        }
        if let campaign {
            guard campaign > 0, stage != nil else { throw SRTBandwidthProbeError.invalidConfiguration }
        }
        if let stage {
            guard generation > 0, (1...32).contains(stage),
                  let campaignStartedAt, campaignStartedAt.isFinite, campaignStartedAt >= 0,
                  campaignStartedAt <= at, at - campaignStartedAt < 60,
                  previouslyAcceptedPayloadBytes % 1316 == 0,
                  previouslyAcceptedPayloadBytes <= 16 * 1024 * 1024 - 1316,
                  stage != 1 || (campaignStartedAt == at && previouslyAcceptedPayloadBytes == 0) else {
                throw SRTBandwidthProbeError.invalidConfiguration
            }
        } else {
            guard campaignStartedAt == nil, previouslyAcceptedPayloadBytes == 0 else {
                throw SRTBandwidthProbeError.invalidConfiguration
            }
        }
        guard let sampled = statistics.sampledAt, sampled.isFinite, sampled >= 0,
              sampled <= at, at - sampled <= 0.1, statistics.msRTT.isFinite,
              statistics.pktSndDropTotal >= 0 else { throw SRTBandwidthProbeError.unavailableStatistics }
        if policy == .recoveryBudget {
            guard let value = SRTProbeTransportGuard(statistics: statistics, at: at) else {
                throw SRTBandwidthProbeError.unavailableStatistics
            }
            recoveryGuard = value
        } else {
            guard (0...50).contains(statistics.msRTT), (0...50).contains(statistics.msSndBuf) else {
                throw SRTBandwidthProbeError.unavailableStatistics
            }
        }
        let id = UUID()
        self.id = id; authority = SRTBandwidthProbeAuthority(id: id, generation: generation, stage: stage, policy: policy)
        self.stage = stage; self.campaign = campaign; self.campaignStartedAt = campaignStartedAt
        self.previouslyAcceptedPayloadBytes = previouslyAcceptedPayloadBytes
        self.bitRate = bitRate; self.generation = generation; startedAt = at
        deadline = at + 0.3; lastTime = at; tokenAt = at; statisticsAt = sampled
        retransmitted = statistics.byteRetransTotal; dropped = statistics.pktSndDropTotal
    }

    /// Only the native owner supplies the current ordinal; restart checks this
    /// before cancelling wake work or beginning a new admission. Never wraps.
    func nextCampaign() throws -> UInt32 {
        guard let campaign else { throw SRTBandwidthProbeError.obsolete }
        let (next, overflow) = campaign.addingReportingOverflow(1)
        guard !overflow else { throw SRTBandwidthProbeError.invalidConfiguration }
        return next
    }

    @discardableResult private func stop(_ next: SRTBandwidthProbeSnapshot.Reason) -> Bool {
        reason = reason ?? next; tokens = 0; authority.revoke(); return false
    }
    private func check(_ at: Double) -> Bool {
        guard reason == nil else { return false }
        guard at.isFinite, at >= lastTime else { return stop(.invalidClock) }
        lastTime = at
        guard at - (campaignStartedAt ?? startedAt) < 60 else { return stop(.timeLimit) }
        guard at < deadline else { return stop(.leaseExpired) }
        guard previouslyAcceptedPayloadBytes + bytes + 1316 <= 16 * 1024 * 1024 else { return stop(.byteLimit) }
        return true
    }
    private func eligible(_ at: Double) -> Bool {
        guard check(at) else { return false }
        tokens = min(1360, tokens + (at - tokenAt) * Double(bitRate) / 8)
        tokenAt = at
        return tokens >= 1360
    }
    /// Versioned wake bound; readiness still requires one 1360-byte token.
    var minimumWakeInterval: Double { stage == nil ? 0.002 : 0.0005 }

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
            if policy == .recoveryBudget {
                guard var value = recoveryGuard else { return stop(.unavailableStatistics) }
                if let failure = value.observe(statistics, at: at) { return stop(failure) }
                recoveryGuard = value
            } else {
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
            }
            do {
                let message: Data
                if let stage, let campaign {
                    message = try SRTProbeMessage.encodeCampaign(id: id, generation: generation,
                        campaign: campaign, stage: stage, sequence: bytes / 1316, bitRate: bitRate)
                } else if let stage {
                    message = try SRTProbeMessage.encodeStage(id: id, generation: generation,
                        stage: stage, sequence: bytes / 1316, bitRate: bitRate)
                } else {
                    message = SRTProbeMessage.encode(id: id, generation: generation,
                        sequence: bytes / 1316, bitRate: bitRate)
                }
                guard try send(message) else { return stop(.transportBackpressure) }
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
                leaseDeadline: deadline, acceptedPayloadBytes: bytes, lastAcceptedAt: lastAcceptedAt, reason: reason,
                stage: stage, campaign: campaign, authority: authority, campaignStartedAt: campaignStartedAt,
                totalAcceptedPayloadBytes: stage == nil ? nil : previouslyAcceptedPayloadBytes + bytes, policy: policy)
        }
    }
}

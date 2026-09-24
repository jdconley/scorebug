import Foundation

/// Native-send admission only; neither policy establishes receiver delivery.
public enum SRTBandwidthProbePolicy: String, Sendable {
    case localZeroLoss = "local-zero-loss-v1"
    case recoveryBudget = "recovery-budget-v1"
}

/// Constant-size native-send guard. Receipt and media proof remain separate.
/// The half-delay queue ceiling reserves recovery room; it is a project probe
/// bound, not a protocol promise that packets will arrive before a deadline.
struct SRTProbeTransportGuard {
    private struct Sample: Equatable {
        let at: Double
        let elapsed: Int64
        let sent: UInt64
        let retransmitted: UInt64
        let dropped: Int32
        let rtt: Double
        let buffer: Int32
        let delay: Int32
        init?(_ value: SRTPerformanceData, at now: Double) {
            guard let at = value.sampledAt, at.isFinite, at >= 0,
                  now.isFinite, at <= now, now - at <= 0.1,
                  value.msTimeStamp >= 0, value.byteRetransTotal <= value.byteSentTotal,
                  value.pktSndDropTotal >= 0, value.msRTT.isFinite, value.msRTT >= 0,
                  value.msSndBuf >= 0, value.msSndTsbPdDelay > 0 else { return nil }
            self.at = at; elapsed = value.msTimeStamp; sent = value.byteSentTotal
            retransmitted = value.byteRetransTotal; dropped = value.pktSndDropTotal
            rtt = value.msRTT; buffer = value.msSndBuf; delay = value.msSndTsbPdDelay
        }
        var withinBudget: Bool {
            rtt <= min(500, Double(delay) / 4) && Double(buffer) <= min(500, Double(delay) / 2)
        }
    }
    private var previous: Sample
    init?(statistics: SRTPerformanceData, at now: Double) {
        guard let initial = Sample(statistics, at: now), initial.withinBudget else { return nil }
        previous = initial
    }
    mutating func observe(_ statistics: SRTPerformanceData?, at now: Double) -> SRTBandwidthProbeSnapshot.Reason? {
        guard let statistics, let current = Sample(statistics, at: now),
              current.at >= previous.at, current.elapsed >= previous.elapsed,
              current.sent >= previous.sent, current.retransmitted >= previous.retransmitted,
              current.dropped >= previous.dropped,
              current.retransmitted - previous.retransmitted <= current.sent - previous.sent,
              current.at != previous.at || current == previous else { return .unavailableStatistics }
        guard current.withinBudget, current.dropped == previous.dropped else { return .transportPressure }
        previous = current
        return nil
    }
}

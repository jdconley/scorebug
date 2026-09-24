import Foundation
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTRecoveryBudgetProbeTests {
    private func stats(_ at: Double, sent: UInt64 = 10_000, retransmitted: UInt64 = 0,
                       rtt: Double = 65, buffer: Int32 = 67, delay: Int32 = 400,
                       elapsed: Int64 = 1000, drops: Int32 = 0) -> SRTPerformanceData {
        var value = CBytePerfMon()
        value.byteSentTotal = sent; value.byteRetransTotal = retransmitted
        value.msRTT = rtt; value.msSndBuf = buffer; value.msSndTsbPdDelay = delay
        value.msTimeStamp = elapsed; value.pktSndDropTotal = drops
        return .init(mon: value, sampledAt: at)
    }
    private func probe(_ sample: SRTPerformanceData? = nil) throws -> SRTBandwidthProbe {
        try SRTBandwidthProbe(bitRate: 500_000, generation: 1, statistics: sample ?? stats(10), at: 10,
            stage: 1, campaignStartedAt: 10, policy: .recoveryBudget)
    }
    @Test func recoverySnapshotsRetainRawSuccessfulCheckWithoutRefreshingOrLosingFailureContext() throws {
        let p = try probe(), initial = p.snapshot(now: { 10 })
        let first = try #require(initial.recoveryObservation)
        #expect(first.isValid && first.checkedAt == 10 && first.sampledAt == 10)
        #expect(first.elapsedMilliseconds == 1000 && first.sentBytes == 10_000 && first.retransmittedBytes == 0)
        #expect(first.droppedPackets == 0 && first.rttMilliseconds == 65)
        #expect(first.senderBufferMilliseconds == 67 && first.senderDeliveryDelayMilliseconds == 400)
        let sample = stats(10.05, sent: 12000, retransmitted: 1316)
        #expect(try p.offer(statistics: sample, now: { 10.1 }, send: { _ in true }))
        let next = try #require(p.snapshot(now: { 10.11 }).recoveryObservation)
        #expect(next.checkedAt == 10.1 && next.sampledAt == 10.05 && next.isValid)
        #expect(next.sentBytes == 12000 && next.retransmittedBytes == 1316)
        #expect(initial.recoveryObservation == first)
        #expect(p.snapshot(now: { 10.12 }).recoveryObservation == next)
        #expect(try p.offer(statistics: sample, now: { 10.13 }, send: { _ in true }))
        let cached = try #require(p.snapshot(now: { 10.13 }).recoveryObservation)
        #expect(cached.checkedAt == 10.13 && cached.sampledAt == 10.05)
        #expect(try !p.offer(statistics: stats(10.2, sent: 14000, retransmitted: 1500, drops: 1), now: { 10.2 }, send: { _ in Issue.record("Dropped sample sent"); return true }))
        let terminal = p.snapshot(now: { 10.21 })
        #expect(terminal.reason == .transportPressure && terminal.recoveryObservation == cached)
        p.cancel(.cancelled)
        #expect(p.snapshot(now: { 11 }).recoveryObservation == cached)
        let legacy = try SRTBandwidthProbe(bitRate: 500_000, generation: 1,
            statistics: stats(10, rtt: 20, buffer: 20), at: 10)
        #expect(legacy.snapshot(now: { 10 }).recoveryObservation == nil)
    }
    @Test func delayedLinkAndRecoveredRetriesKeepNativePermitWithoutClaimingDelivery() throws {
        let p = try probe(), initial = p.snapshot(now: { 10 })
        #expect(initial.policy == .recoveryBudget)
        #expect(initial.authority?.permits(id: initial.id, generation: 1, stage: 1) == false)
        #expect(initial.authority?.permits(id: initial.id, generation: 1, stage: 1, policy: .recoveryBudget) == true)
        var sends = 0
        #expect(try p.offer(statistics: stats(10.1, sent: 12_000, retransmitted: 1316), now: { 10.1 }, send: { _ in sends += 1; return true }))
        #expect(sends == 1)
        #expect(p.snapshot(now: { 10.1 }).acceptedPayloadBytes == 1316)
        #expect(p.snapshot(now: { 10.1 }).reason == nil)
        p.cancel(.cancelled)
        #expect(initial.authority?.permits(id: initial.id, generation: 1, stage: 1, policy: .recoveryBudget) == false)
    }
    @Test func optInDoesNotChangeLegacyOrPermitUnstagedNetworkProbe() throws {
        #expect(throws: SRTBandwidthProbeError.unavailableStatistics) {
            try SRTBandwidthProbe(bitRate: 500_000, generation: 1, statistics: stats(10), at: 10,
                stage: 1, campaignStartedAt: 10)
        }
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTBandwidthProbe(bitRate: 500_000, generation: 1, statistics: stats(10), at: 10,
                policy: .recoveryBudget)
        }
    }
    @Test func exactBudgetBoundariesAndAbsoluteCeilings() throws {
        for sample in [stats(10, rtt: 100, buffer: 200), stats(10, rtt: 500, buffer: 500, delay: 2000)] {
            #expect(try probe(sample).snapshot(now: { 10 }).reason == nil)
        }
        for sample in [stats(10, rtt: 100.001), stats(10, buffer: 201),
                       stats(10, rtt: 501, delay: 10000), stats(10, buffer: 501, delay: 10000)] {
            #expect(throws: SRTBandwidthProbeError.unavailableStatistics) { try probe(sample) }
        }
    }
    @Test func invalidInitialMeasurementsFailClosed() {
        for sample in [stats(10, delay: 0), stats(10, delay: -1), stats(10, rtt: .nan),
                       stats(10, rtt: -.infinity), stats(10, buffer: -1), stats(10, elapsed: -1),
                       stats(10, drops: -1), stats(10, sent: 5, retransmitted: 6),
                       stats(9.89), stats(10.01)] {
            #expect(throws: SRTBandwidthProbeError.unavailableStatistics) { try probe(sample) }
        }
    }
    @Test func pressureAndUnavailableSamplesRevokeBeforeSending() throws {
        let cases: [(SRTPerformanceData?, SRTBandwidthProbeSnapshot.Reason)] = [
            (stats(10.1, rtt: 100.001), .transportPressure),
            (stats(10.1, buffer: 201), .transportPressure),
            (stats(10.1, drops: 1), .transportPressure),
            (stats(10.1, delay: 200), .transportPressure),
            (stats(10.1, delay: 0), .unavailableStatistics),
            (stats(10.1, rtt: .nan), .unavailableStatistics),
            (stats(10.1, sent: 9000), .unavailableStatistics),
            (stats(10.1, sent: 10010, retransmitted: 11), .unavailableStatistics),
            (stats(10.1, elapsed: 999), .unavailableStatistics),
            (stats(9.99), .unavailableStatistics), (nil, .unavailableStatistics),
        ]
        for (sample, reason) in cases {
            let p = try probe(), initial = p.snapshot(now: { 10 })
            var sends = 0
            #expect(try !p.offer(statistics: sample, now: { 10.1 }, send: { _ in sends += 1; return true }))
            #expect(sends == 0)
            #expect(p.snapshot(now: { 10.1 }).reason == reason)
            #expect(initial.authority?.permits(id: initial.id, generation: 1, stage: 1, policy: .recoveryBudget) == false)
        }
    }
    @Test func validatesAgainstLatestObservationAndRejectsChangedCachedCollection() throws {
        for next in [stats(10.15, sent: 19_999, retransmitted: 100),
                     stats(10.15, sent: 20_010, retransmitted: 111),
                     stats(10.15, sent: 21_000, retransmitted: 99),
                     stats(10.1, sent: 20_000, retransmitted: 100, rtt: 66),
                     stats(10.1, sent: 20_001, retransmitted: 100),
                     stats(10.1, sent: 20_000, retransmitted: 100, delay: 401)] {
            let p = try probe()
            #expect(try p.offer(statistics: stats(10.1, sent: 20_000, retransmitted: 100), now: { 10.1 }, send: { _ in true }))
            #expect(try !p.offer(statistics: next, now: { 10.18 }, send: { _ in Issue.record("Invalid collection submitted"); return true }))
            #expect(p.snapshot(now: { 10.18 }).reason == .unavailableStatistics)
        }
        let p = try probe(), cached = stats(10.1, sent: 20_000, retransmitted: 100)
        #expect(try p.offer(statistics: cached, now: { 10.1 }, send: { _ in true }))
        #expect(try p.offer(statistics: cached, now: { 10.18 }, send: { _ in true }))
        #expect(try !p.offer(statistics: cached, now: { 10.21 }, send: { _ in Issue.record("Stale collection submitted"); return true }))
        #expect(p.snapshot(now: { 10.21 }).reason == .unavailableStatistics)
    }
    @Test func networkPolicyRetainsPacingLeaseAndBackpressureLimits() throws {
        let p = try probe()
        #expect(try !p.offer(statistics: stats(10), now: { 10 }, send: { _ in Issue.record("No token"); return true }))
        #expect(try p.offer(statistics: stats(10.1), now: { 10.1 }, send: { _ in true }))
        #expect(try !p.offer(statistics: stats(10.1), now: { 10.1 }, send: { _ in Issue.record("Burst"); return true }))
        #expect(try !p.offer(statistics: stats(10.3), now: { 10.3 }, send: { _ in Issue.record("Expired lease"); return true }))
        #expect(p.snapshot(now: { 10.3 }).reason == .leaseExpired)
        let blocked = try probe()
        #expect(try !blocked.offer(statistics: stats(10.1), now: { 10.1 }, send: { _ in false }))
        #expect(blocked.snapshot(now: { 10.1 }).reason == .transportBackpressure)
    }
}

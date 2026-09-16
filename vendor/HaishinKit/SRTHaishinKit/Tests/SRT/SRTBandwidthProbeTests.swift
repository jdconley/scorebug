import Foundation
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTBandwidthProbeTests {
    @Test func opportunityDelayTracksTokensWithoutBankingCatchUpTraffic() throws {
        let probe = try makeProbe()
        #expect(abs(try #require(probe.nextOpportunityDelay(now: { 10 })) - 0.01088) < 0.000001)
        #expect(abs(try #require(probe.nextOpportunityDelay(now: { 10.005 })) - 0.00588) < 0.000001)
        #expect(probe.nextOpportunityDelay(now: { 10.2 }) == 0)
        #expect(try probe.offer(statistics: stats(10.2), now: { 10.2 }, send: { true }))
        #expect(abs(try #require(probe.nextOpportunityDelay(now: { 10.2 })) - 0.01088) < 0.000001)
        #expect(probe.nextOpportunityDelay(now: { 10.3 }) == nil)
        #expect(probe.snapshot(now: { 10.3 }).reason == .leaseExpired)
    }
    @Test func transportWakeCoalescesAndClosedGenerationCannotWakeOrAdmit() async {
        let accounting = TransportOutputAccounting()
        for _ in 0..<1000 { accounting.wake() }
        #expect(accounting.enqueue { true })
        accounting.finish()
        var wakes = 0
        for await _ in accounting.wakes { wakes += 1 }
        #expect(wakes == 1)
        #expect(accounting.pending == 1)
        #expect(!accounting.enqueue { Issue.record("Closed output admitted"); return true })
        #expect(accounting.dequeue())
        #expect(accounting.pending == 0)
        accounting.wake()
    }
    @Test func wakeOwnerCancelledBeforeTimerResumeStillJoinsWithoutWaking() async throws {
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: stats(at), at: at)
        let owner = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await SRTProbeWakeSchedule.run(probe: probe, wake: { Issue.record("Cancelled owner woke transport") })
        }
        await owner.value
    }
    @Test func wakeOwnerCancellationJoinsEnteredHandler() async throws {
        let at = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: stats(at), at: at)
        let gate = ProbeSubmissionGate(); defer { gate.release() }
        let owner = Task { await SRTProbeWakeSchedule.run(probe: probe, wake: { gate.enter() }); gate.markJoined() }
        let end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        owner.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!gate.joined)
        gate.release()
        await owner.value
        let entries = gate.entries
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.entries == entries)
        #expect(entries == 1)
    }
    @Test func nullPacketShapeAndOneMessageTokenBound() throws {
        let data = SRTBandwidthProbe.message
        #expect(data.count == 1316)
        for at in stride(from: 0, to: data.count, by: 188) {
            #expect(Array(data[at..<at + 4]) == [0x47, 0x1f, 0xff, 0x10])
            #expect(data[at + 4..<at + 188].allSatisfy { $0 == 0xff })
        }
        let probe = try makeProbe()
        #expect(!probe.isEligible(now: { 10 }))
        #expect(probe.isEligible(now: { 10.02 }))
        #expect(try probe.offer(statistics: stats(10.02), now: { 10.02 }, send: { true }))
        #expect(!probe.isEligible(now: { 10.02 }))
        #expect(probe.renew(now: { 10.1 }))
        #expect(try probe.offer(statistics: stats(10.3), now: { 10.3 }, send: { true }))
        #expect(!probe.isEligible(now: { 10.3 }))
        #expect(probe.snapshot(now: { 10.3 }).acceptedPayloadBytes == 2632)
    }
    @Test func expiryAndLateRenewalAreStickyEvenWithoutMedia() throws {
        let probe = try makeProbe()
        #expect(!probe.renew(now: { 10.3 }))
        #expect(probe.snapshot(now: { 10.3 }).reason == .leaseExpired)
        #expect(!probe.renew(now: { 10.4 }))
        #expect(!probe.isEligible(now: { 10.4 }))
        #expect(try !probe.offer(statistics: stats(10.4), now: { 10.4 }, send: { Issue.record("Expired probe submitted"); return true }))
    }
    @Test(arguments: 0..<9) func invalidOrPressuredStatisticsWithdrawWithoutSending(mode: Int) throws {
        let probe = try makeProbe()
        var mon = CBytePerfMon(); mon.msRTT = 2; mon.byteRetransTotal = 10; mon.pktSndDropTotal = 2
        var at: Double? = 10.02
        switch mode {
        case 0: mon.msRTT = 50.01
        case 1: mon.msSndBuf = 51
        case 2: mon.byteRetransTotal = 11
        case 3: mon.pktSndDropTotal = 3
        case 4: at = 9.9
        case 5: at = 10.03
        case 6: at = nil
        case 7: mon.byteRetransTotal = 9
        default: mon.msRTT = .nan
        }
        #expect(try !probe.offer(statistics: .init(mon: mon, sampledAt: at), now: { 10.02 }, send: { Issue.record("Unhealthy probe submitted"); return true }))
        #expect(probe.snapshot(now: { 10.02 }).reason != nil)
        #expect(!probe.renew(now: { 10.03 }))
    }
    @Test func cancellationBackpressureAndFailureDoNotCountAcceptance() throws {
        let cancelled = try makeProbe(); cancelled.cancel(.cancelled)
        #expect(!cancelled.isEligible(now: { 10.02 }))
        let blocked = try makeProbe()
        #expect(try !blocked.offer(statistics: stats(10.02), now: { 10.02 }, send: { false }))
        #expect(blocked.snapshot(now: { 10.02 }).reason == .transportBackpressure)
        #expect(blocked.snapshot(now: { 10.02 }).acceptedPayloadBytes == 0)
        let failed = try makeProbe()
        #expect(throws: Failure.injected) {
            try failed.offer(statistics: stats(10.02), now: { 10.02 }, send: { throw Failure.injected })
        }
        #expect(failed.snapshot(now: { 10.02 }).reason == .transportFailed)
        #expect(failed.snapshot(now: { 10.02 }).acceptedPayloadBytes == 0)
    }
    @Test func acceptanceRecordsCompletionAndExposesExpiryCrossedDuringNativeCall() throws {
        let probe = try makeProbe(); var clock = 10.29
        #expect(try probe.offer(statistics: stats(10.29), now: { clock }, send: { clock = 10.31; return true }))
        let result = probe.snapshot(now: { clock })
        #expect(result.lastAcceptedAt == 10.31)
        #expect(result.acceptedPayloadBytes == 1316)
        #expect(result.reason == .leaseExpired)
    }
    @Test func timeBudgetAndConfigurationBounds() throws {
        for rate in [0, -1, 2_000_001] {
            #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try SRTBandwidthProbe(bitRate: rate, generation: 1, statistics: stats(10), at: 10)
            }
        }
        let probe = try makeProbe(); var at = 10.0
        while at < 70 {
            at += 0.05
            _ = probe.renew(now: { at })
            _ = try probe.offer(statistics: stats(at), now: { at }, send: { true })
        }
        let value = probe.snapshot(now: { at })
        #expect(value.reason == .timeLimit)
        #expect(value.acceptedPayloadBytes <= 16 * 1024 * 1024)
        let reversed = try makeProbe()
        #expect(!reversed.isEligible(now: { 9 }))
        #expect(reversed.snapshot(now: { 10 }).reason == .invalidClock)
    }
    @Test func acceptedPaddingRemainsCountedWhenRestoringSocketModeFails() throws {
        let probe = try makeProbe()
        #expect(throws: (any Error).self) {
            try probe.offer(statistics: stats(10.02), now: { 10.02 }, send: {
                try SRTNonblockingSend.perform(get: { true }, set: { if $0 { throw Failure.injected } }, send: { true }, now: { 10.02 })
            })
        }
        let result = probe.snapshot(now: { 10.03 })
        #expect(result.acceptedPayloadBytes == 1316)
        #expect(result.lastAcceptedAt != nil)
        #expect(result.reason == .transportFailed)
    }
    @Test func revocationJoinsEnteredSubmissionAndPreventsEveryLaterWrite() async throws {
        let probe = try makeProbe(), gate = ProbeSubmissionGate()
        defer { gate.release() }
        let sending = Task.detached {
            try probe.offer(statistics: self.stats(10.02), now: { 10.02 }, send: { gate.enter(); return true })
        }
        let end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        let cancelling = Task.detached { probe.cancel(.cancelled) }
        gate.release()
        #expect(try await sending.value)
        await cancelling.value
        #expect(probe.snapshot(now: { 10.03 }).acceptedPayloadBytes == 1316)
        #expect(probe.snapshot(now: { 10.03 }).reason == .cancelled)
        #expect(try !probe.offer(statistics: stats(10.04), now: { 10.04 }, send: {
            Issue.record("Revoked permit submitted"); return true
        }))
    }
    private enum Failure: Error { case injected }
    private func makeProbe() throws -> SRTBandwidthProbe {
        try .init(bitRate: 1_000_000, generation: 1, statistics: stats(10), at: 10)
    }
    private func stats(_ at: Double) -> SRTPerformanceData {
        var mon = CBytePerfMon(); mon.msRTT = 2; mon.byteRetransTotal = 10; mon.pktSndDropTotal = 2
        return .init(mon: mon, sampledAt: at)
    }
}
private final class ProbeSubmissionGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var entryCount = 0
    private var didJoin = false
    var joined: Bool { lock.withLock { didJoin } }
    func markJoined() { lock.withLock { didJoin = true } }
    var entries: Int { lock.withLock { entryCount } }
    var entered: Bool { lock.withLock { didEnter } }
    func enter() { lock.withLock { didEnter = true; entryCount += 1 }; _ = signal.wait(timeout: .now() + 5) }
    func release() { signal.signal() }
}

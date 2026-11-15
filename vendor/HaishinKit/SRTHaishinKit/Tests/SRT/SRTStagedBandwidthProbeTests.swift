import Foundation
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTStagedBandwidthProbeTests {
    @Test func wakeFloorIsVersionedAndDoesNotChangeTokenEligibility() throws {
        let staged = try makeProbe(rate: 12_000_000)
        let legacy = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: stats(10), at: 10)
        #expect(staged.minimumWakeInterval == 0.0005)
        #expect(legacy.minimumWakeInterval == 0.002)
        // The first staged tick cannot grant a send before 1360 wire bytes accrue.
        #expect(!staged.isEligible(now: { 10 + staged.minimumWakeInterval }))
        #expect(staged.isEligible(now: { 10.001 }))
        #expect(!legacy.isEligible(now: { 10 + legacy.minimumWakeInterval }))
        #expect(legacy.isEligible(now: { 10.006 }))
    }

    @Test func stagedRateCeilingKeepsLegacyLimitAndOneMessagePacing() throws {
        let probe = try makeProbe(rate: 12_000_000)
        let interval = 1360.0 * 8 / 12_000_000
        #expect(abs(try #require(probe.nextOpportunityDelay(now: { 10 })) - interval) < 0.000000001)
        #expect(!probe.isEligible(now: { 10 + interval / 2 }))
        var messages: [Data] = []
        #expect(try probe.offer(statistics: stats(10.2), now: { 10.2 }, send: { messages.append($0); return true }))
        // A delayed wake can bank exactly one 1360-byte token, not a burst.
        #expect(try !probe.offer(statistics: stats(10.2), now: { 10.2 }, send: { messages.append($0); return true }))
        #expect(messages.count == 1 && messages.first?.count == 1316)
        #expect(Array(try #require(messages.first)[44..<48]) == [0, 0xb7, 0x1b, 0])
        #expect(abs(try #require(probe.nextOpportunityDelay(now: { 10.2 })) - interval) < 0.000000001)
        #expect(probe.snapshot(now: { 10.2 }).acceptedPayloadBytes == 1316)
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) { try makeProbe(rate: 12_000_001) }
        let legacy = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: stats(10), at: 10)
        #expect(legacy.snapshot(now: { 10 }).bitRate == 2_000_000)
        for rate in [2_000_001, 12_000_000] {
            #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try SRTBandwidthProbe(bitRate: rate, generation: 1, statistics: stats(10), at: 10)
            }
        }
    }

    @Test(arguments: ["lease", "pressure", "cancel"])
    func highRateRetainsRevocation(mode: String) throws {
        let probe = try makeProbe(rate: 12_000_000)
        let retained = probe.snapshot(now: { 10 })
        let reason: SRTBandwidthProbeSnapshot.Reason
        switch mode {
        case "lease":
            reason = .leaseExpired
            #expect(!probe.renew(now: { 10.3 }))
        case "pressure":
            reason = .transportPressure
            var mon = CBytePerfMon(); mon.msRTT = 51
            #expect(try !probe.offer(statistics: .init(mon: mon, sampledAt: 10.02), now: { 10.02 }, send: { _ in
                Issue.record("Pressured high-rate probe submitted"); return true
            }))
        default: reason = .cancelled; probe.cancel(.cancelled)
        }
        #expect(probe.snapshot(now: { 10.3 }).reason == reason)
        #expect(retained.authority?.permits(id: retained.id, generation: 1, stage: 1) == false)
        #expect(!probe.renew(now: { 10.3 }))
        #expect(try !probe.offer(statistics: stats(10.3), now: { 10.3 }, send: { _ in
            Issue.record("Revoked high-rate probe submitted"); return true
        }))
    }

    @Test func stagedWireBindsAuthorityAndUsesLocalAcceptedSequence() throws {
        let probe = try makeProbe(stage: 2, campaign: 9, previous: 1316 * 5)
        let original = probe.snapshot(now: { 10 })
        let authority = try #require(original.authority)
        #expect(original.campaign == nil)
        #expect(original.stage == 2)
        #expect(original.campaignStartedAt == 9)
        #expect(original.totalAcceptedPayloadBytes == 1316 * 5)
        #expect(authority.permits(id: original.id, generation: 1, stage: 2))
        for stage: UInt32? in [nil, 1, 3] {
            #expect(!authority.permits(id: original.id, generation: 1, stage: stage))
        }
        #expect(!authority.permits(id: UUID(), generation: 1, stage: 2))
        #expect(!authority.permits(id: original.id, generation: 2, stage: 2))
        var messages: [Data] = []
        for index in 0..<3 {
            let at = 10.02 + Double(index) * 0.02
            let accepted = try probe.offer(statistics: stats(at), now: { at }, send: {
                messages.append($0); return index < 2
            })
            #expect(accepted == (index < 2))
        }
        #expect(messages.count == 3)
        for (sequence, message) in messages.enumerated() {
            #expect(message == (try SRTProbeMessage.encodeStage(id: original.id, generation: 1,
                stage: 2, sequence: UInt64(sequence), bitRate: 1_000_000)))
        }
        let final = probe.snapshot(now: { 10.06 })
        #expect(final.acceptedPayloadBytes == 2632)
        #expect(final.totalAcceptedPayloadBytes == 1316 * 7)
        #expect(final.reason == .transportBackpressure)
        #expect(!authority.permits(id: original.id, generation: 1, stage: 2))
    }

    @Test func replacementCarriesCampaignBudgetButResetsSequence() throws {
        let first = try makeProbe()
        #expect(try first.offer(statistics: stats(10.02), now: { 10.02 }, send: { _ in true }))
        first.cancel(.replaced)
        let prior = first.snapshot(now: { 10.03 })
        let second = try makeProbe(stage: 2, at: 10.03,
            campaign: prior.campaignStartedAt, previous: try #require(prior.totalAcceptedPayloadBytes))
        #expect(second.id != first.id)
        var secondMessage: Data?
        #expect(try second.offer(statistics: stats(10.05), now: { 10.05 }, send: { message in
            secondMessage = message; return true
        }))
        #expect(Array(try #require(secondMessage)[36..<44]) == Array(repeating: 0, count: 8))
        let current = second.snapshot(now: { 10.05 })
        #expect(current.acceptedPayloadBytes == 1316)
        #expect(current.totalAcceptedPayloadBytes == 2632)
        #expect(current.campaignStartedAt == 10)
    }

    @Test(arguments: [1_000_000, 12_000_000]) func cumulativeLimitAllowsLastWholeMessageThenRevokes(rate: Int) throws {
        let lastWholeMessage = UInt64(16 * 1024 * 1024 / 1316) * 1316
        let probe = try makeProbe(stage: 32, campaign: 9, previous: lastWholeMessage - 1316, rate: rate)
        let original = probe.snapshot(now: { 10 })
        #expect(try probe.offer(statistics: stats(10.02), now: { 10.02 }, send: { _ in true }))
        let final = probe.snapshot(now: { 10.02 })
        #expect(final.acceptedPayloadBytes == 1316)
        #expect(final.totalAcceptedPayloadBytes == lastWholeMessage)
        #expect(final.reason == .byteLimit)
        #expect(!probe.renew(now: { 10.02 }))
        #expect(try !probe.offer(statistics: stats(10.04), now: { 10.04 }, send: { _ in
            Issue.record("Exhausted campaign submitted"); return true
        }))
        #expect(original.authority?.permits(id: original.id, generation: 1, stage: 32) == false)
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try makeProbe(stage: 3, campaign: 9, previous: lastWholeMessage)
        }
    }

    @Test(arguments: [1_000_000, 12_000_000]) func campaignDeadlineCannotRestartAtStageTransition(rate: Int) throws {
        let probe = try makeProbe(stage: 2, at: 69.95, campaign: 10, previous: 1316, rate: rate)
        #expect(probe.renew(now: { 69.97 }))
        #expect(try probe.offer(statistics: stats(69.98), now: { 69.98 }, send: { _ in true }))
        #expect(!probe.isEligible(now: { 70 }))
        let final = probe.snapshot(now: { 70 })
        #expect(final.startedAt == 69.95)
        #expect(final.campaignStartedAt == 10)
        #expect(final.reason == .timeLimit)
        #expect(!probe.renew(now: { 70 }))
    }

    @Test func acceptedSendCrossingCampaignDeadlineStillCounts() throws {
        let probe = try makeProbe(stage: 2, at: 69.95, campaign: 10, previous: 2632)
        var clock = 69.98
        #expect(try probe.offer(statistics: stats(clock), now: { clock }, send: { _ in clock = 70; return true }))
        let final = probe.snapshot(now: { clock })
        #expect(final.acceptedPayloadBytes == 1316)
        #expect(final.totalAcceptedPayloadBytes == 3948)
        #expect(final.lastAcceptedAt == 70)
        #expect(final.reason == .timeLimit)
    }

    @Test func restorationFailureCountsAcceptanceInCampaignBudget() throws {
        let probe = try makeProbe(stage: 2, campaign: 9, previous: 2632)
        #expect(try probe.offer(statistics: stats(10.02), now: { 10.02 }, send: { _ in true }))
        #expect(throws: (any Error).self) {
            try probe.offer(statistics: stats(10.04), now: { 10.04 }, send: { _ in
                try SRTNonblockingSend.perform(get: { true }, set: { if $0 { throw Failure.injected } },
                    send: { true }, now: { 10.04 })
            })
        }
        let final = probe.snapshot(now: { 10.04 })
        #expect(final.acceptedPayloadBytes == 2632)
        #expect(final.totalAcceptedPayloadBytes == 5264)
        #expect(final.lastAcceptedAt == 10.04)
        #expect(final.reason == .transportFailed)
        #expect(final.authority?.permits(id: final.id, generation: 1, stage: 2) == false)
    }

    @Test(arguments: 0..<18) func malformedCampaignConfigurationIsRejected(mode: Int) {
        var generation: UInt64 = 1, stage: UInt32? = 2, campaign: Double? = 9, previous: UInt64 = 1316
        switch mode {
        case 0: generation = 0
        case 1: stage = 0
        case 2: stage = 33
        case 3: stage = .max
        case 4: campaign = nil
        case 5: campaign = .nan
        case 6: campaign = .infinity
        case 7: campaign = -1
        case 8: campaign = 10.01
        case 9: previous = 1
        case 10: previous = 16 * 1024 * 1024
        case 11: previous = .max
        case 12: previous = UInt64.max - UInt64.max % 1316
        case 13: stage = 1; campaign = 9; previous = 0
        case 14: stage = 1; campaign = 10
        case 15: stage = nil; campaign = nil
        case 16: stage = nil; previous = 0
        default: campaign = -.infinity
        }
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTBandwidthProbe(bitRate: 1_000_000, generation: generation, statistics: stats(10), at: 10,
                stage: stage, campaignStartedAt: campaign, previouslyAcceptedPayloadBytes: previous)
        }
    }

    @Test(arguments: [60.0, 60.01]) func expiredCampaignCannotInitialize(at: Double) {
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try makeProbe(stage: 2, at: at, campaign: 0)
        }
    }

    @Test func legacyDefaultsKeepV1WireAndAbsentCampaignFields() throws {
        let probe = try SRTBandwidthProbe(bitRate: 1_000_000, generation: 0, statistics: stats(10), at: 10)
        var legacyMessage: Data?
        #expect(try probe.offer(statistics: stats(10.02), now: { 10.02 }, send: { message in
            legacyMessage = message; return true
        }))
        #expect(legacyMessage == SRTProbeMessage.encode(id: probe.id, generation: 0, sequence: 0, bitRate: 1_000_000))
        let snapshot = probe.snapshot(now: { 10.02 })
        #expect(snapshot.campaign == nil)
        #expect(snapshot.stage == nil)
        #expect(snapshot.campaignStartedAt == nil)
        #expect(snapshot.totalAcceptedPayloadBytes == nil)
        #expect(snapshot.acceptedPayloadBytes == 1316)
        #expect(snapshot.authority?.permits(id: snapshot.id, generation: 0, stage: nil) == true)
    }

    @Test func repeatableOwnerEmitsCampaignAndPreservesCampaignAccounting() throws {
        let probe = try SRTBandwidthProbe(bitRate: 12_000_000, generation: 1, statistics: stats(10), at: 10,
            stage: 2, campaign: 7, campaignStartedAt: 9, previouslyAcceptedPayloadBytes: 2632)
        #expect(probe.renew(now: { 10.01 }))
        var message: Data?
        #expect(try probe.offer(statistics: stats(10.02), now: { 10.02 }, send: { message = $0; return true }))
        #expect(message == (try SRTProbeMessage.encodeCampaign(id: probe.id, generation: 1,
            campaign: 7, stage: 2, sequence: 0, bitRate: 12_000_000)))
        let snapshot = probe.snapshot(now: { 10.02 })
        #expect(snapshot.campaign == 7 && snapshot.stage == 2)
        #expect(snapshot.campaignStartedAt == 9 && snapshot.totalAcceptedPayloadBytes == 3948)
        #expect(snapshot.acceptedPayloadBytes == 1316)
        #expect(try probe.nextCampaign() == 8)
    }

    @Test func repeatableCampaignRetainsFiniteByteAndTimeBudgets() throws {
        let lastWholeMessage = UInt64(16 * 1024 * 1024 / 1316) * 1316
        let byteLimited = try SRTBandwidthProbe(bitRate: 12_000_000, generation: 1, statistics: stats(10), at: 10,
            stage: 32, campaign: 3, campaignStartedAt: 9, previouslyAcceptedPayloadBytes: lastWholeMessage - 1316)
        #expect(try byteLimited.offer(statistics: stats(10.02), now: { 10.02 }, send: { _ in true }))
        #expect(byteLimited.snapshot(now: { 10.02 }).reason == .byteLimit)
        #expect(byteLimited.snapshot(now: { 10.02 }).totalAcceptedPayloadBytes == lastWholeMessage)
        #expect(!byteLimited.renew(now: { 10.02 }))
        let timeLimited = try SRTBandwidthProbe(bitRate: 12_000_000, generation: 1, statistics: stats(69.95), at: 69.95,
            stage: 2, campaign: 3, campaignStartedAt: 10, previouslyAcceptedPayloadBytes: 1316)
        #expect(timeLimited.renew(now: { 69.97 }))
        #expect(!timeLimited.isEligible(now: { 70 }))
        #expect(timeLimited.snapshot(now: { 70 }).reason == .timeLimit)
        #expect(timeLimited.snapshot(now: { 70 }).campaign == 3)
    }

    @Test func campaignRequiresNonzeroOrdinalAndStage() {
        let configurations: [(UInt32?, UInt32?)] = [(nil, 1), (1, 0)]
        for (stage, campaign) in configurations {
            #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try SRTBandwidthProbe(bitRate: 1_000_000, generation: 1, statistics: stats(10), at: 10,
                    stage: stage, campaign: campaign, campaignStartedAt: stage == nil ? nil : 10)
            }
        }
    }

    @Test func checkedCampaignSuccessorRejectsOverflowWithoutMutatingOwner() throws {
        let probe = try SRTBandwidthProbe(bitRate: 1_000_000, generation: 1, statistics: stats(10), at: 10,
            stage: 1, campaign: .max, campaignStartedAt: 10)
        let before = probe.snapshot(now: { 10 })
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) { try probe.nextCampaign() }
        #expect(probe.snapshot(now: { 10 }) == before)
        #expect(before.authority?.permits(id: before.id, generation: 1, stage: 1) == true)
        probe.cancel(.cancelled)
        let retired = probe.snapshot(now: { 10 })
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) { try probe.nextCampaign() }
        #expect(probe.snapshot(now: { 10 }) == retired)
        let legacy = try makeProbe()
        #expect(throws: SRTBandwidthProbeError.obsolete) { try legacy.nextCampaign() }
    }

    private enum Failure: Error { case injected }
    @Test func uhdBudgetAllowsOnlyFourMessageCatchUp() throws {
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTBandwidthProbe(bitRate: 48_000_000, generation: 1, statistics: stats(10), at: 10,
                stage: 1, campaign: 1, campaignStartedAt: 10)
        }
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTBandwidthProbe(bitRate: 48_000_001, generation: 1, statistics: stats(10), at: 10,
                stage: 1, campaign: 1, campaignStartedAt: 10, budget: .uhd)
        }
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTBandwidthProbe(bitRate: 1_000_000, generation: 1, statistics: stats(10), at: 10,
                stage: 1, campaignStartedAt: 10, budget: .uhd)
        }
        let probe = try SRTBandwidthProbe(bitRate: 48_000_000, generation: 1, statistics: stats(10), at: 10,
            stage: 1, campaign: 1, campaignStartedAt: 10, budget: .uhd)
        #expect(probe.minimumWakeInterval == 0.0002)
        #expect(!probe.isEligible(now: { 10.0002 }))
        var sent: [Data] = []
        for _ in 0..<4 {
            #expect(try probe.offer(statistics: stats(10.1), now: { 10.1 }, send: { sent.append($0); return true }))
        }
        #expect(try !probe.offer(statistics: stats(10.1), now: { 10.1 }, send: { sent.append($0); return true }))
        #expect(sent.count == 4)
        #expect(try !probe.offer(statistics: stats(10.1002), now: { 10.1002 }, send: { _ in true }))
        #expect(try probe.offer(statistics: stats(10.1003), now: { 10.1003 }, send: { _ in true }))
        #expect(try !probe.offer(statistics: stats(10.1003), now: { 10.1003 }, send: { _ in true }))
        let bytes = try #require(sent.first)
        #expect(String(data: bytes[4..<12], encoding: .utf8) == "SBUGPRB4")
        #expect(Array(bytes[44..<48]) == [2, 0xdc, 0x6c, 0])
        #expect(probe.snapshot(now: { 10.1003 }).budget == .uhd)
        #expect(probe.snapshot(now: { 10.301 }).reason == .leaseExpired)
    }

    @Test func uhdCampaignReservesWholeLastMessageAndRevokesAtBound() throws {
        let cap = SRTBandwidthProbeBudget.uhd.maximumPayloadBytes / 1316 * 1316
        let probe = try SRTBandwidthProbe(bitRate: 48_000_000, generation: 1, statistics: stats(10), at: 10,
            stage: 2, campaign: 1, campaignStartedAt: 9, previouslyAcceptedPayloadBytes: cap - 1316, budget: .uhd)
        #expect(try probe.offer(statistics: stats(10.1), now: { 10.1 }, send: { _ in true }))
        let value = probe.snapshot(now: { 10.1 })
        #expect(value.totalAcceptedPayloadBytes == cap)
        #expect(value.reason == .byteLimit)
        #expect(!probe.renew(now: { 10.11 }))
        #expect(value.authority?.permits(id: value.id, generation: 1, stage: 2) == false)
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTProbeMessage.encodeCampaign(id: UUID(), generation: 1, campaign: 1,
                stage: 1, sequence: cap / 1316, bitRate: 48_000_000, budget: .uhd)
        }
    }

    private func makeProbe(stage: UInt32 = 1, at: Double = 10, campaign: Double? = 10,
                           previous: UInt64 = 0, rate: Int = 1_000_000) throws -> SRTBandwidthProbe {
        try .init(bitRate: rate, generation: 1, statistics: stats(at), at: at,
            stage: stage, campaignStartedAt: campaign, previouslyAcceptedPayloadBytes: previous)
    }
    private func stats(_ at: Double) -> SRTPerformanceData {
        var mon = CBytePerfMon(); mon.msRTT = 2
        return .init(mon: mon, sampledAt: at)
    }
}

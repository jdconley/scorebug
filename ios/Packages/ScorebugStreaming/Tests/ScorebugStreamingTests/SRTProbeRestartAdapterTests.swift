import Foundation
import XCTest
@testable import ScorebugStreaming

final class SRTProbeRestartAdapterTests: XCTestCase {
    func testCampaignIdentityCannotChangeOnRenewalOrReplacement() {
        let prior = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7,
            bitRate: 500_000, startedAt: 10, leaseDeadline: 10.3, acceptedPayloadBytes: 0,
            lastAcceptedAt: nil, reason: nil, stage: 1, campaign: 1,
            campaignStartedAt: 10, totalAcceptedPayloadBytes: 0)
        XCTAssertTrue(prior.isValidStart(staged: true, bitRate: 500_000, repeatable: true))
        XCTAssertFalse(prior.isValidStart(staged: true, bitRate: 500_000))
        for ordinal: UInt32? in [nil, 0, 2, UInt32.max] {
            var renewal = prior
            renewal.campaign = ordinal
            XCTAssertFalse(renewal.isValidRenewal(of: prior))
            let replacement = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7,
                bitRate: 1_000_000, startedAt: 10.1, leaseDeadline: 10.4, acceptedPayloadBytes: 0,
                lastAcceptedAt: nil, reason: nil, stage: 2, campaign: ordinal,
                campaignStartedAt: 10, totalAcceptedPayloadBytes: 0)
            XCTAssertFalse(replacement.isValidReplacement(of: prior, bitRate: 1_000_000))
        }
        var final = prior
        final.campaign = UInt32.max
        let wrapped = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7,
            bitRate: 500_000, startedAt: 11, leaseDeadline: 11.3, acceptedPayloadBytes: 0,
            lastAcceptedAt: nil, reason: nil, stage: 1, campaign: 0,
            campaignStartedAt: 11, totalAcceptedPayloadBytes: 0)
        XCTAssertFalse(wrapped.isValidRestart(of: final, bitRate: 500_000, requestedAt: 11, observedAt: 11.1))
    }

    func testRepeatableRequiresStagingAndDefaultsToDisabled() async throws {
        let fixture = RestartAdapterFixture()
        var operations = await fixture.operations()
        operations.beginRepeatableProbe = { _ in throw PublishingBandwidthProbeError.disabled }
        let publisher = SRTMediaPublisher(operations: operations)
        try await publisher.start()
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, repeatable: true); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
        await publisher.stop()
    }

    func testRepeatedCampaignsUseFreshIdentitiesAndRejectOldCommands() async throws {
        let fixture = RestartAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        var prior = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
        for _ in 0..<3 {
            await publisher.cancelBandwidthProbe(id: prior.id, publishingGeneration: 7)
            let next = try await publisher.restartBandwidthProbe(id: prior.id, publishingGeneration: 7, stage: 1, bitRate: 500_000)
            XCTAssertNotEqual(next.id, prior.id)
            XCTAssertEqual(next.stage, 1)
            XCTAssertEqual(next.campaign, prior.campaign.map { $0 + 1 })
            XCTAssertEqual(next.campaignStartedAt, next.startedAt)
            XCTAssertGreaterThan(next.startedAt, prior.startedAt)
            XCTAssertEqual(next.totalAcceptedPayloadBytes, 0)
            XCTAssertEqual(next.acceptedPayloadBytes, 0)
            do { _ = try await publisher.restartBandwidthProbe(id: prior.id, publishingGeneration: 7, stage: 1, bitRate: 500_000); XCTFail("Old identity survived restart") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            prior = next
        }
        let count = await fixture.restarts
        XCTAssertEqual(count, 3)
        await publisher.stop()
    }

    func testLegacyCampaignCannotReachNativeRestart() async throws {
        let fixture = RestartAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
        do { _ = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        let count = await fixture.restarts
        XCTAssertEqual(count, 0)
        await publisher.stop()
    }

    func testInvalidLocalIdentityDoesNotReachNativeRestart() async throws {
        let fixture = RestartAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
        for (id, generation, stage) in [(UUID(), UInt64(7), UInt32(1)), (first.id, 8, 1), (first.id, 7, 2)] {
            do { _ = try await publisher.restartBandwidthProbe(id: id, publishingGeneration: generation, stage: stage, bitRate: 500_000); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        }
        let count = await fixture.restarts
        XCTAssertEqual(count, 0)
        await publisher.stop()
    }

    func testDefaultRestartOperationIsDisabled() async throws {
        let fixture = RestartAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations(enabled: false))
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
        await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
        do { _ = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
        await publisher.stop()
    }

    func testMalformedRestartResponsesAreRevoked() async throws {
        for mutation in RestartMutation.allCases {
            let fixture = RestartAdapterFixture(mutation: mutation)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
            await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
            let priorCancellations = await fixture.cancelled
            do { _ = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000); XCTFail("Accepted \(mutation)") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            let returnedID = await fixture.returnedID
            let cancelled = await fixture.cancelled
            XCTAssertGreaterThan(cancelled.filter { $0 == returnedID! }.count,
                priorCancellations.filter { $0 == returnedID! }.count, "Invalid response was not revoked: \(mutation)")
            let healthy = await publisher.isPublishing
            XCTAssertTrue(healthy)
            await publisher.stop()
        }
    }

    func testInvalidRequestedRatesCannotInstallRestart() async throws {
        for rate in [0, -1, 12_000_001] {
            let fixture = RestartAdapterFixture()
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
            await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
            do { _ = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: rate); XCTFail("Accepted invalid rate") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            await publisher.stop()
        }
    }

    func testFailedRestartRetainsIdentityForExplicitRetry() async throws {
        let fixture = RestartAdapterFixture(failFirst: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
        await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
        do { _ = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .failed) }
        let next = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000)
        XCTAssertNotEqual(next.id, first.id)
        await publisher.stop()
    }

    func testRacesJoinAndRevokeLateRestart() async throws {
        for action in ["caller", "cancel", "settings", "stop", "unhealthy"] {
            let fixture = RestartAdapterFixture(gated: true)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
            await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
            let pending = Task { try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000) }
            await fixture.waitUntilEntered()
            do { _ = try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
            do { _ = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
            switch action {
            case "caller": pending.cancel()
            case "cancel": await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
            case "settings": do { try await publisher.setBitRate(1_000_000) } catch {}
            case "stop": await publisher.stop()
            default: await fixture.withdrawHealth()
            }
            await fixture.release()
            do { _ = try await pending.value; XCTFail("Restart survived \(action)") } catch {}
            let returnedID = await fixture.returnedID
            let cancelled = await fixture.cancelled
            XCTAssertTrue(cancelled.contains(returnedID!), "Late response was not revoked: \(action)")
            await publisher.stop()
        }
    }
}

private enum RestartMutation: CaseIterable, Sendable {
    case sameID, generation, stage, origin, carry, bytes, rate, terminal, lastAccepted, stale, beforeRequest, future, nan, leaseZero, leaseLong, campaignMissing, campaignSame, campaignSkipped
}

private actor RestartAdapterFixture {
    let mutation: RestartMutation?
    let failFirst: Bool, gated: Bool
    var restarts = 0
    var cancelled: [UUID] = []
    var returnedID: UUID?
    var healthy = true
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var firstStart = 0.0
    private var currentCampaign: UInt32 = 1
    init(mutation: RestartMutation? = nil, failFirst: Bool = false, gated: Bool = false) {
        self.mutation = mutation; self.failFirst = failFirst; self.gated = gated
    }
    func operations(enabled: Bool = true) -> SRTMediaPublisher.Operations {
        var value = SRTMediaPublisher.Operations(configure: {}, start: {}, append: { _ in },
            isPublishing: { await self.healthy }, stop: { await self.stop() },
            setBitRate: { _ in throw PublishingBandwidthProbeError.disabled }, metrics: { nil },
            cancelProbe: { id, _ in await self.cancel(id) }, beginStagedProbe: { await self.begin($0, repeatable: false) },
            beginRepeatableProbe: { await self.begin($0, repeatable: true) })
        if enabled { value.restartProbe = { id, generation, stage, rate in try await self.restart(id, generation: generation, stage: stage, rate: rate) } }
        return value
    }
    func begin(_ rate: Int, repeatable: Bool) -> PublishingBandwidthProbeSnapshot {
        firstStart = ProcessInfo.processInfo.systemUptime - 1
        return .init(id: UUID(), publishingGeneration: 7, bitRate: rate, startedAt: firstStart,
            leaseDeadline: firstStart + 0.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: 1, campaign: repeatable ? 1 : nil, campaignStartedAt: firstStart, totalAcceptedPayloadBytes: 0)
    }
    func restart(_ priorID: UUID, generation: UInt64, stage: UInt32, rate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        restarts += 1
        if gated { entered = true; await withCheckedContinuation { waiter = $0 } }
        if failFirst && restarts == 1 { throw PublishingBandwidthProbeError.failed }
        var start = ProcessInfo.processInfo.systemUptime
        if mutation == .stale { start = firstStart }
        if mutation == .beforeRequest { start = firstStart + 0.5 }
        if mutation == .future { start += 100 }
        if mutation == .nan { start = .nan }
        let id = mutation == .sameID ? priorID : UUID()
        returnedID = id
        let campaign: UInt32? = mutation == .campaignMissing ? nil : mutation == .campaignSame ? currentCampaign : mutation == .campaignSkipped ? currentCampaign + 2 : currentCampaign + 1
        currentCampaign += 1
        return .init(id: id, publishingGeneration: mutation == .generation ? generation + 1 : generation,
            bitRate: mutation == .rate ? rate + 1 : rate, startedAt: start,
            leaseDeadline: start + (mutation == .leaseZero ? 0 : mutation == .leaseLong ? 1 : 0.3),
            acceptedPayloadBytes: mutation == .bytes ? 1316 : 0,
            lastAcceptedAt: mutation == .lastAccepted ? start : nil,
            reason: mutation == .terminal ? .cancelled : nil,
            stage: mutation == .stage ? stage + 1 : 1, campaign: campaign,
            campaignStartedAt: mutation == .origin ? firstStart : start,
            totalAcceptedPayloadBytes: mutation == .carry ? 1316 : 0)
    }
    func cancel(_ id: UUID) { cancelled.append(id) }
    func withdrawHealth() { healthy = false }
    func stop() { healthy = false; release() }
    func release() { waiter?.resume(); waiter = nil }
    func waitUntilEntered() async {
        let limit = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < limit { await Task.yield() }
        XCTAssertTrue(entered)
    }
}

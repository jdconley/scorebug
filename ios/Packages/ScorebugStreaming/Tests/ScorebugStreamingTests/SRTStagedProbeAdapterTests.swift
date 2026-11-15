import Foundation
import XCTest
@testable import ScorebugStreaming

final class SRTStagedProbeAdapterTests: XCTestCase {
    func testLegacyBeginRejectsStagedOwner() async throws {
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7,
            bitRate: 500_000, startedAt: 10, leaseDeadline: 10.3,
            acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil, stage: 1)
        let recorder = StagedCancellationRecorder()
        let publisher = SRTMediaPublisher(operations: .init(configure: {}, start: {}, append: { _ in },
            isPublishing: { true }, stop: {}, setBitRate: { _ in throw PublishingBandwidthProbeError.disabled },
            metrics: { nil }, beginProbe: { _ in value }, cancelProbe: { id, _ in await recorder.record(id) }))
        try await publisher.start()
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000); XCTFail("Legacy begin cannot install a staged owner") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        let cancelled = await recorder.ids
        XCTAssertTrue(cancelled.contains(value.id))
        await publisher.stop()
    }

    func testLegacyRenewalRejectsStageFlip() async throws {
        let first = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7,
            bitRate: 500_000, startedAt: 10, leaseDeadline: 10.3,
            acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil)
        var changed = first
        changed.stage = 1
        let invalid = changed
        let recorder = StagedCancellationRecorder()
        let publisher = SRTMediaPublisher(operations: .init(configure: {}, start: {}, append: { _ in },
            isPublishing: { true }, stop: {}, setBitRate: { _ in throw PublishingBandwidthProbeError.disabled },
            metrics: { nil }, beginProbe: { _ in first }, renewProbe: { _, _ in invalid },
            cancelProbe: { id, _ in await recorder.record(id) }))
        try await publisher.start()
        _ = try await publisher.beginBandwidthProbe(bitRate: 500_000)
        do { _ = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail("Renewal cannot change stage") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        let cancelled = await recorder.ids
        XCTAssertTrue(cancelled.contains(first.id))
        await publisher.stop()
    }
    func testStagedCycleAndExactReplacementIdentity() async throws {
        let fixture = StagedAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        XCTAssertEqual(first.stage, 1)
        XCTAssertEqual(first.campaignStartedAt, 10)
        XCTAssertEqual(first.totalAcceptedPayloadBytes, 0)
        let renewed = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7)
        XCTAssertEqual(renewed.totalAcceptedPayloadBytes, 1316)
        for (id, generation, stage) in [(UUID(), UInt64(7), UInt32(1)), (first.id, 8, 1), (first.id, 7, 2)] {
            do { _ = try await publisher.replaceBandwidthProbe(id: id, publishingGeneration: generation, stage: stage, bitRate: 1_000_000); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        }
        let before = await fixture.replacements
        XCTAssertEqual(before, 0)
        let second = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.stage, 2)
        XCTAssertEqual(second.campaignStartedAt, first.campaignStartedAt)
        XCTAssertEqual(second.acceptedPayloadBytes, 0)
        XCTAssertEqual(second.totalAcceptedPayloadBytes, 2632, "Includes native acceptance after the last renewal")
        let renewedSecond = try await publisher.renewBandwidthProbe(id: second.id, publishingGeneration: 7)
        XCTAssertEqual(renewedSecond.totalAcceptedPayloadBytes, 3948)
        do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        await publisher.stop()
    }

    func testDefaultOperationsKeepStagedProbesDisabled() async throws {
        let fixture = StagedAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations(enabled: false))
        try await publisher.start()
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
        let healthy = await publisher.isPublishing
        XCTAssertTrue(healthy)
        await publisher.stop()
    }

    func testRejectsMalformedStagedStarts() async throws {
        for mutation in [StagedMutation.stage(nil), .stage(2), .campaign(nil), .campaign(9), .total(nil), .total(1316), .bytes(1316), .zeroGeneration, .deadline(.nan), .deadline(9)] {
            let fixture = StagedAdapterFixture(beginMutation: mutation)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true); XCTFail("Accepted \(mutation)") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            let cancelled = await fixture.cancelled
            XCTAssertEqual(cancelled.count, 1)
            await publisher.stop()
        }
    }

    func testRejectsMalformedReplacementAndRevokesReturnedHandle() async throws {
        for mutation in [StagedMutation.sameID, .generation, .stage(nil), .stage(1), .stage(3), .campaign(nil), .campaign(9), .total(nil), .total(0), .bytes(1316), .rate, .total(1317), .total(1316 * 13_000), .startedAt(70), .deadline(.infinity)] {
            let fixture = StagedAdapterFixture(replaceMutation: mutation)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
            _ = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7)
            do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail("Accepted \(mutation)") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            let snapshot = await fixture.snapshot
            let cancelled = await fixture.cancelled
            XCTAssertTrue(cancelled.contains(snapshot!.id))
            let healthy = await publisher.isPublishing
            XCTAssertTrue(healthy)
            await publisher.stop()
        }
    }

    func testRenewalPreservesCampaignAndCumulativeCarry() async throws {
        for mutation in [StagedMutation.stage(nil), .stage(2), .campaign(nil), .campaign(9), .total(nil), .total(0), .total(2632), .rate, .counters(1), .counters(1316 * 13_000), .deadline(.nan)] {
            let fixture = StagedAdapterFixture(renewMutation: mutation)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
            do { _ = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail("Accepted \(mutation)") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            let cancelled = await fixture.cancelled
            XCTAssertTrue(cancelled.contains(first.id))
            await publisher.stop()
        }
    }

    func testFailedReplacementRetiresOwnerAndAllowsExplicitRetry() async throws {
        let fixture = StagedAdapterFixture(failFirstReplacement: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .failed) }
        let cancelled = await fixture.cancelled
        XCTAssertTrue(cancelled.contains(first.id))
        let second = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000)
        XCTAssertEqual(second.stage, 2)
        let healthy = await publisher.isPublishing
        XCTAssertTrue(healthy)
        await publisher.stop()
    }

    func testReplacementRacesRejectAndRevokeLateHandle() async throws {
        for action in ["cancelTask", "cancelProbe", "settings", "stop", "unhealthy"] {
            let fixture = StagedAdapterFixture(gateReplacement: true)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
            let replace = Task { try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000) }
            await fixture.waitUntilEntered()
            do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
            do { _ = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
            switch action {
            case "cancelTask": replace.cancel()
            case "cancelProbe": await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
            case "settings": do { try await publisher.setBitRate(2_000_000) } catch {}
            case "stop": await publisher.stop()
            default: await fixture.withdrawHealth()
            }
            if action == "stop" {
                let late = await fixture.snapshot
                let cancelled = await fixture.cancelled
                XCTAssertTrue(cancelled.contains(late!.id), "Stop joins replacement revocation")
            }
            await fixture.release()
            do { _ = try await replace.value; XCTFail("Late result survived \(action)") } catch {}
            let late = await fixture.snapshot
            let cancelled = await fixture.cancelled
            XCTAssertTrue(cancelled.contains(late!.id))
            if action == "cancelTask" || action == "cancelProbe" {
                let healthy = await publisher.isPublishing
                XCTAssertTrue(healthy)
            }
            await publisher.stop()
        }
    }

}

private actor StagedCancellationRecorder {
    var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

private enum StagedMutation: Sendable {
    case sameID, generation, zeroGeneration, stage(UInt32?), campaign(Double?), total(UInt64?), bytes(UInt64), rate
    case startedAt(Double), deadline(Double), counters(UInt64)
    func apply(_ value: PublishingBandwidthProbeSnapshot, priorID: UUID? = nil) -> PublishingBandwidthProbeSnapshot {
        var id = value.id, generation = value.publishingGeneration, rate = value.bitRate
        var startedAt = value.startedAt, deadline = value.leaseDeadline
        var stage = value.stage, campaign = value.campaignStartedAt, total = value.totalAcceptedPayloadBytes, bytes = value.acceptedPayloadBytes
        switch self {
        case .sameID: id = priorID!
        case .generation: generation += 1
        case .zeroGeneration: generation = 0
        case .startedAt(let v): startedAt = v
        case .deadline(let v): deadline = v
        case .counters(let v): bytes = v; total = v
        case .stage(let v): stage = v
        case .campaign(let v): campaign = v
        case .total(let v): total = v
        case .bytes(let v): bytes = v
        case .rate: rate += 1
        }
        return .init(id: id, publishingGeneration: generation, bitRate: rate, startedAt: startedAt,
            leaseDeadline: deadline, acceptedPayloadBytes: bytes, lastAcceptedAt: value.lastAcceptedAt,
            reason: value.reason, stage: stage, campaignStartedAt: campaign, totalAcceptedPayloadBytes: total)
    }
}

private actor StagedAdapterFixture {
    let beginMutation: StagedMutation?, renewMutation: StagedMutation?, replaceMutation: StagedMutation?
    let gateReplacement: Bool, failFirstReplacement: Bool
    var replacements = 0
    var snapshot: PublishingBandwidthProbeSnapshot?
    var cancelled: [UUID] = []
    var healthy = true
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(beginMutation: StagedMutation? = nil, renewMutation: StagedMutation? = nil, replaceMutation: StagedMutation? = nil,
         gateReplacement: Bool = false, failFirstReplacement: Bool = false) {
        self.beginMutation = beginMutation; self.renewMutation = renewMutation; self.replaceMutation = replaceMutation
        self.gateReplacement = gateReplacement; self.failFirstReplacement = failFirstReplacement
    }
    func operations(enabled: Bool = true) -> SRTMediaPublisher.Operations {
        var operations = SRTMediaPublisher.Operations(configure: {}, start: {}, append: { _ in },
            isPublishing: { await self.healthy }, stop: { await self.stop() },
            setBitRate: { _ in throw PublishingBandwidthProbeError.disabled }, metrics: { nil },
            renewProbe: { _, _ in await self.renew() }, cancelProbe: { id, _ in await self.cancel(id) },
            probeSnapshot: { await self.snapshot })
        if enabled {
            operations.beginStagedProbe = { await self.begin($0) }
            operations.replaceProbe = { id, _, stage, rate in try await self.replace(id, stage: stage, rate: rate) }
        }
        return operations
    }
    func begin(_ rate: Int) -> PublishingBandwidthProbeSnapshot {
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7, bitRate: rate,
            startedAt: 10, leaseDeadline: 10.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: 1, campaignStartedAt: 10, totalAcceptedPayloadBytes: 0)
        let result = beginMutation?.apply(value) ?? value
        snapshot = result
        return result
    }
    func renew() -> PublishingBandwidthProbeSnapshot {
        let prior = snapshot!
        let value = PublishingBandwidthProbeSnapshot(id: prior.id, publishingGeneration: 7, bitRate: prior.bitRate,
            startedAt: prior.startedAt, leaseDeadline: 11, acceptedPayloadBytes: prior.acceptedPayloadBytes + 1316,
            lastAcceptedAt: 10.1, reason: nil, stage: prior.stage, campaignStartedAt: prior.campaignStartedAt,
            totalAcceptedPayloadBytes: prior.totalAcceptedPayloadBytes! + 1316)
        let result = renewMutation?.apply(value) ?? value
        snapshot = result
        return result
    }
    func replace(_ id: UUID, stage: UInt32, rate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        replacements += 1
        if gateReplacement { entered = true; await withCheckedContinuation { waiter = $0 } }
        if failFirstReplacement && replacements == 1 { throw PublishingBandwidthProbeError.failed }
        let prior = snapshot!
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7, bitRate: rate,
            startedAt: 10.2, leaseDeadline: 10.5, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: stage + 1, campaignStartedAt: 10, totalAcceptedPayloadBytes: prior.totalAcceptedPayloadBytes! + 1316)
        let result = replaceMutation?.apply(value, priorID: id) ?? value
        snapshot = result
        return result
    }
    func cancel(_ id: UUID) { cancelled.append(id) }
    func withdrawHealth() { healthy = false }
    func stop() { healthy = false; release() }
    func release() { waiter?.resume(); waiter = nil }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
}

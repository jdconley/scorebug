import CoreMedia
import Foundation
import libsrt
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming
@testable import SRTHaishinKit

final class SRTOwnedProbeRouteTests: XCTestCase {
    func testDownwardWriteRemainsAvailableWhileProbeCleanupIsHeld() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        let operation = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        _ = try await operation.value()
        await fixture.hold(.retire)
        let retiring = Task { try await operation.retire() }
        await fixture.waitForEntry()
        let write = Task { try await publisher.setVideoBitRate(700_000) }
        let deadline = ContinuousClock.now + .seconds(1)
        while await fixture.selected.configuration.bitRate != 700_000, ContinuousClock.now < deadline { await Task.yield() }
        let writtenBeforeJoin = await fixture.selected.configuration.bitRate == 700_000
        XCTAssertTrue(writtenBeforeJoin, "A downward write must not wait for probe cleanup")
        await fixture.release() // Always release, including a failing regression path.
        let receipt = try await retiring.value, selected = try await write.value
        let fresh = try await publisher.captureOwnedProbeContext(matching: selected)
        let next = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: fresh, bitRate: 500_000)
        _ = try await next.value(); _ = try await next.retire()
        await publisher.stop()
    }

    func testForeignReceiptAndBadArgumentsDoNotConsumeValidContinuation() async throws {
        let firstFixture = OwnedRouteFixture(), secondFixture = OwnedRouteFixture()
        let first = SRTMediaPublisher(operations: await firstFixture.operations())
        let second = SRTMediaPublisher(operations: await secondFixture.operations())
        try await first.start(); try await second.start()
        let firstContext = try await first.captureOwnedProbeContext(matching: await firstFixture.selected)
        let secondContext = try await second.captureOwnedProbeContext(matching: await secondFixture.selected)
        let operation = try await first.beginOwnedBandwidthProbe(in: firstContext, bitRate: 500_000)
        _ = try await operation.value(); let receipt = try await operation.retire()
        await rejects { _ = try await second.restartOwnedBandwidthProbe(after: receipt, in: secondContext, bitRate: 500_000) }
        await rejects { _ = try await first.restartOwnedBandwidthProbe(after: receipt, in: firstContext, bitRate: 0) }
        let successor = try await first.restartOwnedBandwidthProbe(after: receipt, in: firstContext, bitRate: 500_000)
        _ = try await successor.value(); _ = try await successor.retire()
        await first.stop(); await second.stop()
    }

    func testMissingOwnedCapabilityCannotAllocateThroughLegacyFallback() async throws {
        let fixture = OwnedRouteFixture()
        var operations = await fixture.operations()
        operations.beginOwnedProbe = nil
        let publisher = SRTMediaPublisher(operations: operations)
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        await rejects { _ = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000) }
        let allocations = await fixture.counts.allocations
        XCTAssertEqual(allocations, 0)
        await publisher.stop()
    }
    func testThreeStagesPreserveExactJoinedCarryAndOldHandlesAreInert() async throws {
        let fixture = OwnedRouteFixture()
        let upper = SRTMediaPublisher(operations: await fixture.operations())
        try await upper.start()
        let context = try await upper.captureOwnedProbeContext(matching: await fixture.selected)
        var operation = try await upper.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        var ids = Set<UUID>()
        for stage in 1...3 {
            let value = try await operation.value()
            XCTAssertEqual(value.stage, UInt32(stage)); XCTAssertEqual(value.campaign, 1)
            XCTAssertEqual(value.totalAcceptedPayloadBytes, UInt64(stage - 1) * 1316)
            ids.insert(value.id)
            try await fixture.sendPacket()
            let receipt = try await operation.retire()
            XCTAssertEqual(receipt.terminal?.totalAcceptedPayloadBytes, UInt64(stage) * 1316)
            XCTAssertEqual(receipt.terminalSnapshot?.id, value.id)
            XCTAssertNotNil(receipt.terminalSnapshot?.reason)
            XCTAssertEqual(receipt.terminalSnapshot?.totalAcceptedPayloadBytes, UInt64(stage) * 1316)
            await rejects { _ = try await operation.value() }
            await rejects { _ = try await operation.renew() }
            if stage < 3 {
                let previous = operation
                operation = try await upper.replaceOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000)
                await previous.cancel()
                let duplicate = try await previous.retire()
                XCTAssertTrue(duplicate === receipt)
                await rejects { _ = try await upper.replaceOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000) }
            }
        }
        XCTAssertEqual(ids.count, 3)
        await upper.stop()
    }

    func testSamePublisherDownshiftAndFailedRestartKeepOriginalCampaignContext() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let oldContext = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        let first = try await publisher.beginOwnedBandwidthProbe(in: oldContext, bitRate: 500_000)
        let a = try await first.value(), receipt = try await first.retire()
        let written = try await publisher.setVideoBitRate(700_000)
        let fresh = try await publisher.captureOwnedProbeContext(matching: written)
        await rejects { _ = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: oldContext, bitRate: 500_000) }
        await fixture.failNextAllocation()
        let failed = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: fresh, bitRate: 500_000)
        await rejects { _ = try await failed.value() }
        let reissued = try await failed.retire()
        XCTAssertEqual(reissued.terminal?.id, a.id)
        await rejects { _ = try await publisher.replaceOwnedBandwidthProbe(after: reissued, in: fresh, bitRate: 500_000) }
        let retry = try await publisher.restartOwnedBandwidthProbe(after: reissued, in: fresh, bitRate: 500_000)
        let b = try await retry.value()
        XCTAssertNotEqual(b.id, a.id); XCTAssertEqual(b.campaign, 2); XCTAssertEqual(b.stage, 1)
        XCTAssertEqual(b.totalAcceptedPayloadBytes, 0)
        _ = try await retry.retire(); await publisher.stop()
    }

    func testLowerRejectedLateBStillReturnsExactJoinedContinuation() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        let a = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        _ = try await a.value()
        let firstReceipt = try await a.retire()
        await fixture.invalidateAfterAllocation()
        let rejected = try await publisher.replaceOwnedBandwidthProbe(after: firstReceipt, in: context, bitRate: 600_000)
        await rejects { _ = try await rejected.value() }
        let receipt = try await rejected.retire()
        XCTAssertTrue(receipt.eligible); XCTAssertEqual(receipt.terminal?.stage, 2)
        XCTAssertNotEqual(receipt.terminal?.id, firstReceipt.terminal?.id)
        let selected = try await publisher.setVideoBitRate(700_000)
        let fresh = try await publisher.captureOwnedProbeContext(matching: selected)
        let restarted = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: fresh, bitRate: 500_000)
        let restartedValue = try await restarted.value()
        XCTAssertEqual(restartedValue.campaign, 2)
        _ = try await restarted.retire(); await publisher.stop()
    }

    func testNoAllocationContinuationsAcrossBothLayers() async throws {
        for proof in ["nativeFailure", "factoryProof", "beforeLowerDispatch", "lowerCancelled"] {
            let fixture = OwnedRouteFixture()
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
            if proof == "nativeFailure" { await fixture.failNextAllocation() }
            if proof == "factoryProof" { await fixture.rejectNextFactory() }
            if proof == "lowerCancelled" { await fixture.setDefect("cancelBeforeStart") }
            if proof == "beforeLowerDispatch" { await fixture.hold(.context) }
            let first = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
            if proof == "beforeLowerDispatch" {
                await fixture.waitForEntry(); await first.cancel(); await fixture.release()
            }
            await rejects { _ = try await first.value() }
            let receipt = try await first.retire()
            XCTAssertNil(receipt.terminal); XCTAssertTrue(receipt.eligible, proof)
            XCTAssertNil(receipt.terminalSnapshot)
            XCTAssertEqual(receipt.lower != nil, proof == "nativeFailure" || proof == "lowerCancelled")
            let retry = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000)
            let retriedValue = try await retry.value()
            XCTAssertEqual(retriedValue.campaign, 1)
            _ = try await retry.retire(); await publisher.stop()
        }
    }

    func testConcurrentContinuationUseReservesExactlyOneSuccessor() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        let initial = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        _ = try await initial.value()
        let receipt = try await initial.retire()
        let first = Task { try await publisher.restartOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000) }
        let second = Task { try await publisher.restartOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000) }
        var successors: [PublishingBandwidthProbeOperation] = []
        for result in [await first.result, await second.result] {
            if case .success(let operation) = result { successors.append(operation) }
        }
        XCTAssertEqual(successors.count, 1)
        for operation in successors { _ = try await operation.value(); _ = try await operation.retire() }
        await publisher.stop()
    }

    func testHeldRenewalAndCanceledRetirementWaitersJoinExactlyOnce() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        let operation = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        _ = try await operation.value()
        await fixture.hold(.renew)
        let renewal = Task { try await operation.renew() }
        await fixture.waitForEntry()
        let first = Task { try await operation.retire() }, second = Task { try await operation.retire() }
        first.cancel(); second.cancel()
        await fixture.release()
        await rejects { _ = try await renewal.value }
        let receipt = try await first.value
        let duplicate = try await second.value
        XCTAssertTrue(duplicate === receipt)
        let counts = await fixture.counts
        XCTAssertEqual(counts.retirements, 1)
        await publisher.stop()
    }

    func testOldCancelCannotPoisonSuspendedSuccessor() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        let first = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        _ = try await first.value()
        await fixture.hold(.cancel)
        let retiring = Task { try await first.retire() }
        await fixture.waitForEntry()
        await fixture.release()
        let receipt = try await retiring.value
        let before = await fixture.counts.cancellations
        await fixture.hold(.allocation)
        let successor = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000)
        await fixture.waitForEntry()
        await first.cancel(); _ = try await first.retire()
        let after = await fixture.counts.cancellations
        XCTAssertEqual(after, before)
        await fixture.release()
        let successorValue = try await successor.value()
        XCTAssertEqual(successorValue.campaign, 2)
        _ = try await successor.retire(); await publisher.stop()
    }

    func testUnknownFactoryFailureAndForeignHandleNeverGrantContinuation() async throws {
        for defect in ["genericFactory", "foreignContext", "wrongRate", "inflatedCarry", "foreignRenewal", "failedJoin", "rollback"] {
            let fixture = OwnedRouteFixture()
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
            if ["genericFactory", "foreignContext", "wrongRate"].contains(defect) { await fixture.setDefect(defect) }
            var operation = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
            if defect == "inflatedCarry" {
                _ = try await operation.value(); let prior = try await operation.retire()
                await fixture.setDefect(defect)
                operation = try await publisher.replaceOwnedBandwidthProbe(after: prior, in: context, bitRate: 500_000)
            } else if defect == "rollback" {
                _ = try await operation.value(); try await fixture.sendPacket()
                _ = try await operation.renew(); await fixture.setDefect(defect)
            } else if defect == "foreignRenewal" || defect == "failedJoin" {
                _ = try await operation.value(); await fixture.setDefect(defect)
                if defect == "foreignRenewal" { await rejects { _ = try await operation.renew() } }
            }
            if defect != "failedJoin" && defect != "rollback" { await rejects { _ = try await operation.value() } }
            do {
                let receipt = try await operation.retire()
                if defect == "foreignRenewal" {
                    // Malformed renewal did not change the exact allocation we own.
                    XCTAssertTrue(receipt.eligible)
                } else {
                    XCTAssertFalse(receipt.eligible, defect)
                    await rejects { _ = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000) }
                }
            } catch {
                XCTAssertTrue(["genericFactory", "foreignContext", "wrongRate", "failedJoin"].contains(defect), "\(defect): \(error)")
            }
            if defect == "foreignContext" || defect == "wrongRate" {
                let cancellations = await fixture.cancelCount()
                XCTAssertEqual(cancellations, 0, "Foreign returned handle must not be canceled by upper")
            }
            await publisher.stop(); await fixture.disposeForeign()
        }
    }

    func testStopDuringLateAllocationJoinsAndNeverPublishesValue() async throws {
        let fixture = OwnedRouteFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let context = try await publisher.captureOwnedProbeContext(matching: await fixture.selected)
        await fixture.hold(.allocation)
        let operation = try await publisher.beginOwnedBandwidthProbe(in: context, bitRate: 500_000)
        await fixture.waitForEntry()
        await publisher.stop()
        await rejects { _ = try await operation.value() }
        let receipt = try await operation.retire()
        await rejects { _ = try await publisher.restartOwnedBandwidthProbe(after: receipt, in: context, bitRate: 500_000) }
        let retirements = await fixture.retirementCount()
        XCTAssertEqual(retirements, 1)
    }

    private func rejects(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected rejection") } catch {}
    }
}

private actor OwnedRouteFixture {
    enum Gate { case allocation, renew, cancel, context, retire }
    let issuer = UUID()
    private var epoch = UUID(), stopped = false, valid = true
    var selected = PublishingBitRateChange(publishingGeneration: 7,
        configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 900_000)!,
        acceptedAt: 1, lastSubmittedSourcePTS: .zero)!
    private var slot: PublishingBandwidthProbeOperation?, foreign: PublishingBandwidthProbeOperation?
    private var probe: SRTBandwidthProbe?
    private var failAllocation = false, rejectFactory = false, invalidateAllocation = false
    private var defect = "", revision = 0
    private var gate: Gate?, entered = false, wait: CheckedContinuation<Void, Never>?
    var counts = (allocations: 0, retirements: 0, cancellations: 0)
    func setDefect(_ value: String) { defect = value }
    func failNextAllocation() { failAllocation = true }
    func rejectNextFactory() { rejectFactory = true }
    func invalidateAfterAllocation() { invalidateAllocation = true }
    func hold(_ value: Gate) { gate = value; entered = false }
    func release() { gate = nil; wait?.resume(); wait = nil }
    func waitForEntry() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    private func pause(_ value: Gate) async {
        guard gate == value else { return }; entered = true
        await withCheckedContinuation { wait = $0 }
    }
    func cancelCount() -> Int { counts.cancellations }
    func retirementCount() -> Int { counts.retirements }
    func capture(_ receipt: PublishingBitRateChange) throws -> PublishingBandwidthProbeContext {
        let context = PublishingBandwidthProbeContext(issuer: issuer, epoch: epoch, selected: selected)
        guard valid, !stopped, context.matches(receipt) else { throw PublishingBandwidthProbeError.obsolete }
        return context
    }
    func validate(_ context: PublishingBandwidthProbeContext) async throws {
        await pause(.context)
        guard valid, !stopped, context.issuer == issuer, context.epoch == epoch, context.matches(selected) else {
            throw PublishingBandwidthProbeError.obsolete
        }
    }
    func write(_ bitRate: Int) async -> PublishingBitRateChange {
        epoch = UUID(); valid = true
        await slot?.cancel()
        selected = PublishingBitRateChange(publishingGeneration: 7,
            configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: bitRate)!,
            acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: .zero)!
        return selected
    }
    func make(_ context: PublishingBandwidthProbeContext, request: PublishingOwnedProbeRequest,
              predecessor: PublishingBandwidthProbeRetirement?) throws -> PublishingBandwidthProbeOperation {
        do {
            guard !Task.isCancelled, !stopped, context.issuer == issuer, context.epoch == epoch else { throw PublishingBandwidthProbeError.obsolete }
            if rejectFactory { rejectFactory = false; throw PublishingBandwidthProbeError.obsolete }
            try validateOwnedReservation(current: slot, issuer: issuer, context: context, receipt: predecessor, request: request)
            try predecessor?.consume()
        } catch {
            throw PublishingOwnedFactoryRejection(context: context, predecessor: predecessor, request: request, reason: publishingProbeError(error))
        }
        if defect == "genericFactory" { throw CancellationError() }
        let actualContext = defect == "foreignContext"
            ? PublishingBandwidthProbeContext(issuer: UUID(), epoch: context.epoch, selected: context.selected) : context
        let actualRequest = defect == "wrongRate" ? PublishingOwnedProbeRequest(kind: request.kind, bitRate: request.bitRate + 1, policy: request.policy) : request
        let operation = PublishingBandwidthProbeOperation(issuer: actualContext.issuer, context: actualContext, request: actualRequest,
            predecessor: predecessor, backend: .native(.init(validate: { id in
                try await self.validateOperation(context, id: id)
            }, allocate: { request, prior in try await self.allocate(request, prior: prior) },
                renew: { try await self.renew($0, generation: $1) },
                cancel: { await self.cancel($0, generation: $1) },
                retire: { try await self.retire($0, generation: $1) })))
        slot = operation
        if defect == "foreignContext" || defect == "wrongRate" { foreign = operation }
        if defect == "cancelBeforeStart" { defect = ""; operation.revoke() }
        operation.start()
        return operation
    }
    func validateOperation(_ context: PublishingBandwidthProbeContext, id: UUID) async throws {
        guard slot?.id == id else { throw PublishingBandwidthProbeError.obsolete }
        try await validate(context)
        guard slot?.id == id else { throw PublishingBandwidthProbeError.obsolete }
    }
    func allocate(_ request: PublishingOwnedProbeRequest, prior: PublishingBandwidthProbeSnapshot?) async throws -> PublishingBandwidthProbeSnapshot {
        counts.allocations += 1
        let capturedRevision = revision
        await pause(.allocation)
        if failAllocation { failAllocation = false; throw PublishingBandwidthProbeError.failed }
        guard capturedRevision == revision else { throw PublishingBandwidthProbeError.obsolete }
        let at = ProcessInfo.processInfo.systemUptime
        let replacing = request.kind == .replace
        var mon = CBytePerfMon(); mon.msRTT = 2; mon.msSndTsbPdDelay = 200
        let next = try SRTBandwidthProbe(bitRate: request.bitRate, generation: 7,
            statistics: .init(mon: mon, sampledAt: at), at: at,
            stage: replacing ? prior!.stage! + 1 : 1,
            campaign: replacing ? prior!.campaign : (prior.map { $0.campaign! + 1 } ?? 1),
            campaignStartedAt: replacing ? prior!.campaignStartedAt : at,
            previouslyAcceptedPayloadBytes: replacing ? prior!.totalAcceptedPayloadBytes! : 0, policy: request.policy)
        probe = next
        if invalidateAllocation { invalidateAllocation = false; valid = false }
        var value = PublishingBandwidthProbeSnapshot(next.snapshot(now: { at }))
        if defect == "inflatedCarry" { value.totalAcceptedPayloadBytes = (value.totalAcceptedPayloadBytes ?? 0) + 1316 }
        return value
    }
    func sendPacket() async throws {
        try await Task.sleep(for: .milliseconds(25))
        let at = ProcessInfo.processInfo.systemUptime
        var mon = CBytePerfMon(); mon.msRTT = 2; mon.msSndTsbPdDelay = 200
        let probe = try XCTUnwrap(probe)
        XCTAssertTrue(try probe.offer(statistics: .init(mon: mon, sampledAt: at), now: { at }, send: { _ in true }))
    }
    func renew(_ id: UUID, generation: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        await pause(.renew)
        let probe = try XCTUnwrap(probe)
        _ = probe.renew(now: { ProcessInfo.processInfo.systemUptime })
        let value = PublishingBandwidthProbeSnapshot(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }))
        if defect != "foreignRenewal" { return value }
        return .init(id: UUID(), publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: value.acceptedPayloadBytes,
            lastAcceptedAt: value.lastAcceptedAt, reason: value.reason, stage: value.stage, campaign: value.campaign,
            authority: value.authority, campaignStartedAt: value.campaignStartedAt, totalAcceptedPayloadBytes: value.totalAcceptedPayloadBytes)
    }
    func cancel(_ id: UUID, generation: UInt64) async {
        await pause(.cancel)
        guard probe?.id == id, probe?.generation == generation else { return }
        counts.cancellations += 1; revision += 1; probe?.cancel(.cancelled)
    }
    func retire(_ id: UUID, generation: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        counts.retirements += 1
        await pause(.retire)
        guard let probe, probe.id == id, probe.generation == generation else { throw PublishingBandwidthProbeError.obsolete }
        if defect == "failedJoin" { throw PublishingBandwidthProbeError.failed }
        probe.cancel(.cancelled)
        let value = PublishingBandwidthProbeSnapshot(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }))
        if defect != "rollback" { return value }
        return .init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: 0,
            lastAcceptedAt: nil, reason: value.reason, stage: value.stage, campaign: value.campaign,
            authority: value.authority, campaignStartedAt: value.campaignStartedAt, totalAcceptedPayloadBytes: 0)
    }
    func stop() {
        stopped = true; slot?.revoke(); probe?.cancel(.closed); release()
    }
    func disposeForeign() async { if let foreign { _ = try? await foreign.retire() } }
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: {}, start: {}, append: { _ in }, isPublishing: { true }, stop: { await self.stop() },
            setBitRate: { await self.write($0) }, metrics: { nil },
            captureProbeContext: { try await self.capture($0) }, validateProbeContext: { try await self.validate($0) },
            beginOwnedProbe: { try await self.make($0, request: .init(kind: .begin, bitRate: $1, policy: $2), predecessor: nil) },
            replaceOwnedProbe: { try await self.make($1, request: .init(kind: .replace, bitRate: $2, policy: $0.policy), predecessor: $0) },
            restartOwnedProbe: { try await self.make($1, request: .init(kind: .restart, bitRate: $2, policy: $0.policy), predecessor: $0) })
    }
}

import Foundation
import CoreMedia
import XCTest
import ScorebugMedia
@testable import ScorebugStreaming

final class SRTProbeRetirementBridgeTests: XCTestCase {
    func testRetirementWaitsForCleanupAndCoalescesCancelledWaiters() async throws {
        let fixture = RetirementBridgeFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let finished = RetirementFlag()
        let retirement = Task { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7); await finished.set() }
        await fixture.cleanupEntered.wait()
        do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail("Retirement barrier admitted new work") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
        let duplicate = Task { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7) }
        retirement.cancel(); duplicate.cancel()
        let before = await finished.value
        XCTAssertFalse(before, "Cancellation must not turn an unjoined cleanup into success")
        await fixture.cleanupRelease.open()
        try await retirement.value; try await duplicate.value
        let calls = await fixture.retired
        XCTAssertEqual(calls, [first.id])
        try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7)
        let count22 = await fixture.retirementCount()
        XCTAssertEqual(count22, 1)
        await publisher.stop()
    }

    func testRetirementOfPredecessorJoinsReturnedReplacementDuringHealthAwait() async throws {
        let fixture = RetirementBridgeFixture(holdReplacementHealth: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let replace = Task { try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000) }
        await fixture.healthEntered.wait()
        let retirement = Task { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7) }
        await fixture.cancelEntered.wait()
        await fixture.healthRelease.open()
        await fixture.cleanupEntered.wait()
        let second = await fixture.current!
        let calls = await fixture.retired
        XCTAssertEqual(calls, [second.id])
        XCTAssertNotEqual(second.id, first.id)
        await fixture.cleanupRelease.open()
        do { _ = try await replace.value; XCTFail("Replacement survived retirement") } catch {}
        try await retirement.value
        try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7)
        try await publisher.retireBandwidthProbe(id: second.id, publishingGeneration: 7)
        let count46 = await fixture.retirementCount()
        XCTAssertEqual(count46, 1)
        await publisher.stop()
    }

    func testLateAllocationAfterRetirementIsCleanedBeforeAnyFurtherHealthRead() async throws {
        let fixture = RetirementBridgeFixture(holdReplacementHealth: true, holdReplacement: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let replacement = Task { try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000) }
        await fixture.replacementEntered.wait()
        let retirement = Task { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7) }
        await fixture.cancelEntered.wait() // Retirement has revoked A and cancelled its allocator.
        await fixture.replacementRelease.open() // The allocator deliberately ignores cancellation and returns B.
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await fixture.cleanupEntered.opened), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let cleanedBeforeHealthRelease = await fixture.retired
        let second = await fixture.current!
        let attemptedHealthRead = await fixture.healthEntered.opened
        XCTAssertEqual(cleanedBeforeHealthRelease, [second.id], "Late B must enter exact joined retirement before the unrelated health reader can suspend")
        XCTAssertFalse(attemptedHealthRead, "Revoked allocation must not begin another health read")
        // Always release every held operation and join it, including on the red path.
        await fixture.healthRelease.open()
        await fixture.cleanupRelease.open()
        if case .success = await replacement.result { XCTFail("Cancelled allocator published B") }
        if case .failure(let error) = await retirement.result { XCTFail("Retirement failed: \(error)") }
        await publisher.stop()
    }

    func testMalformedReplacementRemainsJoinableThroughBothExactIdentities() async throws {
        let fixture = RetirementBridgeFixture(malformedReplacement: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let replace = Task { try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000) }
        await fixture.cleanupEntered.wait()
        let second = await fixture.current!
        let retirement = Task { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7) }
        await fixture.cleanupRelease.open()
        do { _ = try await replace.value; XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        try await retirement.value
        try await publisher.retireBandwidthProbe(id: second.id, publishingGeneration: 7)
        let count64 = await fixture.retirementCount()
        XCTAssertEqual(count64, 1)
        await publisher.stop()
    }

    func testCancelledInitialAllocationJoinsReturnedOwnerBeforeThrowing() async throws {
        let fixture = RetirementBridgeFixture(holdBegin: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let completed = RetirementFlag()
        let begin = Task {
            do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true) }
            catch { await completed.set(); throw error }
        }
        await fixture.beginEntered.wait()
        begin.cancel()
        await fixture.beginRelease.open()
        await fixture.cleanupEntered.wait()
        let before = await completed.value
        XCTAssertFalse(before)
        await fixture.cleanupRelease.open()
        do { try await begin.value; XCTFail() } catch {}
        let value = await fixture.current!
        try await publisher.retireBandwidthProbe(id: value.id, publishingGeneration: 7)
        let count87 = await fixture.retirementCount()
        XCTAssertEqual(count87, 1)
        await publisher.stop()
    }

    func testForeignRetirementDoesNotCancelAndLegacyCancelDoesNotJoin() async throws {
        let fixture = RetirementBridgeFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        for (id, generation) in [(UUID(), UInt64(7)), (first.id, UInt64(8))] {
            do { try await publisher.retireBandwidthProbe(id: id, publishingGeneration: generation); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        }
        let count100 = await fixture.cancelCount()
        XCTAssertEqual(count100, 0)
        let count101 = await fixture.retirementCount()
        XCTAssertEqual(count101, 0)
        await publisher.cancelBandwidthProbe(id: first.id, publishingGeneration: 7)
        let count103 = await fixture.cancelCount()
        XCTAssertEqual(count103, 1)
        let count104 = await fixture.retirementCount()
        XCTAssertEqual(count104, 0)
        await publisher.stop()
    }

    func testDownwardEncoderActionRemainsAvailableDuringHeldRetirement() async throws {
        let fixture = RetirementBridgeFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let retirement = Task { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7) }
        await fixture.cleanupEntered.wait()
        do { _ = try await publisher.setVideoBitRate(350_000) } catch {}
        let count116 = await fixture.encoderWrites()
        XCTAssertEqual(count116, 1)
        await fixture.cleanupRelease.open()
        try await retirement.value
        await publisher.stop()
    }

    func testLegacyAdapterWithoutJoinCapabilityCannotClaimRetirement() async throws {
        let fixture = RetirementBridgeFixture()
        var operations = await fixture.operations()
        operations.retireProbe = nil
        let publisher = SRTMediaPublisher(operations: operations)
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        do { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail("Cancellation is not a join") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
        let cancels = await fixture.cancelCount(), joins = await fixture.retirementCount()
        XCTAssertEqual(cancels, 0); XCTAssertEqual(joins, 0)
        let renewed = try await publisher.renewBandwidthProbe(id: first.id, publishingGeneration: 7)
        XCTAssertEqual(renewed.id, first.id)
        await publisher.stop()
    }

    func testSuccessfulReplacementRejectsOldRetirementWithoutMutation() async throws {
        let fixture = RetirementBridgeFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let second = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000)
        await fixture.cleanupRelease.open()
        do { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail("Old owner retired accepted replacement") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        let cancels = await fixture.cancelCount(), joins = await fixture.retirementCount()
        XCTAssertEqual(cancels, 0); XCTAssertEqual(joins, 0)
        let renewed = try await publisher.renewBandwidthProbe(id: second.id, publishingGeneration: 7)
        XCTAssertEqual(renewed.id, second.id)
        await publisher.stop()
    }

    func testRealCleanupFailureBlocksFurtherAllocationAndPreservesOperationError() async throws {
        let fixture = RetirementBridgeFixture(malformedReplacement: true, failCleanup: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)
        await fixture.cleanupRelease.open()
        do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        do { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .failed) }
        do { _ = try await publisher.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000); XCTFail("Unjoined allocation was discarded") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
        let allocations = await fixture.replacements
        XCTAssertEqual(allocations, 1)
        await publisher.stop()
    }

    func testDuplicateCompletedRetirementDoesNotPoisonHeldRestart() async throws {
        let fixture = RetirementBridgeFixture(holdRestart: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: true)
        await fixture.cleanupRelease.open()
        try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7)
        let restart = Task { try await publisher.restartBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 500_000) }
        await fixture.restartEntered.wait()
        try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7)
        let cancels = await fixture.cancelCount()
        XCTAssertEqual(cancels, 1)
        await fixture.restartRelease.open()
        let second = try await restart.value
        XCTAssertNotEqual(second.id, first.id)
        do { try await publisher.retireBandwidthProbe(id: first.id, publishingGeneration: 7); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        let renewed = try await publisher.renewBandwidthProbe(id: second.id, publishingGeneration: 7)
        XCTAssertEqual(renewed.id, second.id)
        await publisher.stop()
    }

    func testNestedBridgeRetirementRevokesRawReplacementBeforeHealthReturns() async throws {
        let fixture = RetirementBridgeFixture(holdReplacementHealth: true)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let upper = SRTMediaPublisher(operations: .init(configure: {}, start: { try await lower.start() }, append: { _ in },
            isPublishing: { true }, stop: { await lower.stop() }, setBitRate: { try await lower.setVideoBitRate($0) }, metrics: { nil },
            cancelProbe: { await lower.cancelBandwidthProbe(id: $0, publishingGeneration: $1) },
            beginStagedProbe: { try await lower.beginBandwidthProbe(bitRate: $0, staged: true) },
            replaceProbe: { try await lower.replaceBandwidthProbe(id: $0, publishingGeneration: $1, stage: $2, bitRate: $3) },
            retireProbe: { try await lower.retireBandwidthProbe(id: $0, publishingGeneration: $1) }))
        try await upper.start()
        let first = try await upper.beginBandwidthProbe(bitRate: 500_000, staged: true)
        let replace = Task { try await upper.replaceBandwidthProbe(id: first.id, publishingGeneration: 7, stage: 1, bitRate: 1_000_000) }
        await fixture.healthEntered.wait()
        let second = await fixture.current!
        let retirement = Task { try await upper.retireBandwidthProbe(id: first.id, publishingGeneration: 7) }
        await fixture.cancelEntered.wait()
        let cancelled = await fixture.cancelled
        XCTAssertTrue(cancelled.contains(second.id), "Actual lower bridge must revoke raw B before its health await is released")
        await fixture.healthRelease.open()
        await fixture.cleanupEntered.wait()
        await fixture.cleanupRelease.open()
        do { _ = try await replace.value; XCTFail() } catch {}
        try await retirement.value
        let joins = await fixture.retirementCount()
        XCTAssertEqual(joins, 1)
        await upper.stop()
    }

    func testStopClosesFirstThenJoinsLateAllocationCleanup() async throws {
        let fixture = RetirementBridgeFixture(holdBegin: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let begin = Task { try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true) }
        await fixture.beginEntered.wait()
        let stopped = RetirementFlag()
        let stop = Task { await publisher.stop(); await stopped.set() }
        await fixture.cleanupEntered.wait()
        let before = await stopped.value
        XCTAssertFalse(before)
        await fixture.cleanupRelease.open()
        await stop.value
        do { _ = try await begin.value; XCTFail() } catch {}
        let count136 = await fixture.retirementCount()
        XCTAssertEqual(count136, 1)
    }
}

private actor RetirementFlag {
    var value = false
    func set() { value = true }
}
private actor RetirementGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
private actor RetirementBridgeFixture {
    let cleanupEntered = RetirementGate(), cleanupRelease = RetirementGate()
    let healthEntered = RetirementGate(), healthRelease = RetirementGate()
    let beginEntered = RetirementGate(), beginRelease = RetirementGate(), cancelEntered = RetirementGate()
    let holdReplacement: Bool
    let replacementEntered = RetirementGate(), replacementRelease = RetirementGate()
    let holdReplacementHealth: Bool, malformedReplacement: Bool, holdBegin: Bool, failCleanup: Bool, holdRestart: Bool
    let restartEntered = RetirementGate(), restartRelease = RetirementGate()
    var current: PublishingBandwidthProbeSnapshot?
    var retired: [UUID] = [], cancelled: [UUID] = []
    var replacementReturned = false, stopped = false, writes = 0, replacements = 0
    init(holdReplacementHealth: Bool = false, malformedReplacement: Bool = false, holdBegin: Bool = false, failCleanup: Bool = false, holdRestart: Bool = false, holdReplacement: Bool = false) {
        self.holdReplacementHealth = holdReplacementHealth; self.malformedReplacement = malformedReplacement; self.holdBegin = holdBegin
        self.failCleanup = failCleanup; self.holdRestart = holdRestart; self.holdReplacement = holdReplacement
    }
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: {}, start: {}, append: { _ in }, isPublishing: { await self.healthy() },
            stop: { await self.close() }, setBitRate: { rate in await self.write(rate) }, metrics: { nil },
            renewProbe: { _, _ in await self.current! },
            cancelProbe: { id, _ in await self.cancel(id) }, probeSnapshot: { await self.current },
            beginStagedProbe: { rate in await self.begin(rate) },
            replaceProbe: { _, _, _, rate in await self.replace(rate) },
            restartProbe: { _, _, _, rate in await self.restart(rate) },
            beginRepeatableProbe: { rate in await self.begin(rate, repeatable: true) },
            retireProbe: { id, _ in try await self.retire(id) })
    }
    func begin(_ rate: Int, repeatable: Bool = false) async -> PublishingBandwidthProbeSnapshot {
        if holdBegin { await beginEntered.open(); await beginRelease.wait() }
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7, bitRate: rate,
            startedAt: 10, leaseDeadline: 10.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: 1, campaign: repeatable ? 1 : nil, campaignStartedAt: 10, totalAcceptedPayloadBytes: 0)
        current = value; return value
    }
    func replace(_ rate: Int) async -> PublishingBandwidthProbeSnapshot {
        replacements += 1
        if holdReplacement { await replacementEntered.open(); await replacementRelease.wait() }
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7, bitRate: rate,
            startedAt: 11, leaseDeadline: 11.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: malformedReplacement ? 3 : 2, campaignStartedAt: 10, totalAcceptedPayloadBytes: 0)
        current = value; replacementReturned = true; return value
    }
    func healthy() async -> Bool {
        if replacementReturned && holdReplacementHealth { await healthEntered.open(); await healthRelease.wait() }
        return !stopped
    }
    func cancel(_ id: UUID) async { cancelled.append(id); await cancelEntered.open() }
    func retire(_ id: UUID) async throws {
        retired.append(id); await cleanupEntered.open(); await cleanupRelease.wait()
        if failCleanup { throw PublishingBandwidthProbeError.failed }
    }
    func restart(_ rate: Int) async -> PublishingBandwidthProbeSnapshot {
        if holdRestart { await restartEntered.open(); await restartRelease.wait() }
        let now = ProcessInfo.processInfo.systemUptime
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7, bitRate: rate,
            startedAt: now, leaseDeadline: now + 0.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: 1, campaign: 2, campaignStartedAt: now, totalAcceptedPayloadBytes: 0)
        current = value; return value
    }
    func close() async { stopped = true; await beginRelease.open(); await healthRelease.open() }
    func write(_ rate: Int) -> PublishingBitRateChange {
        writes += 1
        return PublishingBitRateChange(publishingGeneration: 7,
            configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!,
            acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: CMTime(value: 42, timescale: 30))!
    }
    func retirementCount() -> Int { retired.count }
    func cancelCount() -> Int { cancelled.count }
    func encoderWrites() -> Int { writes }
}

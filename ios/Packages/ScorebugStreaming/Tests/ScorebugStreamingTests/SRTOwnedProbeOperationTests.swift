import CoreMedia
import Foundation
import libsrt
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming
@testable import SRTHaishinKit

final class SRTOwnedProbeOperationTests: XCTestCase {
    func testUHDLowerHandoffRetainsBudgetAndJoinsRetirement() async throws {
        // The app uses two owned layers, unlike the direct native fixture.
        for rate in [500_000, 36_192_000] {
            let fixture = OwnedNativeFixture(budget: .uhd, rate: rate)
            let lowerContext = await fixture.context
            let issuer = UUID()
            let context = PublishingBandwidthProbeContext(issuer: issuer, epoch: UUID(),
                selected: lowerContext.selected, lower: lowerContext)
            let operation = PublishingBandwidthProbeOperation(issuer: issuer, context: context,
                request: .init(kind: .begin, bitRate: rate, policy: .localZeroLoss, budget: .uhd),
                predecessor: nil, backend: .lower(.init(validate: { _ in },
                    allocate: { _, _ in await fixture.operation() })))
            operation.start()
            let initial = try await operation.value()
            XCTAssertEqual(initial.budget, .uhd)
            let renewed = try await operation.renew()
            XCTAssertEqual(renewed.budget, .uhd)
            let retired = try await operation.retire()
            XCTAssertTrue(retired.eligible)
            XCTAssertEqual(retired.lower?.terminal?.budget, .uhd)
            let counts = await fixture.counts
            XCTAssertEqual(counts.retirements, 1)
        }
    }

    func testUHDBudgetCrossesOwnedBridgeAndRejectsSubstitutedReadback() async throws {
        let fixture = OwnedNativeFixture(budget: .uhd, rate: 36_192_000)
        let operation = await fixture.operation()
        let initial = try await operation.value()
        XCTAssertEqual(initial.budget, .uhd)
        XCTAssertEqual(initial.bitRate, 36_192_000)
        let renewed = try await operation.renew()
        XCTAssertEqual(renewed.budget, .uhd)
        let terminal = try await operation.retire()
        XCTAssertTrue(terminal.eligible)
        XCTAssertEqual(terminal.terminal?.budget, .uhd)
        // Low rate is valid under either ceiling; budget identity still must match.
        let wrong = OwnedNativeFixture(defect: "budget", budget: .uhd)
        let rejected = await wrong.operation()
        if case .success = await Result(catchingAsync: { try await rejected.value() }) { XCTFail("Changed budget granted authority") }
        _ = try await rejected.retire()
        let counts = await wrong.counts
        XCTAssertEqual(counts.retirements, 1)
    }

    func testZeroLengthInitialLeaseCannotProduceContinuation() async throws {
        let fixture = OwnedNativeFixture(defect: "zeroInitialLease")
        let operation = await fixture.operation()
        if case .success = await Result(catchingAsync: { try await operation.value() }) { XCTFail("Zero lease became live") }
        let receipt = try await operation.retire()
        XCTAssertFalse(receipt.eligible, "A malformed initial lease cannot become restart lineage after cleanup")
        let counts = await fixture.counts
        XCTAssertEqual(counts.retirements, 1, "Malformed allocation must still be joined")
    }
    func testFinalWrapperValidationRevokesAndJoinsBeforeThrowing() async throws {
        for renewing in [false, true] {
            let fixture = OwnedNativeFixture()
            await fixture.holdFinalValidation(renewing: renewing)
            let operation = await fixture.operation()
            if renewing { _ = try await operation.value() }
            let done = OwnedOperationDone()
            let pending = Task {
                do {
                    let value = try await (renewing ? operation.renew() : operation.value())
                    await done.set(); return value
                } catch { await done.set(); throw error }
            }
            await fixture.waitForValidation()
            await fixture.invalidateAndReleaseValidation()
            let entered = await fixture.waitForRetirement()
            let completed = await done.value, live = await fixture.hasLiveAuthority()
            XCTAssertTrue(entered, "Final wrapper rejection must join cleanup")
            XCTAssertFalse(completed, "The wrapper must not throw while owned cleanup is held")
            XCTAssertFalse(live, "Failed configuration validation must revoke native authority")
            await fixture.releaseRetirement()
            if case .success = await pending.result { XCTFail("Invalidated wrapper returned authority") }
            let receipt = try await operation.retire()
            XCTAssertTrue(receipt.eligible)
            let duplicate = try await operation.retire()
            XCTAssertTrue(receipt === duplicate)
        }
    }
    func testHandleExistsBeforeLateAllocationAndRetirementJoinsIt() async throws {
        let fixture = OwnedNativeFixture()
        await fixture.holdAllocation()
        let operation = await fixture.operation()
        await fixture.waitForAllocation()
        let retired = Task { try await operation.retire() }
        retired.cancel()
        await fixture.releaseAllocation()
        let receipt = try await retired.value
        XCTAssertNotNil(receipt.terminal)
        XCTAssertTrue(receipt.eligible)
        if case .success = await Result(catchingAsync: { try await operation.value() }) { XCTFail("Retired handle granted live authority") }
        let duplicate = try await operation.retire()
        XCTAssertTrue(receipt === duplicate)
        let counts = await fixture.counts
        XCTAssertEqual(counts.allocations, 1); XCTAssertEqual(counts.retirements, 1)
    }

    func testCancellationBeforeDispatchProducesNoAllocationContinuation() async throws {
        let fixture = OwnedNativeFixture()
        let operation = await fixture.operation(start: false)
        operation.revoke()
        operation.start()
        let receipt = try await operation.retire()
        XCTAssertTrue(receipt.eligible); XCTAssertNil(receipt.terminal)
        let counts = await fixture.counts
        XCTAssertEqual(counts.allocations, 0)
    }

    func testMalformedTerminalCannotGrantContinuation() async throws {
        for defect in ["authority", "live", "liveAuthority", "identity", "counter", "clock", "carry", "futureLease"] {
            let fixture = OwnedNativeFixture(defect: defect)
            let operation = await fixture.operation()
            _ = try await operation.value()
            let receipt = try await operation.retire()
            XCTAssertFalse(receipt.eligible, defect)
        }
    }

    func testExpiredTerminalCanContainAcceptedSendBeyondLease() async throws {
        let fixture = OwnedNativeFixture(defect: "lateAcceptance")
        let operation = await fixture.operation()
        _ = try await operation.value()
        let receipt = try await operation.retire()
        XCTAssertTrue(receipt.eligible)
    }
}

private actor OwnedOperationDone {
    var value = false
    func set() { value = true }
}

private extension Result where Failure == Error {
    init(catchingAsync operation: () async throws -> Success) async {
        do { self = .success(try await operation()) } catch { self = .failure(error) }
    }
}

private actor OwnedNativeFixture {
    let issuer = UUID()
    let context: PublishingBandwidthProbeContext
    private let defect: String
    private var heldAllocation = false, allocationEntered = false
    private var allocationWait: CheckedContinuation<Void, Never>?
    private var current: SRTBandwidthProbe?
    private var original: PublishingBandwidthProbeSnapshot?
    private var valid = true, validationCount = 0, heldValidation: Int?
    private var validationEntered = false, validationWait: CheckedContinuation<Void, Never>?
    private var retirementHeld = false, retirementEntered = false, retirementWait: CheckedContinuation<Void, Never>?
    var counts = (allocations: 0, retirements: 0)
    private let budget: PublishingBandwidthProbeSnapshot.Budget
    private let rate: Int
    init(defect: String = "", budget: PublishingBandwidthProbeSnapshot.Budget = .standard, rate: Int = 500_000) {
        self.budget = budget; self.rate = rate
        self.defect = defect
        context = PublishingBandwidthProbeContext(issuer: issuer, epoch: UUID(), selected:
            PublishingBitRateChange(publishingGeneration: 7,
                configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 900_000)!,
                acceptedAt: 1, lastSubmittedSourcePTS: .zero)!)
    }
    func operation(start: Bool = true) -> PublishingBandwidthProbeOperation {
        let result = PublishingBandwidthProbeOperation(issuer: issuer, context: context,
            request: .init(kind: .begin, bitRate: rate, policy: .localZeroLoss, budget: budget), predecessor: nil,
            backend: .native(.init(validate: { _ in try await self.validate() },
                allocate: { _, _ in try await self.allocate() },
                renew: { _, _ in try await self.renew() }, cancel: { _, _ in await self.cancel() },
                retire: { _, _ in try await self.retire() })))
        if start { result.start() }
        return result
    }
    func holdFinalValidation(renewing: Bool) { heldValidation = renewing ? 6 : 3; retirementHeld = true }
    func validate() async throws {
        validationCount += 1
        if heldValidation == validationCount {
            validationEntered = true
            await withCheckedContinuation { validationWait = $0 }
        }
        guard valid else { throw PublishingBandwidthProbeError.obsolete }
    }
    func waitForValidation() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !validationEntered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(validationEntered)
    }
    func invalidateAndReleaseValidation() { valid = false; validationWait?.resume(); validationWait = nil }
    func waitForRetirement() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while !retirementEntered && ContinuousClock.now < deadline { await Task.yield() }
        return retirementEntered
    }
    func releaseRetirement() { retirementHeld = false; retirementWait?.resume(); retirementWait = nil }
    func hasLiveAuthority() -> Bool {
        guard let original else { return false }
        return original.authority?.permits(id: original.id, generation: original.publishingGeneration,
            stage: original.stage, policy: original.policy) == true
    }
    func holdAllocation() { heldAllocation = true }
    func waitForAllocation() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !allocationEntered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(allocationEntered)
    }
    func releaseAllocation() { heldAllocation = false; allocationWait?.resume(); allocationWait = nil }
    func allocate() async throws -> PublishingBandwidthProbeSnapshot {
        counts.allocations += 1; allocationEntered = true
        if heldAllocation { await withCheckedContinuation { allocationWait = $0 } }
        let at = ProcessInfo.processInfo.systemUptime
        var mon = CBytePerfMon(); mon.msRTT = 2
        let probe = try SRTBandwidthProbe(bitRate: rate, generation: 7,
            statistics: .init(mon: mon, sampledAt: at), at: at, stage: 1, campaign: 1, campaignStartedAt: at, budget: budget)
        current = probe
        let raw = PublishingBandwidthProbeSnapshot(probe.snapshot(now: { at }))
        var value = defect == "zeroInitialLease" ? PublishingBandwidthProbeSnapshot(id: raw.id,
            publishingGeneration: raw.publishingGeneration, bitRate: raw.bitRate, startedAt: raw.startedAt,
            leaseDeadline: raw.startedAt, acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil,
            stage: raw.stage, campaign: raw.campaign, authority: raw.authority,
            campaignStartedAt: raw.campaignStartedAt, totalAcceptedPayloadBytes: 0) : raw
        if defect == "budget" { value.budget = .standard }
        original = value
        return value
    }
    func renew() throws -> PublishingBandwidthProbeSnapshot {
        let probe = try XCTUnwrap(current)
        _ = probe.renew(now: { ProcessInfo.processInfo.systemUptime })
        return .init(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }))
    }
    func cancel() { if defect != "live" && defect != "liveAuthority" { current?.cancel(.cancelled) } }
    func retire() async throws -> PublishingBandwidthProbeSnapshot {
        counts.retirements += 1
        retirementEntered = true
        if retirementHeld { await withCheckedContinuation { retirementWait = $0 } }
        let probe = try XCTUnwrap(current), base = try XCTUnwrap(original)
        if defect == "lateAcceptance" { try await Task.sleep(for: .milliseconds(310)) }
        if defect != "live" && defect != "liveAuthority" { probe.cancel(.cancelled) }
        let raw = PublishingBandwidthProbeSnapshot(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }))
        if defect.isEmpty || defect == "live" { return raw }
        var result = PublishingBandwidthProbeSnapshot(id: defect == "identity" ? UUID() : raw.id,
            publishingGeneration: raw.publishingGeneration, bitRate: raw.bitRate, startedAt: raw.startedAt,
            leaseDeadline: defect == "futureLease" ? raw.leaseDeadline + 100 : raw.leaseDeadline,
            acceptedPayloadBytes: defect == "counter" ? 1 : (defect == "lateAcceptance" ? 1316 : 0),
            lastAcceptedAt: defect == "clock" ? raw.startedAt - 1 : (defect == "lateAcceptance" ? ProcessInfo.processInfo.systemUptime : nil),
            reason: .cancelled, stage: raw.stage, campaign: raw.campaign, authority: raw.authority,
            campaignStartedAt: raw.campaignStartedAt,
            totalAcceptedPayloadBytes: defect == "carry" || defect == "lateAcceptance" ? 1316 : 0)
        if defect == "authority" {
            let authority = SRTBandwidthProbeAuthority(id: base.id, generation: 7, stage: 1)
            authority.revoke(); result.authority = authority
        }
        return result
    }
}

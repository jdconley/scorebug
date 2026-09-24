import Foundation
import XCTest
@testable import ScorebugStreaming

final class SRTRecoveryPolicyAdapterTests: XCTestCase {
    typealias Policy = PublishingBandwidthProbeSnapshot.Policy
    private func snapshot(policy: Policy, stage: UInt32 = 1, campaign: UInt32? = 1,
                          at: Double = 10, origin: Double = 10) -> PublishingBandwidthProbeSnapshot {
        .init(id: UUID(), publishingGeneration: 7, bitRate: 500_000, startedAt: at,
            leaseDeadline: at + 0.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil,
            stage: stage, campaign: campaign, campaignStartedAt: origin, totalAcceptedPayloadBytes: 0, policy: policy)
    }
    func testSnapshotLifecycleCannotChangePolicyOrBorrowLegacyAdmission() {
        for policy: Policy in [.localZeroLoss, .recoveryBudget] {
            let prior = snapshot(policy: policy)
            let other: Policy = policy == .localZeroLoss ? .recoveryBudget : .localZeroLoss
            XCTAssertTrue(prior.isValidStart(staged: true, bitRate: 500_000, repeatable: true, policy: policy))
            XCTAssertFalse(prior.isValidStart(staged: true, bitRate: 500_000, repeatable: true, policy: other))
            var next = prior; next.policy = other
            XCTAssertFalse(next.isValidRenewal(of: prior))
            let replacement = snapshot(policy: policy, stage: 2, at: 10.1)
            XCTAssertTrue(replacement.isValidReplacement(of: prior, bitRate: 500_000))
            var changed = replacement; changed.policy = other
            XCTAssertFalse(changed.isValidReplacement(of: prior, bitRate: 500_000))
            let restart = snapshot(policy: policy, campaign: 2, at: 11, origin: 11)
            XCTAssertTrue(restart.isValidRestart(of: prior, bitRate: 500_000, requestedAt: 11, observedAt: 11.1))
            changed = restart; changed.policy = other
            XCTAssertFalse(changed.isValidRestart(of: prior, bitRate: 500_000, requestedAt: 11, observedAt: 11.1))
        }
        var unstaged = snapshot(policy: .recoveryBudget, campaign: nil)
        unstaged.stage = nil; unstaged.campaignStartedAt = nil; unstaged.totalAcceptedPayloadBytes = nil
        XCTAssertFalse(unstaged.isValidStart(staged: false, bitRate: 500_000, policy: .recoveryBudget))
        let network = snapshot(policy: .recoveryBudget)
        XCTAssertFalse(network.isValidStart(staged: true, bitRate: 500_000, repeatable: true), "Omitted policy must keep old admission")
    }
    func testExplicitNetworkStartUsesPolicyAwareOperationAndRepeatability() async throws {
        for repeatable in [false, true] {
            let value = snapshot(policy: .recoveryBudget, campaign: repeatable ? 1 : nil)
            let calls = RecoveryPolicyCalls()
            var ops = operations()
            ops.beginRecoveryProbe = { rate, repeatableArgument in
                XCTAssertEqual(rate, 500_000); XCTAssertEqual(repeatableArgument, repeatable)
                await calls.began(); return value
            }
            let publisher = SRTMediaPublisher(operations: ops)
            try await publisher.start()
            let first = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, repeatable: repeatable, policy: .recoveryBudget)
            XCTAssertEqual(first.policy, .recoveryBudget)
            let begins = await calls.begins; XCTAssertEqual(begins, 1)
            await publisher.stop()
        }
    }
    func testPolicyMismatchIsRejectedAndReturnedOwnerRevoked() async throws {
        for requested: Policy in [.localZeroLoss, .recoveryBudget] {
            let value = snapshot(policy: requested == .localZeroLoss ? .recoveryBudget : .localZeroLoss, campaign: nil)
            let calls = RecoveryPolicyCalls()
            var ops = operations()
            ops.beginStagedProbe = { _ in value }; ops.beginRecoveryProbe = { _, _ in value }
            ops.cancelProbe = { id, _ in await calls.cancel(id) }
            let publisher = SRTMediaPublisher(operations: ops)
            try await publisher.start()
            do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, policy: requested); XCTFail("Policy mismatch accepted") }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            let cancellations = await calls.cancelled; XCTAssertTrue(cancellations.contains(value.id))
            await publisher.stop()
        }
    }
    func testNetworkPolicyCannotSelectUnstagedOrDefaultDisabledOperation() async throws {
        let publisher = SRTMediaPublisher(operations: operations())
        try await publisher.start()
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, policy: .recoveryBudget); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true, policy: .recoveryBudget); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
        await publisher.stop()
    }
    private func operations() -> SRTMediaPublisher.Operations {
        .init(configure: {}, start: {}, append: { _ in }, isPublishing: { true }, stop: {},
              setBitRate: { _ in throw PublishingBandwidthProbeError.disabled }, metrics: { nil })
    }
}
private actor RecoveryPolicyCalls {
    var begins = 0
    var cancelled: [UUID] = []
    func began() { begins += 1 }
    func cancel(_ id: UUID) { cancelled.append(id) }
}

import Foundation
import ScorebugCore
import XCTest

final class QualityCandidateMeasurementReadinessTests: XCTestCase {
    private typealias Q = QualityController
    private let attempt = UUID()
    private let baseline = Q.Settings(profileID: "small", videoBitrate: 500_000)
    private let next = Q.Settings(profileID: "small", videoBitrate: 550_000)
    private var profiles: [Q.Profile] {
        [.init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 1_000_000),
         .init(id: "large", width: 1280, height: 720, minimumBitrate: 1_500_000, maximumBitrate: 3_000_000)]
    }
    private func controller(applied: Q.Settings? = nil,
                            strategy: Q.RecoveryStrategy = .measuredCandidateTrials,
                            behavior: Q.Behavior = .progressive) throws -> Q {
        try Q(profiles: profiles, attemptID: attempt, applied: applied ?? baseline, at: 0,
              recoveryStrategy: strategy, behavior: behavior)
    }
    private func window(_ start: Double = 0, duration: Double = 4, sequence: UInt64 = 1,
                        revision: UInt64 = 0, receiver: Bool = true, observedAt: Double? = nil,
                        frames: Int? = nil, queue: Double = 0.1,
                        connectivity: Q.Connectivity = .connected) -> Q.Window {
        let count = frames ?? Int(duration * 30)
        return .init(attemptID: attempt, sequence: sequence, appliedRevision: revision,
                     start: start, end: start + duration, capturedFreshFrames: count, encodedFreshFrames: count,
                     receiver: receiver ? .init(freshFrames: count, observedAt: observedAt ?? start + duration) : nil,
                     sourceLoss: .init(expectedFrames: max(count, 1), lostFrames: 0), meanQueueOccupancy: queue,
                     usableVideoCapacity: nil, connectivity: connectivity, thermalPressure: .nominal,
                     workerPressure: .nominal, transportPressure: .nominal)
    }
    private func qualified(applied: Q.Settings? = nil) throws -> Q {
        var policy = try controller(applied: applied)
        XCTAssertNil(try policy.evaluate(window(), at: 4).recommendation)
        return policy
    }
    private func candidate(at now: Double = 4, revision: UInt64 = 0) -> Q.CandidateAdmission {
        .init(id: UUID(), attemptID: attempt, appliedRevision: revision, baseline: baseline, settings: next,
              measuredStart: now - 1, measuredEnd: now, evaluatedAt: now, validUntil: now + 1.5,
              candidateTransportBitsPerSecond: 1_000_000, deliveredPaddingBitsPerSecond: 1_250_000)
    }

    func testReadinessRequiresMeasuredProgressivePolicyAndStrongReceiverHealth() throws {
        XCTAssertNil(try controller().candidateMeasurementReadiness(at: 0))
        for strategy in [Q.RecoveryStrategy.capacityQualified, .receiverValidatedTrials, .receiverValidatedProfileTrials] {
            var policy = try controller(strategy: strategy)
            _ = try policy.evaluate(window(), at: 4)
            XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
        }
        var legacy = try controller(strategy: .capacityQualified, behavior: .legacy)
        _ = try legacy.evaluate(window(), at: 4)
        XCTAssertNil(legacy.candidateMeasurementReadiness(at: 4))
        for sample in [window(receiver: false), window(observedAt: 3.9), window(queue: 0.6),
                       window(connectivity: .unknown), window(connectivity: .disconnected)] {
            var policy = try controller()
            _ = try policy.evaluate(sample, at: 4)
            XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
        }
    }

    func testExactHealthyBoundaryReturnsImmutableScopedNextSettings() throws {
        var policy = try controller()
        _ = try policy.evaluate(window(duration: 3), at: 3)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 3))
        // Waiting and repeated reads cannot create a fourth second of coverage.
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
        _ = try policy.evaluate(window(3, duration: 1, sequence: 2), at: 4)
        let frozen = policy
        let ready: Q.CandidateMeasurementReadiness = try XCTUnwrap(frozen.candidateMeasurementReadiness(at: 4))
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(ready)
        XCTAssertEqual(ready, frozen.candidateMeasurementReadiness(at: 4))
        XCTAssertEqual(ready.attemptID, attempt)
        XCTAssertEqual(ready.appliedRevision, 0)
        XCTAssertEqual(ready.baseline, baseline)
        XCTAssertEqual(ready.settings, next)
        XCTAssertEqual(ready.healthSequence, 2)
        XCTAssertEqual(ready.healthySince, 0)
        XCTAssertEqual(ready.healthyThrough, 4)
        XCTAssertEqual(ready.validUntil, 6)
    }

    func testInvalidStaleAndReversedTimesDoNotAdvanceOrRevokePolicy() throws {
        var policy = try qualified()
        let expected = try XCTUnwrap(policy.candidateMeasurementReadiness(at: 4))
        for now in [Double.nan, .infinity, -.infinity, -1, 3.999, 6.001, 1e12 + 1] {
            XCTAssertNil(policy.candidateMeasurementReadiness(at: now))
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4), expected)
        }
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 6), expected)
        XCTAssertEqual(policy.applied, baseline)
        XCTAssertEqual(policy.appliedRevision, 0)
        // A later advisory read must not advance the policy clock or consume admission.
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(), at: 4).recommendation)
    }

    func testHealthDeadlineIsNotRenewedByDelayedReceiverOrReads() throws {
        var policy = try controller()
        _ = try policy.evaluate(window(observedAt: 4.5), at: 4.5)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 4.25))
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4.5)?.validUntil, 6)
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 6)?.validUntil, 6)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 6.001))
    }

    func testExactNextProfileAndTopProfileExhaustion() throws {
        let atProfileCeiling = Q.Settings(profileID: "small", videoBitrate: 1_000_000)
        let policy = try qualified(applied: atProfileCeiling)
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4)?.baseline, atProfileCeiling)
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4)?.settings,
                       .init(profileID: "large", videoBitrate: 1_500_000))
        let top = try qualified(applied: .init(profileID: "large", videoBitrate: 3_000_000))
        XCTAssertNil(top.candidateMeasurementReadiness(at: 4))
    }

    func testPendingAdviceApplicationAndTrialBlockReadinessWithoutRevokingAdvice() throws {
        var policy = try qualified()
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(), at: 4).recommendation)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 100))
        let application = try policy.beginApplication(advice, at: 4)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
        try policy.acknowledge(application, applied: next, at: 4)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
        _ = try policy.evaluate(window(4, sequence: 2, revision: 1), at: 8)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 8))
    }

    func testPendingDecreaseAndMinimumResetBlockReadiness() throws {
        var decreasing = try qualified(applied: next)
        let decrease = try XCTUnwrap(decreasing.evaluate(window(4, sequence: 2, queue: 0.8), at: 8).recommendation)
        XCTAssertEqual(decrease.kind, .decrease)
        XCTAssertNil(decreasing.candidateMeasurementReadiness(at: 8))
        XCTAssertNoThrow(try decreasing.beginApplication(decrease, at: 8))

        var resetting = try qualified()
        let advice = try XCTUnwrap(resetting.evaluateCandidate(candidate(), at: 4).recommendation)
        _ = try resetting.beginApplication(advice, at: 4)
        resetting.invalidateTelemetry()
        XCTAssertNil(resetting.candidateMeasurementReadiness(at: 4))
        let reset = try XCTUnwrap(resetting.checkTrialDeadline(at: 4))
        XCTAssertEqual(reset.kind, .reset)
        XCTAssertNil(resetting.candidateMeasurementReadiness(at: 4))
        // Even strong evidence cannot bypass an unacknowledged reset at minimum.
        XCTAssertEqual(try resetting.evaluate(window(4, sequence: 2), at: 8).recommendation?.kind, .reset)
        XCTAssertNil(resetting.candidateMeasurementReadiness(at: 8))
    }

    func testGapInvalidationAndUnknownHealthRestartContinuousCoverage() throws {
        for mode in 0..<3 {
            var policy = try qualified()
            var start = 4.0
            var sequence: UInt64 = 2
            if mode == 0 {
                policy.invalidateTelemetry()
                XCTAssertNil(policy.candidateMeasurementReadiness(at: 4))
            } else if mode == 1 {
                start = 5
            } else {
                _ = try policy.evaluate(window(4, duration: 1, sequence: sequence, receiver: false), at: 5)
                XCTAssertNil(policy.candidateMeasurementReadiness(at: 5))
                start = 5
                sequence += 1
            }
            _ = try policy.evaluate(window(start, duration: 3, sequence: sequence), at: start + 3)
            XCTAssertNil(policy.candidateMeasurementReadiness(at: start + 3))
            _ = try policy.evaluate(window(start + 3, duration: 1, sequence: sequence + 1), at: start + 4)
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: start + 4)?.healthySince, start)
        }
    }

    func testRepeatedFailuresReuseEscalatingRecoveryAfterAcknowledgedReset() throws {
        var policy = try qualified()
        var now = 4.0
        var sequence: UInt64 = 2
        var revision: UInt64 = 0
        for requiredRecovery in [10, 20, 40, 60, 60] {
            let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(at: now, revision: revision), at: now).recommendation)
            try policy.acknowledge(advice, applied: next, at: now)
            revision += 1
            let reset = try XCTUnwrap(policy.evaluate(window(now, duration: 1, sequence: sequence,
                                                            revision: revision, frames: 0), at: now + 1).recommendation)
            now += 1
            sequence += 1
            XCTAssertNil(policy.candidateMeasurementReadiness(at: now))
            try policy.acknowledge(reset, applied: baseline, at: now)
            revision += 1
            let recoveryStart = now
            XCTAssertNil(policy.candidateMeasurementReadiness(at: now))
            for elapsed in 1...requiredRecovery {
                _ = try policy.evaluate(window(now, duration: 1, sequence: sequence, revision: revision), at: now + 1)
                now += 1
                sequence += 1
                if elapsed < requiredRecovery {
                    XCTAssertNil(policy.candidateMeasurementReadiness(at: now), "Recovery must last \(requiredRecovery)s")
                }
            }
            let ready = try XCTUnwrap(policy.candidateMeasurementReadiness(at: now))
            XCTAssertEqual(ready.appliedRevision, revision)
            XCTAssertEqual(ready.healthySince, recoveryStart)
            XCTAssertEqual(ready.healthyThrough - ready.healthySince, Double(requiredRecovery))
            XCTAssertEqual(ready.settings, next)
        }
    }
}

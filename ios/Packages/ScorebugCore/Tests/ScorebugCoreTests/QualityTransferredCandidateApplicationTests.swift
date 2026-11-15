import Foundation
import ScorebugCore
import XCTest

final class QualityTransferredCandidateApplicationTests: XCTestCase {
    private typealias Q = QualityController
    private let publication = UUID()
    private let minimum = Q.Settings(profileID: "small", videoBitrate: 500_000)

    private func controller() throws -> Q {
        try Q(profiles: [.init(id: "small", width: 640, height: 360,
            minimumBitrate: 500_000, maximumBitrate: 1_000_000)], attemptID: publication,
            applied: .init(profileID: "small", videoBitrate: 800_000), at: 0,
            recoveryStrategy: .measuredCandidateTrials, behavior: .progressive)
    }
    private func window(_ start: Double, duration: Double = 1, sequence: UInt64,
                        revision: UInt64 = 0, queue: Double = 0.1) -> Q.Window {
        let count = Int(duration * 30)
        return .init(attemptID: publication, sequence: sequence, appliedRevision: revision,
            start: start, end: start + duration, capturedFreshFrames: count, encodedFreshFrames: count,
            receiver: .init(freshFrames: count, observedAt: start + duration),
            sourceLoss: .init(expectedFrames: count, lostFrames: 0), meanQueueOccupancy: queue,
            usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
            workerPressure: .nominal, transportPressure: .nominal)
    }
    private func candidate(_ token: Q.CandidateMeasurementAttempt, id: UUID = UUID(), start: Double, end: Double) -> Q.CandidateAdmission {
        .init(id: id, attemptID: publication, appliedRevision: token.readiness.appliedRevision,
            baseline: token.readiness.baseline, settings: token.readiness.settings,
            measuredStart: start, measuredEnd: end, evaluatedAt: end, validUntil: end + 1.5,
            candidateTransportBitsPerSecond: 1_000_000, deliveredPaddingBitsPerSecond: 1_250_000)
    }
    private func transferred(_ policy: inout Q, at now: Double = 4, sequence: UInt64 = 2) throws
        -> (Q.CandidateMeasurementAttempt, Q.Application) {
        let token = try policy.beginCandidateMeasurement(at: now)
        _ = try policy.evaluate(window(now, sequence: sequence, revision: policy.appliedRevision), at: now + 1)
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(token, start: now, end: now + 1),
            for: token, at: now + 1).recommendation)
        return (token, try policy.beginApplication(advice, for: token, at: now + 1))
    }
    private func ready() throws -> Q {
        var policy = try controller()
        _ = try policy.evaluate(window(0, duration: 4, sequence: 1), at: 4)
        return policy
    }
    private func reject(_ policy: inout Q, _ application: Q.Application,
                        for token: Q.CandidateMeasurementAttempt, at now: Double) throws {
        try policy.settleCandidateApplicationRejection(application, for: token, at: now)
    }
    private func failDelivery(_ policy: inout Q, sequence: UInt64 = 3, at now: Double = 5) throws {
        _ = try policy.evaluateDeliveryFailure(.init(attemptID: publication, appliedRevision: policy.appliedRevision,
            sequence: sequence, start: now - 1, end: now, expectedFrames: 30, onTimeFrames: 0,
            lateFrames: 0, missingFrames: 30, observedAtLowerBound: now), at: now)
    }
    private func recover(_ policy: inout Q, from start: Double, seconds: Int, sequence: inout UInt64) throws {
        for elapsed in 1...seconds {
            let end = start + Double(elapsed)
            _ = try policy.evaluate(window(end - 1, sequence: sequence, revision: policy.appliedRevision), at: end)
            sequence += 1
            if elapsed < seconds { XCTAssertNil(policy.candidateMeasurementReadiness(at: end)) }
        }
        XCTAssertNotNil(policy.candidateMeasurementReadiness(at: start + Double(seconds)))
    }

    func testNoEffectRejectionAtNonminimumPreservesSettingsAndRequiresTenSecondsWithoutReset() throws {
        var policy = try ready()
        let (token, application) = try transferred(&policy)
        try reject(&policy, application, for: token, at: 5)
        XCTAssertEqual(policy.applied, token.readiness.baseline)
        XCTAssertEqual(policy.appliedRevision, 0)
        XCTAssertNil(try policy.checkTrialDeadline(at: 5))
        var sequence: UInt64 = 3
        try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
        let (second, next) = try transferred(&policy, at: 15, sequence: sequence)
        sequence += 1
        try reject(&policy, next, for: second, at: 16)
        try recover(&policy, from: 16, seconds: 20, sequence: &sequence)
    }

    func testForeignPairDuplicateAndInvalidTimeCannotPoisonCurrentOwner() throws {
        var policy = try ready(), other = try ready()
        let (token, application) = try transferred(&policy)
        let (foreign, foreignApplication) = try transferred(&other)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try reject(&policy, application, for: foreign, at: now))
            XCTAssertThrowsError(try reject(&policy, foreignApplication, for: token, at: now))
            XCTAssertThrowsError(try policy.acknowledge(foreignApplication, applied: foreign.readiness.settings, at: now))
        }
        for now in [Double.nan, .infinity, 4, 1e12 + 1] {
            XCTAssertThrowsError(try reject(&policy, application, for: token, at: now))
        }
        try reject(&policy, application, for: token, at: 5)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try reject(&policy, application, for: token, at: now))
        }
        var sequence: UInt64 = 3
        try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
    }

    func testDeliveryFailureAndNoEffectRejectionCountOnceInEitherOrder() throws {
        for deliveryFirst in [false, true] {
            var policy = try ready()
            let (token, application) = try transferred(&policy)
            if deliveryFirst { try failDelivery(&policy) }
            try reject(&policy, application, for: token, at: 5)
            if !deliveryFirst { try failDelivery(&policy) }
            let reset = try XCTUnwrap(policy.checkTrialDeadline(at: 5))
            try policy.acknowledge(reset, applied: minimum, at: 5)
            var sequence: UInt64 = 4
            try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
        }
    }

    func testRevokedApplicationSettlementPreservesDownwardAdviceOrApplication() throws {
        for admitDownward in [false, true] {
            var policy = try ready()
            let (token, application) = try transferred(&policy)
            // New telemetry revokes the application while its cleanup is held.
            let reset = try XCTUnwrap(policy.evaluate(window(5, sequence: 3, queue: 0.8), at: 6).recommendation)
            let downward = admitDownward ? try policy.beginApplication(reset, at: 6) : nil
            try reject(&policy, application, for: token, at: 6)
            if let downward { try policy.acknowledge(downward, applied: minimum, at: 6) }
            else { try policy.acknowledge(reset, applied: minimum, at: 6) }
            XCTAssertEqual(policy.applied, minimum)
            XCTAssertEqual(policy.appliedRevision, 1)
            var sequence: UInt64 = 4
            try recover(&policy, from: 6, seconds: 10, sequence: &sequence)
        }
    }

    func testUnresolvedTransferRejectsUpwardBypassesBeforeClockMutation() throws {
        var policy = try ready()
        let (token, application) = try transferred(&policy)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.beginCandidateMeasurement(at: now))
            XCTAssertThrowsError(try policy.evaluateCandidate(candidate(token, start: 4, end: 5), at: now))
            XCTAssertThrowsError(try policy.beginApplication(application.recommendation, at: now))
            XCTAssertThrowsError(try policy.acknowledge(application.recommendation, applied: application.recommendation.settings, at: now))
        }
        try reject(&policy, application, for: token, at: 5)
    }

    func testOnlyActualRevisionChangeAllowsRetirementAndPreservesNewOwner() throws {
        for admitDownward in [false, true] {
            var policy = try ready()
            let (token, application) = try transferred(&policy)
            XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
            try failDelivery(&policy)
            XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
            let reset = try XCTUnwrap(policy.checkTrialDeadline(at: 5))
            if admitDownward {
                let downward = try policy.beginApplication(reset, at: 5)
                try policy.acknowledge(downward, applied: minimum, at: 5)
            } else { try policy.acknowledge(reset, applied: minimum, at: 5) }
            for now in [100.0, .nan, 3] {
                XCTAssertThrowsError(try reject(&policy, application, for: token, at: now))
            }
            var sequence: UInt64 = 4
            try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
            let readiness = try XCTUnwrap(policy.candidateMeasurementReadiness(at: 15))
            XCTAssertThrowsError(try policy.beginCandidateMeasurement(at: 15))
            XCTAssertThrowsError(try policy.beginCandidateMeasurement(at: 100))
            try policy.retireObsoleteCandidateMeasurement(token)
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: 15), readiness)
            XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
            let (next, nextApplication) = try transferred(&policy, at: 15, sequence: sequence)
            for now in [100.0, .nan, 3] {
                XCTAssertThrowsError(try reject(&policy, application, for: token, at: now))
            }
            try policy.acknowledge(nextApplication, applied: next.readiness.settings, at: 16)
            XCTAssertEqual(policy.appliedRevision, 2)
        }
    }

    func testSuccessfulAcknowledgmentConsumesTransferAndOldRejectionCannotTouchProbation() throws {
        var policy = try ready()
        let (token, application) = try transferred(&policy)
        try policy.acknowledge(application, applied: token.readiness.settings, at: 5)
        XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try reject(&policy, application, for: token, at: now))
        }
        _ = try policy.evaluate(window(5, duration: 5, sequence: 3, revision: 1), at: 10)
        let decision = try policy.evaluate(window(10, duration: 5, sequence: 4, revision: 1), at: 15)
        XCTAssertTrue(decision.reasons.contains(.trialConfirmed))
        var sequence: UInt64 = 5
        try recover(&policy, from: 15, seconds: 4, sequence: &sequence)
        _ = try policy.beginCandidateMeasurement(at: 19)
    }

    func testUncertainFailureAcknowledgmentStillRequiresMinimumReset() throws {
        var policy = try ready()
        let (_, application) = try transferred(&policy)
        try policy.acknowledge(application, applied: nil, at: 5)
        XCTAssertEqual(try policy.checkTrialDeadline(at: 5)?.kind, .reset)
        XCTAssertEqual(policy.appliedRevision, 0)
    }

    func testRejectionBoundaryExcludesCrossingWindowAndRetainsCandidateIdentity() throws {
        var policy = try ready()
        let (token, application) = try transferred(&policy)
        try reject(&policy, application, for: token, at: 5.5)
        _ = try policy.evaluate(window(5, sequence: 3), at: 6)
        var sequence: UInt64 = 4
        try recover(&policy, from: 6, seconds: 10, sequence: &sequence)
        let next = try policy.beginCandidateMeasurement(at: 16)
        _ = try policy.evaluate(window(16, sequence: sequence), at: 17)
        XCTAssertThrowsError(try policy.evaluateCandidate(candidate(next,
            id: try XCTUnwrap(application.recommendation.candidateID), start: 16, end: 17), for: next, at: 100))
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(next, start: 16, end: 17), for: next, at: 17).recommendation)
    }

    func testSettlementRetainsSourceSequenceAndDeliveryLaneWatermarks() throws {
        var policy = try ready()
        let (token, application) = try transferred(&policy)
        try failDelivery(&policy)
        try reject(&policy, application, for: token, at: 5)
        // A higher policy sequence cannot replay a consumed delivery interval.
        XCTAssertThrowsError(try failDelivery(&policy, sequence: 4)) {
            XCTAssertEqual($0 as? Q.ValidationError, .outOfOrder)
        }
        // Nor can a fresh interval reuse the consumed sequence.
        XCTAssertThrowsError(try policy.evaluate(window(5, sequence: 3), at: 6)) {
            XCTAssertEqual($0 as? Q.ValidationError, .outOfOrder)
        }
        let reset = try XCTUnwrap(policy.checkTrialDeadline(at: 6))
        try policy.acknowledge(reset, applied: minimum, at: 6)
        var sequence: UInt64 = 5
        try recover(&policy, from: 6, seconds: 10, sequence: &sequence)
    }

    func testRejectedApplicationRetainsConsumedSourceInterval() throws {
        var policy = try ready()
        let (token, application) = try transferred(&policy)
        try reject(&policy, application, for: token, at: 5)
        XCTAssertThrowsError(try policy.evaluate(window(4, sequence: 3), at: 5)) {
            XCTAssertEqual($0 as? Q.ValidationError, .outOfOrder)
        }
        var sequence: UInt64 = 4
        try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
    }
}

import Foundation
import ScorebugCore
import XCTest

final class QualityOwnedCandidateMeasurementTests: XCTestCase {
    private typealias Q = QualityController
    private let publication = UUID()
    private let baseline = Q.Settings(profileID: "small", videoBitrate: 500_000)
    private let next = Q.Settings(profileID: "small", videoBitrate: 550_000)
    private func controller(rate: Int = 500_000) throws -> Q {
        try Q(profiles: [.init(id: "small", width: 640, height: 360,
                              minimumBitrate: 500_000, maximumBitrate: 1_000_000)],
              attemptID: publication, applied: .init(profileID: "small", videoBitrate: rate), at: 0,
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
    private func qualified(rate: Int = 500_000) throws -> Q {
        var policy = try controller(rate: rate)
        _ = try policy.evaluate(window(0, duration: 4, sequence: 1), at: 4)
        return policy
    }
    private func candidate(id: UUID = UUID(), start: Double = 4, end: Double = 5,
                           revision: UInt64 = 0, base: Q.Settings? = nil, target: Q.Settings? = nil,
                           padding: Double = 1_250_000) -> Q.CandidateAdmission {
        .init(id: id, attemptID: publication, appliedRevision: revision, baseline: base ?? baseline,
              settings: target ?? next, measuredStart: start, measuredEnd: end, evaluatedAt: end,
              validUntil: end + 1.5, candidateTransportBitsPerSecond: 1_000_000,
              deliveredPaddingBitsPerSecond: padding)
    }
    private func failDelivery(_ policy: inout Q, sequence: UInt64, at now: Double) throws {
        _ = try policy.evaluateDeliveryFailure(.init(attemptID: publication, appliedRevision: policy.appliedRevision,
            sequence: sequence, start: now - 1, end: now, expectedFrames: 30, onTimeFrames: 0,
            lateFrames: 0, missingFrames: 30, observedAtLowerBound: now), at: now)
    }
    private func recover(_ policy: inout Q, from start: Double, seconds: Int, sequence: inout UInt64,
                         revision: UInt64 = 0) throws {
        for elapsed in 1...seconds {
            let end = start + Double(elapsed)
            _ = try policy.evaluate(window(end - 1, sequence: sequence, revision: revision), at: end)
            sequence += 1
            if elapsed < seconds { XCTAssertNil(policy.candidateMeasurementReadiness(at: end)) }
        }
        XCTAssertNotNil(policy.candidateMeasurementReadiness(at: start + Double(seconds)))
    }

    func testDiagnosticProjectsActualFailureEpisodeAndFreshHealthWatermark() throws {
        for deliveryFirst in [false, true] {
            var policy = try qualified()
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.consecutiveFailures, 0)
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.requiredHealthyDuration, 4)
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.strongHealthSequence, 1)
            let token = try policy.beginCandidateMeasurement(at: 4)
            if deliveryFirst { try failDelivery(&policy, sequence: 2, at: 5) }
            try policy.settleCandidateMeasurementFailure(token, at: 5)
            if !deliveryFirst { try failDelivery(&policy, sequence: 2, at: 5) }
            let failed = policy.candidateMeasurementDiagnostic
            XCTAssertEqual(failed.consecutiveFailures, 1)
            XCTAssertEqual(failed.requiredHealthyDuration, 10)
            XCTAssertTrue(failed.failureEpisodeActive)
            XCTAssertEqual(failed.healthyNotBefore, 5)
            XCTAssertNil(failed.strongHealthSequence)
            var sequence: UInt64 = 3
            try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.strongHealthSequence, 12)
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.strongHealthEnd, 15)
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.recoveryStart, 5)
        }
    }

    func testSameRevisionFailuresRequireTenTwentyFortySixtySecondsOfActualHealth() throws {
        var policy = try qualified(), now = 4.0
        var sequence: UInt64 = 2
        for duration in [10, 20, 40, 60, 60] {
            let token = try policy.beginCandidateMeasurement(at: now)
            try policy.settleCandidateMeasurementFailure(token, at: now)
            XCTAssertNil(policy.candidateMeasurementReadiness(at: now))
            XCTAssertNil(policy.candidateMeasurementReadiness(at: now + Double(duration)))
            XCTAssertEqual(policy.appliedRevision, 0)
            XCTAssertEqual(policy.applied, baseline)
            XCTAssertNil(try policy.checkTrialDeadline(at: now))
            try recover(&policy, from: now, seconds: duration, sequence: &sequence)
            now += Double(duration)
        }
    }

    func testRegistrationRechecksFreshnessAndDuplicateDoesNotChangeClockOrReadiness() throws {
        var absent = try controller()
        XCTAssertThrowsError(try absent.beginCandidateMeasurement(at: 4))
        var expired = try qualified()
        XCTAssertThrowsError(try expired.beginCandidateMeasurement(at: 6.001))
        XCTAssertNotNil(expired.candidateMeasurementReadiness(at: 4))
        var policy = try qualified()
        let readiness = try XCTUnwrap(policy.candidateMeasurementReadiness(at: 4))
        let token = try policy.beginCandidateMeasurement(at: 4)
        XCTAssertEqual(token.readiness, readiness)
        XCTAssertEqual(token.registeredAt, 4)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.beginCandidateMeasurement(at: now))
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4), readiness)
        }
        try policy.settleCandidateMeasurementFailure(token, at: 4)
    }

    func testForeignAndConsumedTokensCannotMutateClockOrRecovery() throws {
        var foreign = try qualified()
        let foreignToken = try foreign.beginCandidateMeasurement(at: 4)
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        let readiness = policy.candidateMeasurementReadiness(at: 4)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.settleCandidateMeasurementFailure(foreignToken, at: now))
            XCTAssertThrowsError(try policy.evaluateCandidate(candidate(), for: foreignToken, at: now))
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4), readiness)
        }
        try policy.settleCandidateMeasurementFailure(token, at: 4)
        var sequence: UInt64 = 2
        try recover(&policy, from: 4, seconds: 10, sequence: &sequence)
        let recovered = policy.candidateMeasurementReadiness(at: 14)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.settleCandidateMeasurementFailure(token, at: now))
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: 14), recovered)
        }
        let newToken = try policy.beginCandidateMeasurement(at: 14)
        XCTAssertThrowsError(try policy.settleCandidateMeasurementFailure(token, at: 100))
        try policy.settleCandidateMeasurementFailure(newToken, at: 14)
    }

    func testDeliveryAndMeasurementFailureShareOneEpisodeInEitherOrder() throws {
        for deliveryFirst in [false, true] {
            var policy = try qualified()
            let token = try policy.beginCandidateMeasurement(at: 4)
            if deliveryFirst { try failDelivery(&policy, sequence: 2, at: 4) }
            try policy.settleCandidateMeasurementFailure(token, at: 4)
            if !deliveryFirst { try failDelivery(&policy, sequence: 2, at: 4) }
            var sequence: UInt64 = 3
            try recover(&policy, from: 4, seconds: 10, sequence: &sequence)
            let second = try policy.beginCandidateMeasurement(at: 14)
            try policy.settleCandidateMeasurementFailure(second, at: 14)
            try recover(&policy, from: 14, seconds: 20, sequence: &sequence)
        }
    }

    func testBoundAdmissionIsOneShotAndOnlyExactApplicationCanTransferIt() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        _ = try policy.evaluate(window(4, sequence: 2), at: 5)
        let admission = candidate()
        let advice = try XCTUnwrap(policy.evaluateCandidate(admission, for: token, at: 5).recommendation)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.evaluateCandidate(admission, for: token, at: now))
            XCTAssertThrowsError(try policy.evaluateCandidate(candidate(), at: now))
            XCTAssertThrowsError(try policy.beginApplication(advice, at: now))
            XCTAssertThrowsError(try policy.acknowledge(advice, applied: next, at: now))
        }
        let wrong = Q.Recommendation(kind: advice.kind, attemptID: publication, windowSequence: 999,
            appliedRevision: 0, validUntil: advice.validUntil, settings: next, candidateID: advice.candidateID)
        XCTAssertThrowsError(try policy.beginApplication(wrong, for: token, at: 100))
        let application = try policy.beginApplication(advice, for: token, at: 5)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.settleCandidateMeasurementFailure(token, at: now))
            XCTAssertThrowsError(try policy.beginApplication(advice, for: token, at: now))
        }
        try policy.acknowledge(application, applied: next, at: 5)
        XCTAssertEqual(policy.appliedRevision, 1)
    }

    func testKnownNoEffectRejectionReleasesApplicationButRetainsJoinedSettlement() throws {
        for settleBeforeDownward in [false, true] {
            var policy = try qualified(rate: 800_000)
            let token = try policy.beginCandidateMeasurement(at: 4)
            _ = try policy.evaluate(window(4, sequence: 2), at: 5)
            let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(base: token.readiness.baseline,
                target: token.readiness.settings), for: token, at: 5).recommendation)
            let application = try policy.beginApplication(advice, for: token, at: 5)
            var foreign = try qualified()
            let foreignToken = try foreign.beginCandidateMeasurement(at: 4)
            XCTAssertThrowsError(try policy.noteCandidateApplicationRejection(application, for: foreignToken))
            try policy.noteCandidateApplicationRejection(application, for: token)
            XCTAssertThrowsError(try policy.noteCandidateApplicationRejection(application, for: token))
            XCTAssertEqual(policy.candidateMeasurementDiagnostic.consecutiveFailures, 0)
            let healthy = try policy.evaluate(window(5, sequence: 3), at: 6)
            XCTAssertNil(healthy.recommendation, "Known no-effect rejection must not latch a reset")
            XCTAssertThrowsError(try policy.beginCandidateMeasurement(at: 6))
            let downward = try XCTUnwrap(policy.evaluate(window(6, sequence: 4, queue: 0.8), at: 7).recommendation)
            XCTAssertEqual(downward.kind, .decrease)
            XCTAssertThrowsError(try policy.noteCandidateApplicationRejection(application, for: token))
            if settleBeforeDownward {
                try policy.settleCandidateApplicationRejection(application, for: token, at: 7)
                XCTAssertEqual(policy.candidateMeasurementDiagnostic.consecutiveFailures, 1)
                XCTAssertNil(policy.candidateMeasurementDiagnostic.strongHealthSequence)
                XCTAssertThrowsError(try policy.settleCandidateApplicationRejection(application, for: token, at: 7))
            }
            let lower = try policy.beginApplication(downward, at: 7)
            try policy.acknowledge(lower, applied: downward.settings, at: 7)
            XCTAssertThrowsError(try policy.noteCandidateApplicationRejection(application, for: token))
            if !settleBeforeDownward { try policy.retireObsoleteCandidateMeasurement(token) }
        }
    }

    func testNoOpAdmissionStillBindsAndNeedsFailureSettlement() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        _ = try policy.evaluate(window(4, sequence: 2), at: 5)
        XCTAssertNil(try policy.evaluateCandidate(candidate(padding: 0), for: token, at: 5).recommendation)
        XCTAssertThrowsError(try policy.evaluateCandidate(candidate(), for: token, at: 100))
        XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
        try policy.settleCandidateMeasurementFailure(token, at: 5)
        var sequence: UInt64 = 3
        try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
    }

    func testOwnedScopeAndMalformedAdmissionCannotEraseDownwardAdviceOrApplication() throws {
        for admitDownward in [false, true] {
            var policy = try qualified(rate: 800_000)
            let token = try policy.beginCandidateMeasurement(at: 4)
            let downward = try XCTUnwrap(policy.evaluate(window(4, sequence: 2, queue: 0.8), at: 5).recommendation)
            let application = admitDownward ? try policy.beginApplication(downward, at: 5) : nil
            for now in [100.0, .nan, 3] {
                XCTAssertThrowsError(try policy.evaluateCandidate(candidate(), for: token, at: now))
            }
            let malformed = candidate(base: token.readiness.baseline, target: token.readiness.settings, padding: .nan)
            XCTAssertThrowsError(try policy.evaluateCandidate(malformed, for: token, at: 100))
            try policy.settleCandidateMeasurementFailure(token, at: 5)
            if let application { try policy.acknowledge(application, applied: downward.settings, at: 5) }
            else { try policy.acknowledge(downward, applied: downward.settings, at: 5) }
            XCTAssertEqual(policy.applied, downward.settings)
        }
    }

    func testOnlyChangedRevisionPermitsNonCountingRetirementAndPreservesNewHealth() throws {
        var policy = try qualified(rate: 800_000)
        let token = try policy.beginCandidateMeasurement(at: 4)
        XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
        let downward = try XCTUnwrap(policy.evaluate(window(4, sequence: 2, queue: 0.8), at: 5).recommendation)
        try policy.acknowledge(downward, applied: downward.settings, at: 5)
        _ = try policy.evaluate(window(5, duration: 4, sequence: 3, revision: 1), at: 9)
        let ready = try XCTUnwrap(policy.candidateMeasurementReadiness(at: 9))
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.settleCandidateMeasurementFailure(token, at: now))
            XCTAssertThrowsError(try policy.evaluateCandidate(candidate(), for: token, at: now))
        }
        try policy.retireObsoleteCandidateMeasurement(token)
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 9), ready)
        XCTAssertThrowsError(try policy.retireObsoleteCandidateMeasurement(token))
        let next = try policy.beginCandidateMeasurement(at: 9)
        try policy.settleCandidateMeasurementFailure(next, at: 9)
        var sequence: UInt64 = 4
        try recover(&policy, from: 9, seconds: 10, sequence: &sequence, revision: 1)
    }

    func testMeasurementCannotPredateRegistrationAndRegistrationExpiryDoesNotEndCampaign() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        XCTAssertThrowsError(try policy.evaluateCandidate(candidate(start: 3), for: token, at: 5))
        _ = try policy.evaluate(window(4, duration: 4, sequence: 2), at: 8)
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(start: 7, end: 8), for: token, at: 8).recommendation)
    }

    func testSettlementBoundaryAndSourceWatermarkRequireWholeNewCoverage() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        try policy.settleCandidateMeasurementFailure(token, at: 4.5)
        _ = try policy.evaluate(window(4, sequence: 2), at: 5)
        XCTAssertNil(policy.candidateMeasurementReadiness(at: 5))
        var sequence: UInt64 = 3
        try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
        // Settlement did not erase the consumed source interval or its sequence.
        XCTAssertThrowsError(try policy.evaluate(window(4, sequence: 2), at: 15))
    }
    func testOwnedApplicationAndProbationKeepFailureCountUntilConfirmedTrial() throws {
        for confirm in [false, true] {
            var policy = try qualified(), now = 4.0
            var sequence: UInt64 = 2
            for duration in [10, 20] {
                let token = try policy.beginCandidateMeasurement(at: now)
                try policy.settleCandidateMeasurementFailure(token, at: now)
                try recover(&policy, from: now, seconds: duration, sequence: &sequence)
                now += Double(duration)
            }
            let token = try policy.beginCandidateMeasurement(at: now)
            _ = try policy.evaluate(window(now, sequence: sequence), at: now + 1)
            sequence += 1; now += 1
            let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(start: now - 1, end: now),
                for: token, at: now).recommendation)
            let application = try policy.beginApplication(advice, for: token, at: now)
            try policy.acknowledge(application, applied: next, at: now)
            if confirm {
                for _ in 0..<2 {
                    let decision = try policy.evaluate(window(now, duration: 5, sequence: sequence, revision: 1), at: now + 5)
                    now += 5; sequence += 1
                    if decision.state != .probing { XCTAssertTrue(decision.reasons.contains(.trialConfirmed)) }
                }
                try recover(&policy, from: now, seconds: 4, sequence: &sequence, revision: 1)
            } else {
                let reset = try XCTUnwrap(policy.evaluate(window(now, sequence: sequence, revision: 1, queue: 0.8),
                    at: now + 1).recommendation)
                now += 1; sequence += 1
                XCTAssertEqual(reset.kind, .reset)
                try policy.acknowledge(reset, applied: baseline, at: now)
                try recover(&policy, from: now, seconds: 40, sequence: &sequence, revision: 2)
            }
        }
    }

    func testDeliveryFailureEpisodeSurvivesOwnedApplicationAndProbationAcknowledgment() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        try failDelivery(&policy, sequence: 2, at: 4)
        var sequence: UInt64 = 3
        try recover(&policy, from: 4, seconds: 10, sequence: &sequence)
        _ = try policy.evaluate(window(14, sequence: sequence), at: 15)
        sequence += 1
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(start: 14, end: 15), for: token, at: 15).recommendation)
        let application = try policy.beginApplication(advice, for: token, at: 15)
        try policy.acknowledge(application, applied: next, at: 15)
        let reset = try XCTUnwrap(policy.evaluate(window(15, sequence: sequence, revision: 1, queue: 0.8), at: 16).recommendation)
        sequence += 1
        try policy.acknowledge(reset, applied: baseline, at: 16)
        // This is still the measurement episode whose delivery already failed.
        try recover(&policy, from: 16, seconds: 10, sequence: &sequence, revision: 2)
    }

    func testSettlementRetainsDeliveryAndCandidateReplayWatermarks() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        _ = try policy.evaluate(window(4, sequence: 2), at: 5)
        let admission = candidate()
        _ = try policy.evaluateCandidate(admission, for: token, at: 5)
        try failDelivery(&policy, sequence: 3, at: 5)
        try policy.settleCandidateMeasurementFailure(token, at: 5)
        // A new sequence does not permit reusing an already consumed lane span.
        XCTAssertThrowsError(try policy.evaluateDeliveryFailure(.init(attemptID: publication, appliedRevision: 0,
            sequence: 4, start: 4, end: 5, expectedFrames: 30, onTimeFrames: 0, lateFrames: 0,
            missingFrames: 30, observedAtLowerBound: 5), at: 5))
        var sequence: UInt64 = 5
        try recover(&policy, from: 5, seconds: 10, sequence: &sequence)
        let second = try policy.beginCandidateMeasurement(at: 15)
        _ = try policy.evaluate(window(15, sequence: sequence), at: 16)
        let ready = policy.candidateMeasurementReadiness(at: 16)
        XCTAssertThrowsError(try policy.evaluateCandidate(candidate(id: admission.id, start: 15, end: 16),
            for: second, at: 100))
        XCTAssertEqual(policy.candidateMeasurementReadiness(at: 16), ready)
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(start: 15, end: 16), for: second, at: 16).recommendation)
    }

    func testInvalidCurrentSettlementTimeLeavesAttemptAvailable() throws {
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        let ready = policy.candidateMeasurementReadiness(at: 4)
        for now in [Double.nan, .infinity, 3, 1e12 + 1] {
            XCTAssertThrowsError(try policy.settleCandidateMeasurementFailure(token, at: now))
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: 4), ready)
        }
        try policy.settleCandidateMeasurementFailure(token, at: 4)
    }

    func testUnregisteredApplicationAcknowledgmentCannotAdvanceOwnedMeasurementClock() throws {
        var other = try qualified()
        let oldAdvice = try XCTUnwrap(other.evaluateCandidate(candidate(start: 3, end: 4), at: 4).recommendation)
        let oldApplication = try other.beginApplication(oldAdvice, at: 4)
        var policy = try qualified()
        let token = try policy.beginCandidateMeasurement(at: 4)
        for now in [100.0, .nan, 3] {
            XCTAssertThrowsError(try policy.acknowledge(oldApplication, applied: next, at: now))
        }
        try policy.settleCandidateMeasurementFailure(token, at: 4)
    }

    func testFailureSettlementRetainsResetAdviceAndAdmittedReset() throws {
        for admitReset in [false, true] {
            var policy = try qualified(rate: 800_000)
            let token = try policy.beginCandidateMeasurement(at: 4)
            try failDelivery(&policy, sequence: 2, at: 4)
            let reset = try XCTUnwrap(policy.checkTrialDeadline(at: 4))
            XCTAssertEqual(reset.kind, .reset)
            let application = admitReset ? try policy.beginApplication(reset, at: 4) : nil
            try policy.settleCandidateMeasurementFailure(token, at: 4)
            if let application { try policy.acknowledge(application, applied: baseline, at: 4) }
            else { try policy.acknowledge(reset, applied: baseline, at: 4) }
            var sequence: UInt64 = 3
            try recover(&policy, from: 4, seconds: 10, sequence: &sequence, revision: 1)
        }
    }

    func testObsoleteRetirementDoesNotClearNewRevisionDownwardApplication() throws {
        var policy = try qualified(rate: 800_000)
        let token = try policy.beginCandidateMeasurement(at: 4)
        let first = try XCTUnwrap(policy.evaluate(window(4, sequence: 2, queue: 0.8), at: 5).recommendation)
        try policy.acknowledge(first, applied: first.settings, at: 5)
        let second = try XCTUnwrap(policy.evaluate(window(5, sequence: 3, revision: 1, queue: 0.8), at: 6).recommendation)
        let application = try policy.beginApplication(second, at: 6)
        try policy.retireObsoleteCandidateMeasurement(token)
        try policy.acknowledge(application, applied: second.settings, at: 6)
        XCTAssertEqual(policy.appliedRevision, 2)
        XCTAssertEqual(policy.applied, second.settings)
    }

}


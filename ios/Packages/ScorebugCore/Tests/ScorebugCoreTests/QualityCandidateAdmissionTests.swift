import Foundation
import ScorebugCore
import XCTest

final class QualityCandidateAdmissionTests: XCTestCase {
    typealias Q = QualityController
    private let attempt = UUID()
    private let baseline = Q.Settings(profileID: "small", videoBitrate: 500_000)
    private let next = Q.Settings(profileID: "small", videoBitrate: 550_000)
    private var profiles: [Q.Profile] {
        [.init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 1_000_000),
         .init(id: "large", width: 1280, height: 720, minimumBitrate: 1_500_000, maximumBitrate: 3_000_000)]
    }
    private func controller(applied: Q.Settings? = nil, at: Double = 0) throws -> Q {
        try Q(profiles: profiles, attemptID: attempt, applied: applied ?? baseline, at: at,
              recoveryStrategy: .measuredCandidateTrials, behavior: .progressive)
    }
    private func window(_ start: Double = 0, duration: Double = 4, sequence: UInt64 = 1,
                        revision: UInt64 = 0, frames: Int? = nil, receiver: Bool = true,
                        capacity: Double? = nil, queue: Double = 0.1) -> Q.Window {
        let count = frames ?? Int(duration * 30)
        return .init(attemptID: attempt, sequence: sequence, appliedRevision: revision, start: start, end: start + duration,
              capturedFreshFrames: count, encodedFreshFrames: count,
              receiver: receiver ? .init(freshFrames: count, observedAt: start + duration) : nil,
              sourceLoss: .init(expectedFrames: max(count, 1), lostFrames: 0), meanQueueOccupancy: queue,
              usableVideoCapacity: capacity, connectivity: .connected, thermalPressure: .nominal,
              workerPressure: .nominal, transportPressure: .nominal)
    }
    private func candidate(id: UUID = UUID(), attemptID: UUID? = nil, revision: UInt64 = 0,
                           base: Q.Settings? = nil, settings: Q.Settings? = nil,
                           start: Double = 3, end: Double = 4, evaluated: Double = 4,
                           until: Double = 5.5, cost: Double = 1_000_000, padding: Double = 1_250_000) -> Q.CandidateAdmission {
        .init(id: id, attemptID: attemptID ?? attempt, appliedRevision: revision, baseline: base ?? baseline,
              settings: settings ?? next, measuredStart: start, measuredEnd: end, evaluatedAt: evaluated,
              validUntil: until, candidateTransportBitsPerSecond: cost, deliveredPaddingBitsPerSecond: padding)
    }
    private func qualified() throws -> Q {
        var policy = try controller()
        XCTAssertNil(try policy.evaluate(window(), at: 4).recommendation)
        return policy
    }

    func testStrategyRequiresProgressiveBehavior() {
        XCTAssertThrowsError(try Q(profiles: profiles, attemptID: attempt, applied: baseline, at: 0,
                                  recoveryStrategy: .measuredCandidateTrials))
    }
    func testHealthAndKnownCapacityCannotBypassCandidate() throws {
        for capacity in [nil, 20_000_000.0] {
            var policy = try controller()
            for index in 0..<4 {
                XCTAssertNil(try policy.evaluate(window(Double(index * 4), sequence: UInt64(index + 1), capacity: capacity),
                                                 at: Double((index + 1) * 4)).recommendation)
            }
        }
    }
    func testMissingCandidatePreservesCreditAndValidCandidateUsesExactNext() throws {
        var policy = try qualified()
        let admission = candidate()
        let advice = try XCTUnwrap(policy.evaluateCandidate(admission, at: 4).recommendation)
        XCTAssertEqual(advice.kind, .trial)
        XCTAssertEqual(advice.candidateID, admission.id)
        XCTAssertEqual(advice.settings, next)
        XCTAssertEqual(advice.windowSequence, 1)
        XCTAssertEqual(advice.validUntil, 5.5)
        XCTAssertEqual(policy.applied, baseline)
    }
    func testCandidateRequiresTwentyFivePercentOfActualTransportCost() throws {
        for padding in [0.0, 1_249_999] {
            var policy = try qualified()
            let decision = try policy.evaluateCandidate(candidate(padding: padding), at: 4)
            XCTAssertNil(decision.recommendation)
            XCTAssertEqual(policy.applied, baseline)
        }
        var policy = try qualified()
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(), at: 4).recommendation)
    }
    func testMalformedScopeTimeCostAndTargetReject() throws {
        let invalid = [candidate(attemptID: UUID()), candidate(revision: 1), candidate(base: next),
            candidate(settings: baseline), candidate(settings: .init(profileID: "small", videoBitrate: 600_000)),
            candidate(start: -1), candidate(start: 4), candidate(end: 5), candidate(evaluated: 3.9),
            candidate(evaluated: .nan), candidate(until: 4), candidate(until: 5.5001),
            candidate(start: .nan), candidate(end: .infinity), candidate(until: .infinity),
            candidate(cost: 0), candidate(cost: -1), candidate(cost: .nan), candidate(cost: .infinity),
            candidate(padding: -1), candidate(padding: .nan), candidate(padding: .infinity)]
        for admission in invalid {
            var policy = try qualified()
            XCTAssertThrowsError(try policy.evaluateCandidate(admission, at: 4))
        }
    }
    func testNoUnknownStaleOrNonoverlappingHealthCannotAuthorize() throws {
        var absent = try controller()
        XCTAssertNil(try absent.evaluateCandidate(candidate(), at: 4).recommendation)
        var unknown = try controller()
        _ = try unknown.evaluate(window(receiver: false), at: 4)
        XCTAssertNil(try unknown.evaluateCandidate(candidate(), at: 4).recommendation)
        var stale = try qualified()
        XCTAssertNil(try stale.evaluateCandidate(candidate(start: 5, end: 6.1, evaluated: 6.1, until: 7.6), at: 6.1).recommendation)
        var nonoverlap = try qualified()
        XCTAssertNil(try nonoverlap.evaluateCandidate(candidate(start: 4.1, end: 5, evaluated: 5, until: 6), at: 5).recommendation)
    }
    func testTouchingHealthAndCandidateBoundariesDoNotAuthorize() throws {
        var priorHealth = try qualified()
        XCTAssertNil(try priorHealth.evaluateCandidate(candidate(start: 4, end: 4.5, evaluated: 4.5, until: 6), at: 4.5).recommendation)
        var laterHealth = try qualified()
        _ = try laterHealth.evaluate(window(4, duration: 1, sequence: 2), at: 5)
        XCTAssertNil(try laterHealth.evaluateCandidate(candidate(evaluated: 5, until: 6), at: 5).recommendation)
    }
    func testReplayAndOverlappingMeasurementsCannotRefreshAuthority() throws {
        var policy = try qualified()
        let admission = candidate()
        let advice = try XCTUnwrap(policy.evaluateCandidate(admission, at: 4).recommendation)
        XCTAssertThrowsError(try policy.evaluateCandidate(admission, at: 4.1))
        XCTAssertThrowsError(try policy.beginApplication(advice, at: 4.1))
        XCTAssertThrowsError(try policy.evaluateCandidate(candidate(start: 3.5, end: 4.5, evaluated: 4.5, until: 6), at: 4.5))
    }
    func testCandidateDoesNotAddCreditOrConsumeHealthSequence() throws {
        var policy = try controller()
        _ = try policy.evaluate(window(duration: 2), at: 2)
        XCTAssertNil(try policy.evaluateCandidate(candidate(start: 1, end: 2, evaluated: 2, until: 3.5), at: 2).recommendation)
        _ = try policy.evaluate(window(2, duration: 2, sequence: 2), at: 4)
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(), at: 4).recommendation)
    }
    func testExactNextProfileAtMaximumBitrate() throws {
        let base = Q.Settings(profileID: "small", videoBitrate: 1_000_000)
        let target = Q.Settings(profileID: "large", videoBitrate: 1_500_000)
        var policy = try controller(applied: base)
        _ = try policy.evaluate(window(), at: 4)
        XCTAssertEqual(try policy.evaluateCandidate(candidate(base: base, settings: target), at: 4).recommendation?.settings, target)
    }
    func testAdviceExpirationAndNewHealthSupersede() throws {
        var expired = try qualified()
        let advice = try XCTUnwrap(expired.evaluateCandidate(candidate(), at: 4).recommendation)
        XCTAssertThrowsError(try expired.beginApplication(advice, at: 5.5001))
        var superseded = try qualified()
        let old = try XCTUnwrap(superseded.evaluateCandidate(candidate(), at: 4).recommendation)
        _ = try superseded.evaluate(window(4, duration: 1, sequence: 2), at: 5)
        XCTAssertThrowsError(try superseded.beginApplication(old, at: 5))
    }
    func testOwnedApplicationCanFinishAfterCandidateExpiryAndConfirmTrial() throws {
        var policy = try qualified()
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(until: 4.2), at: 4).recommendation)
        let application = try policy.beginApplication(advice, at: 4.1)
        try policy.acknowledge(application, applied: next, at: 5)
        XCTAssertNil(try policy.checkTrialDeadline(at: 5.1))
        XCTAssertEqual(try policy.evaluate(window(5, duration: 5, sequence: 2, revision: 1), at: 10).state, .probing)
        let confirmed = try policy.evaluate(window(10, duration: 5, sequence: 3, revision: 1), at: 15)
        XCTAssertTrue(confirmed.reasons.contains(.trialConfirmed))
        XCTAssertEqual(policy.applied, next)
    }
    func testExpiredOwnedApplicationAndFailedTrialResetMinimum() throws {
        var policy = try qualified()
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(), at: 4).recommendation)
        let application = try policy.beginApplication(advice, at: 4)
        XCTAssertEqual(try policy.checkTrialDeadline(at: 6.01)?.kind, .reset)
        XCTAssertThrowsError(try policy.acknowledge(application, applied: next, at: 6.01))
        var trial = try qualified()
        let proposal = try XCTUnwrap(trial.evaluateCandidate(candidate(), at: 4).recommendation)
        try trial.acknowledge(proposal, applied: next, at: 4)
        let failed = try trial.evaluate(window(4, sequence: 2, revision: 1, frames: 80), at: 8)
        XCTAssertEqual(failed.recommendation?.kind, .reset)
        XCTAssertEqual(failed.recommendation?.settings, baseline)
    }
    func testExplicitInvalidationRevokesAdmissionHealth() throws {
        var policy = try qualified()
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(), at: 4).recommendation)
        policy.invalidateTelemetry()
        XCTAssertThrowsError(try policy.beginApplication(advice, at: 4))
        XCTAssertNil(try policy.evaluateCandidate(candidate(start: 4, end: 4.1, evaluated: 4.1, until: 5.6), at: 4.1).recommendation)
    }
    func testBoundedCandidateCompletionCanExceedHealthWindowSpan() throws {
        var policy = try controller()
        _ = try policy.evaluate(window(), at: 4)
        _ = try policy.evaluate(window(4, duration: 2, sequence: 2), at: 6)
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(start: 0, end: 6, evaluated: 6, until: 7.5), at: 6).recommendation)
        var tooLong = try controller()
        XCTAssertThrowsError(try tooLong.evaluateCandidate(candidate(start: 0, end: 7.01, evaluated: 7.01, until: 8), at: 7.01))
    }
    func testRepeatedIdentityCannotClaimNewMeasurementTimes() throws {
        var policy = try qualified()
        let id = UUID()
        _ = try policy.evaluateCandidate(candidate(id: id), at: 4)
        XCTAssertThrowsError(try policy.evaluateCandidate(candidate(id: id, start: 4, end: 4.5, evaluated: 4.5, until: 6), at: 4.5))
    }
    func testFreshHealthDeadlineCapsAdviceAndIncludesBoundary() throws {
        var policy = try qualified()
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(start: 3, end: 5, evaluated: 5, until: 6.5), at: 5).recommendation)
        XCTAssertEqual(advice.validUntil, 6)
        XCTAssertNoThrow(try policy.beginApplication(advice, at: 6))
    }
    func testOutOfDomainCandidateTimeDoesNotPoisonClock() throws {
        for invalidNow in [1e12 + 1, Double.infinity, Double.nan, -1] {
            var policy = try qualified()
            XCTAssertThrowsError(try policy.evaluateCandidate(candidate(), at: invalidNow))
            _ = try policy.evaluate(window(4, sequence: 2), at: 8)
            XCTAssertNotNil(try policy.evaluateCandidate(candidate(start: 7, end: 8, evaluated: 8, until: 9.5), at: 8).recommendation)
        }
    }
    func testCandidateStalenessAndBeforeAppliedMeasurementReject() throws {
        var stale = try qualified()
        XCTAssertThrowsError(try stale.evaluateCandidate(candidate(), at: 6.01))
        var beforeApplied = try controller(at: 2)
        _ = try beforeApplied.evaluate(window(2), at: 6)
        XCTAssertThrowsError(try beforeApplied.evaluateCandidate(candidate(start: 1, end: 6, evaluated: 6, until: 7.5), at: 6))
    }
    func testFailureSignalAndLocalPressureRevokeCandidateAuthority() throws {
        for mode in 0..<3 {
            var policy = try qualified()
            let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(), at: 4).recommendation)
            if mode == 0 {
                _ = try policy.evaluateDecoderStall(.init(attemptID: attempt, appliedRevision: 0, sequence: 2,
                                                         observedAtLowerBound: 4), at: 4)
            } else if mode == 1 {
                _ = try policy.evaluateDeliveryFailure(.init(attemptID: attempt, appliedRevision: 0, sequence: 2,
                    start: 3, end: 4, expectedFrames: 30, onTimeFrames: 0, lateFrames: 0, missingFrames: 30,
                    observedAtLowerBound: 4), at: 4)
            } else {
                _ = try policy.evaluateLocalPressure(.init(attemptID: attempt, sequence: 2, appliedRevision: 0,
                    start: 4, end: 4.25, capturedFreshFrames: nil, encodedFreshFrames: nil, receiver: nil,
                    sourceLoss: nil, meanQueueOccupancy: nil, usableVideoCapacity: nil, connectivity: .unknown,
                    thermalPressure: .elevated, workerPressure: .unknown), at: 4.25)
            }
            XCTAssertThrowsError(try policy.beginApplication(advice, at: 4.25))
            XCTAssertNil(try policy.evaluateCandidate(candidate(start: 4, end: 4.5, evaluated: 4.5, until: 6), at: 4.5).recommendation)
        }
    }
    func testAdmissionShortfallDoesNotEraseRecoveryCredit() throws {
        var policy = try qualified()
        XCTAssertNil(try policy.evaluateCandidate(candidate(padding: 0), at: 4).recommendation)
        _ = try policy.evaluate(window(4, duration: 1, sequence: 2), at: 5)
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(start: 4, end: 5, evaluated: 5, until: 6.5), at: 5).recommendation)
    }
    func testResetRetainsProgressiveRecoveryCooldown() throws {
        var policy = try qualified()
        let advice = try XCTUnwrap(policy.evaluateCandidate(candidate(), at: 4).recommendation)
        try policy.acknowledge(advice, applied: next, at: 4)
        let reset = try XCTUnwrap(policy.evaluate(window(4, sequence: 2, revision: 1, frames: 80), at: 8).recommendation)
        try policy.acknowledge(reset, applied: baseline, at: 8)
        _ = try policy.evaluate(window(8, sequence: 3, revision: 2), at: 12)
        XCTAssertNil(try policy.evaluateCandidate(candidate(revision: 2, start: 11, end: 12, evaluated: 12, until: 13.5), at: 12).recommendation)
        _ = try policy.evaluate(window(12, sequence: 4, revision: 2), at: 16)
        _ = try policy.evaluate(window(16, duration: 2, sequence: 5, revision: 2), at: 18)
        XCTAssertNotNil(try policy.evaluateCandidate(candidate(revision: 2, start: 17, end: 18, evaluated: 18, until: 19.5), at: 18).recommendation)
    }

}

import Foundation
import XCTest
@testable import ScorebugCore

final class QualityTrialTests: XCTestCase {
    private let attempt = UUID()
    private func controller(rate: Int = 2_000_000) throws -> QualityController {
        try .init(profiles: [
            .init(id: "720", width: 1280, height: 720, minimumBitrate: 1_000_000, maximumBitrate: 3_000_000),
            .init(id: "1080", width: 1920, height: 1080, minimumBitrate: 3_000_000, maximumBitrate: 6_000_000)],
            attemptID: attempt, applied: .init(profileID: "720", videoBitrate: rate), at: 0,
            recoveryStrategy: .receiverValidatedTrials)
    }
    private func window(_ start: Double, revision: UInt64 = 0, received: Int? = 150,
                        queue: Double? = 0.1, capacity: Double? = nil,
                        connected: QualityController.Connectivity = .connected,
                        thermal: QualityController.Pressure = .nominal,
                        worker: QualityController.Pressure = .nominal,
                        transport: QualityController.Pressure = .nominal, duration: Double = 5) -> QualityController.Window {
        .init(attemptID: attempt, sequence: UInt64(start + 1), appliedRevision: revision,
              start: start, end: start + duration, capturedFreshFrames: 150, encodedFreshFrames: 150,
              receiver: received.map { .init(freshFrames: $0, observedAt: start + duration) },
              sourceLoss: .init(expectedFrames: 150, lostFrames: 0), meanQueueOccupancy: queue,
              usableVideoCapacity: capacity, connectivity: connected, thermalPressure: thermal, workerPressure: worker, transportPressure: transport)
    }
    private func ready(_ policy: inout QualityController) throws -> QualityController.Recommendation {
        for start in stride(from: 0.0, to: 25, by: 5) {
            XCTAssertNil(try policy.evaluate(window(start), at: start + 5).recommendation)
        }
        let result = try policy.evaluate(window(25), at: 30)
        XCTAssertTrue(result.reasons.contains(.missingCapacity))
        return try XCTUnwrap(result.recommendation)
    }
    private func probing() throws -> QualityController {
        var policy = try controller()
        let advice = try ready(&policy)
        try policy.acknowledge(advice, applied: advice.settings, at: 30)
        return policy
    }
    func testMeasuredNativeTimelineRequiresThirdWindowWithoutPrematureTimeout() throws {
        var policy = try controller()
        let advice = try ready(&policy)
        // Actual native-app-r29PCh boundaries shifted to the recovery endpoint30.
        let ack = 31.9388389168
        try policy.acknowledge(advice, applied: advice.settings, at: ack)
        let start = 35.0015033751, middle = 40.0017947917, end = 45.0014831251
        let first = try policy.evaluate(window(start, revision: 1, duration: middle - start), at: 41.8298047918)
        XCTAssertEqual(first.state, .probing)
        let second = try policy.evaluate(window(middle, revision: 1, duration: end - middle), at: 46.9056670833)
        XCTAssertLessThan(end - start, 10)
        XCTAssertFalse(second.reasons.contains(.trialConfirmed))
        XCTAssertNil(try policy.checkTrialDeadline(at: ack + 15))
        let third = try policy.evaluate(window(end, revision: 1), at: 51.85)
        XCTAssertTrue(third.reasons.contains(.trialConfirmed))
        XCTAssertNil(third.recommendation)
        XCTAssertNil(try policy.checkTrialDeadline(at: 100))
    }
    func testInitialProbationGapHasAnExactBoundAndCannotBeRehabilitated() throws {
        var boundary = try probing()
        let accepted = try boundary.evaluate(window(35.25, revision: 1), at: 40.25)
        XCTAssertEqual(accepted.state, .probing)
        var late = try probing()
        let rejected = try late.evaluate(window(35.250001, revision: 1), at: 40.250001)
        XCTAssertEqual(rejected.recommendation?.kind, .rollback)
        XCTAssertEqual(try late.evaluate(window(40.250001, revision: 1), at: 45.250001).recommendation?.kind, .rollback)
    }
    func testMeasuredDurationAllowanceDoesNotClampActualFrameRates() throws {
        for duration in [5.000622458290309, 5.00198454153724, 5.25] {
            var policy = try controller()
            let result = try policy.evaluate(window(0, duration: duration), at: duration)
            XCTAssertFalse(result.reasons.contains(.freshFrameFloor))
        }
        var bad = try controller()
        XCTAssertThrowsError(try bad.evaluate(window(0, duration: 5.250001), at: 5.250001))
        var floor = try controller()
        let result = try floor.evaluate(window(0, received: 125, duration: 5.25), at: 5.25)
        XCTAssertTrue(result.reasons.contains(.freshFrameFloor), "125/5.25 is below 24 even though 125/5 is not")
        XCTAssertEqual(result.recommendation?.kind, .decrease)
    }
    func testInputAllowanceCannotMakeWeakCadenceQualifyRecovery() throws {
        var policy = try controller()
        for i in 0..<12 {
            let start = Double(i) * 5.25
            XCTAssertNil(try policy.evaluate(window(start, duration: 5.25), at: start + 5.25).recommendation,
                "150/5.25 must stay below the 29.7 fps recovery gate")
        }
    }
    func testJitteredWindowsUseActualElapsedRecoveryAndTrialConfirmation() throws {
        var policy = try controller(), start = 0.0
        let durations = [5.000622458290309, 5.00198454153724, 4.99989033350721, 5.0002941666170955, 4.998970333486795, 5.001]
        var recommendation: QualityController.Recommendation?
        for (i, duration) in durations.enumerated() {
            let decision = try policy.evaluate(window(start, duration: duration), at: start + duration)
            if i < 5 { XCTAssertNil(decision.recommendation) }
            recommendation = decision.recommendation
            start += duration
        }
        let trial = try XCTUnwrap(recommendation)
        XCTAssertEqual(trial.kind, .trial)
        try policy.acknowledge(trial, applied: trial.settings, at: start)
        let first = try policy.evaluate(window(start, revision: 1, duration: 5.001), at: start + 5.001)
        XCTAssertFalse(first.reasons.contains(.trialConfirmed))
        start += 5.001
        let second = try policy.evaluate(window(start, revision: 1, duration: 5.001), at: start + 5.001)
        XCTAssertTrue(second.reasons.contains(.trialConfirmed))
    }
    func testExternalInvalidationRevokesAdviceAndRestartsRecovery() throws {
        var policy = try controller()
        let advice = try ready(&policy)
        policy.invalidateTelemetry()
        XCTAssertEqual(policy.appliedRevision, 0)
        XCTAssertThrowsError(try policy.acknowledge(advice, applied: advice.settings, at: 30))
        for start in stride(from: 30.0, through: 50, by: 5) {
            XCTAssertNil(try policy.evaluate(window(start), at: start + 5).recommendation)
        }
        XCTAssertEqual(try policy.evaluate(window(55), at: 60).recommendation?.kind, .trial)
    }
    func testExternalInvalidationRequiresStickyRollbackWithoutChangingAppliedState() throws {
        var policy = try probing()
        policy.invalidateTelemetry()
        XCTAssertEqual(policy.appliedRevision, 1)
        XCTAssertEqual(policy.applied.videoBitrate, 2_200_000)
        XCTAssertEqual(try policy.checkTrialDeadline(at: 31)?.kind, .rollback)
        XCTAssertEqual(try policy.evaluate(window(30, revision: 1), at: 35).recommendation?.kind, .rollback)
    }
    func testUnknownCapacityCanRecommendExplicitBoundedTrialAfterThirtySeconds() throws {
        var policy = try controller()
        let advice = try ready(&policy)
        XCTAssertEqual(advice.kind, .trial)
        XCTAssertEqual(advice.settings, .init(profileID: "720", videoBitrate: 2_200_000))
        XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
        XCTAssertEqual(policy.appliedRevision, 0)
    }
    func testOtherUnknownsAndKnownInsufficientCandidateCapacityPreventTrials() throws {
        for mode in 0..<6 {
            var policy = try controller()
            for start in stride(from: 0.0, to: 40, by: 5) {
                let w = window(start, received: mode == 0 ? nil : 150,
                               queue: mode == 1 ? nil : 0.1, capacity: mode == 4 ? 2_600_000 : nil,
                               thermal: mode == 2 ? .unknown : .nominal, worker: mode == 3 ? .unknown : .nominal, transport: mode == 5 ? .unknown : .nominal)
                XCTAssertNil(try policy.evaluate(w, at: start + 5).recommendation)
            }
        }
    }
    func testTrialCannotJumpResolutionOrExceedProfileMaximum() throws {
        var maximum = try controller(rate: 3_000_000)
        for start in stride(from: 0.0, to: 40, by: 5) {
            XCTAssertNil(try maximum.evaluate(window(start), at: start + 5).recommendation)
        }
        var near = try controller(rate: 2_900_000)
        XCTAssertEqual(try ready(&near).settings.videoBitrate, 3_000_000)
    }
    func testExactApplicationAndTenPostApplicationSecondsRequiredForConfirmation() throws {
        var policy = try probing()
        XCTAssertEqual(policy.appliedRevision, 1)
        let first = try policy.evaluate(window(30, revision: 1), at: 35)
        XCTAssertEqual(first.state, .probing); XCTAssertNil(first.recommendation)
        let confirmed = try policy.evaluate(window(35, revision: 1), at: 40)
        XCTAssertTrue(confirmed.reasons.contains(.trialConfirmed))
        XCTAssertNil(confirmed.recommendation)
        XCTAssertNil(try policy.checkTrialDeadline(at: 50))
        XCTAssertEqual(policy.applied.videoBitrate, 2_200_000)
    }
    func testFailedApplicationDoesNotStartTrialAndUnexpectedSettingsAreRejected() throws {
        for actual in [QualityController.Settings(profileID: "720", videoBitrate: 2_100_000),
                       .init(profileID: "720", videoBitrate: 2_300_000)] {
            var policy = try controller(); let advice = try ready(&policy)
            XCTAssertThrowsError(try policy.acknowledge(advice, applied: actual, at: 30))
            XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
            XCTAssertEqual(policy.appliedRevision, 0)
        }
        var failed = try controller(); let advice = try ready(&failed)
        try failed.acknowledge(advice, applied: nil, at: 30)
        XCTAssertNil(try failed.checkTrialDeadline(at: 100))
        XCTAssertEqual(failed.appliedRevision, 0)
    }
    func testBadUnknownAndDisconnectedTrialEvidenceRequestExactBaselineRollback() throws {
        let failures = [window(30, revision: 1, received: 100), window(30, revision: 1, received: nil),
                        window(30, revision: 1, queue: 0.6), window(30, revision: 1, connected: .disconnected),
                        window(30, revision: 1, thermal: .unknown), window(30, revision: 1, worker: .elevated),
                        window(30, revision: 1, transport: .unknown), window(30, revision: 1, transport: .elevated)]
        for failure in failures {
            var policy = try probing()
            let advice = try XCTUnwrap(policy.evaluate(failure, at: 35).recommendation)
            XCTAssertEqual(advice.kind, .rollback)
            XCTAssertEqual(advice.settings.videoBitrate, 2_000_000)
            XCTAssertEqual(policy.applied.videoBitrate, 2_200_000)
        }
    }
    func testGapAndInvalidWindowCannotRehabilitateTrial() throws {
        var gap = try probing()
        _ = try gap.evaluate(window(30, revision: 1), at: 35)
        XCTAssertEqual(try gap.evaluate(window(36, revision: 1), at: 41).recommendation?.kind, .rollback)
        var invalid = try probing()
        XCTAssertThrowsError(try invalid.evaluate(window(30, revision: 0), at: 35))
        let advice = try XCTUnwrap(invalid.checkTrialDeadline(at: 35))
        XCTAssertEqual(advice.kind, .rollback)
        let later = try invalid.evaluate(window(35, revision: 1), at: 40)
        XCTAssertEqual(later.recommendation?.kind, .rollback)
    }
    func testDeadlinePollRollsBackWithoutReceiverWindowsAndSupersedesExpiredAdvice() throws {
        var policy = try probing()
        XCTAssertNil(try policy.checkTrialDeadline(at: 52.499))
        let first = try XCTUnwrap(policy.checkTrialDeadline(at: 52.5))
        XCTAssertEqual(first.kind, .rollback)
        XCTAssertEqual(first.validUntil, 54.5)
        let next = try XCTUnwrap(policy.checkTrialDeadline(at: 55.5))
        XCTAssertEqual(next.validUntil, 57.5)
        XCTAssertThrowsError(try policy.acknowledge(first, applied: first.settings, at: 55.5))
        try policy.acknowledge(next, applied: next.settings, at: 55.5)
        XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
    }
    func testFailedRollbackStaysRequiredAndSuccessfulRollbackStartsCooldown() throws {
        var policy = try probing()
        let advice = try XCTUnwrap(policy.evaluate(window(30, revision: 1, received: nil), at: 35).recommendation)
        try policy.acknowledge(advice, applied: nil, at: 35)
        let retry = try XCTUnwrap(policy.checkTrialDeadline(at: 36))
        XCTAssertEqual(retry.kind, .rollback)
        try policy.acknowledge(retry, applied: retry.settings, at: 36)
        XCTAssertEqual(policy.appliedRevision, 2)
        for start in stride(from: 36.0, to: 91, by: 5) {
            XCTAssertNil(try policy.evaluate(window(start, revision: 2), at: start + 5).recommendation)
        }
        XCTAssertEqual(try policy.evaluate(window(91, revision: 2), at: 96).recommendation?.kind, .trial)
    }
    func testKnownBadSignalsStillDecreaseWithoutCapacityBeforeTrial() throws {
        var policy = try controller()
        let result = try policy.evaluate(window(0, received: 100), at: 5)
        XCTAssertEqual(result.recommendation?.kind, .decrease)
        XCTAssertEqual(result.recommendation?.settings.videoBitrate, 1_600_000)
    }
    func testLateTrialAcknowledgmentAndInvalidDeadlineClockCannotStartOrHideTrial() throws {
        var initial = try controller(); let advice = try ready(&initial)
        XCTAssertThrowsError(try initial.acknowledge(advice, applied: advice.settings, at: 33))
        XCTAssertNil(try initial.checkTrialDeadline(at: 100))
        var active = try probing()
        for bad in [Double.nan, .infinity, 29] { XCTAssertThrowsError(try active.checkTrialDeadline(at: bad)) }
        XCTAssertNotNil(try active.checkTrialDeadline(at: 45))
    }
    func testLateCompleteTrialCannotConfirmAfterDeadline() throws {
        var policy = try probing()
        _ = try policy.evaluate(window(35, revision: 1), at: 40)
        let result = try policy.evaluate(window(47.5, revision: 1), at: 52.5)
        XCTAssertEqual(result.recommendation?.kind, .rollback)
        XCTAssertTrue(result.reasons.contains(.trialTimedOut))
    }
    func testIntegerRoundingNeverExceedsTenPercentOrInventsMinimumStep() throws {
        for rate in [1, 9, 11, 29] {
            var policy = try QualityController(profiles: [
                .init(id: "tiny", width: 640, height: 360, minimumBitrate: 1, maximumBitrate: 100)],
                attemptID: attempt, applied: .init(profileID: "tiny", videoBitrate: rate), at: 0,
                recoveryStrategy: .receiverValidatedTrials)
            var advice: QualityController.Recommendation?
            for start in stride(from: 0.0, to: 30, by: 5) {
                advice = try policy.evaluate(window(start), at: start + 5).recommendation
            }
            if rate < 10 { XCTAssertNil(advice) }
            else {
                let value = try XCTUnwrap(advice).settings.videoBitrate
                XCTAssertLessThanOrEqual(Double(value), Double(rate) * 1.1)
                XCTAssertGreaterThan(value, rate)
            }
        }
    }

    func testInvalidDeadlineClockRequiresRollbackBeforeDeadline() throws {
        for bad in [Double.nan, .infinity, 29] {
            var policy = try probing()
            XCTAssertThrowsError(try policy.checkTrialDeadline(at: bad))
            XCTAssertEqual(try policy.checkTrialDeadline(at: 31)?.kind, .rollback)
        }
    }

    func testTrialRollbackKeepsOutageAndStallStatesExplicit() throws {
        var disconnected = try probing()
        let outage = try disconnected.evaluate(window(30, revision: 1, connected: .disconnected), at: 35)
        XCTAssertEqual(outage.state, .disconnected)
        XCTAssertEqual(outage.recommendation?.kind, .rollback)
        var stalled = try probing()
        let stopped = try stalled.evaluate(window(30, revision: 1, received: 0), at: 35)
        XCTAssertEqual(stopped.state, .stalled)
        XCTAssertEqual(stopped.recommendation?.kind, .rollback)
    }

}

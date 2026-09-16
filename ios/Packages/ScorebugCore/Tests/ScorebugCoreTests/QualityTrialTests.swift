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
                        transport: QualityController.Pressure = .nominal) -> QualityController.Window {
        .init(attemptID: attempt, sequence: UInt64(start + 1), appliedRevision: revision,
              start: start, end: start + 5, capturedFreshFrames: 150, encodedFreshFrames: 150,
              receiver: received.map { .init(freshFrames: $0, observedAt: start + 5) },
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
        XCTAssertNil(try policy.checkTrialDeadline(at: 44.999))
        let first = try XCTUnwrap(policy.checkTrialDeadline(at: 45))
        XCTAssertEqual(first.kind, .rollback)
        XCTAssertEqual(first.validUntil, 47)
        let next = try XCTUnwrap(policy.checkTrialDeadline(at: 48))
        XCTAssertEqual(next.validUntil, 50)
        XCTAssertThrowsError(try policy.acknowledge(first, applied: first.settings, at: 48))
        try policy.acknowledge(next, applied: next.settings, at: 48)
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
        let result = try policy.evaluate(window(40, revision: 1), at: 46)
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

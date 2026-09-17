import Foundation
import XCTest
@testable import ScorebugCore

final class ProgressiveQualityTests: XCTestCase {
    private let attempt = UUID()
    private let minimum = QualityController.Settings(profileID: "low", videoBitrate: 350_000)
    private let high = QualityController.Settings(profileID: "high", videoBitrate: 6_000_000)
    private var profiles: [QualityController.Profile] { [
        .init(id: "low", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
        .init(id: "middle", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000),
        .init(id: "high", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
    ] }
    private func controller(high: Bool = true) throws -> QualityController {
        try .init(profiles: profiles, attemptID: attempt, applied: high ? self.high : minimum,
                  at: 0, recoveryStrategy: .receiverValidatedProfileTrials, behavior: .progressive)
    }
    private func window(_ start: Double, duration: Double = 1, revision: UInt64 = 0,
                        received: Int? = 30, lost: Int = 0, capacity: Double? = 20_000_000,
                        transport: QualityController.Pressure = .nominal,
                        connectivity: QualityController.Connectivity = .connected) -> QualityController.Window {
        let count = Int(duration * 30)
        return .init(attemptID: attempt, sequence: UInt64(start * 1000) + 1, appliedRevision: revision,
            start: start, end: start + duration, capturedFreshFrames: count, encodedFreshFrames: count,
            receiver: received.map { .init(freshFrames: $0, observedAt: start + duration) },
            sourceLoss: .init(expectedFrames: count, lostFrames: lost), meanQueueOccupancy: 0.1,
            usableVideoCapacity: capacity, connectivity: connectivity, thermalPressure: .nominal,
            workerPressure: .nominal, transportPressure: transport)
    }
    private func healthy(_ policy: inout QualityController, from: Double, seconds: Int,
                         adviceAtEnd: Bool = true) throws -> QualityController.Recommendation? {
        var advice: QualityController.Recommendation?
        for i in 0..<seconds {
            let t = from + Double(i)
            advice = try policy.evaluate(window(t, revision: policy.appliedRevision), at: t + 1).recommendation
            if i < seconds - 1 || !adviceAtEnd { XCTAssertNil(advice, "premature increase at \(t + 1)") }
        }
        if adviceAtEnd { XCTAssertNotNil(advice) }
        return advice
    }
    func testProgressiveStartupNeedsFourContinuousHealthySeconds() throws {
        var p = try controller(high: false)
        let advice = try XCTUnwrap(healthy(&p, from: 0, seconds: 4))
        XCTAssertEqual(advice.kind, .trial)
        XCTAssertEqual(advice.settings.profileID, "middle")
        XCTAssertEqual(p.applied, minimum)
    }
    func testTwoSecondLossBoundaryResetsDirectlyToMinimum() throws {
        for lost in [3, 4] {
            var p = try controller()
            let d = try p.evaluate(window(0, duration: 2, received: 60 - lost, lost: lost), at: 2)
            XCTAssertEqual(d.recommendation?.settings, lost == 4 ? minimum : nil)
            XCTAssertEqual(d.recommendation?.kind, lost == 4 ? .reset : nil)
            XCTAssertEqual(p.applied, high)
        }
        var short = try controller()
        XCTAssertNil(try short.evaluate(window(0, received: 28, lost: 2), at: 1).recommendation,
                     "A one-second loss fraction is not a complete two-second loss window")
    }
    func testOneSecondFreshFloorBoundaryAndStall() throws {
        for frames in [24, 23, 0] {
            var p = try controller()
            let d = try p.evaluate(window(0, received: frames), at: 1)
            XCTAssertEqual(d.recommendation?.settings, frames < 24 ? minimum : nil)
            if frames == 0 { XCTAssertEqual(d.state, .stalled) }
        }
        var floor = try controller(high: false)
        for i in 0..<20 {
            XCTAssertNil(try floor.evaluate(window(Double(i), received: 24), at: Double(i + 1)).recommendation)
        }
    }
    func testMinimumFailureDoesNotRecreateEncoderAndStillRequiresTenHealthySeconds() throws {
        var p = try controller(high: false)
        for i in 0..<5 {
            let d = try p.evaluate(window(Double(i), received: 23), at: Double(i + 1))
            XCTAssertEqual(d.state, .insufficient)
            XCTAssertNil(d.recommendation)
        }
        XCTAssertNil(try p.checkTrialDeadline(at: 5))
        _ = try healthy(&p, from: 5, seconds: 10)
        XCTAssertEqual(p.appliedRevision, 0)
    }
    func testResetRequiresExactAcknowledgmentAndPostCompletionHealth() throws {
        var p = try controller()
        let reset = try XCTUnwrap(p.evaluate(window(0, received: 23), at: 1).recommendation)
        let admitted = try p.beginApplication(reset, at: 2)
        XCTAssertEqual(p.applied, high)
        try p.acknowledge(admitted, applied: minimum, at: 3)
        XCTAssertEqual(p.applied, minimum)
        XCTAssertEqual(p.appliedRevision, 1)
        _ = try healthy(&p, from: 3, seconds: 10)
    }
    private func beginTrial(_ p: inout QualityController, from: Double = 0,
                            hold: Int = 4) throws -> Double {
        let advice = try XCTUnwrap(healthy(&p, from: from, seconds: hold))
        let t = from + Double(hold)
        try p.acknowledge(advice, applied: advice.settings, at: t)
        return t
    }
    func testFailureDuringTrialDiscardsHigherBaselineAndStaysLatchedThroughHealthyOrUnknown() throws {
        var p = try controller(high: false)
        _ = try beginTrial(&p)
        // Confirm the first step, then trial high from a middle baseline.
        _ = try healthy(&p, from: 4, seconds: 10, adviceAtEnd: false)
        let highAt = try beginTrial(&p, from: 14)
        XCTAssertEqual(p.applied, high)
        let failure = try p.evaluate(window(highAt, revision: 2, transport: .elevated), at: highAt + 1)
        XCTAssertEqual(failure.recommendation?.kind, .reset)
        XCTAssertEqual(failure.recommendation?.settings, minimum)
        let healthy = try p.evaluate(window(highAt + 1, revision: 2), at: highAt + 2)
        XCTAssertEqual(healthy.recommendation?.settings, minimum)
        p.invalidateTelemetry()
        XCTAssertEqual(try p.checkTrialDeadline(at: highAt + 3)?.settings, minimum)
        let unknown = try p.evaluate(window(highAt + 2, revision: 2, received: nil), at: highAt + 3)
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.recommendation?.kind, .reset)
    }
    func testResetFailureExpiryClampingAndInvalidClockNeverReleaseIntent() throws {
        for mode in 0..<5 {
            var p = try controller()
            let reset = try XCTUnwrap(p.evaluate(window(0, received: 0), at: 1).recommendation)
            let a = try p.beginApplication(reset, at: 1)
            switch mode {
            case 0: try p.acknowledge(a, applied: nil, at: 2)
            case 1: XCTAssertThrowsError(try p.acknowledge(a, applied: minimum, at: 3.01))
            case 2: XCTAssertThrowsError(try p.acknowledge(a, applied: high, at: 2))
            case 3: p.invalidateTelemetry()
            default: XCTAssertThrowsError(try p.acknowledge(a, applied: minimum, at: .nan))
            }
            XCTAssertEqual(p.applied, high)
            XCTAssertEqual(p.appliedRevision, 0)
            let retry = try XCTUnwrap(p.checkTrialDeadline(at: 4))
            XCTAssertEqual(retry.kind, .reset)
            XCTAssertEqual(retry.settings, minimum)
            XCTAssertThrowsError(try p.acknowledge(a, applied: minimum, at: 4))
            try p.acknowledge(retry, applied: minimum, at: 4)
            _ = try healthy(&p, from: 4, seconds: 10)
        }
    }
    func testPollingNeverRevokesLiveResetApplicationOrRenewsItsCompletionBudget() throws {
        var p = try controller()
        let reset = try XCTUnwrap(p.evaluate(window(0, received: 23), at: 1).recommendation)
        let a = try p.beginApplication(reset, at: 2.9)
        XCTAssertNil(try p.checkTrialDeadline(at: 3.1), "Original advice has expired, admitted work has not")
        XCTAssertThrowsError(try p.beginApplication(reset, at: 3.1))
        try p.acknowledge(a, applied: minimum, at: 4.5)
        XCTAssertNil(try p.checkTrialDeadline(at: 4.5))
        _ = try healthy(&p, from: 4.5, seconds: 10)
    }
    func testProgressiveTrialTimeoutAndInvalidTelemetryResetWithoutNewFrames() throws {
        for invalidation in [false, true] {
            var p = try controller(high: false)
            _ = try beginTrial(&p)
            if invalidation { p.invalidateTelemetry() }
            let t = invalidation ? 4.5 : 4 + QualityController.maximumTrialDuration
            let reset = try XCTUnwrap(p.checkTrialDeadline(at: t))
            XCTAssertEqual(reset.kind, .reset)
            XCTAssertEqual(reset.settings, minimum)
            try p.acknowledge(reset, applied: minimum, at: t)
            _ = try healthy(&p, from: t, seconds: 10)
        }
    }
    func testFailedIncreaseApplicationsResetAndCannotPretendNativeSettingsChanged() throws {
        for mode in 0..<4 {
            var p = try controller(high: false)
            let advice = try XCTUnwrap(healthy(&p, from: 0, seconds: 4))
            let a = try p.beginApplication(advice, at: 4)
            switch mode {
            case 0: try p.acknowledge(a, applied: nil, at: 4)
            case 1: XCTAssertThrowsError(try p.acknowledge(a, applied: advice.settings, at: 6.01))
            case 2: p.invalidateTelemetry()
            default: _ = try p.evaluate(window(4, received: nil), at: 5)
            }
            XCTAssertEqual(p.applied, minimum)
            XCTAssertEqual(p.appliedRevision, 0)
            let retry = try p.checkTrialDeadline(at: 7)
            if mode == 0 {
                XCTAssertNil(retry, "Known failed write at already-applied minimum needs only a hold")
            } else {
                let reset = try XCTUnwrap(retry)
                XCTAssertEqual(reset.kind, .reset, "A revoked upward write may have changed hardware")
                try p.acknowledge(reset, applied: minimum, at: 7)
            }
            _ = try healthy(&p, from: 7, seconds: 10)
        }
    }
    func testExpiredUpwardApplicationIsRetiredByHealthLoopAndOldCompletionCannotCommit() throws {
        var p = try controller(high: false)
        let advice = try XCTUnwrap(healthy(&p, from: 0, seconds: 4))
        let a = try p.beginApplication(advice, at: 4)
        XCTAssertNil(try p.checkTrialDeadline(at: 6))
        let reset = try XCTUnwrap(p.checkTrialDeadline(at: 6.001))
        XCTAssertEqual(reset.kind, .reset)
        XCTAssertThrowsError(try p.acknowledge(a, applied: advice.settings, at: 6.001))
        try p.acknowledge(reset, applied: minimum, at: 6.001)
    }
    func testRepeatedFailedTrialsBackOffTenTwentyFortySixtyThenConfirmedTrialClearsHistory() throws {
        var p = try controller(high: false)
        var now = try beginTrial(&p)
        for hold in [10, 20, 40, 60, 60] {
            let d = try p.evaluate(window(now, revision: p.appliedRevision, received: 23), at: now + 1)
            now += 1
            let reset = try XCTUnwrap(d.recommendation)
            try p.acknowledge(reset, applied: minimum, at: now)
            now = try beginTrial(&p, from: now, hold: hold)
        }
        _ = try healthy(&p, from: now, seconds: 10, adviceAtEnd: false)
        now += 10
        now = try beginTrial(&p, from: now)
        let failure = try XCTUnwrap(p.evaluate(window(now, revision: p.appliedRevision, received: 0), at: now + 1).recommendation)
        now += 1
        try p.acknowledge(failure, applied: minimum, at: now)
        _ = try healthy(&p, from: now, seconds: 10)
    }
    func testUnknownGapAndExplicitInvalidationClearHealthyCoverageWithoutClearingBackoff() throws {
        for mode in 0..<3 {
            var p = try controller(high: false)
            _ = try p.evaluate(window(0, received: 23), at: 1)
            _ = try healthy(&p, from: 1, seconds: 9, adviceAtEnd: false)
            if mode == 0 { _ = try p.evaluate(window(10, received: nil), at: 11) }
            if mode == 1 { p.invalidateTelemetry() }
            _ = try healthy(&p, from: 11, seconds: 10)
        }
    }
    func testLocalPressureStillReducesPromptlyWithoutClaimingDeliveryFailure() throws {
        var p = try controller()
        let local = QualityController.Window(attemptID: attempt, sequence: 1, appliedRevision: 0,
            start: 0, end: 0.25, capturedFreshFrames: nil, encodedFreshFrames: nil, receiver: nil,
            sourceLoss: nil, meanQueueOccupancy: 0.75, usableVideoCapacity: nil, connectivity: .unknown,
            thermalPressure: .nominal, workerPressure: .unknown, transportPressure: .unknown)
        let d = try p.evaluateLocalPressure(local, at: 0.25)
        XCTAssertEqual(d.recommendation?.kind, .decrease)
        XCTAssertEqual(d.recommendation?.settings.profileID, "middle")
        XCTAssertFalse(d.reasons.contains(.freshFrameFloor))
        XCTAssertFalse(d.reasons.contains(.sourceLoss))
    }

    func testRepeatedNativeIncreaseFailuresEscalateBackoffWithEitherAcknowledgmentAPI() throws {
        for admitted in [false, true] {
            var p = try controller(high: false)
            _ = try p.evaluate(window(0, received: 23), at: 1)
            var t = 1.0
            for hold in [10, 20, 40, 60, 60] {
                let advice = try XCTUnwrap(healthy(&p, from: t, seconds: hold))
                t += Double(hold)
                if admitted {
                    let a = try p.beginApplication(advice, at: t)
                    try p.acknowledge(a, applied: nil, at: t)
                } else { try p.acknowledge(advice, applied: nil, at: t) }
                XCTAssertNil(try p.checkTrialDeadline(at: t))
                XCTAssertEqual(p.appliedRevision, 0)
            }
        }
    }
    func testCapacityQualifiedProgressiveIncreaseHasProbationAndResetsOnUnknownTransport() throws {
        var p = try QualityController(profiles: profiles, attemptID: attempt, applied: minimum,
                                      at: 0, behavior: .progressive)
        let advice = try XCTUnwrap(healthy(&p, from: 0, seconds: 4))
        XCTAssertEqual(advice.kind, .trial)
        try p.acknowledge(advice, applied: advice.settings, at: 4)
        let bad = try p.evaluate(window(4, revision: 1, transport: .unknown), at: 5)
        XCTAssertEqual(bad.recommendation?.kind, .reset)
        XCTAssertEqual(bad.recommendation?.settings, minimum)
    }
    func testCapacityStrategyNeverRoundsAProgressiveRateStepAboveTenPercent() throws {
        for rate in [9, 19, 101] {
            let profiles: [QualityController.Profile] = [.init(id: "low", width: 426, height: 240,
                minimumBitrate: rate, maximumBitrate: 1000)]
            var p = try QualityController(profiles: profiles, attemptID: attempt,
                applied: .init(profileID: "low", videoBitrate: rate), at: 0, behavior: .progressive)
            let advice = try healthy(&p, from: 0, seconds: 4, adviceAtEnd: rate >= 10)
            if rate >= 10 {
                XCTAssertEqual(advice?.settings.videoBitrate, rate + rate / 10)
            }
        }
    }
    func testShortLossCannotResetButCannotContributeToHealthyRecoveryEither() throws {
        var p = try controller(high: false)
        for i in 0..<20 {
            // Separate stage counts do not prove this missing source was on time.
            let d = try p.evaluate(window(Double(i), lost: 2), at: Double(i + 1))
            XCTAssertNil(d.recommendation)
        }
    }
    func testProgressiveResetKeepsAttemptRevisionSequenceAndFreshnessAdmission() throws {
        var p = try controller()
        let reset = try XCTUnwrap(p.evaluate(window(0, received: 23), at: 1).recommendation)
        for sample in [window(0, received: 0), window(1, revision: 1, received: 0),
                       window(1, received: 0)] {
            XCTAssertThrowsError(try p.evaluate(sample, at: 5))
            XCTAssertEqual(p.applied, high)
        }
        XCTAssertThrowsError(try p.acknowledge(reset, applied: minimum, at: 5))
        let current = try XCTUnwrap(p.checkTrialDeadline(at: 5))
        XCTAssertEqual(current.settings, minimum)
        try p.acknowledge(current, applied: minimum, at: 5)
        XCTAssertThrowsError(try p.evaluate(window(5, revision: 0), at: 6))
        _ = try healthy(&p, from: 6, seconds: 10)
    }

}

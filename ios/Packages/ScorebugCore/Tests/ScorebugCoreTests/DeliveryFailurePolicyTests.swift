import Foundation
import XCTest
@testable import ScorebugCore

final class DeliveryFailurePolicyTests: XCTestCase {
    private let attempt = UUID()
    private let minimum = QualityController.Settings(profileID: "low", videoBitrate: 350_000)
    private let high = QualityController.Settings(profileID: "high", videoBitrate: 6_000_000)

    private func controller(low: Bool = false, progressive: Bool = true) throws -> QualityController {
        try .init(profiles: [
            .init(id: "low", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "high", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, applied: low ? minimum : high, at: 100,
           recoveryStrategy: .receiverValidatedProfileTrials, behavior: progressive ? .progressive : .legacy)
    }

    private func failure(start: Double = 100, end: Double = 101, expected: Int = 30,
                         onTime: Int = 23, late: Int = 0, missing: Int = 7,
                         observed: Double? = nil, sequence: UInt64 = 1, revision: UInt64 = 0,
                         attemptID: UUID? = nil) -> QualityController.DeliveryFailure {
        .init(attemptID: attemptID ?? attempt, appliedRevision: revision, sequence: sequence,
              start: start, end: end, expectedFrames: expected, onTimeFrames: onTime,
              lateFrames: late, missingFrames: missing, observedAtLowerBound: observed ?? end)
    }

    private func healthy(_ start: Double, duration: Double = 1, sequence: UInt64? = nil,
                         revision: UInt64 = 0) -> QualityController.Window {
        let frames = Int(duration * 30)
        return .init(attemptID: attempt, sequence: sequence ?? UInt64(start), appliedRevision: revision,
            start: start, end: start + duration, capturedFreshFrames: frames, encodedFreshFrames: frames,
            receiver: .init(freshFrames: frames, observedAt: start + duration),
            sourceLoss: .init(expectedFrames: frames, lostFrames: 0), meanQueueOccupancy: 0,
            usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
            workerPressure: .nominal, transportPressure: .nominal)
    }

    func testOneSecondFloorIsStrictAndResetDoesNotChangeAppliedTruth() throws {
        var p = try controller()
        XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(onTime: 24, missing: 6), at: 101)) {
            XCTAssertEqual($0 as? QualityController.ValidationError, .invalidWindow)
        }
        let d = try p.evaluateDeliveryFailure(failure(), at: 101.25)
        XCTAssertEqual(d.state, .degraded)
        XCTAssertEqual(d.reasons, [.freshFrameFloor])
        let reset = try XCTUnwrap(d.recommendation)
        XCTAssertEqual(reset.kind, .reset)
        XCTAssertEqual(reset.settings, minimum)
        XCTAssertEqual(reset.validUntil, 101.25)
        XCTAssertEqual(reset.windowSequence, 1)
        XCTAssertEqual(p.applied, high)
        XCTAssertEqual(p.appliedRevision, 0)
        let application = try p.beginApplication(reset, at: 101.25)
        try p.acknowledge(application, applied: minimum, at: 102)
        XCTAssertEqual(p.applied, minimum)
        XCTAssertEqual(p.appliedRevision, 1)
    }

    func testTwoSecondLossIsStrictAndCountsBothLateAndMissing() throws {
        for late in 0...4 {
            var p = try controller()
            XCTAssertThrowsError(try p.evaluateDeliveryFailure(
                failure(end: 102, expected: 60, onTime: 57, missing: 3), at: 102))
            let d = try p.evaluateDeliveryFailure(
                failure(end: 102, expected: 60, onTime: 56, late: late, missing: 4 - late), at: 102)
            XCTAssertEqual(d.state, .degraded)
            XCTAssertEqual(d.reasons, [.sourceLoss])
            XCTAssertEqual(d.recommendation?.kind, .reset)
        }
    }

    func testZeroOnTimeFramesAddsStalledReasonForEitherLane() throws {
        for duration in [1.0, 2.0] {
            var p = try controller(low: true)
            let d = try p.evaluateDeliveryFailure(failure(end: 100 + duration, onTime: 0, missing: 30), at: 100 + duration)
            XCTAssertEqual(d.state, .stalled)
            XCTAssertEqual(d.reasons, [duration == 1 ? .freshFrameFloor : .sourceLoss, .stalled, .minimumProfileInsufficient])
            XCTAssertNil(d.recommendation)
        }
    }

    func testMinimumFailureDoesNotRecreateEncoderAndRequiresTenNewHealthySeconds() throws {
        var p = try controller(low: true)
        for i in 100..<103 { _ = try p.evaluate(healthy(Double(i)), at: Double(i + 1)) }
        let d = try p.evaluateDeliveryFailure(failure(start: 102, end: 103, sequence: 103), at: 103.25)
        XCTAssertEqual(d.state, .degraded)
        XCTAssertEqual(d.reasons, [.freshFrameFloor, .minimumProfileInsufficient])
        XCTAssertNil(d.recommendation)
        XCTAssertNil(try p.checkTrialDeadline(at: 103.25))
        XCTAssertEqual(p.appliedRevision, 0)
        for i in 103..<114 {
            let d = try p.evaluate(healthy(Double(i), sequence: UInt64(i + 1)), at: Double(i + 1))
            // 103...104 straddles receipt and cannot earn recovery credit.
            XCTAssertEqual(d.recommendation != nil, i == 113)
        }
    }

    func testFailureDoesNotOverwriteRegularWindowEndOrGrantHealthyCoverage() throws {
        var p = try controller(low: true)
        _ = try p.evaluate(healthy(100, duration: 2, sequence: 1), at: 102)
        _ = try p.evaluateDeliveryFailure(failure(observed: 102, sequence: 2), at: 102)
        let next = try p.evaluate(healthy(102, sequence: 3), at: 103)
        XCTAssertFalse(next.reasons.contains(.telemetryGap))
        XCTAssertNil(next.recommendation)
    }

    func testSameLaneRejectsReplayAndOverlapWithNewSequenceButAllowsAdjacentWindows() throws {
        for duration in [1.0, 2.0] {
            var p = try controller(low: true)
            let first = failure(end: 100 + duration, sequence: 1)
            _ = try p.evaluateDeliveryFailure(first, at: 100 + duration)
            XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(end: 100 + duration, sequence: 2), at: 100 + duration)) {
                XCTAssertEqual($0 as? QualityController.ValidationError, .outOfOrder)
            }
            XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(start: 100.5, end: 100.5 + duration, sequence: 3), at: 100.5 + duration))
            XCTAssertNoThrow(try p.evaluateDeliveryFailure(failure(start: 100 + duration, end: 100 + 2 * duration, sequence: 4), at: 100 + 2 * duration))
        }
    }

    func testDifferentLanesMayOverlapInEitherOrder() throws {
        for shortFirst in [true, false] {
            var p = try controller(low: true)
            let first = failure(start: shortFirst ? 101 : 100, end: 102, sequence: 1)
            let second = failure(start: shortFirst ? 100 : 101, end: 102, sequence: 2)
            XCTAssertNoThrow(try p.evaluateDeliveryFailure(first, at: 102))
            XCTAssertNoThrow(try p.evaluateDeliveryFailure(second, at: 102))
        }
    }

    func testRevisionScopeAndGlobalSequenceAdmission() throws {
        var p = try controller()
        _ = try p.evaluate(healthy(100, sequence: 7), at: 101)
        XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(sequence: 7), at: 101))
        let reset = try XCTUnwrap(try p.evaluateDeliveryFailure(failure(sequence: 8), at: 101).recommendation)
        try p.acknowledge(reset, applied: minimum, at: 101)
        XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(start: 101, end: 102, sequence: 9), at: 102))
        XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(sequence: 9, revision: 1), at: 102))
        XCTAssertNoThrow(try p.evaluateDeliveryFailure(failure(start: 101, end: 102, sequence: 9, revision: 1), at: 102))
        XCTAssertThrowsError(try p.evaluate(healthy(102, sequence: 9, revision: 1), at: 103))
    }

    func testScopeAndFreshnessRejectionsCannotCauseReset() throws {
        let cases: [(QualityController.DeliveryFailure, Double, QualityController.ValidationError)] = [
            (failure(attemptID: UUID()), 101, .wrongAttempt),
            (failure(revision: 1), 101, .wrongAppliedRevision),
            (failure(sequence: 0), 101, .outOfOrder),
            (failure(), 101.250001, .staleWindow),
            (failure(observed: 103.000001), 103.000001, .staleWindow),
            (failure(observed: 101.1), 101, .invalidWindow),
            (failure(observed: 100.99), 101, .invalidWindow),
            (failure(start: 99), 101, .invalidWindow)
        ]
        for (signal, now, error) in cases {
            var p = try controller()
            XCTAssertThrowsError(try p.evaluateDeliveryFailure(signal, at: now)) { XCTAssertEqual($0 as? QualityController.ValidationError, error) }
            XCTAssertNil(try p.checkTrialDeadline(at: now))
            XCTAssertEqual(p.applied, high)
        }
        var legacy = try controller(progressive: false)
        XCTAssertThrowsError(try legacy.evaluateDeliveryFailure(failure(), at: 101))
    }

    func testAllMalformedCountsAndTimesReject() throws {
        let malformed = [
            failure(expected: 0, onTime: 0, missing: 0),
            failure(expected: 241, onTime: 0, missing: 241),
            failure(onTime: -1, missing: 31), failure(late: -1, missing: 8), failure(onTime: 31, missing: -1),
            failure(onTime: 241), failure(late: 241), failure(missing: 241),
            failure(onTime: 22), failure(expected: Int.max, onTime: Int.max, late: Int.max, missing: Int.max),
            failure(start: .nan), failure(start: -.infinity), failure(end: .infinity),
            failure(end: 101.000001), failure(end: 101.5), failure(end: 103),
            failure(observed: .nan), failure(observed: 1e12 + 1)
        ]
        for signal in malformed {
            var p = try controller()
            XCTAssertThrowsError(try p.evaluateDeliveryFailure(signal, at: 101)) {
                XCTAssertEqual($0 as? QualityController.ValidationError, .invalidWindow)
            }
            XCTAssertNil(try p.checkTrialDeadline(at: 101))
        }
        for now in [Double.nan, .infinity, -1, 1e12 + 1] {
            var p = try controller()
            XCTAssertThrowsError(try p.evaluateDeliveryFailure(failure(), at: now))
        }
    }

    func testFreshnessBoundaryAndRecommendationUseEarlierExpiry() throws {
        var p = try controller()
        let d = try p.evaluateDeliveryFailure(failure(observed: 102.9), at: 103)
        XCTAssertEqual(d.recommendation?.validUntil, 103)
        XCTAssertThrowsError(try p.beginApplication(try XCTUnwrap(d.recommendation), at: 103.000001))
    }

    func testFailureRevokesUpwardApplicationEvenAtHistoricalMinimum() throws {
        var p = try controller(low: true), advice: QualityController.Recommendation?
        for i in 100..<104 { advice = try p.evaluate(healthy(Double(i)), at: Double(i + 1)).recommendation }
        let up = try XCTUnwrap(advice), application = try p.beginApplication(up, at: 104)
        let d = try p.evaluateDeliveryFailure(failure(start: 103, end: 104, sequence: 104), at: 104)
        XCTAssertEqual(d.recommendation?.kind, .reset)
        XCTAssertEqual(d.recommendation?.settings, minimum)
        XCTAssertThrowsError(try p.acknowledge(application, applied: up.settings, at: 104.1))
        p.invalidateTelemetry()
        XCTAssertEqual(try p.checkTrialDeadline(at: 110)?.settings, minimum)
    }

    func testFailureDuringTrialChoosesMinimumResetAndRevokesExpiredTrial() throws {
        var p = try controller(low: true), advice: QualityController.Recommendation?
        for i in 100..<104 { advice = try p.evaluate(healthy(Double(i)), at: Double(i + 1)).recommendation }
        let up = try XCTUnwrap(advice)
        try p.acknowledge(up, applied: up.settings, at: 104)
        let d = try p.evaluateDeliveryFailure(failure(start: 104, end: 105, sequence: 104, revision: 1), at: 105)
        XCTAssertEqual(d.recommendation?.kind, .reset)
        XCTAssertEqual(d.recommendation?.settings, minimum)
        XCTAssertFalse(d.reasons.contains(.trialRollback))
        let reset = try XCTUnwrap(d.recommendation)
        try p.acknowledge(reset, applied: minimum, at: 105)
        XCTAssertNil(try p.checkTrialDeadline(at: 130))
    }
}

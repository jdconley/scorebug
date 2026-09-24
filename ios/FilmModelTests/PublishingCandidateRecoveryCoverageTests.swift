import Foundation
@testable import ScorebugCore
import XCTest

final class PublishingCandidateRecoveryCoverageTests: XCTestCase {
    func testCompletedPrefixDoesNotChaseNewerSourceTail() {
        let coverage = PublishingCandidateRecoveryCoverage()
        coverage.resume(at: 18.5)
        coverage.recordSource(start: 19.5, end: 24.5, sequence: 1)
        coverage.recordSource(start: 24.5, end: 29.5, sequence: 2)
        deliver(coverage, from: 19, through: 29)
        XCTAssertFalse(coverage.permits(healthySince: 19.5, healthyThrough: 29.5, healthSequence: 2))
        deliver(coverage, from: 29, through: 31)
        XCTAssertTrue(coverage.permits(healthySince: 19.5, healthyThrough: 29.5, healthSequence: 2))
        coverage.recordSource(start: 29.5, end: 34.5, sequence: 3)
        XCTAssertTrue(coverage.permits(healthySince: 19.5, healthyThrough: 34.5, healthSequence: 3),
            "A completed prefix must not require delivery through the latest source end")
        XCTAssertFalse(coverage.permits(healthySince: 24.5, healthyThrough: 34.5, healthSequence: 3),
            "The old prefix cannot survive a newer Core healthy segment")
    }
    func testLaterLaneStartAndResumptionRequireWholeSourceWindows() {
        for resumed in [18.5, 21.0] {
            let coverage = PublishingCandidateRecoveryCoverage()
            coverage.resume(at: resumed)
            for index in 0..<4 {
                coverage.recordSource(start: 19.5 + Double(index) * 5,
                    end: 24.5 + Double(index) * 5, sequence: UInt64(index + 1))
            }
            deliver(coverage, from: 21, through: 33)
            XCTAssertFalse(coverage.permits(healthySince: 19.5, healthyThrough: 39.5, healthSequence: 4),
                "Clipping 19.5...24.5 at lane start would invent a partial source window")
            deliver(coverage, from: 33, through: 35)
            XCTAssertTrue(coverage.permits(healthySince: 19.5, healthyThrough: 39.5, healthSequence: 4))
        }
    }
    func testUncertaintyLossWeakFloorAndGapsRevokePreviouslyCompletedPrefix() {
        for fault in 0..<6 {
            let coverage = ready()
            switch fault {
            case 0: coverage.recordDelivery(start: 11, end: 12, result: result(1, uncertain: 1))
            case 1: coverage.recordDelivery(start: 11, end: 12, result: result(1, missing: 1))
            case 2: coverage.recordDelivery(start: 11, end: 12, result: result(1, late: 1))
            case 3: coverage.recordDelivery(start: 11, end: 12, result: result(1, onTime: 28))
            case 4: coverage.recordDelivery(start: 12, end: 13, result: result(1))
            default: coverage.recordSource(start: 12, end: 17, sequence: 3)
            }
            XCTAssertFalse(coverage.permits(healthySince: 1, healthyThrough: 17, healthSequence: 3), "fault \(fault)")
        }
    }
    func testLosslessBoundaryCountsKeepBothLanesAndWholeSourcePrefix() {
        let coverage = PublishingCandidateRecoveryCoverage()
        coverage.resume(at: 0)
        coverage.recordSource(start: 1, end: 6, sequence: 1)
        coverage.recordSource(start: 6, end: 11, sequence: 2)
        for index in 0..<10 {
            coverage.recordDelivery(start: Double(index + 1), end: Double(index + 2),
                result: result(1, onTime: index.isMultiple(of: 2) ? 31 : 29))
        }
        for index in 0..<5 {
            coverage.recordDelivery(start: Double(index * 2 + 1), end: Double(index * 2 + 3),
                result: result(2, onTime: index.isMultiple(of: 2) ? 61 : 59))
        }
        XCTAssertTrue(coverage.permits(healthySince: 1, healthyThrough: 11, healthSequence: 2))
        XCTAssertFalse(coverage.permits(healthySince: 6, healthyThrough: 11, healthSequence: 2),
            "Lossless delivery does not invent sufficient Core source health")
    }
    func testMoreThanOneFrameBelowNominalCannotKeepRecovery() {
        for (duration, frames) in [(1.0, 28), (2.0, 58), (1.0, 24), (2.0, 48)] {
            let coverage = ready()
            coverage.recordDelivery(start: 11, end: 11 + duration, result: result(duration, onTime: frames))
            XCTAssertFalse(coverage.permits(healthySince: 1, healthyThrough: 11, healthSequence: 2))
        }
    }
    func testExplicitInvalidationNeedsFreshResumptionAndNewWholePrefix() {
        let coverage = ready()
        coverage.invalidate()
        deliver(coverage, from: 11, through: 23)
        coverage.recordSource(start: 11, end: 16, sequence: 3)
        coverage.recordSource(start: 16, end: 21, sequence: 4)
        XCTAssertFalse(coverage.permits(healthySince: 1, healthyThrough: 21, healthSequence: 4))
        coverage.resume(at: 16.1)
        XCTAssertFalse(coverage.permits(healthySince: 1, healthyThrough: 21, healthSequence: 4))
        coverage.recordSource(start: 21, end: 26, sequence: 5)
        coverage.recordSource(start: 26, end: 31, sequence: 6)
        deliver(coverage, from: 23, through: 31)
        XCTAssertTrue(coverage.permits(healthySince: 1, healthyThrough: 31, healthSequence: 6))
    }
    func testSourceBoundAndMalformedInputFailClosedUntilInvalidated() {
        for fault in 0..<3 {
            let coverage = PublishingCandidateRecoveryCoverage()
            coverage.resume(at: 0)
            if fault == 0 {
                for index in 0..<257 {
                    coverage.recordSource(start: Double(index), end: Double(index + 1), sequence: UInt64(index + 1))
                }
            } else if fault == 1 {
                coverage.recordSource(start: .nan, end: 10, sequence: 1)
            } else {
                coverage.recordSource(start: 1, end: 6, sequence: 1)
                coverage.recordSource(start: 6, end: 11, sequence: 1)
            }
            coverage.recordSource(start: 300, end: 305, sequence: 300)
            coverage.recordSource(start: 305, end: 310, sequence: 301)
            deliver(coverage, from: 300, through: 310)
            XCTAssertFalse(coverage.permits(healthySince: 300, healthyThrough: 310, healthSequence: 301))
            coverage.invalidate(); coverage.resume(at: 300)
            coverage.recordSource(start: 300, end: 305, sequence: 300)
            coverage.recordSource(start: 305, end: 310, sequence: 301)
            deliver(coverage, from: 300, through: 310)
            XCTAssertTrue(coverage.permits(healthySince: 300, healthyThrough: 310, healthSequence: 301))
        }
    }
    func testRepeatedResumptionDoesNotMoveFloorAndFutureSequenceCannotContribute() {
        let coverage = ready()
        coverage.resume(at: 20)
        XCTAssertTrue(coverage.permits(healthySince: 1, healthyThrough: 11, healthSequence: 2))
        XCTAssertFalse(coverage.permits(healthySince: 1, healthyThrough: 11, healthSequence: 1))
        XCTAssertFalse(coverage.permits(healthySince: 1, healthyThrough: 10, healthSequence: 2))
    }
    private func ready() -> PublishingCandidateRecoveryCoverage {
        let value = PublishingCandidateRecoveryCoverage()
        value.resume(at: 0)
        value.recordSource(start: 1, end: 6, sequence: 1)
        value.recordSource(start: 6, end: 11, sequence: 2)
        deliver(value, from: 1, through: 11)
        XCTAssertTrue(value.permits(healthySince: 1, healthyThrough: 11, healthSequence: 2))
        return value
    }
    private func deliver(_ coverage: PublishingCandidateRecoveryCoverage, from start: Int, through end: Int) {
        for at in start..<end { coverage.recordDelivery(start: Double(at), end: Double(at + 1), result: result(1)) }
        for at in stride(from: start, to: end, by: 2) { coverage.recordDelivery(start: Double(at), end: Double(at + 2), result: result(2)) }
    }
    private func result(_ duration: Double, onTime: Int? = nil, late: Int = 0, missing: Int = 0, uncertain: Int = 0) -> DeliveryDeadlineResult {
        .init(expectedFrames: onTime ?? Int(duration * 30), onTimeFrames: (onTime ?? Int(duration * 30)) - late - missing - uncertain,
            lateFrames: late, missingFrames: missing, uncertainFrames: uncertain, duration: duration)
    }
}

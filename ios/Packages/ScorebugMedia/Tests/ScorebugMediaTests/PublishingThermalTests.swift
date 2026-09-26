import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingThermalTests: XCTestCase {
    func testHundredMillisecondHistoryRetainsAgedSourceAndMeasurementPressure() throws {
        var tracker = PublishingThermalTracker()
        for i in 0...200 {
            tracker.observe(.init(state: i == 113 ? .serious : .nominal, sampledAt: Double(i) / 10))
        }
        let source = try XCTUnwrap(tracker.snapshot.interval(from: 11.25, to: 16.5))
        XCTAssertEqual(source.enclosingStart, 11.2)
        XCTAssertEqual(source.enclosingEnd, 16.5)
        XCTAssertEqual(source.enclosingMaximumState, .serious)
        XCTAssertNotNil(tracker.snapshot.interval(from: 13, to: 20))
        XCTAssertNil(tracker.snapshot.interval(from: 13, to: 20.001))
        XCTAssertEqual(tracker.snapshot.samples.count, 160)
        XCTAssertEqual(tracker.snapshot.samples.first?.sampledAt, 4.1)
    }
    func testNonuniformFractionalBoundsUseEnclosingReportedMaximum() throws {
        var tracker = PublishingThermalTracker()
        for (time, state) in [(0.0, PublishingThermalState.nominal), (0.4, .fair), (1.1, .nominal), (2, .serious)] {
            tracker.observe(.init(state: state, sampledAt: time))
        }
        let interval = try XCTUnwrap(tracker.snapshot.interval(from: 0.2, to: 1.5))
        XCTAssertEqual(interval.start, 0.2); XCTAssertEqual(interval.end, 1.5)
        XCTAssertEqual(interval.enclosingStart, 0); XCTAssertEqual(interval.enclosingEnd, 2)
        XCTAssertEqual(interval.sampleCount, 4)
        XCTAssertEqual(interval.enclosingMaximumState, .serious)
        XCTAssertEqual(tracker.snapshot.interval(from: 0.4, to: 1.1)?.enclosingMaximumState, .fair)
        XCTAssertNil(tracker.snapshot.interval(from: 0, to: 2.001))
        XCTAssertNil(tracker.snapshot.interval(from: -0.1, to: 1))
    }
    func testUnknownNeverBecomesNominalOrConcealsMissingReading() {
        var tracker = PublishingThermalTracker()
        for (time, state) in [(0.0, PublishingThermalState.nominal), (1, .unknown), (2, .critical), (3, .nominal)] {
            tracker.observe(.init(state: state, sampledAt: time))
        }
        XCTAssertEqual(tracker.snapshot.interval(from: 0, to: 2)?.enclosingMaximumState, .unknown)
        XCTAssertEqual(tracker.snapshot.interval(from: 2, to: 3)?.enclosingMaximumState, .critical)
    }
    func testGapResetsCoverageAndTwoSecondBoundaryIsAllowed() {
        var tracker = PublishingThermalTracker()
        tracker.observe(.init(state: .nominal, sampledAt: 0))
        tracker.observe(.init(state: .nominal, sampledAt: 2))
        XCTAssertNotNil(tracker.snapshot.interval(from: 0, to: 2))
        tracker.observe(.init(state: .nominal, sampledAt: 4.001))
        XCTAssertEqual(tracker.snapshot.samples.count, 1)
        XCTAssertNil(tracker.snapshot.interval(from: 2, to: 4.001))
        tracker.observe(.init(state: .fair, sampledAt: 5))
        XCTAssertEqual(tracker.snapshot.interval(from: 4.001, to: 5)?.enclosingMaximumState, .fair)
    }
    func testHistoryBoundEvictsCoverageAndSnapshotsRemainImmutable() throws {
        var tracker = PublishingThermalTracker()
        for time in 0..<160 { tracker.observe(.init(state: .nominal, sampledAt: Double(time))) }
        let saved = tracker.snapshot
        for time in 160..<20_000 { tracker.observe(.init(state: .nominal, sampledAt: Double(time))) }
        XCTAssertEqual(tracker.snapshot.samples.count, 160)
        XCTAssertEqual(tracker.snapshot.samples.first?.sampledAt, 19_840)
        XCTAssertNil(tracker.snapshot.interval(from: 19_839.9, to: 19_999))
        XCTAssertNotNil(tracker.snapshot.interval(from: 19_840, to: 19_999))
        XCTAssertEqual(saved.samples.first?.sampledAt, 0)
        XCTAssertEqual(try XCTUnwrap(saved.interval(from: 0, to: 159)).sampleCount, 160)
    }
    func testDuplicateDoesNotExtendCoverageAndConflictingDuplicateQuarantines() {
        var tracker = PublishingThermalTracker()
        let sample = PublishingThermalSample(state: .nominal, sampledAt: 1)
        tracker.observe(sample); tracker.observe(sample)
        XCTAssertEqual(tracker.snapshot.samples, [sample])
        XCTAssertNil(tracker.snapshot.interval(from: 1, to: 1.1))
        tracker.observe(.init(state: .fair, sampledAt: 1))
        XCTAssertTrue(tracker.snapshot.isQuarantined)
        tracker.observe(.init(state: .nominal, sampledAt: 2))
        XCTAssertNil(tracker.snapshot.freshSample(at: 2))
        XCTAssertNil(tracker.snapshot.interval(from: 1, to: 2))
    }
    func testInvalidAndRegressingTimestampsPermanentlyQuarantine() {
        for time in [Double.nan, .infinity, -1, 1e12 + 1, 0.5] {
            var tracker = PublishingThermalTracker()
            tracker.observe(.init(state: .nominal, sampledAt: 1))
            tracker.observe(.init(state: .nominal, sampledAt: time))
            XCTAssertTrue(tracker.snapshot.isQuarantined)
            tracker.observe(.init(state: .nominal, sampledAt: 2))
            XCTAssertNil(tracker.snapshot.freshSample(at: 2))
        }
    }
    func testClosedHistoryIsQueryableButNeverFreshOrMutable() {
        var tracker = PublishingThermalTracker()
        tracker.observe(.init(state: .nominal, sampledAt: 1))
        tracker.observe(.init(state: .fair, sampledAt: 2))
        XCTAssertEqual(tracker.snapshot.freshSample(at: 4)?.state, .fair)
        XCTAssertNil(tracker.snapshot.freshSample(at: 4.001))
        for time in [Double.nan, .infinity, -1, 1.9, 1e12 + 1] {
            XCTAssertNil(tracker.snapshot.freshSample(at: time))
        }
        for end in [Double.nan, .infinity, -1, 1, 1e12 + 1] {
            XCTAssertNil(tracker.snapshot.interval(from: 1, to: end))
        }
        XCTAssertNil(tracker.snapshot.interval(from: .nan, to: 2))
        XCTAssertNil(tracker.snapshot.freshSample(at: 2, maximumAge: -1))
        XCTAssertNil(tracker.snapshot.freshSample(at: 2, maximumAge: .infinity))
        tracker.close()
        let closed = tracker.snapshot
        XCTAssertTrue(closed.isClosed)
        tracker.observe(.init(state: .critical, sampledAt: 3)); tracker.close()
        XCTAssertEqual(tracker.snapshot, closed)
        XCTAssertNil(closed.freshSample(at: 2))
        XCTAssertEqual(closed.interval(from: 1, to: 2)?.enclosingMaximumState, .fair)
    }
    func testFoundationStatesArePreserved() {
        XCTAssertEqual(PublishingThermalState(.nominal), .nominal)
        XCTAssertEqual(PublishingThermalState(.fair), .fair)
        XCTAssertEqual(PublishingThermalState(.serious), .serious)
        XCTAssertEqual(PublishingThermalState(.critical), .critical)
    }
}

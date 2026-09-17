import Foundation
import XCTest

final class PublishingDeliveryMonitorTests: XCTestCase {
    func testSchedulesIndependentNonoverlappingWindowsAfterDeadline() throws {
        var schedule = try PublishingDeliveryMonitor.Schedule(latencyBudget: 1, maximumSampleAge: 0.25)
        XCTAssertEqual(schedule.poll(at: 10.1, identity: "a"), [])
        XCTAssertEqual(schedule.poll(at: 13.249, identity: "a"), [])
        XCTAssertEqual(schedule.poll(at: 13.25, identity: "a"), [.init(start: 11, end: 12)])
        XCTAssertEqual(schedule.poll(at: 13.25, identity: "a"), [])
        XCTAssertEqual(schedule.poll(at: 14.25, identity: "a"), [.init(start: 12, end: 13), .init(start: 11, end: 13)])
        XCTAssertEqual(schedule.poll(at: 15.25, identity: "a"), [.init(start: 13, end: 14)])
        XCTAssertEqual(schedule.poll(at: 16.25, identity: "a"), [.init(start: 14, end: 15), .init(start: 13, end: 15)])
    }
    func testMissingEvidenceAndScopeChangesCannotGiveOldWindowsAnotherTry() throws {
        var schedule = try PublishingDeliveryMonitor.Schedule(latencyBudget: 1, maximumSampleAge: 0.25)
        _ = schedule.poll(at: 10.1, identity: "a")
        XCTAssertEqual(schedule.poll(at: 13.3, identity: "a").count, 1)
        XCTAssertEqual(schedule.poll(at: 13.4, identity: nil), [])
        XCTAssertEqual(schedule.poll(at: 14.1, identity: "a"), [])
        XCTAssertEqual(schedule.poll(at: 17.3, identity: "a"), [.init(start: 15, end: 16)])
        XCTAssertEqual(schedule.poll(at: 17.4, identity: "b"), [])
        XCTAssertEqual(schedule.poll(at: 20.3, identity: "b"), [.init(start: 18, end: 19)])
    }
    func testClockReversalAndNonfiniteTimeQuarantineSchedule() throws {
        for invalid in [Double.nan, .infinity, -1, 9.99, 1e12 + 1] {
            var schedule = try PublishingDeliveryMonitor.Schedule(latencyBudget: 1, maximumSampleAge: 0.25)
            _ = schedule.poll(at: 10, identity: "a")
            XCTAssertEqual(schedule.poll(at: invalid, identity: "a"), [])
            XCTAssertTrue(schedule.invalid)
            XCTAssertEqual(schedule.poll(at: 20, identity: "b"), [])
        }
    }
    func testLongSuspensionSkipsUncoveredBacklogAndBoundsWork() throws {
        var schedule = try PublishingDeliveryMonitor.Schedule(latencyBudget: 1, maximumSampleAge: 0.25)
        _ = schedule.poll(at: 10.1, identity: "a")
        XCTAssertEqual(schedule.poll(at: 100, identity: "a"), [], "A suspended consumer must reacquire a current window")
        XCTAssertEqual(schedule.poll(at: 102.25, identity: "a"), [.init(start: 100, end: 101)])
        XCTAssertLessThanOrEqual(schedule.poll(at: 110, identity: "a").count, 2)
    }
    func testInvalidBudgetCannotStartSchedule() throws {
        for budget in [0.0, -1, .nan, .infinity, 10.01] {
            XCTAssertThrowsError(try PublishingDeliveryMonitor.Schedule(latencyBudget: budget, maximumSampleAge: 0.25))
        }
        for age in [0.0, -1, .nan, .infinity, 5.01] {
            XCTAssertThrowsError(try PublishingDeliveryMonitor.Schedule(latencyBudget: 1, maximumSampleAge: age))
        }
    }
}

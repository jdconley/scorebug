import Foundation
import XCTest

final class PublishingDeliveryMonitorTests: XCTestCase {
    func testDeadlineBudgetOverrideRequiresExactControlledFixture() throws {
        XCTAssertEqual(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: [:]), 1)
        let base = ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_CADENCE_REPORTS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_DECODER_STALL": "1"]
        for raw in ["1000", "1500"] {
            var environment = base
            environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] = raw
            XCTAssertEqual(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: environment), Double(raw)! / 1000)
            for key in base.keys {
                var incomplete = environment; incomplete.removeValue(forKey: key)
                XCTAssertThrowsError(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: incomplete), key)
            }
        }
        for raw in ["", "1500.0", "01500", " 1500", "1500 ", "1.5", "1e3", "2000", "0", "NaN"] {
            var environment = base; environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] = raw
            XCTAssertThrowsError(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: environment), raw)
        }
    }
    func testDeadlineResetActivationRequiresExactIsolatedFixture() throws {
        XCTAssertFalse(try PublishingDeliveryMonitor.fixtureResetsRequested(environment: [:]))
        let base = ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_CADENCE_REPORTS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_DECODER_STALL": "1", "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": "1500",
            "SCOREBUG_TEST_DEADLINE_RESETS": "1"]
        XCTAssertTrue(try PublishingDeliveryMonitor.fixtureResetsRequested(environment: base))
        for key in base.keys where key != "SCOREBUG_TEST_DEADLINE_RESETS" {
            var incomplete = base; incomplete.removeValue(forKey: key)
            XCTAssertThrowsError(try PublishingDeliveryMonitor.fixtureResetsRequested(environment: incomplete), key)
        }
        for raw in ["", "0", "true", "01", " 1", "1 "] {
            var invalid = base; invalid["SCOREBUG_TEST_DEADLINE_RESETS"] = raw
            XCTAssertThrowsError(try PublishingDeliveryMonitor.fixtureResetsRequested(environment: invalid), raw)
        }
        var short = base; short["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] = "1000"
        XCTAssertThrowsError(try PublishingDeliveryMonitor.fixtureResetsRequested(environment: short))
        var reset = base; reset["SCOREBUG_TEST_DECODER_STALL"] = "reset540"
        XCTAssertTrue(try PublishingDeliveryMonitor.fixtureResetsRequested(environment: reset))
    }
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
    func testScheduleUnavailableSignalDistinguishesOrdinaryWaitFromDiscontinuity() throws {
        var schedule = try PublishingDeliveryMonitor.Schedule(latencyBudget: 1, maximumSampleAge: 0.25)
        var unavailable = 0
        _ = schedule.poll(at: 10, identity: "a", onUnavailable: { unavailable += 1 })
        unavailable = 0
        _ = schedule.poll(at: 10.5, identity: "a", onUnavailable: { unavailable += 1 })
        XCTAssertEqual(unavailable, 0)
        _ = schedule.poll(at: 16, identity: "a", onUnavailable: { unavailable += 1 })
        XCTAssertGreaterThan(unavailable, 0, "Suspension must invalidate before another source query")
        unavailable = 0
        _ = schedule.poll(at: 16.1, identity: nil, onUnavailable: { unavailable += 1 })
        XCTAssertGreaterThan(unavailable, 0)
        unavailable = 0
        _ = schedule.poll(at: 17, identity: "b", onUnavailable: { unavailable += 1 })
        _ = schedule.poll(at: 17.1, identity: "c", onUnavailable: { unavailable += 1 })
        XCTAssertGreaterThan(unavailable, 0)
        unavailable = 0
        _ = schedule.poll(at: .nan, identity: "c", onUnavailable: { unavailable += 1 })
        XCTAssertGreaterThan(unavailable, 0)
        unavailable = 0
        _ = schedule.poll(at: 18, identity: "c", onUnavailable: { unavailable += 1 })
        XCTAssertGreaterThan(unavailable, 0, "Terminal invalid schedule must not look like a normal empty poll")
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

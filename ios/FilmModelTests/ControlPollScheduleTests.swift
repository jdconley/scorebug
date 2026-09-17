import Foundation
import XCTest

@MainActor final class ControlPollScheduleTests: XCTestCase {
    func testWorkDurationDoesNotExtendStartToStartPeriod() {
        let start = ContinuousClock.now
        var schedule = ControlPollSchedule(start: start)
        XCTAssertEqual(schedule.nextDeadline(startedAt: start, completedAt: start + .milliseconds(70), interval: .milliseconds(100)), start + .milliseconds(100))
    }

    func testOverrunsAndExactBoundariesSkipMissedSlots() {
        let start = ContinuousClock.now
        for elapsed in [100, 350] {
            var schedule = ControlPollSchedule(start: start)
            XCTAssertEqual(schedule.nextDeadline(startedAt: start, completedAt: start + .milliseconds(elapsed), interval: .milliseconds(100)), start + .milliseconds(elapsed == 100 ? 200 : 400))
        }
    }

    func testLateWakePreservesScheduleAndIntervalChangesRebase() {
        let start = ContinuousClock.now
        var schedule = ControlPollSchedule(start: start)
        XCTAssertEqual(schedule.nextDeadline(startedAt: start, completedAt: start + .milliseconds(20), interval: .milliseconds(100)), start + .milliseconds(100))
        XCTAssertEqual(schedule.nextDeadline(startedAt: start + .milliseconds(130), completedAt: start + .milliseconds(150), interval: .milliseconds(100)), start + .milliseconds(200))
        XCTAssertEqual(schedule.nextDeadline(startedAt: start + .milliseconds(200), completedAt: start + .milliseconds(250), interval: .seconds(2)), start + .milliseconds(2200))
        XCTAssertEqual(schedule.nextDeadline(startedAt: start + .milliseconds(2200), completedAt: start + .milliseconds(2230), interval: .milliseconds(100)), start + .milliseconds(2300))
    }

    func testLoopUsesInjectedMonotonicClockAndStopsWhenSleepIsCancelled() async {
        let start = ContinuousClock.now
        var now = start, polls = 0, deadlines: [ContinuousClock.Instant] = []
        await ControlPollSchedule.run(now: { now }, sleepUntil: { deadline in
            deadlines.append(deadline)
            if deadlines.count == 3 { throw CancellationError() }
            now = deadline
        }, interval: { polls < 2 ? .milliseconds(100) : .seconds(2) }, poll: {
            polls += 1
            now += .milliseconds(70)
        })
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(deadlines, [start + .milliseconds(100), start + .milliseconds(2100), start + .milliseconds(4100)])
    }

    func testCancellationDuringPollDoesNotSleepOrPollAgain() async {
        var polls = 0, sleeps = 0
        let task = Task { @MainActor in
            await ControlPollSchedule.run(sleepUntil: { _ in sleeps += 1 }, interval: { .milliseconds(100) }, poll: {
                polls += 1
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await task.value
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(sleeps, 0)
    }
}

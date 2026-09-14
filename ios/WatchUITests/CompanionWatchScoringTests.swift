import XCTest

/// Requires the paired-phone test to send an offer through real WatchConnectivity.
/// This test never receives a fixture envelope, endpoint, device ID or credential.
final class CompanionWatchScoringTests: XCTestCase {
    @MainActor func testScoreUsingRealCompanionSetup() {
        continueAfterFailure = false
        executionTimeAllowance = 420
        let app = XCUIApplication()
        // Explicitly defeat any inherited debug fixture from another test lane.
        app.launchEnvironment["SCOREBUG_TEST_WATCH_SETUP"] = ""
        app.launch()
        tap(app, "watch.joinOffered", timeout: 180)
        value(app.staticTexts["watch.phase"], "paired")
        attach(app, "Watch accepted setup delivered by paired iPhone")
        tap(app, "watch.takeover")
        tap(app, "watch.homePoint")
        value(app.staticTexts["watch.score"], "1-0")
        tap(app, "watch.undo")
        value(app.staticTexts["watch.score"], "0-0")
        tap(app, "watch.awayPoint")
        value(app.staticTexts["watch.score"], "0-1")
        attach(app, "Watch scoring while companion records")
        tap(app, "watch.endMatch")
        // watchOS confirmation dialogs do not retain the SwiftUI identifiers.
        tap(app, "End match", confirmation: true)
        XCTAssertTrue(app.staticTexts["Match ended"].waitForExistence(timeout: 30), app.debugDescription)
        attach(app, "Watch ended companion match")
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String,
                                confirmation: Bool = false, timeout: Double = 30) {
        let button = confirmation ? app.tables.buttons[id] : app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), app.debugDescription)
        func fullyVisible() -> Bool {
            button.isHittable && button.frame.minY >= 40 && button.frame.maxY <= app.frame.maxY - 5
        }
        for _ in 0..<20 {
            if fullyVisible() { break }
            let below = button.frame.midY > app.frame.midY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.65 : 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.45 : 0.65))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        let ready = NSPredicate { _, _ in button.isEnabled && fullyVisible() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30), .completed, app.debugDescription)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func value(_ element: XCUIElement, _ expected: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: element)], timeout: 30), .completed)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

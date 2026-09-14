import XCTest

final class NativeWatchScoringTests: XCTestCase {
    @MainActor func testNativePairScoreAndRecoverAfterRelaunch() throws {
        continueAfterFailure = false
        let envelope = try XCTUnwrap(ProcessInfo.processInfo.environment["SCOREBUG_TEST_WATCH_SETUP"])
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_WATCH_SETUP"] = envelope
        app.launch()
        tap(app, "watch.joinOffered")
        value(app.staticTexts["watch.phase"], "paired")
        tap(app, "watch.takeover")
        tap(app, "watch.homePoint")
        value(app.staticTexts["watch.score"], "1-0")
        attach(app, "Watch point accepted")
        tap(app, "watch.undo")
        value(app.staticTexts["watch.score"], "0-0")
        tap(app, "watch.endSet")
        tap(app, "Confirm end set", confirmation: true)
        let rejected = NSPredicate(format: "label CONTAINS[c] %@", "tied")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rejected, object: app.staticTexts["watch.message"])], timeout: 20), .completed, app.debugDescription)
        top(app)
        tap(app, "watch.awayPoint")
        value(app.staticTexts["watch.score"], "0-1")
        app.terminate()
        app.launchEnvironment.removeAll()
        app.launch()
        value(app.staticTexts["watch.phase"], "paired")
        value(app.staticTexts["watch.score"], "0-1")
        attach(app, "Watch restored from Keychain without setup injection")
        tap(app, "watch.endMatch")
        tap(app, "End match", confirmation: true)
        XCTAssertTrue(app.staticTexts["Match ended"].waitForExistence(timeout: 20), app.debugDescription)
        attach(app, "Match ended from native Watch")
    }
    @MainActor private func top(_ app: XCUIApplication) { for _ in 0..<5 { app.swipeDown() } }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String, confirmation: Bool = false) {
        let button = confirmation ? app.tables.buttons[id] : app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 25), app.debugDescription)
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
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20), .completed, app.debugDescription)
        print("Tapping " + id + " at " + String(describing: button.frame))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func value(_ element: XCUIElement, _ expected: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 25))
        let predicate = NSPredicate(format: "value == %@", expected)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 25), .completed)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

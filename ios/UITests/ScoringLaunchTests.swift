import XCTest

final class ScoringLaunchTests: XCTestCase {
    @MainActor
    func testNativeScoringWorkflowWithoutCameraPermission() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(env["SCOREBUG_TEST_API_URL"])
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:"), "Use the owned API created by pnpm test:apple")
        let scenario = env["SCOREBUG_TEST_SCENARIO"] ?? "lifecycle"
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = url
        app.launchEnvironment["SCOREBUG_TEST_TOKEN"] = try XCTUnwrap(env["SCOREBUG_TEST_TOKEN"])
        app.resetAuthorizationStatus(for: .camera)
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        let home = app.buttons["scoring.homePoint"]
        let away = app.buttons["scoring.awayPoint"]
        if scenario == "observe" {
            XCTAssertTrue(app.staticTexts["scoring.ended"].waitForExistence(timeout: 10))
            XCTAssertTrue(waitForValue("1", element: home))
            XCTAssertTrue(waitForValue("0", element: away))
            XCTAssertFalse(home.isEnabled)
        } else {
            XCTAssertTrue(app.buttons["scoring.connect"].waitForExistence(timeout: 10))
            XCTAssertTrue(waitForValue(url, element: app.textFields["scoring.endpoint"]), app.debugDescription)
            tapWhenEnabled(app.buttons["scoring.connect"])
            if scenario == "join" {
                XCTAssertTrue(home.waitForExistence(timeout: 10))
                XCTAssertTrue(waitForValue("1", element: home))
                XCTAssertFalse(home.isEnabled)
                tapWhenEnabled(app.buttons["scoring.takeover"])
                tapWhenEnabled(away)
                XCTAssertTrue(waitForValue("1", element: away))
                tapWhenEnabled(app.buttons["scoring.undo"])
                XCTAssertTrue(waitForValue("0", element: away))
                app.terminate(); app.launch()
                XCTAssertTrue(home.waitForExistence(timeout: 10))
                XCTAssertTrue(waitForValue("1", element: home))
                XCTAssertTrue(waitForValue("0", element: away))
                endMatch(app)
            } else {
                let create = app.buttons["scoring.create"]
                XCTAssertTrue(create.waitForExistence(timeout: 10))
                app.swipeUp()
                tapWhenEnabled(create)
                XCTAssertTrue(home.waitForExistence(timeout: 10))
                XCTAssertEqual(home.value as? String, "0")
                tapWhenEnabled(home)
                XCTAssertTrue(waitForValue("1", element: home))
                app.terminate(); app.launch()
                XCTAssertTrue(home.waitForExistence(timeout: 10))
                XCTAssertTrue(waitForValue("1", element: home))
                tapWhenEnabled(app.buttons["scoring.undo"])
                XCTAssertTrue(waitForValue("0", element: home))
                tapWhenEnabled(app.buttons["scoring.endSet"])
                // SwiftUI exposes a nested button for the same confirmation action.
                tapWhenEnabled(app.buttons["scoring.confirmSet"].firstMatch)
                XCTAssertTrue(app.staticTexts["A tied set cannot end. Correct the score first."].waitForExistence(timeout: 10))
                if scenario == "create" {
                    tapWhenEnabled(home)
                    XCTAssertTrue(waitForValue("1", element: home))
                } else { endMatch(app) }
            }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native scoring \(scenario)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    @MainActor
    private func endMatch(_ app: XCUIApplication) {
        tapWhenEnabled(app.buttons["scoring.endMatch"])
        tapWhenEnabled(app.buttons["scoring.confirmEnd"].firstMatch)
        XCTAssertTrue(app.staticTexts["scoring.ended"].waitForExistence(timeout: 10))
    }
    @MainActor
    private func tapWhenEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        element.tap()
    }
    @MainActor
    private func waitForValue(_ value: String, element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}

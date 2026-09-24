import XCTest

final class PhoneWatchIntegrationTests: XCTestCase {
    @MainActor func testLocalRecordingWhilePairedWatchScores() throws {
        continueAfterFailure = false
        executionTimeAllowance = 480
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try XCTUnwrap(environment["SCOREBUG_TEST_API_URL"])
        XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = endpoint
        app.launchEnvironment["SCOREBUG_TEST_TOKEN"] = try XCTUnwrap(environment["SCOREBUG_TEST_TOKEN"])
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_DIAGNOSTICS"] = "1"
        app.launch()
        app.tabBars.buttons["Score"].tap()
        tap(app, app.buttons["scoring.connect"])
        XCTAssertTrue(app.buttons["scoring.takeover"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["scoring.homePoint"].isEnabled, "Joining must not take scorer ownership")
        app.tabBars.buttons["Film"].tap()
        tap(app, app.buttons["film.start"])
        recording(app, atLeast: 2)
        attach(app, "Local archive started before any Watch scoring")
        app.tabBars.buttons["Watch"].tap()
        // The button stays disabled until the real paired Watch advertises identity.
        // No manual Watch ID or simulator setup fixture may bypass this handshake.
        tap(app, app.buttons["phoneWatch.connect.0"], timeout: 180)
        let connected = app.descendants(matching: .any).matching(identifier: "phoneWatch.status").firstMatch
        let confirmed = NSPredicate(format: "exists == true AND label CONTAINS %@", "Watch reports connected")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: confirmed, object: connected)], timeout: 180), .completed, app.debugDescription)
        attach(app, "Phone received real paired Watch confirmation")
        app.tabBars.buttons["Score"].tap()
        XCTAssertTrue(app.staticTexts["scoring.ended"].waitForExistence(timeout: 180), app.debugDescription)
        XCTAssertEqual(app.buttons["scoring.homePoint"].value as? String, "0")
        XCTAssertEqual(app.buttons["scoring.awayPoint"].value as? String, "1")
        attach(app, "Phone observed match ended by Watch")
        app.tabBars.buttons["Film"].tap()
        let elapsed = try XCTUnwrap(Double(app.staticTexts["film.duration"].value as? String ?? ""))
        recording(app, atLeast: elapsed + 3)
        attach(app, "Local archive continues after Watch ended match")
        tap(app, app.buttons["film.stop"])
        XCTAssertTrue(app.buttons["film.start"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Recordings"].tap()
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.export.")).firstMatch
        tap(app, export)
        XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 60), app.debugDescription)
        attach(app, "Paired Watch recording exported")
    }

    @MainActor private func tap(_ app: XCUIApplication, _ element: XCUIElement, timeout: Double = 30) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        for _ in 0..<12 {
            if element.isHittable && element.frame.minY >= 80 && element.frame.maxY < app.frame.maxY - 70 { break }
            let below = element.frame.midY > app.frame.midY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.7 : 0.35))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.35 : 0.7))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element)], timeout: timeout), .completed, app.debugDescription)
        element.tap()
    }
    @MainActor private func recording(_ app: XCUIApplication, atLeast seconds: Double) {
        let advances = NSPredicate { _, _ in
            (Double(app.staticTexts["film.duration"].value as? String ?? "") ?? 0) >= seconds
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advances, object: nil)], timeout: 30), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["film.stop"].isEnabled)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

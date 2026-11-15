import XCTest

final class NativeRecordingTests: XCTestCase {
    @MainActor func testOfflineRecordingExportAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .camera)
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()
        app.tabBars.buttons["Score"].tap()
        XCTAssertTrue(app.navigationBars["Scorebug"].waitForExistence(timeout: 10))
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.tabBars.buttons["Film"].tap()
        tap(app.buttons["film.start"])
        waitForRecording(app, seconds: 2)
        attach(app, name: "Film recording locally")
        app.tabBars.buttons["Score"].tap()
        XCTAssertTrue(app.navigationBars["Scorebug"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Film"].tap()
        waitForRecording(app, seconds: 4)
        tap(app.buttons["film.stop"])
        XCTAssertTrue(waitEnabled(app.buttons["film.start"]))
        app.tabBars.buttons["Recordings"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "Completed").firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        exportFirst(app)
        app.buttons["recordings.closePlayer"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Recordings"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "Completed").firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "Offline recording survived relaunch")
    }

    @MainActor func testForcedTerminationRecoveryAndExport() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        tap(app.buttons["film.start"])
        waitForRecording(app, seconds: 7)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Recordings"].tap()
        XCTAssertTrue(app.staticTexts["Recoverable"].waitForExistence(timeout: 10), app.debugDescription)
        // Select the recovered row even when the completed-case test ran first.
        let recovered = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.recover.")).firstMatch
        tap(recovered)
        XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 30), app.debugDescription)
        attach(app, name: "Recovered recording exported")
    }

    @MainActor func testNativeScoringWhileRecording() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let endpoint = try XCTUnwrap(env["SCOREBUG_TEST_API_URL"])
        XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = endpoint
        app.launchEnvironment["SCOREBUG_TEST_TOKEN"] = try XCTUnwrap(env["SCOREBUG_TEST_TOKEN"])
        app.launch()
        tap(app.buttons["film.start"])
        waitForRecording(app, seconds: 2)
        attach(app, name: "Film recording locally")
        app.tabBars.buttons["Score"].tap()
        tap(app.buttons["scoring.connect"])
        XCTAssertTrue(app.buttons["scoring.create"].waitForExistence(timeout: 10))
        app.swipeUp()
        tap(app.buttons["scoring.create"])
        let point = app.buttons["scoring.homePoint"]
        tap(point)
        let scored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: point)
        XCTAssertEqual(XCTWaiter.wait(for: [scored], timeout: 10), .completed)
        attach(app, name: "Native scoring while local recording continues")
        app.tabBars.buttons["Film"].tap()
        waitForRecording(app, seconds: 4)
        tap(app.buttons["film.stop"])
        XCTAssertTrue(waitEnabled(app.buttons["film.start"]))
        app.tabBars.buttons["Score"].tap()
        XCTAssertEqual(app.buttons["scoring.homePoint"].value as? String, "1")
    }

    @MainActor private func exportFirst(_ app: XCUIApplication) {
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.export.")).firstMatch
        tap(button)
        XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 30), app.debugDescription)
        tap(app.buttons["recordings.play"])
        let playback = app.staticTexts["recordings.playbackTime"]
        let advances = NSPredicate { _, _ in (Double(playback.value as? String ?? "") ?? 0) >= 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advances, object: nil)], timeout: 10), .completed)
        attach(app, name: "Validated MP4 playing")
    }
    @MainActor private func waitForRecording(_ app: XCUIApplication, seconds: Double) {
        let value = app.staticTexts["film.duration"]
        let predicate = NSPredicate { _, _ in
            (Double(value.value as? String ?? "") ?? 0) >= seconds
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: seconds + 20), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["film.stop"].isEnabled)
    }
    @MainActor private func waitEnabled(_ value: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: value)], timeout: 20) == .completed
    }
    @MainActor private func tap(_ value: XCUIElement) {
        XCTAssertTrue(waitEnabled(value))
        value.tap()
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

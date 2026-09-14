import XCTest

final class NativeStreamingTests: XCTestCase {
    @MainActor func testNativePublishScoreAndStopPreservesRecording() throws {
        continueAfterFailure = false
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["SCOREBUG_TEST_API_URL"])
        XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = endpoint
        app.launchEnvironment["SCOREBUG_TEST_TOKEN"] = "qa-phone-token-not-production"
        app.launch()
        app.swipeUp()
        tap(app.buttons["streaming.setup"])
        replace(app.textFields["streaming.endpoint"], endpoint)
        replace(app.secureTextFields["streaming.token"], "qa-phone-token-not-production")
        replace(app.textFields["streaming.worker"], "mac")
        replace(app.textFields["streaming.output"], "local-sink")
        app.swipeUp()
        tap(app.buttons["streaming.connect"])
        XCTAssertTrue(app.staticTexts["streaming.connected"].waitForExistence(timeout: 20), app.debugDescription)
        tap(app.buttons["streaming.closeSetup"])
        app.swipeDown()
        tap(app.buttons["film.start"])
        duration(app, atLeast: 2)
        app.swipeUp()
        tap(app.buttons["streaming.start"])
        value(app.staticTexts["streaming.localStatus"], equals: "publishing", timeout: 30)
        value(app.staticTexts["streaming.workerStatus"], equals: "producing_output", timeout: 45)
        attach(app, "Native camera sending and worker producing output")
        app.tabBars.buttons["Score"].tap()
        tap(app.buttons["scoring.connect"])
        tap(app.buttons["scoring.takeover"])
        tap(app.buttons["scoring.homePoint"])
        value(app.buttons["scoring.homePoint"], equals: "1")
        app.tabBars.buttons["Film"].tap()
        // At least twelve more seconds yields several complete identity markers.
        app.swipeDown()
        let elapsed = Double(app.staticTexts["film.duration"].value as? String ?? "") ?? 0
        duration(app, atLeast: elapsed + 12)
        app.swipeUp()
        tap(app.buttons["streaming.stop"])
        value(app.staticTexts["streaming.localStatus"], equals: "idle")
        app.swipeDown()
        let stoppedAt = Double(app.staticTexts["film.duration"].value as? String ?? "") ?? 0
        duration(app, atLeast: stoppedAt + 3)
        attach(app, "Local recording continues after streaming stops")
        tap(app.buttons["film.stop"])
        XCTAssertTrue(app.buttons["film.start"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Recordings"].tap()
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.export.")).firstMatch
        tap(export)
        XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 45), app.debugDescription)
        attach(app, "Recording exported after native streaming")
    }
    @MainActor private func tap(_ element: XCUIElement) {
        let ready = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 20), .completed)
        element.tap()
    }
    @MainActor private func replace(_ element: XCUIElement, _ text: String) {
        tap(element)
        let old = element.value as? String ?? ""
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }
    @MainActor private func value(_ element: XCUIElement, equals text: String, timeout: Double = 20) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: element)], timeout: timeout), .completed)
    }
    @MainActor private func duration(_ app: XCUIApplication, atLeast seconds: Double) {
        let predicate = NSPredicate { _, _ in (Double(app.staticTexts["film.duration"].value as? String ?? "") ?? 0) >= seconds }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 35), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["film.stop"].isEnabled)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

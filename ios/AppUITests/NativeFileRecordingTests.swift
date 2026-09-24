import XCTest

/// Opt-in case: the runner stages input.mov in this app's data container first.
final class NativeFileRecordingTests: XCTestCase {
    @MainActor func testStagedMatchRecordingExportPlaybackAndRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCOREBUG_TEST_FILE_CAPTURE"] == "1", "Requires a staged local match fixture")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_FILE_CAPTURE"] = "1"
        app.launch()
        app.tabBars.buttons["Recordings"].tap()
        XCTAssertTrue(app.staticTexts["No saved recordings"].waitForExistence(timeout: 10), "This test requires a fresh app container")
        app.tabBars.buttons["Film"].tap()
        tap(app.buttons["film.start"])
        let duration = app.staticTexts["film.duration"]
        let recorded = NSPredicate { _, _ in (Double(duration.value as? String ?? "") ?? 0) >= 6 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: recorded, object: nil)], timeout: 25), .completed, app.debugDescription)
        tap(app.buttons["film.stop"])
        XCTAssertTrue(waitEnabled(app.buttons["film.start"]))
        app.tabBars.buttons["Recordings"].tap()
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10), app.debugDescription)
        let exports = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.export."))
        XCTAssertEqual(exports.count, 1, "Exactly the newly completed recording must exist")
        XCTAssertFalse(app.staticTexts["Recoverable"].exists)
        XCTAssertFalse(app.staticTexts["Unavailable"].exists)
        let export = exports.firstMatch
        let exportID = export.identifier
        tap(export)
        XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 30), app.debugDescription)
        tap(app.buttons["recordings.play"])
        let playback = app.staticTexts["recordings.playbackTime"]
        let advances = NSPredicate { _, _ in (Double(playback.value as? String ?? "") ?? 0) >= 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advances, object: nil)], timeout: 10), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Local match export playing"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Recordings"].tap()
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[exportID].exists, "The same completed recording must survive relaunch")
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: element)], timeout: 20) == .completed
    }
    @MainActor private func tap(_ element: XCUIElement) {
        XCTAssertTrue(waitEnabled(element))
        element.tap()
    }
}

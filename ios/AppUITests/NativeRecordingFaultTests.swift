import XCTest

final class NativeRecordingFaultTests: XCTestCase {
    @MainActor func testRecordingFaultRecovery() throws {
        continueAfterFailure = false
        for fault in ["source", "storage", "queue"] {
            let app = XCUIApplication()
            app.launchEnvironment["SCOREBUG_TEST_RECORDING_FAULT"] = fault
            if fault == "source" { app.launchEnvironment["SCOREBUG_FIXTURE_FAIL_AFTER"] = "240" }
            app.launch()
            let start = app.buttons["film.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
            let duration = app.staticTexts["film.duration"]
            let started = NSPredicate { _, _ in (Double(duration.value as? String ?? "") ?? 0) >= 2 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: started, object: nil)], timeout: 10), .completed)
            let stopped = NSPredicate(format: "exists == true AND enabled == true")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: start)], timeout: 25), .completed)
            let message = app.staticTexts["film.message"]
            XCTAssertTrue(message.label.contains("Any video already saved was kept"), message.label)
            app.tabBars.buttons["Recordings"].tap()
            XCTAssertTrue(app.staticTexts.matching(identifier: "Recoverable").firstMatch.waitForExistence(timeout: 10))
            let recover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.recover.")).firstMatch
            XCTAssertTrue(recover.waitForExistence(timeout: 10)); recover.tap()
            XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 30))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Recovered \(fault) fault"; attachment.lifetime = .keepAlways; add(attachment)
            print("SCOREBUG_RECORDING_FAULT_RECOVERED \(fault)")
            app.terminate()
        }
    }
}

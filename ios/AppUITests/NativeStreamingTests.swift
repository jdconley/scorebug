import XCTest

final class NativeStreamingTests: XCTestCase {
    @MainActor func testNativePublishScoreAndStopPreservesRecording() throws {
        continueAfterFailure = false
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["SCOREBUG_TEST_API_URL"])
        XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = endpoint
        app.launchEnvironment["SCOREBUG_TEST_TOKEN"] = "qa-phone-token-not-production"
        let fileFlag = ProcessInfo.processInfo.environment["SCOREBUG_TEST_FILE_CAPTURE"] ?? ""
        if !fileFlag.isEmpty {
            XCTAssertEqual(fileFlag, "1")
            XCTAssertTrue((ProcessInfo.processInfo.environment["SCOREBUG_TEST_MOTION_FIXTURE"] ?? "").isEmpty)
            app.launchEnvironment["SCOREBUG_TEST_FILE_CAPTURE"] = fileFlag
        }
        let rawHold = ProcessInfo.processInfo.environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] ?? ""
        var holdSeconds = 12
        if !rawHold.isEmpty {
            let parsed = try XCTUnwrap(Int(rawHold))
            XCTAssertEqual(String(parsed), rawHold)
            XCTAssertTrue((12...600).contains(parsed))
            holdSeconds = parsed
            app.launchEnvironment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = rawHold
        }
        let motionFlag = ProcessInfo.processInfo.environment["SCOREBUG_TEST_MOTION_FIXTURE"] ?? ""
        if !motionFlag.isEmpty {
            XCTAssertTrue(["1", "blocks16"].contains(motionFlag), "Malformed native motion fixture flag")
            app.launchEnvironment["SCOREBUG_TEST_MOTION_FIXTURE"] = motionFlag
        }
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
        XCTAssertTrue(app.staticTexts["streaming.quality"].waitForExistence(timeout: 10))
        attach(app, "Native camera live")
        app.tabBars.buttons["Score"].tap()
        tap(app.buttons["scoring.connect"])
        tap(app.buttons["scoring.takeover"])
        tap(app.buttons["scoring.homePoint"])
        value(app.buttons["scoring.homePoint"], equals: "1")
        app.tabBars.buttons["Film"].tap()
        // The explicit longer hold exercises simultaneous recording and streaming.
        app.swipeDown()
        let elapsed = try XCTUnwrap(Double(try XCTUnwrap(app.staticTexts["film.duration"].value as? String)))
        XCTAssertTrue(elapsed.isFinite && elapsed >= 0)
        duration(app, atLeast: elapsed + Double(holdSeconds), timeout: Double(holdSeconds) + 23, minimumElapsed: Double(holdSeconds))
        app.swipeUp()
        // Preserve the original live checks, but finish the local recording
        // before reporting a live failure that would abort this UI test.
        let publishingAtEnd = matches(app.staticTexts["streaming.localStatus"], equals: "publishing")
        let localAtEnd = app.staticTexts["streaming.localStatus"].value as? String ?? "missing"
        // Preserve these checks even if a later archive stop/export fails.
        let liveChecks: [String: Any] = [
            "phase": "beforeFinalization", "publishingAtEnd": publishingAtEnd,
            "localAtEnd": String(localAtEnd.prefix(128))
        ]
        let liveEvidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: liveChecks, options: [.sortedKeys]),
                                         uniformTypeIdentifier: "public.json")
        liveEvidence.name = "NativeStreamingLiveChecks"; liveEvidence.lifetime = .keepAlways; add(liveEvidence)
        let stop = app.buttons["streaming.stop"]
        let stopAvailable = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: stop)], timeout: 20) == .completed
        var reachedIdle = false
        if stopAvailable {
            stop.tap()
            reachedIdle = matches(app.staticTexts["streaming.localStatus"], equals: "idle")
        }
        app.swipeDown()
        let stoppedAt = try XCTUnwrap(Double(try XCTUnwrap(app.staticTexts["film.duration"].value as? String)))
        XCTAssertTrue(stoppedAt.isFinite && stoppedAt >= 0)
        duration(app, atLeast: stoppedAt + 3)
        attach(app, "Local recording continues after streaming stops")
        tap(app.buttons["film.stop"])
        XCTAssertTrue(app.buttons["film.start"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Recordings"].tap()
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.export.")).firstMatch
        tap(export)
        XCTAssertTrue(app.staticTexts["recordings.exportReady"].waitForExistence(timeout: 45), app.debugDescription)
        attach(app, "Recording exported after native streaming")
        let finalization: [String: Any] = [
            "publishingAtEnd": publishingAtEnd,
            "localAtEnd": String(localAtEnd.prefix(128)),
            "stopAvailable": stopAvailable, "reachedIdle": reachedIdle,
            "recordingStopped": true, "exportReady": true
        ]
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: finalization, options: [.sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
        evidence.name = "NativeStreamingFinalization"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertTrue(publishingAtEnd && stopAvailable && reachedIdle,
                      "Live check failed; local recording was stopped and exported. Local: \(localAtEnd)")
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
        XCTAssertTrue(matches(element, equals: text, timeout: timeout))
    }
    @MainActor private func matches(_ element: XCUIElement, equals text: String, timeout: Double = 20) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: element)], timeout: timeout) == .completed
    }
    @MainActor private func duration(_ app: XCUIApplication, atLeast seconds: Double, timeout: Double = 35, minimumElapsed: Double = 0) {
        let started = ContinuousClock.now
        let predicate = NSPredicate { _, _ in
            (Double(app.staticTexts["film.duration"].value as? String ?? "") ?? 0) >= seconds &&
                started.duration(to: .now) >= .seconds(minimumElapsed)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["film.stop"].isEnabled)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

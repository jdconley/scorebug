import XCTest

final class NativeStreamingTests: XCTestCase {
    @MainActor func testNativePublishScoreAndStopPreservesRecording() throws {
        continueAfterFailure = false
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["SCOREBUG_TEST_API_URL"])
        XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = endpoint
        app.launchEnvironment["SCOREBUG_TEST_TOKEN"] = "qa-phone-token-not-production"
        app.launchEnvironment["SCOREBUG_TEST_VIDEO_OBSERVATIONS"] = "1"
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
        let qualityFlag = ProcessInfo.processInfo.environment["SCOREBUG_TEST_NATIVE_QUALITY"] ?? ""
        if !qualityFlag.isEmpty {
            XCTAssertEqual(qualityFlag, "1"); XCTAssertGreaterThanOrEqual(holdSeconds, 90)
            app.launchEnvironment["SCOREBUG_TEST_NATIVE_QUALITY"] = qualityFlag
        }
        let liveProfile = ProcessInfo.processInfo.environment["SCOREBUG_TEST_LIVE_PROFILE"] ?? ""
        if !liveProfile.isEmpty {
            XCTAssertTrue(["540p30", "360p30", "240p30"].contains(liveProfile)); XCTAssertTrue(qualityFlag.isEmpty)
            XCTAssertEqual(motionFlag, "blocks16"); XCTAssertGreaterThanOrEqual(holdSeconds, 90)
            app.launchEnvironment["SCOREBUG_TEST_LIVE_PROFILE"] = liveProfile
        }
        let transitions = ProcessInfo.processInfo.environment["SCOREBUG_TEST_PROFILE_TRANSITIONS"] ?? ""
        if !transitions.isEmpty {
            XCTAssertTrue(["1", "low240"].contains(transitions)); XCTAssertTrue(qualityFlag.isEmpty && liveProfile.isEmpty)
            XCTAssertEqual(motionFlag, "blocks16"); XCTAssertGreaterThanOrEqual(holdSeconds, 90)
            app.launchEnvironment["SCOREBUG_TEST_PROFILE_TRANSITIONS"] = transitions
        }
        let uplinkPort = ProcessInfo.processInfo.environment["SCOREBUG_TEST_UPLINK_PROXY_PORT"] ?? ""
        if !uplinkPort.isEmpty {
            XCTAssertTrue(transitions.isEmpty)
            let parsed = try XCTUnwrap(Int(uplinkPort))
            XCTAssertEqual(String(parsed), uplinkPort); XCTAssertTrue((1...65535).contains(parsed))
            XCTAssertTrue(qualityFlag == "1" || ["540p30", "360p30", "240p30"].contains(liveProfile)); XCTAssertEqual(motionFlag, "blocks16")
            app.launchEnvironment["SCOREBUG_TEST_UPLINK_PROXY_PORT"] = uplinkPort
        }
        let adaptive = ProcessInfo.processInfo.environment["SCOREBUG_TEST_ADAPTIVE_PROFILES"] ?? ""
        if !adaptive.isEmpty {
            XCTAssertEqual(adaptive, "1"); XCTAssertEqual(qualityFlag, "1")
            XCTAssertTrue(transitions.isEmpty && liveProfile.isEmpty && !uplinkPort.isEmpty)
            XCTAssertEqual(motionFlag, "blocks16"); XCTAssertGreaterThanOrEqual(holdSeconds, 240)
            app.launchEnvironment["SCOREBUG_TEST_ADAPTIVE_PROFILES"] = adaptive
        }
        let pacing = ProcessInfo.processInfo.environment["SCOREBUG_TEST_SOURCE_CADENCE_PACING"] ?? ""
        if !pacing.isEmpty {
            XCTAssertEqual(pacing, "1"); XCTAssertEqual(adaptive, "1")
            app.launchEnvironment["SCOREBUG_TEST_SOURCE_CADENCE_PACING"] = pacing
        }
        let probe = ProcessInfo.processInfo.environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] ?? ""
        if !probe.isEmpty {
            XCTAssertTrue(["renew", "expire", "staged"].contains(probe)); XCTAssertEqual(liveProfile, "540p30")
            XCTAssertTrue(qualityFlag.isEmpty && transitions.isEmpty && adaptive.isEmpty && pacing.isEmpty)
            app.launchEnvironment["SCOREBUG_TEST_BANDWIDTH_PROBE"] = probe
        }
        let cadenceReports = ProcessInfo.processInfo.environment["SCOREBUG_TEST_CADENCE_REPORTS"] ?? ""
        if !cadenceReports.isEmpty {
            XCTAssertEqual(cadenceReports, "1"); XCTAssertEqual(liveProfile, "240p30")
            XCTAssertTrue(qualityFlag.isEmpty && transitions.isEmpty && adaptive.isEmpty && probe.isEmpty && uplinkPort.isEmpty)
            XCTAssertTrue((90...120).contains(holdSeconds))
            app.launchEnvironment["SCOREBUG_TEST_CADENCE_REPORTS"] = cadenceReports
        }
        let decoderStall = ProcessInfo.processInfo.environment["SCOREBUG_TEST_DECODER_STALL"] ?? ""
        if !decoderStall.isEmpty {
            XCTAssertTrue(["1", "reset540"].contains(decoderStall)); XCTAssertEqual(cadenceReports, "1")
            app.launchEnvironment["SCOREBUG_TEST_DECODER_STALL"] = decoderStall
        }
        let deliveryDeadline = ProcessInfo.processInfo.environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] ?? ""
        if !deliveryDeadline.isEmpty {
            XCTAssertTrue(["1000", "1500"].contains(deliveryDeadline)); XCTAssertFalse(decoderStall.isEmpty)
            XCTAssertEqual(cadenceReports, "1")
            app.launchEnvironment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] = deliveryDeadline
        }
        let deadlineResets = ProcessInfo.processInfo.environment["SCOREBUG_TEST_DEADLINE_RESETS"] ?? ""
        if !deadlineResets.isEmpty {
            XCTAssertEqual(deadlineResets, "1"); XCTAssertTrue(["1", "reset540"].contains(decoderStall))
            XCTAssertEqual(deliveryDeadline, "1500"); XCTAssertEqual(cadenceReports, "1")
            app.launchEnvironment["SCOREBUG_TEST_DEADLINE_RESETS"] = deadlineResets
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
        value(app.staticTexts["streaming.workerStatus"], equals: "producing_output", timeout: 45)
        attach(app, "Native camera sending and worker producing output")
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
        let producingAtEnd = matches(app.staticTexts["streaming.workerStatus"], equals: "producing_output")
        let localAtEnd = app.staticTexts["streaming.localStatus"].value as? String ?? "missing"
        let workerAtEnd = app.staticTexts["streaming.workerStatus"].value as? String ?? "missing"
        // Preserve these checks even if a later archive stop/export fails.
        let liveChecks: [String: Any] = [
            "phase": "beforeFinalization", "publishingAtEnd": publishingAtEnd, "producingAtEnd": producingAtEnd,
            "localAtEnd": String(localAtEnd.prefix(128)), "workerAtEnd": String(workerAtEnd.prefix(128))
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
            "publishingAtEnd": publishingAtEnd, "producingAtEnd": producingAtEnd,
            "localAtEnd": String(localAtEnd.prefix(128)), "workerAtEnd": String(workerAtEnd.prefix(128)),
            "stopAvailable": stopAvailable, "reachedIdle": reachedIdle,
            "recordingStopped": true, "exportReady": true
        ]
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: finalization, options: [.sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
        evidence.name = "NativeStreamingFinalization"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertTrue(publishingAtEnd && producingAtEnd && stopAvailable && reachedIdle,
                      "Live qualification failed; local recording was stopped and exported. Local: \(localAtEnd), worker: \(workerAtEnd)")
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

import XCTest

/// Opt-in hardware smoke: the normal app launch selects IOSCameraCaptureSource.
/// Run only against a seeded, disposable HOME/AWAY match on a private LAN.
final class PhysicalStreamingTests: XCTestCase {
    private var deadline = Date.distantPast
    private enum SmokeFailure: Error { case failed(String) }

    @MainActor func testPhysicalIPhoneCameraPublishScoreStopAndExport() throws {
        try runVertical(watchScoring: false)
    }

    @MainActor func testPhysicalPairedWatchWhileCameraPublishes() throws {
        guard ProcessInfo.processInfo.environment["SCOREBUG_DEVICE_WATCH_SCORING"] == "1" else {
            throw XCTSkip("Set SCOREBUG_DEVICE_WATCH_SCORING=1 and concurrently run the paired Watch companion test.")
        }
        try runVertical(watchScoring: true)
    }

    @MainActor private func runVertical(watchScoring: Bool) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone camera smoke is not a simulator test.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = explicitValue(environment["SCOREBUG_DEVICE_API_URL"]),
              let token = explicitValue(environment["SCOREBUG_DEVICE_TOKEN"]) else {
            throw XCTSkip("Set both SCOREBUG_DEVICE_API_URL and SCOREBUG_DEVICE_TOKEN to opt into the physical device smoke.")
        }
        try require(isPrivateLANEndpoint(endpoint), "Device smoke requires an HTTP(S) URL with a numeric RFC1918 IPv4 host and no credentials, query, or fragment.")
        continueAfterFailure = true // Thrown failures still run the stop cleanup below.
        executionTimeAllowance = watchScoring ? 600 : 240
        // Reserve 35 seconds for independent stream and recording cleanup,
        // plus a little headroom for final evidence within the 240-second test.
        deadline = Date().addingTimeInterval(watchScoring ? 550 : 200)
        let app = XCUIApplication()
        // Never inject SCOREBUG_TEST_* environments or bypass the actual setup UI.
        // activate() preserves an existing process so the prior-capture guard
        // below can refuse the run without terminating someone's recording.
        app.activate()
        var recordingRequested = false
        var streamingRequested = false
        defer {
            cleanup(app, recordingRequested: recordingRequested, streamingRequested: streamingRequested)
            evidence(app, phase: "final-observation", screenshot: false)
        }

        // A prior failed setup may leave this app-owned sheet open. Dismissing
        // it neither edits saved settings nor changes capture state.
        if app.buttons["streaming.closeSetup"].exists {
            try tap(app.buttons["streaming.closeSetup"], in: app)
        }
        try selectTab("Film", app)
        try wait("Film did not become ready; inspect prior recording state.", seconds: 12) {
            app.buttons["film.start"].exists || app.buttons["film.stop"].exists
        }
        try require(!app.buttons["film.stop"].exists && !app.buttons["streaming.stop"].exists,
                    "Existing recording or streaming state prevents an isolated smoke; existing state was preserved.")
        try wait("Saved recording scan did not complete.", seconds: 10) {
            app.buttons["film.start"].isEnabled
        }
        try selectTab("Recordings", app)
        // The library sorts newest first. Compare this ID before exporting so a
        // failed recording cannot accidentally pass by exporting an old video.
        let exports = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.export."))
        let oldNewestExport = exports.firstMatch.exists ? exports.firstMatch.identifier : nil

        try selectTab("Score", app)
        if !app.textFields["scoring.endpoint"].exists {
            try tap(app.buttons["Server"], in: app,
                    timeout: 25,
                    failure: "Saved Score setup cannot be changed; resolve pending scoring state on the phone.")
        }
        try replace(app.textFields["scoring.endpoint"], with: endpoint, in: app)
        try replace(app.secureTextFields["scoring.token"], with: token, in: app)
        try tap(app.buttons["scoring.connect"], in: app)
        try wait("Score did not join the seeded active match.", seconds: 20) {
            self.allowExpectedPermissions()
            return app.buttons["scoring.homePoint"].exists
        }
        try require(app.buttons["scoring.homePoint"].label == "Award point to HOME" &&
                    app.buttons["scoring.awayPoint"].label == "Award point to AWAY",
                    "The active match is not the expected HOME/AWAY smoke fixture.")
        try require(app.buttons["scoring.homePoint"].value as? String == "0" &&
                    app.buttons["scoring.awayPoint"].value as? String == "0",
                    "Seeded match must start at 0–0; existing score was preserved.")
        if app.buttons["scoring.takeover"].exists {
            try tap(app.buttons["scoring.takeover"], in: app)
        }
        try wait("The phone did not gain scoring control.", seconds: 12) {
            app.buttons["scoring.homePoint"].isEnabled
        }

        try selectTab("Film", app)
        try tap(app.buttons["streaming.setup"], in: app)
        try replace(app.textFields["streaming.endpoint"], with: endpoint, in: app)
        try replace(app.secureTextFields["streaming.token"], with: token, in: app)
        try replace(app.textFields["streaming.worker"], with: "mac", in: app)
        try replace(app.textFields["streaming.output"], with: "local-sink", in: app)
        try tap(app.buttons["streaming.connect"], in: app)
        try wait("Film setup did not join the active match; check saved setup and LAN connectivity.", seconds: 20) {
            self.allowExpectedPermissions()
            return app.staticTexts["streaming.connected"].exists && app.buttons["streaming.connect"].isEnabled
        }
        try tap(app.buttons["streaming.closeSetup"], in: app)

        recordingRequested = true
        try tap(app.buttons["film.start"], in: app)
        try wait("Hardware camera/microphone recording did not advance.", seconds: 25) {
            self.allowExpectedPermissions()
            return self.elapsed(app) >= 2 && app.buttons["film.stop"].exists
        }
        streamingRequested = true
        try tap(app.buttons["streaming.start"], in: app)
        try wait("Camera did not publish to the LAN worker.", seconds: 25) {
            self.allowExpectedPermissions()
            return self.value(app, "streaming.localStatus") == "publishing"
        }
        try wait("Worker did not report producing_output.", seconds: 35) {
            self.value(app, "streaming.workerStatus") == "producing_output"
        }
        evidence(app, phase: "hardware-publishing", screenshot: true)

        if watchScoring {
            try selectTab("Watch", app)
            let connect = app.buttons["phoneWatch.connect.0"]
            try wait("Paired Watch did not advertise its identity to the phone.", seconds: 150) {
                connect.exists && connect.isEnabled
            }
            try selectTab("Film", app)
            try require(value(app, "streaming.localStatus") == "publishing" &&
                        value(app, "streaming.workerStatus") == "producing_output",
                        "Live output stopped before offering paired Watch setup.")
            try selectTab("Watch", app)
            try tap(connect, in: app)
            let status = app.descendants(matching: .any).matching(identifier: "phoneWatch.status").firstMatch
            try wait("Paired Watch did not confirm native setup.", seconds: 100) {
                status.exists && status.label.contains("Watch reports connected")
            }
            evidence(app, phase: "physical-watch-setup-confirmed", screenshot: true)
            try selectTab("Score", app)
            // The opt-in physical Watch runner holds its first point for 30s
            // so the phone can observe both that point and concurrent output.
            try wait("Phone did not observe the Watch's first point before match end.", seconds: 60) {
                app.buttons["scoring.homePoint"].value as? String == "1" &&
                    app.buttons["scoring.awayPoint"].value as? String == "0"
            }
            try selectTab("Film", app)
            try require(value(app, "streaming.localStatus") == "publishing" &&
                        value(app, "streaming.workerStatus") == "producing_output" &&
                        app.buttons["film.stop"].exists,
                        "Recording and live output did not remain active during Watch scoring.")
            evidence(app, phase: "physical-watch-point-while-publishing", screenshot: true)
            try selectTab("Score", app)
            try wait("Watch did not complete point, undo, away point, and end-match workflow.", seconds: 180) {
                app.staticTexts["scoring.ended"].exists
            }
            try require(app.buttons["scoring.homePoint"].value as? String == "0" &&
                        app.buttons["scoring.awayPoint"].value as? String == "1",
                        "Phone did not observe the expected Watch 0–1 final score.")
            evidence(app, phase: "physical-watch-score-and-end-observed", screenshot: true)
            try selectTab("Film", app)
            // Remote match end may already stop publishing; the archive must
            // still be active and advance through the common checks below.
            if app.buttons["streaming.stop"].exists {
                try tap(app.buttons["streaming.stop"], in: app)
            }
        } else {
            try selectTab("Score", app)
            try tap(app.buttons["scoring.homePoint"], in: app)
            try wait("Native HOME point was not acknowledged as 1.", seconds: 12) {
                app.buttons["scoring.homePoint"].value as? String == "1"
            }
            evidence(app, phase: "native-home-point-acknowledged", screenshot: true)
            try selectTab("Film", app)
            let holdStarted = Date()
            let initialDuration = elapsed(app)
            try wait("Recording did not advance throughout the 12-second live hold.", seconds: 18) {
                Date().timeIntervalSince(holdStarted) >= 12 && self.elapsed(app) >= initialDuration + 12
            }
            try require(value(app, "streaming.localStatus") == "publishing" &&
                        value(app, "streaming.workerStatus") == "producing_output",
                        "Live publishing or worker output stopped during the recording hold.")
            evidence(app, phase: "live-hold-complete", screenshot: true)
            try tap(app.buttons["streaming.stop"], in: app)
        }
        try wait("Streaming did not return to idle.", seconds: 15) {
            self.value(app, "streaming.localStatus") == "idle"
        }
        let stoppedAt = elapsed(app)
        try wait("Local recording did not continue after streaming stopped.", seconds: 8) {
            self.elapsed(app) >= stoppedAt + 3 && app.buttons["film.stop"].exists
        }
        evidence(app, phase: "recording-continues-after-stream-stop", screenshot: true)
        try tap(app.buttons["film.stop"], in: app)
        try wait("Recording did not finish saving.", seconds: 20) {
            app.buttons["film.start"].exists && app.buttons["film.start"].isEnabled
        }
        try selectTab("Recordings", app)
        try wait("No new completed recording appeared; existing recordings were preserved.", seconds: 10) {
            exports.firstMatch.exists && exports.firstMatch.identifier != oldNewestExport
        }
        try tap(exports.firstMatch, in: app)
        try wait("The new recording could not be exported to MP4.", seconds: 35) {
            app.staticTexts["recordings.exportReady"].exists
        }
        evidence(app, phase: "new-hardware-recording-export-ready", screenshot: true)
        // No recording/keychain deletion, external share, or Photos-library write.
        #endif
    }

    private func explicitValue(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.hasPrefix("$(") else { return nil }
        return value
    }

    private func isPrivateLANEndpoint(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host else { return false }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              zip(components, octets).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeFailure.failed(message) }
    }

    @MainActor private func wait(_ message: String, seconds: Double, until condition: () -> Bool) throws {
        let end = min(deadline, Date().addingTimeInterval(seconds))
        while Date() < end {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw SmokeFailure.failed(message)
    }

    @MainActor private func selectTab(_ name: String, _ app: XCUIApplication) throws {
        let button = app.tabBars.buttons[name]
        tabEvidence(app, requested: name, phase: "before-selection")
        do {
            try dismissSetupKeyboard(app)
            for _ in 0..<2 {
                if button.exists && button.isSelected { return }
                try wait("Tab \(name) is unavailable or covered; leave Scorebug's tab bar visible.", seconds: 4) {
                    guard button.exists && button.isEnabled,
                          !app.keyboards.firstMatch.exists, !app.alerts.firstMatch.exists else { return false }
                    let frame = button.frame
                    return !frame.isEmpty && !frame.isNull && !frame.isInfinite && app.frame.contains(frame)
                }
                // On the physical phone element.tap() reported a {-1, -1}
                // hit point despite a visible tab. Its observed frame provides
                // the real center; no content scrolling is needed for a tab.
                if button.isSelected { return }
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let selectionEnd = min(deadline, Date().addingTimeInterval(3))
                while Date() < selectionEnd {
                    if button.exists && button.isSelected { return }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
            }
            throw SmokeFailure.failed("Tab \(name) did not become selected after two center taps.")
        } catch {
            tabEvidence(app, requested: name)
            throw error
        }
    }

    @MainActor private func dismissSetupKeyboard(_ app: XCUIApplication) throws {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let scoreField = app.textFields["scoring.endpoint"]
        let filmField = app.textFields["streaming.endpoint"]
        let setupVisible = (scoreField.exists && scoreField.isHittable) ||
            (filmField.exists && filmField.isHittable)
        try require(setupVisible && !app.alerts.firstMatch.exists && keyboard.isHittable,
                    "Keyboard is not on an accessible Scorebug connection form; dismiss the covering UI manually.")
        // These single-line setup fields have no onSubmit action. Use only a
        // keyboard-owned Done/Return key, never a form button or password-manager
        // control, and confirm dismissal before attempting any tab tap.
        for title in ["Done", "done", "Return", "return"] {
            let button = keyboard.buttons[title]
            let key = keyboard.keys[title]
            if button.exists && button.isEnabled && button.isHittable {
                button.tap()
            } else if key.exists && key.isEnabled && key.isHittable {
                key.tap()
            } else { continue }
            try wait("Connection keyboard did not dismiss; tab navigation was not attempted.", seconds: 4) {
                !app.keyboards.firstMatch.exists
            }
            return
        }
        throw SmokeFailure.failed("Connection keyboard has no accessible Done/Return key; tab navigation was not attempted.")
    }

    @MainActor private func tabEvidence(_ app: XCUIApplication, requested: String, phase: String = "failed") {
        let names = ["Film", "Score", "Watch", "Recordings"]
        let safeLabels = names + ["video", "sportscourt", "applewatch", "rectangle.stack"]
        let appFrame = app.frame
        let keyboard = app.keyboards.firstMatch
        let keyboardExists = keyboard.exists
        let keyboardFrame = keyboardExists ? keyboard.frame : .zero
        // Only known action labels, never predictive suggestions or typed text.
        let dismissalKeys: [[String: Any]] = keyboardExists ? ["Done", "done", "Return", "return"].map { title in
            let button = keyboard.buttons[title]
            let key = keyboard.keys[title]
            return ["label": title, "buttonExists": button.exists, "keyExists": key.exists,
                    "buttonHittable": button.exists && button.isHittable,
                    "keyHittable": key.exists && key.isHittable]
        } : []
        let alert = app.alerts.firstMatch
        let window = app.windows.firstMatch
        let windowExists = window.exists
        let tabs: [[String: Any]] = names.map { name in
            let button = app.tabBars.buttons[name]
            guard button.exists else { return ["tab": name, "exists": false] }
            let label = button.label
            let frame = button.frame
            return ["tab": name, "exists": true, "label": safeLabels.contains(label) ? label : "other",
                    "selected": button.isSelected, "enabled": button.isEnabled, "hittable": button.isHittable,
                    "frame": String(describing: frame), "frameEmpty": frame.isEmpty,
                    "frameNull": frame.isNull, "frameInfinite": frame.isInfinite,
                    "appContainsFrame": appFrame.contains(frame),
                    "intersectsKeyboard": keyboardExists && frame.intersects(keyboardFrame)]
        }
        let report: [String: Any] = ["requestedTab": names.contains(requested) ? requested : "other", "tabs": tabs,
                                   "phase": phase, "appFrame": String(describing: appFrame), "appState": app.state.rawValue,
                                   "keyboardExists": keyboardExists,
                                   "keyboardHittable": keyboardExists && keyboard.isHittable,
                                   "keyboardDismissalKeys": dismissalKeys,
                                   "keyboardFrame": String(describing: keyboardFrame), "alertExists": alert.exists,
                                   "windowExists": windowExists,
                                   "windowFrame": windowExists ? String(describing: window.frame) : "missing"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "PhysicalStreaming-tab-selection-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        // Crop to the app's tab bar: a full screen may contain setup fields.
        let tabBar = app.tabBars.firstMatch
        if phase == "failed" && tabBar.exists && !tabBar.frame.isEmpty && app.frame.contains(tabBar.frame) &&
            !app.keyboards.firstMatch.exists && !app.alerts.firstMatch.exists {
            let attachment = XCTAttachment(screenshot: tabBar.screenshot())
            attachment.name = "PhysicalStreaming-tab-bar"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor private func tap(_ element: XCUIElement, in app: XCUIApplication, timeout: Double = 8, failure: String? = nil) throws {
        try reveal(element, in: app)
        try wait(failure ?? "Control \(element.identifier) is unavailable or disabled; prior setup may need attention.", seconds: timeout) {
            self.allowExpectedPermissions()
            return element.exists && element.isEnabled && element.isHittable
        }
        element.tap()
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        // Form/List rows may exist offscreen. Scroll the content, never the tab
        // bar or a system permission dialog, and check hittability after each move.
        for direction in [true, false] {
            for _ in 0..<4 {
                if element.exists && element.isHittable { return }
                try require(Date() < deadline, "Device UI smoke exceeded its time budget.")
                allowExpectedPermissions()
                let scroll = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
                let container = scroll.exists ? scroll : (app.tables.firstMatch.exists ? app.tables.firstMatch : app)
                if direction { container.swipeUp(velocity: .slow) }
                else { container.swipeDown(velocity: .slow) }
            }
        }
    }

    @MainActor private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) throws {
        // A saved offline server may have one 20-second recovery request in
        // flight. Wait for that bounded operation rather than erase its state.
        try tap(field, in: app, timeout: 25,
                failure: "Saved connection cannot be edited; resolve pending state without clearing Keychain.")
        let secure = field.elementType == .secureTextField
        if !secure && fieldContents(field) == text { return }
        if secure {
            // iOS secure fields can suppress Select All. Put the caret at the
            // trailing edge of this specific field before deleting its masked
            // character count; a center tap is not a reliable end position.
            // One bounded retry handles secure fields that reposition on focus.
            for attempt in 0..<2 {
                try require(field.exists && Date() < deadline, "Secure connection field became unavailable.")
                let count = fieldContents(field).count
                if count == 0 { break }
                try require(count <= 1024, "Secure connection field is unexpectedly long; nothing was submitted.")
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
                do {
                    try wait("Secure connection field was not fully cleared; nothing was submitted.", seconds: 3) {
                        field.exists && self.fieldContents(field).isEmpty
                    }
                    break
                } catch {
                    if attempt == 1 { throw error }
                }
            }
            try require(field.exists && fieldContents(field).isEmpty,
                        "Secure connection field was not fully cleared; nothing was submitted.")
        } else if !fieldContents(field).isEmpty {
            // A tap can put the caret in the middle of a value. Select the
            // entire value explicitly instead of assuming backspace starts at
            // its end. iOS exposes the edit menu as menu items or buttons.
            field.press(forDuration: 1.1)
            let menuItem = app.menuItems["Select All"]
            let menuButton = app.buttons["Select All"]
            try wait("The connection field's Select All action was unavailable; nothing was submitted.", seconds: 4) {
                (menuItem.exists && menuItem.isHittable) || (menuButton.exists && menuButton.isHittable)
            }
            if menuItem.exists && menuItem.isHittable { menuItem.tap() }
            else { menuButton.tap() }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            try wait("The connection field was not fully cleared; nothing was submitted.", seconds: 3) {
                field.exists && self.fieldContents(field).isEmpty
            }
        }
        field.typeText(text)
        try wait("Connection field replacement verification failed; nothing was submitted.", seconds: 3) {
            guard field.exists else { return false }
            let actual = self.fieldContents(field)
            // Secure-field verification uses length only; neither expected nor
            // observed credentials appear in assertion messages or attachments.
            return secure ? actual.count == text.count : actual == text
        }
    }

    @MainActor private func fieldContents(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    @MainActor private func allowExpectedPermissions() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return }
        let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
        guard text.contains("scorebug") else { return }
        let cameraOrMic = text.contains("camera") || text.contains("microphone")
        let network = text.contains("local network") || text.contains("devices on your local")
        guard cameraOrMic || network else { return }
        // Match both alert subject and exact affirmative title. Never tap a
        // generic first/last button or accept unrelated app/system dialogs.
        for title in ["Allow", "OK"] {
            let button = alert.buttons[title]
            if button.exists && button.isEnabled { button.tap(); return }
        }
    }

    @MainActor private func elapsed(_ app: XCUIApplication) -> Double {
        let duration = app.staticTexts["film.duration"]
        guard duration.exists else { return -1 }
        return Double(duration.value as? String ?? "") ?? -1
    }

    @MainActor private func value(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.staticTexts[id]
        guard element.exists else { return "missing" }
        return element.value as? String ?? "missing"
    }

    @MainActor private func evidence(_ app: XCUIApplication, phase: String, screenshot: Bool) {
        // Only allowlisted status values: never dump accessibility trees, setup
        // forms, server errors, process environment, or authentication material.
        let statuses = ["idle", "starting", "publishing", "failed", "producing_output", "unknown", "stale",
                        "not_requested", "waiting_source", "stopping", "retrying", "closed", "missing"]
        let local = value(app, "streaming.localStatus")
        let worker = value(app, "streaming.workerStatus")
        let report: [String: Any] = ["phase": phase, "durationSeconds": elapsed(app),
                                   "localStatus": statuses.contains(local) ? local : "other",
                                   "workerStatus": statuses.contains(worker) ? worker : "other",
                                   "exportReady": app.staticTexts["recordings.exportReady"].exists]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "PhysicalStreaming-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        if screenshot {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "PhysicalStreaming-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor private func cleanup(_ app: XCUIApplication, recordingRequested: Bool, streamingRequested: Bool) {
        guard recordingRequested || streamingRequested else { return }
        deadline = Date().addingTimeInterval(15)
        if app.buttons["recordings.closePlayer"].isHittable { app.buttons["recordings.closePlayer"].tap() }
        try? selectTab("Film", app)
        if streamingRequested && app.buttons["streaming.stop"].exists {
            try? tap(app.buttons["streaming.stop"], in: app)
        }
        // A failed navigation/stream stop cannot consume the recording budget.
        // Retry Film navigation using that separate budget before locating stop.
        if recordingRequested {
            deadline = Date().addingTimeInterval(20)
            try? selectTab("Film", app)
            if app.buttons["film.stop"].exists {
                try? tap(app.buttons["film.stop"], in: app)
                try? wait("Cleanup recording save timed out.", seconds: 8) { !app.buttons["film.stop"].exists }
            }
        }
        evidence(app, phase: "cleanup", screenshot: false)
    }
}

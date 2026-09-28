import XCTest

final class ScoringLaunchTests: XCTestCase {
    @MainActor
    func testNativeScoringWorkflowWithoutCameraPermission() async throws {
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
                if scenario == "lost-reply" {
                    exerciseLostReply(app)
                    return
                }
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
                } else {
                    if scenario == "worker-status" {
                        try await exerciseWorkerStatus(app, base: url, token: try XCTUnwrap(env["SCOREBUG_TEST_TOKEN"]))
                    }
                    endMatch(app)
                }
            }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native scoring \(scenario)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    @MainActor
    private func exerciseLostReply(_ app: XCUIApplication) {
        let saved = app.staticTexts["Your last action is saved. The server must confirm it before another point can be sent."]
        XCTAssertTrue(saved.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["scoring.homePoint"].isEnabled)
        app.terminate(); app.launch()
        XCTAssertTrue(saved.waitForExistence(timeout: 15), "Relaunch must recover the real persisted outbox while still offline. " + app.debugDescription)
        if app.buttons["scoring.homePoint"].exists { XCTAssertFalse(app.buttons["scoring.homePoint"].isEnabled) }
        let pending = XCTAttachment(screenshot: app.screenshot())
        pending.name = "Saved action restored offline"; pending.lifetime = .keepAlways; add(pending)
        print("SCOREBUG_SCORING_RESTORE_CONNECTION")
        XCTAssertTrue(waitForValue("1", element: app.buttons["scoring.homePoint"]), app.debugDescription)
        app.swipeUp()
        tapWhenEnabled(app.buttons["scoring.undo"])
        XCTAssertTrue(waitForValue("0", element: app.buttons["scoring.homePoint"]))
        XCTAssertFalse(saved.exists)
        endMatch(app)
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Lost reply reconciled once and undone"; recovered.lifetime = .keepAlways; add(recovered)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    @MainActor
    private func exerciseWorkerStatus(_ app: XCUIApplication, base: String, token: String) async throws {
        func request(_ path: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
            request.timeoutInterval = 5
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func label(_ expected: String) {
            let value = app.staticTexts["scoring.broadcastStatus"]
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", expected), object: value)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, app.debugDescription)
            if expected == "Worker encoding video" || expected == "Worker status unavailable" {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = expected
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
        label("Broadcast not requested")
        let active = try await request("/v1/matches/active", token: token)
        let match = try XCTUnwrap(active["snapshot"] as? [String: Any])
        let game = try XCTUnwrap(match["id"] as? String)
        let capture = try await request("/v1/matches/\(game)/join", token: token,
            body: ["deviceId": "status-camera", "role": "capture"])
        let captureToken = try XCTUnwrap((capture["credential"] as? [String: Any])?["token"] as? String)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        _ = try await request("/v1/matches/\(game)/media/recordings", token: captureToken,
            body: ["recordingId": "status-archive", "sequence": 0, "status": "recording", "startedAt": timestamp])
        _ = try await request("/v1/matches/\(game)/media/commands", token: token,
            body: ["commandId": "status-start", "gameId": game, "expectedGeneration": 0, "issuedAt": timestamp,
                   "operation": ["type": "start", "selection": ["workerId": "status-worker", "outputId": "status-output", "captureDeviceId": "status-camera", "recordingId": "status-archive"]]])
        label("Waiting for worker status")
        let workerToken = "qa-home-token-not-production"
        let session = try await request("/v1/worker/sessions", token: workerToken,
            body: ["workerId": "status-worker", "runId": "status-run"])
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        func report(_ sequence: Int, state: String, frame: Any, time: Any, attempt: Int) async throws {
            _ = try await request("/v1/worker/observations", token: workerToken,
                body: ["workerId": "status-worker", "sessionId": sessionId, "sequence": sequence,
                       "observation": ["gameId": game, "generation": 1, "state": state, "reason": NSNull(),
                                       "attempt": attempt, "frame": frame, "outTimeUs": time, "scoreRevision": NSNull()]])
        }
        try await report(1, state: "waiting_source", frame: NSNull(), time: NSNull(), attempt: 0)
        label("Worker waiting for video source")
        try await report(2, state: "producing_output", frame: 12, time: 400000, attempt: 1)
        label("Worker encoding video")
        let home = app.buttons["scoring.homePoint"]
        tapWhenEnabled(home)
        XCTAssertTrue(waitForValue("1", element: home), "Worker status must not block scoring")
        label("Worker status unavailable")
        try await report(3, state: "producing_output", frame: 24, time: 800000, attempt: 1)
        label("Worker encoding video")
        _ = try await request("/v1/matches/\(game)/media/commands", token: token,
            body: ["commandId": "status-stop", "gameId": game, "expectedGeneration": 1,
                   "issuedAt": ISO8601DateFormatter().string(from: Date()), "operation": ["type": "stop"]])
        label("Broadcast not requested")
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

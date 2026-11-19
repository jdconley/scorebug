import XCTest

/// The App Store and website screenshots: the moments that matter, against the local Worker
/// with the Simulator camera reading a staged clip. Run by ios/AppStore/capture.sh, which stages
/// the clip, sets the status bar and passes:
///   SCOREBUG_STORE_MEDIA=<dir>    where PNGs are written
///   SCOREBUG_TEST_API_URL=<url>   the local Worker (see ios/README.md)
final class StoreMediaTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var directory: URL? {
        environment["SCOREBUG_STORE_MEDIA"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(directory == nil, "Set SCOREBUG_STORE_MEDIA to capture the store screenshots.")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// The film-and-stream phone: team, channel, new match, live with the score on, invite a scorer.
    func testFilmingPhone() throws {
        try identity("chris@example.com", name: "Chris Taylor")
        let app = launch(reset: true, camera: true)
        signIn(app)
        XCTAssertTrue(app.buttons["home.createTeam"].waitForExistence(timeout: 20))
        app.buttons["home.createTeam"].tap()
        let name = app.textFields["createTeam.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Wildcats 14 Blue")
        app.buttons["createTeam.submit"].tap()
        XCTAssertTrue(app.buttons["team.invite"].waitForExistence(timeout: 15))
        if app.buttons["team.channel.connect"].waitForExistence(timeout: 5) {
            signIn(app, button: "team.channel.connect")
            XCTAssertTrue(app.staticTexts["team.channel.title"].waitForExistence(timeout: 20))
        }
        // Two people already on the team.
        app.buttons["team.invite"].tap()
        XCTAssertTrue(app.buttons["invite.createLink"].waitForExistence(timeout: 5))
        app.buttons["invite.createLink"].tap()
        let code = app.staticTexts["invite.teamCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let teamCode = code.label.replacingOccurrences(of: "Code ", with: "").replacingOccurrences(of: " ", with: "")
        app.buttons["Done"].tap()
        let coach = try apiSignIn("coach@example.com", name: "Riley Martinez")
        _ = try call("POST", "/v1/team-invites/accept", token: coach, body: ["code": teamCode])
        _ = try apiSignIn("parent@example.com", name: "Dana Okafor", invite: teamCode)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.team.'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Riley Martinez"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "team")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // New match.
        let newMatch = app.buttons["home.newMatch"].firstMatch
        XCTAssertTrue(newMatch.waitForExistence(timeout: 10))
        newMatch.tap()
        let team2 = app.textFields["newMatch.team2.name"]
        XCTAssertTrue(team2.waitForExistence(timeout: 5))
        team2.tap(); team2.typeText("Mustangs 14 Red\n")
        shot(app, "new-match")
        app.swipeUp()
        let goLive = app.buttons["newMatch.goLive"]
        XCTAssertTrue(goLive.waitForExistence(timeout: 5) && goLive.isEnabled, "Go Live needs the team's channel")
        XCUIDevice.shared.orientation = .landscapeLeft
        goLive.tap()
        XCTAssertTrue(app.buttons["live.watchLink"].waitForExistence(timeout: 40))

        // Play a set: 25-21, then the second set to 18-15.
        let left = app.buttons["live.tap.left"], right = app.buttons["live.tap.right"]
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        try rally(app, left: 25, right: 21, leftButton: left, rightButton: right)
        try rally(app, left: 15, right: 18, leftButton: left, rightButton: right)
        Thread.sleep(forTimeInterval: 2)
        Thread.sleep(forTimeInterval: 4)
        shot(app, "live")

        app.buttons["live.invite"].tap()
        Thread.sleep(forTimeInterval: 2)
        shot(app, "invite-scorer")
        app.buttons["Done"].firstMatch.tap()

        // Win set 2 and the match.
        try rally(app, left: 8, right: 4, leftButton: left, rightButton: right)
        let end = app.buttons["setPoint.confirm"]
        for _ in 0..<5 where !end.waitForExistence(timeout: 0.6) { left.tap() }
        end.tap()
        XCTAssertTrue(app.buttons["matchOver.done"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        shot(app, "final")
    }

    /// The App Store preview: a live match at a natural pace. preview.sh records the Simulator
    /// and cuts the video at the times this writes to marks.txt.
    func testPreview() throws {
        try XCTSkipIf(environment["SCOREBUG_STORE_PREVIEW"] != "1", "preview.sh sets SCOREBUG_STORE_PREVIEW=1.")
        try identity("chris@example.com", name: "Chris Taylor")
        let app = launch(reset: true, camera: true)
        signIn(app)
        XCTAssertTrue(app.buttons["home.createTeam"].waitForExistence(timeout: 20))
        app.buttons["home.createTeam"].tap()
        let name = app.textFields["createTeam.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Wildcats 14 Blue")
        app.buttons["createTeam.submit"].tap()
        XCTAssertTrue(app.buttons["team.channel.connect"].waitForExistence(timeout: 15))
        signIn(app, button: "team.channel.connect")
        XCTAssertTrue(app.staticTexts["team.channel.title"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let newMatch = app.buttons["home.newMatch"].firstMatch
        XCTAssertTrue(newMatch.waitForExistence(timeout: 10))
        newMatch.tap()
        let team2 = app.textFields["newMatch.team2.name"]
        XCTAssertTrue(team2.waitForExistence(timeout: 5))
        team2.tap(); team2.typeText("Mustangs 14 Red\n")
        app.swipeUp()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["newMatch.goLive"].tap()
        XCTAssertTrue(app.buttons["live.watchLink"].waitForExistence(timeout: 40))
        let left = app.buttons["live.tap.left"], right = app.buttons["live.tap.right"]
        XCTAssertTrue(app.staticTexts["LIVE"].waitForExistence(timeout: 30), "the stream should be live")
        // Quickly to 21-19, then the end of the set at a watchable pace.
        try rally(app, left: 21, right: 19, leftButton: left, rightButton: right)
        Thread.sleep(forTimeInterval: 2)
        mark("start")
        for button in [left, right, left, left, left] {
            button.tap()
            Thread.sleep(forTimeInterval: 1.6)
        }
        let confirm = app.buttons["setPoint.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        confirm.tap()
        let swap = app.buttons["swap.yes"]
        if swap.waitForExistence(timeout: 4) { Thread.sleep(forTimeInterval: 1.5); swap.tap() }
        Thread.sleep(forTimeInterval: 2.5)
        app.buttons["live.invite"].tap()
        Thread.sleep(forTimeInterval: 4)
        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        mark("end")
    }

    private func mark(_ name: String) {
        guard let directory else { return }
        let line = "\(name) \(Date().timeIntervalSince1970)\n"
        let file = directory.appendingPathComponent("marks.txt")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: file)
        }
    }

    /// The second phone in the stands: a team member keeps score for a teammate's live match.
    func testScoringPhone() throws {
        let coach = try apiSignIn("coach.kim@example.com", name: "Jordan Kim")
        let team = try call("POST", "/v1/teams", token: coach, body: ["name": "Wildcats 14 Blue"])
        let teamId = try XCTUnwrap((team["team"] as? [String: Any])?["id"] as? String)
        _ = try call("PATCH", "/v1/teams/\(teamId)", token: coach, body: ["color": "#2563EB"])
        let invite = try call("POST", "/v1/teams/\(teamId)/invites", token: coach, body: [:])
        let inviteCode = try XCTUnwrap(invite["code"] as? String)
        _ = try call("POST", "/v1/teams/\(teamId)/matches", token: coach, body: [
            "id": "store-\(Int(Date().timeIntervalSince1970))", "deviceId": "coach-phone",
            "teams": ["home": ["name": "Wildcats 14 Blue", "shortName": "WILDCATS", "color": "#2563eb"],
                      "away": ["name": "Mustangs 14 Red", "shortName": "MUSTANGS", "color": "#dc2626"]],
            "rules": ["bestOf": 3, "pointsToWin": 25, "decidingPointsToWin": 15, "winBy": 2, "pointCap": NSNull()],
            "recordOnly": true,
        ])
        try identity("fan@example.com", name: "Sam Rivera")
        let app = launch(reset: true, camera: false)
        signIn(app)
        let join = app.buttons["home.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 20))
        join.tap()
        let field = app.textFields["join.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(inviteCode)
        app.buttons["join.submit"].tap()
        XCTAssertTrue(app.buttons["home.match.score"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "home")
        app.buttons["home.match.score"].firstMatch.tap()
        let left = app.buttons["score.left"], right = app.buttons["score.right"]
        XCTAssertTrue(left.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        try rally(app, left: 22, right: 19, leftButton: left, rightButton: right)
        Thread.sleep(forTimeInterval: 2)
        shot(app, "scorer")
    }

    // MARK: Helpers

    /// Alternates points so the score reads naturally, confirming each set's end.
    private func rally(_ app: XCUIApplication, left: Int, right: Int, leftButton: XCUIElement, rightButton: XCUIElement) throws {
        var l = 0, r = 0
        while l < left || r < right {
            let pickLeft = r >= right || (l < left && (l * right <= r * left))
            (pickLeft ? leftButton : rightButton).tap()
            if pickLeft { l += 1 } else { r += 1 }
            Thread.sleep(forTimeInterval: 0.15)
            let confirm = app.buttons["setPoint.confirm"]
            if confirm.waitForExistence(timeout: 0.6) {
                confirm.tap()
                let no = app.buttons["swap.no"]
                if no.waitForExistence(timeout: 3) { no.tap() }
                Thread.sleep(forTimeInterval: 2.5)
                return
            }
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        // The whole screen: app.screenshot() crops landscape apps on the Simulator.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private func launch(reset: Bool, camera: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_RESET"] = reset ? "1" : "0"
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = localWorker.absoluteString
        if camera { app.launchEnvironment["SCOREBUG_TEST_FILE_CAPTURE"] = "1" }
        app.launch()
        XCTAssertTrue(app.buttons["signIn.google"].waitForExistence(timeout: 15))
        return app
    }

    /// Taps Google sign-in and the system's "wants to use … to sign in" prompt.
    private func signIn(_ app: XCUIApplication, button: String = "signIn.google") {
        app.buttons[button].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let proceed = springboard.buttons["Continue"]
        if proceed.waitForExistence(timeout: 20) { proceed.tap() }
    }
}

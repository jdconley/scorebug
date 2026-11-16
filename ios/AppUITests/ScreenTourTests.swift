import CryptoKit
import XCTest

/// Walks the hosted app's screens against a local Worker and saves a screenshot of each.
/// Simulator QA, run by hand (see ios/README.md):
///   SCOREBUG_TEST_TOUR=<dir>      where PNGs are written (also kept as test attachments)
///   SCOREBUG_TEST_API_URL=<url>   the local Worker, like http://localhost:8787, started with a
///                                 stand-in Google that signs in as whoever POST /dev/identity names
final class ScreenTourTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var directory: URL? {
        environment["SCOREBUG_TEST_TOUR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private var api: URL { URL(string: environment["SCOREBUG_TEST_API_URL"] ?? "http://127.0.0.1:8787")! }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(directory == nil, "Set SCOREBUG_TEST_TOUR to run the screenshot tour.")
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

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_RESET"] = reset ? "1" : "0"
        app.launchEnvironment["SCOREBUG_TEST_API_URL"] = api.absoluteString
        app.launch()
        return app
    }

    /// Taps Google sign-in and the system's "wants to use … to sign in" prompt.
    private func signIn(_ app: XCUIApplication, button: String = "signIn.google") {
        app.buttons[button].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let proceed = springboard.buttons["Continue"]
        if proceed.waitForExistence(timeout: 10) { proceed.tap() }
    }

    func testHostedTour() throws {
        // Not on the beta list.
        try identity("stranger@example.com", name: "Sam Stranger")
        var app = launch(reset: true)
        XCTAssertTrue(app.buttons["signIn.google"].waitForExistence(timeout: 15))
        shot(app, "01-sign-in")
        signIn(app)
        XCTAssertTrue(app.staticTexts["beta.title"].waitForExistence(timeout: 20))
        shot(app, "02-private-beta")
        app.buttons["Back"].tap()

        // JD: on the beta list, can create teams, no team yet.
        try identity("jd@example.com", name: "JD Conley")
        signIn(app)
        XCTAssertTrue(app.buttons["home.createTeam"].waitForExistence(timeout: 20))
        shot(app, "03-home-no-team")
        app.buttons["home.createTeam"].tap()
        let name = app.textFields["createTeam.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Cascade 14 Black")
        shot(app, "04-create-team")
        app.buttons["createTeam.submit"].tap()
        XCTAssertTrue(app.buttons["team.invite"].waitForExistence(timeout: 15))
        shot(app, "05-team-new")

        // Connect the team's YouTube channel (the local Worker's stand-in YouTube).
        if app.buttons["team.channel.connect"].waitForExistence(timeout: 5) {
            signIn(app, button: "team.channel.connect")
            XCTAssertTrue(app.staticTexts["team.channel.title"].waitForExistence(timeout: 20))
            shot(app, "05b-team-channel")
        }

        // Invite with a link; a coach with an account accepts it.
        app.buttons["team.invite"].tap()
        XCTAssertTrue(app.buttons["invite.createLink"].waitForExistence(timeout: 5))
        shot(app, "06-invite-sheet")
        app.buttons["invite.createLink"].tap()
        let code = app.staticTexts["invite.teamCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        shot(app, "07-invite-ready")
        let cascadeCode = code.label.replacingOccurrences(of: "Code ", with: "").replacingOccurrences(of: " ", with: "")
        app.buttons["Done"].tap()

        let coach = try apiSignIn("coach@example.com", name: "Riley Coach")
        _ = try call("POST", "/v1/team-invites/accept", token: coach, body: ["code": cascadeCode])
        _ = try apiSignIn("mom@example.com", name: "Dana Parent", invite: cascadeCode)
        // The coach's own team, with a match in progress, and an invite JD will type in.
        let summit = try call("POST", "/v1/teams", token: coach, body: ["name": "Summit 14 Red"])
        let summitId = try XCTUnwrap((summit["team"] as? [String: Any])?["id"] as? String)
        _ = try call("PATCH", "/v1/teams/\(summitId)", token: coach, body: ["color": "#DC2626"])
        let summitInvite = try call("POST", "/v1/teams/\(summitId)/invites", token: coach, body: [:])
        let summitCode = try XCTUnwrap(summitInvite["code"] as? String)
        _ = try call("POST", "/v1/teams/\(summitId)/matches", token: coach, body: [
            "id": "tour-\(Int(Date().timeIntervalSince1970))", "deviceId": "coach-phone",
            "teams": ["home": ["name": "Summit 14 Red", "shortName": "SUMMIT", "color": "#dc2626"],
                      "away": ["name": "Cascade 14 Black", "shortName": "CASCADE", "color": "#2563eb"]],
            "rules": ["bestOf": 3, "pointsToWin": 25, "decidingPointsToWin": 15, "winBy": 2, "pointCap": NSNull()],
            "recordOnly": true,
        ])

        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Join the coach's team with its code.
        XCTAssertTrue(app.buttons["home.join"].waitForExistence(timeout: 10))
        app.buttons["home.join"].tap()
        let field = app.textFields["join.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(summitCode)
        shot(app, "08-join-team-code")
        app.buttons["join.submit"].tap()
        XCTAssertTrue(app.buttons["home.match.score"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "09-home-two-teams")

        // JD's own team now has members.
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.team.'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Riley Coach"].waitForExistence(timeout: 10))
        shot(app, "10-team-owner-members")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A member's view of the coach's team.
        app.buttons.matching(NSPredicate(format: "identifier == %@", "home.team.\(summitId)")).firstMatch.tap()
        XCTAssertTrue(app.buttons["team.leave"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "11-team-member-view")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Score the coach's match.
        XCTAssertTrue(app.buttons["home.match.score"].waitForExistence(timeout: 10))
        app.buttons["home.match.score"].tap()
        XCTAssertTrue(app.buttons["score.left"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        app.buttons["score.left"].tap()
        Thread.sleep(forTimeInterval: 2)
        shot(app, "12-scoring-team-match")
    }

    func testSettingsAndNewMatch() throws {
        try identity("jd@example.com", name: "JD Conley")
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["signIn.google"].waitForExistence(timeout: 15))
        signIn(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        shot(app, "13b-home")
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.signOut"].waitForExistence(timeout: 5))
        shot(app, "14-settings")
        app.buttons["Done"].tap()
        let newMatch = app.buttons["home.newMatch"].firstMatch
        XCTAssertTrue(newMatch.waitForExistence(timeout: 10))
        newMatch.tap()
        let team2 = app.textFields["newMatch.team2.name"]
        XCTAssertTrue(team2.waitForExistence(timeout: 5))
        team2.tap(); team2.typeText("Summit 14 Red\n")
        shot(app, "15-new-match")
        app.swipeUp()
        shot(app, "16-new-match-go-live")
        let goLive = app.buttons["newMatch.goLive"]
        if goLive.exists, goLive.isEnabled {
            goLive.tap()
            let watchLink = app.buttons["live.watchLink"]
            XCTAssertTrue(watchLink.waitForExistence(timeout: 40))
            Thread.sleep(forTimeInterval: 2)
            shot(app, "17-live-watch-link")
            watchLink.tap()
            Thread.sleep(forTimeInterval: 2)
            shot(app, "18-share-watch-link")
            // Close the share sheet, then end the match.
            XCUIApplication().swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 1)
            if app.buttons["Close"].exists { app.buttons["Close"].tap() }
            app.buttons["live.end"].tap()
            app.buttons["End match"].firstMatch.tap()
            XCTAssertTrue(app.buttons["matchOver.done"].waitForExistence(timeout: 30))
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["matchOver.done"])
            wait(for: [enabled], timeout: 60)
            app.buttons["matchOver.done"].tap()
        } else {
            app.buttons["Cancel"].tap()
        }
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        app.buttons["home.settings"].tap()
        app.buttons["settings.signOut"].tap()
        app.sheets.buttons["Sign out"].firstMatch.tap()
        XCTAssertTrue(app.buttons["signIn.google"].waitForExistence(timeout: 10))
    }

    // MARK: The local Worker's API, from the test runner

    private func identity(_ email: String, name: String) throws {
        _ = try request("POST", "/dev/identity", body: ["email": email, "name": name])
    }

    /// Runs the sign-in redirect chain without a browser and returns a session token.
    private func apiSignIn(_ email: String, name: String, invite: String? = nil) throws -> String {
        try identity(email, name: name)
        let verifier = String(repeating: "v", count: 43) + String(Int.random(in: 1000...9999))
        let challenge = Self.challenge(verifier)
        var components = URLComponents(url: api.appendingPathComponent("v1/auth/google/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "challenge", value: challenge)] + (invite.map { [URLQueryItem(name: "invite", value: $0)] } ?? [])
        var location = try redirect(components.url!)
        while location.scheme != "scorebug" { location = try redirect(location) }
        let ticket = try XCTUnwrap(URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ticket" }?.value,
                                   "sign-in for \(email) ended at \(location)")
        let session = try request("POST", "/v1/auth/session", body: ["ticket": ticket, "verifier": verifier])
        return try XCTUnwrap(session["token"] as? String)
    }

    private func call(_ method: String, _ path: String, token: String, body: [String: Any]) throws -> [String: Any] {
        try request(method, path, token: token, body: body)
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: api)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try send(request, follow: true)
        XCTAssertLessThan(response.statusCode, 400, "\(method) \(path): \(String(decoding: data, as: UTF8.self))")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func redirect(_ url: URL) throws -> URL {
        let (_, response) = try send(URLRequest(url: url), follow: false)
        let location = try XCTUnwrap(response.value(forHTTPHeaderField: "Location"), "no redirect from \(url)")
        return try XCTUnwrap(URL(string: location, relativeTo: url)?.absoluteURL)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private func send(_ request: URLRequest, follow: Bool) throws -> (Data, HTTPURLResponse) {
        let session = follow ? URLSession.shared : URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        var result: Result<(Data, HTTPURLResponse), Error>?
        let done = expectation(description: "request")
        session.dataTask(with: request) { data, response, error in
            if let data, let response = response as? HTTPURLResponse { result = .success((data, response)) }
            else { result = .failure(error ?? URLError(.badServerResponse)) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(result).get()
    }

    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

import XCTest

/// Walks every screen against a local server and saves a screenshot of each.
/// Simulator QA, run by hand (see ios/README.md):
///   SCOREBUG_TEST_TOUR=<dir>  where PNGs are written (also kept as test attachments)
///   SCOREBUG_TEST_LINK=<link> a fresh scorebug://connect or scorebug://join link
final class ScreenTourTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var directory: URL? {
        environment["SCOREBUG_TEST_TOUR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

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

    private func launch(reset: Bool, link: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_RESET"] = reset ? "1" : "0"
        if let link { app.launchEnvironment["SCOREBUG_TEST_LINK"] = link }
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, times: Int) {
        for _ in 0..<times { element.tap() }
    }

    /// Filming phone, part 1: connect → home → new match → live → set point → swap → invite.
    func testFilmingTourStart() throws {
        let link = try XCTUnwrap(environment["SCOREBUG_TEST_LINK"], "needs a fresh setup link")
        var app = launch(reset: true)
        XCTAssertTrue(app.staticTexts["Connect your server"].waitForExistence(timeout: 10))
        shot(app, "01-connect")
        app.buttons["connect.manual"].tap()
        XCTAssertTrue(app.textFields["connect.address"].waitForExistence(timeout: 5))
        shot(app, "02-connect-manual")
        app.terminate()

        app = launch(reset: false, link: link)
        XCTAssertTrue(app.buttons["link.confirm"].waitForExistence(timeout: 10))
        shot(app, "03-connect-confirm")
        app.buttons["link.confirm"].tap()
        XCTAssertTrue(app.buttons["home.newMatch"].waitForExistence(timeout: 15))
        _ = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'connected'")).firstMatch.waitForExistence(timeout: 5)
        shot(app, "04-home-first")

        app.buttons["home.newMatch"].tap()
        let team1 = app.textFields["newMatch.team1.name"]
        XCTAssertTrue(team1.waitForExistence(timeout: 5))
        team1.tap(); team1.typeText("Cascade 14 Black")
        let team2 = app.textFields["newMatch.team2.name"]
        team2.tap(); team2.typeText("Summit 14 Red\n")
        app.staticTexts["New match"].firstMatch.tap() // dismiss the keyboard
        shot(app, "05-new-match")
        app.swipeUp()
        shot(app, "06-new-match-bottom")
        app.buttons["newMatch.goLive"].tap()

        let left = app.buttons["live.tap.left"]
        XCTAssertTrue(left.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        shot(app, "07-live-start")
        let right = app.buttons["live.tap.right"]
        tap(right, times: 21)
        tap(left, times: 24)
        Thread.sleep(forTimeInterval: 2)
        shot(app, "08-live-scoring")
        left.tap()
        XCTAssertTrue(app.buttons["setPoint.confirm"].waitForExistence(timeout: 10))
        shot(app, "09-set-point")
        app.buttons["setPoint.confirm"].tap()
        XCTAssertTrue(app.buttons["swap.yes"].waitForExistence(timeout: 10))
        shot(app, "10-swap-sides")
        app.buttons["swap.yes"].tap()
        tap(app.buttons["live.tap.left"], times: 3)
        Thread.sleep(forTimeInterval: 2)
        shot(app, "11-live-set2-swapped")
        app.buttons["live.invite"].tap()
        XCTAssertTrue(app.staticTexts["invite.code"].waitForExistence(timeout: 10))
        shot(app, "12-invite")
        app.buttons["Done"].tap()
    }

    /// Second phone, joined through the invite link.
    func testScorerTour() throws {
        let link = try XCTUnwrap(environment["SCOREBUG_TEST_LINK"], "needs an invite link")
        let app = launch(reset: true)
        XCTAssertTrue(app.buttons["connect.join"].waitForExistence(timeout: 10))
        app.buttons["connect.join"].tap()
        XCTAssertTrue(app.textFields["join.code"].waitForExistence(timeout: 5))
        shot(app, "13-join")
        app.terminate()

        let joined = launch(reset: false, link: link)
        XCTAssertTrue(joined.buttons["link.confirm"].waitForExistence(timeout: 10))
        shot(joined, "14-join-confirm")
        joined.buttons["link.confirm"].tap()
        XCTAssertTrue(joined.buttons["score.left"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        joined.buttons["score.right"].tap()
        Thread.sleep(forTimeInterval: 2)
        shot(joined, "15-scorer")
    }

    /// Filming phone, part 2: the filming phone sees the other scorer, takes back, ends the match.
    func testFilmingTourFinish() throws {
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(app.buttons["live.end"].waitForExistence(timeout: 10))
        // A relaunch mid-match resumes recording.
        let recording = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'REC'"),
                                                  object: app.staticTexts["live.status"])
        wait(for: [recording], timeout: 30)
        Thread.sleep(forTimeInterval: 3)
        shot(app, "16-live-scoring-elsewhere")
        if app.buttons["live.takeOver"].exists { app.buttons["live.takeOver"].tap() }
        Thread.sleep(forTimeInterval: 2)
        app.buttons["live.end"].tap()
        let end = app.buttons["End match"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        shot(app, "17-end-confirm")
        end.tap()
        XCTAssertTrue(app.buttons["matchOver.done"].waitForExistence(timeout: 30))
        shot(app, "18-match-over-saving")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["matchOver.done"])
        wait(for: [enabled], timeout: 60)
        shot(app, "18-match-over")
        app.buttons["matchOver.done"].tap()
        XCTAssertTrue(app.buttons["home.recordings"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        shot(app, "19-home-last-match")
        app.buttons["home.recordings"].tap()
        Thread.sleep(forTimeInterval: 6)
        shot(app, "20-recordings")
    }
}

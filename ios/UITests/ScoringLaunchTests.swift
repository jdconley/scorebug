import XCTest

final class ScoringLaunchTests: XCTestCase {
    @MainActor
    func testScorerLaunchesAndValidatesSetupWithoutCameraPermission() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .camera)
        app.resetAuthorizationStatus(for: .microphone)
        app.launch()

        XCTAssertTrue(app.staticTexts["Native scoring foundation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["scoring.endpoint"].exists)
        app.buttons["scoring.validate"].tap()
        XCTAssertTrue(app.staticTexts["Address format is valid. Connection not tested."].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
}

import XCTest

/// Requires the paired-phone test to send an offer through real WatchConnectivity.
/// This test never receives a fixture envelope, endpoint, device ID or credential.
#if DEBUG
final class CompanionWatchScoringTests: XCTestCase {
    private var initialEvidenceAttached = false
    private var pendingEvidenceAttached = false
    /// Inspect saved identity without test-issued setup/scoring actions.
    /// Normal app restoration and receipt recovery still run on launch.
    @MainActor func testInspectPersistedSetup() throws {
        guard ProcessInfo.processInfo.environment["SCOREBUG_WATCH_INSPECT_SETUP"] == "1" else {
            throw XCTSkip("Explicit saved-setup inspection only.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 60
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_WATCH_SETUP"] = ""
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_DIAGNOSTICS"] = ""
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_PROBE"] = ""
        app.launch()
        XCTAssertTrue(app.buttons["watch.refresh"].waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(15)
        var current = try provenance(app)
        while (!current.ready || current.busy) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            current = try provenance(app)
        }
        let metadata = XCTAttachment(string: current.encoded)
        metadata.name = "Watch-inspected-setup-provenance"
        metadata.lifetime = .keepAlways; add(metadata)
        attach(app, "Watch saved setup inspection")
        XCTAssertTrue(current.ready && !current.busy, "Saved setup restoration did not settle.")
    }
    @MainActor func testScoreUsingRealCompanionSetup() throws {
        try runScoring(directFixture: nil)
    }
    @MainActor func testReconcileIdentifiedExpiredSetup() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let game = environment["SCOREBUG_RECONCILE_WATCH_GAME"],
              let pairing = environment["SCOREBUG_RECONCILE_WATCH_PAIRING"] else {
            throw XCTSkip("Requires an explicitly identified test-owned pending setup.")
        }
        let expected = try WatchSetupProvenance.Identity(gameID: game, pairingID: pairing)
        continueAfterFailure = false
        executionTimeAllowance = 60
        let app = XCUIApplication()
        app.launchEnvironment["SCOREBUG_TEST_WATCH_SETUP"] = ""
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_DIAGNOSTICS"] = ""
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_PROBE"] = ""
        app.launch()
        XCTAssertTrue(app.buttons["watch.refresh"].waitForExistence(timeout: 30))
        try tap(app, "watch.reconcilePairing") {
            let current = try self.provenance(app)
            XCTAssertTrue(current.ready && !current.busy && !current.scoringPending)
            XCTAssertEqual(current.pending, expected)
        }
        let deadline = Date().addingTimeInterval(20)
        var current = try provenance(app)
        while (current.setupPending || current.busy) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            current = try provenance(app)
        }
        let metadata = XCTAttachment(string: current.encoded)
        metadata.name = "Watch-reconciled-setup-provenance"
        metadata.lifetime = .keepAlways; add(metadata)
        attach(app, "Watch pairing reconciliation")
        XCTAssertTrue(current.ready && !current.busy && !current.setupPending && !current.scoringPending)
    }
    @MainActor func testScoreUsingSimulatorFixtureSetup() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_DIRECT_WATCH_SIMULATOR"] == "1" else {
            throw XCTSkip("Use the explicit watch-direct simulator lane.")
        }
        let expected = try WatchSetupProvenance.expectedGame(ProcessInfo.processInfo.environment["SCOREBUG_EXPECTED_WATCH_MATCH_ID"])
        let fixture = try WatchSetupProvenance.simulatorFixture(ProcessInfo.processInfo.environment["SCOREBUG_TEST_WATCH_SETUP"], expectedMatch: expected)
        try runScoring(directFixture: fixture)
        #else
        throw XCTSkip("Direct fixture setup is simulator-only.")
        #endif
    }
    @MainActor private func runScoring(directFixture: String?) throws {
        let direct = directFixture != nil
        let separate = direct && ProcessInfo.processInfo.environment["SCOREBUG_SEPARATE_WATCH_SCORER"] == "1"
        let initial = separate ? "1-1" : "0-0"
        let homePoint = separate ? "2-1" : "1-0"
        let awayPoint = separate ? "1-2" : "0-1"
        continueAfterFailure = false
        let expectedMatch = try WatchSetupProvenance.expectedGame(
            ProcessInfo.processInfo.environment["SCOREBUG_EXPECTED_WATCH_MATCH_ID"])
        #if targetEnvironment(simulator)
        let pairedOrdinary = ProcessInfo.processInfo.environment["SCOREBUG_PAIRED_ORDINARY_SIMULATOR"] == "1"
        #else
        let pairedOrdinary = false
        #endif
        // Only the opted-in paired simulator waits for phone preparation and
        // its unchanged 150-second adaptive gate before receiving the offer.
        executionTimeAllowance = pairedOrdinary || direct ? 600 : 420
        let app = XCUIApplication()
        // Explicitly defeat any inherited debug fixture from another test lane.
        app.launchEnvironment["SCOREBUG_TEST_WATCH_SETUP"] = directFixture ?? ""
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_DIAGNOSTICS"] = direct ? "" : "1"
        app.launchEnvironment["SCOREBUG_WATCH_CONNECTIVITY_PROBE"] = direct ? "" : "1"
        app.launch()
        let selected = try waitForOffer(app, expectedMatch: expectedMatch, timeout: pairedOrdinary ? 360 : 180)
        try tap(app, "watch.joinOffered") { try self.provenance(app).requireOffer(selected) }
        try waitForPairing(app, selected: selected)
        @MainActor func scoringIdentity() throws { try provenance(app).requirePaired(selected) }
        attach(app, direct ? "Watch accepted simulator fixture setup via real API" : "Watch accepted setup delivered by paired iPhone")
        if direct {
            let transport = XCTAttachment(string: "setupTransport=simulator-fixture; scoringTransport=direct-http; watchConnectivityQualified=false")
            transport.name = "watch-direct-transport"; transport.lifetime = .keepAlways; add(transport)
        }
        value(app.staticTexts["watch.score"], initial)
        try tap(app, "watch.takeover", beforeTap: scoringIdentity)
        try tap(app, "watch.homePoint", beforeTap: scoringIdentity)
        value(app.staticTexts["watch.score"], homePoint)
        if direct || pairedOrdinary || ProcessInfo.processInfo.environment["SCOREBUG_DEVICE_WATCH_SCORING"] == "1" {
            // Physical phone UI must observe the point and concurrent live
            // output before this runner proceeds to undo and match shutdown.
            RunLoop.current.run(until: Date().addingTimeInterval(30))
        }
        try tap(app, "watch.undo", beforeTap: scoringIdentity)
        value(app.staticTexts["watch.score"], initial)
        try tap(app, "watch.awayPoint", beforeTap: scoringIdentity)
        value(app.staticTexts["watch.score"], awayPoint)
        attach(app, "Watch scoring while companion records")
        if pairedOrdinary || direct {
            RunLoop.current.run(until: Date().addingTimeInterval(15))
        }
        if direct {
            app.terminate()
            // Explicit empty value defeats inherited runner fixture on relaunch.
            app.launchEnvironment["SCOREBUG_TEST_WATCH_SETUP"] = ""
            app.launch()
            try waitForPairing(app, selected: selected)
            value(app.staticTexts["watch.score"], awayPoint)
            attach(app, "Direct Watch restored exact persisted pairing and score without setup injection")
        }
        try tap(app, "watch.endMatch", beforeTap: scoringIdentity)
        // watchOS confirmation dialogs do not retain the SwiftUI identifiers.
        try tap(app, "End match", confirmation: true, beforeTap: scoringIdentity)
        XCTAssertTrue(app.staticTexts["Match ended"].waitForExistence(timeout: 30), app.debugDescription)
        attach(app, "Watch ended companion match")
    }

    private enum ProvenanceFailure: Error { case restorationNotReady, noCurrentOffer, pairingNotConfirmed }

    @MainActor private func provenance(_ app: XCUIApplication) throws -> WatchSetupProvenance {
        let metadata = app.buttons["watch.refresh"]
        guard metadata.exists, let encoded = metadata.value as? String else {
            throw WatchSetupProvenance.Invalid.metadata
        }
        let current = try WatchSetupProvenance(encoded: encoded)
        if !initialEvidenceAttached {
            let attachment = XCTAttachment(string: current.encoded)
            attachment.name = "Watch-initial-setup-provenance"
            attachment.lifetime = .keepAlways; add(attachment)
            initialEvidenceAttached = true
        }
        if (current.setupPending || current.pending != nil || current.scoringPending) && !pendingEvidenceAttached {
            let attachment = XCTAttachment(string: current.encoded)
            attachment.name = "Watch-pending-setup-provenance"
            attachment.lifetime = .keepAlways; add(attachment)
            pendingEvidenceAttached = true
        }
        return current
    }
    @MainActor private func waitForOffer(_ app: XCUIApplication, expectedMatch: String,
                                        timeout: Double) throws -> WatchSetupProvenance.Identity {
        guard app.buttons["watch.refresh"].waitForExistence(timeout: 30) else {
            throw WatchSetupProvenance.Invalid.metadata
        }
        let restorationEnd = Date().addingTimeInterval(30)
        while try !provenance(app).readyForOfferWait() {
            guard Date() < restorationEnd else { throw ProvenanceFailure.restorationNotReady }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // Runner barrier means only that we are waiting, never that an offer exists.
        print("SCOREBUG_WATCH_WAITING_FOR_EXPECTED_MATCH_OFFER")
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let selected = try provenance(app).matchingOffer(expected: expectedMatch) { return selected }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw ProvenanceFailure.noCurrentOffer
    }
    @MainActor private func waitForPairing(_ app: XCUIApplication, selected: WatchSetupProvenance.Identity) throws {
        guard app.buttons["watch.refresh"].waitForExistence(timeout: 30) else {
            throw WatchSetupProvenance.Invalid.metadata
        }
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let current = try provenance(app)
            // Only the just-accepted redemption may be pending here. The harness
            // never refreshes, reconciles or clears it; normal app recovery owns it.
            if current.scoringPending || (current.setupPending && current.pending != selected) {
                throw WatchSetupProvenance.Invalid.pendingState
            }
            if current.ready && !current.busy && !current.setupPending && current.pending == nil && current.paired == selected {
                try current.requirePaired(selected)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw ProvenanceFailure.pairingNotConfirmed
    }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String,
                                confirmation: Bool = false, timeout: Double = 30,
                                beforeTap: (@MainActor () throws -> Void)? = nil) throws {
        let button = confirmation ? app.tables.buttons[id] : app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), app.debugDescription)
        func fullyVisible() -> Bool {
            button.isHittable && button.frame.minY >= 40 && button.frame.maxY <= app.frame.maxY - 5
        }
        for _ in 0..<20 {
            if fullyVisible() { break }
            let below = button.frame.midY > app.frame.midY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.65 : 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.45 : 0.65))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        let ready = NSPredicate { _, _ in button.isEnabled && fullyVisible() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30), .completed, app.debugDescription)
        try beforeTap?()
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor private func value(_ element: XCUIElement, _ expected: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: element)], timeout: 30), .completed)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#else
final class CompanionWatchScoringTests: XCTestCase {
    func testReconcileIdentifiedExpiredSetup() throws {
        throw XCTSkip("Identified setup reconciliation requires DEBUG-only metadata.")
    }
    func testInspectPersistedSetup() throws {
        throw XCTSkip("Saved-setup inspection requires DEBUG-only metadata.")
    }
    func testScoreUsingRealCompanionSetup() throws {
        throw XCTSkip("Companion scoring requires DEBUG-only setup provenance metadata; Release never runs unguarded scoring.")
    }
    func testScoreUsingSimulatorFixtureSetup() throws {
        throw XCTSkip("Direct Watch fixture scoring requires a DEBUG simulator.")
    }
}
#endif

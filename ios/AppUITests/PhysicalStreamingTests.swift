import XCTest
import Network

// BEGIN RECOVERY GUARDS
/// Pure predicates shared by the UI workflow and host-compiled regression tests.
struct OrdinaryRecoverySample {
    enum Invalid: Error { case diagnostic }
    let diagnostic: [String: String]
    let started: Double
    let ended: Double
    let attempt: String
    let scope: String
    let owner: String?
    let revision: UInt64
    let acknowledgedAt: Double
    let observedAt: Double
    let sequence: Int64?
    let windowEnd: Double?

    init(_ diagnostic: [String: String], started: Double, ended: Double, previousReadEnd: Double, previousObserved: Double = 0) throws {
        func number(_ key: String) throws -> Double {
            guard let text = diagnostic[key], let value = Double(text), value.isFinite, value >= 0 else { throw Invalid.diagnostic }
            return value
        }
        guard started.isFinite, ended.isFinite, previousReadEnd.isFinite,
              started >= previousReadEnd, ended >= started, ended - started <= 5,
              diagnostic["sessionClosed"] == "false", diagnostic["driverClosed"] == "false",
              let attempt = diagnostic["policyAttemptID"], !attempt.isEmpty,
              let revisionText = diagnostic["policyAppliedRevision"], let revision = UInt64(revisionText) else { throw Invalid.diagnostic }
        let observed = try number("sessionObservedAtUptimeSeconds")
        let driverObserved = try number("observedAtUptimeSeconds")
        let acknowledgedAt = try number("policyAcknowledgedAtUptimeSeconds")
        guard previousObserved.isFinite, observed >= previousObserved, driverObserved <= ended, ended - driverObserved <= 5, observed <= driverObserved, ended - observed <= 5, acknowledgedAt <= observed else { throw Invalid.diagnostic }
        let owner = diagnostic["policyOwnerKey"]
        let scope = diagnostic["policySourceScopeKey"] ?? ""
        let sequence = diagnostic["policyAcceptedSourceSequence"].flatMap(Int64.init)
        let windowEnd = diagnostic["policyAcceptedSourceWindowEnd"].flatMap(Double.init)
        var maximumSourceAge = 5.0
        if let profile = diagnostic["timingProfileID"] {
            let budgets = ["strict1500-v1": 1500, "broadcast-reliability2000-v1": 2000,
                           "broadcast-reliability3000-v1": 3000, "broadcast-reliability3000-v3": 3000, "broadcast-reliability6000-v1": 6000]
            let allowance = profile == "broadcast-reliability3000-v3" ? 1250 : 500
            guard let budget = budgets[profile], diagnostic["decoderBudgetMilliseconds"] == String(budget),
                  diagnostic["captureWindowMaximumAgeMilliseconds"] == String(budget + allowance) else { throw Invalid.diagnostic }
            if profile == "broadcast-reliability3000-v3" {
                guard diagnostic["reportMaximumAgeMilliseconds"] == "1000" else { throw Invalid.diagnostic }
            }
            maximumSourceAge = max(5, Double(budget + allowance) / 1000)
        }
        if let owner {
            guard owner.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  scope.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let sequence, sequence >= 0, let windowEnd, windowEnd.isFinite,
                  windowEnd >= 0, windowEnd <= observed, observed - windowEnd <= maximumSourceAge else { throw Invalid.diagnostic }
        }
        self.diagnostic = diagnostic; self.started = started; self.ended = ended
        self.attempt = attempt; self.scope = scope; self.owner = owner; self.revision = revision
        self.observedAt = observed
        self.acknowledgedAt = acknowledgedAt; self.sequence = sequence; self.windowEnd = windowEnd
    }
    var unencumbered: Bool {
        diagnostic["sessionBusy"] == "false" &&
        diagnostic["policyRecommendationPending"] == "false" &&
        diagnostic["policyApplicationPending"] == "false" &&
        diagnostic["policyMinimumResetRequired"] == "false" &&
        diagnostic["policyTrialRollbackRequired"] != "true"
    }
    var isProbation: Bool {
        owner != nil && unencumbered && diagnostic["policyTrialActive"] == "true" &&
        diagnostic["policyTrialRollbackRequired"] == "false" &&
        diagnostic["policyTrialHealthyCoverageSeconds"].flatMap(Double.init).map { $0.isFinite && $0 >= 0 } == true
    }
    func acknowledges(profile: String, bitrate: Int, after: Double, newerThan: UInt64?) -> Bool {
        diagnostic["policyAppliedProfile"] == profile && diagnostic["policyAppliedBitrate"] == String(bitrate) &&
        acknowledgedAt > after && (newerThan.map { revision > $0 } ?? true)
    }
    func isInitialEncoderACK(after recordingStarted: Double) -> Bool {
        revision == 0 && unencumbered && diagnostic["policyTrialActive"] == "false" &&
        acknowledges(profile: "240p30", bitrate: 350000, after: recordingStarted, newerThan: nil)
    }
    func isInitialSourceReady(matching initial: Self) -> Bool {
        owner != nil && isInitialEncoderACK(after: 0) && initial.isInitialEncoderACK(after: 0) &&
        revision == initial.revision && attempt == initial.attempt && acknowledgedAt == initial.acknowledgedAt
    }
    func acknowledgesNext(profile: String, bitrate: Int, after: Double, revision previous: UInt64) -> Bool {
        previous < .max && revision == previous + 1 &&
        acknowledges(profile: profile, bitrate: bitrate, after: after, newerThan: previous)
    }
    func confirms(_ probation: Self) -> Bool {
        probation.isProbation && owner != nil && owner == probation.owner &&
        attempt == probation.attempt && scope == probation.scope && revision == probation.revision &&
        acknowledgedAt == probation.acknowledgedAt &&
        diagnostic["policyAppliedProfile"] == probation.diagnostic["policyAppliedProfile"] &&
        diagnostic["policyAppliedBitrate"] == probation.diagnostic["policyAppliedBitrate"] &&
        diagnostic["policyTrialActive"] == "false" && unencumbered &&
        (sequence ?? -1) > (probation.sequence ?? .max) &&
        (windowEnd ?? -1) > (probation.windowEnd ?? .infinity)
    }
}
// END RECOVERY GUARDS

/// Opt-in hardware smoke: the normal app launch selects IOSCameraCaptureSource.
/// Run only against a seeded, disposable HOME/AWAY match on a private LAN.
final class PhysicalStreamingTests: XCTestCase {
    private var evidencePrefix = "PhysicalStreaming"
    private var completedRecordingID: String?
    private var deadline = Date.distantPast
    private var scorerNetworkPermissionOnly = false
    private var runnerNetworkSettingReadOnly = false
    private enum SmokeFailure: Error { case failed(String) }

    @MainActor func testResetIdentifiedPhoneWatchRequest() throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let game = environment["SCOREBUG_RECONCILE_WATCH_GAME"],
              let pairing = environment["SCOREBUG_RECONCILE_WATCH_PAIRING"],
              UUID(uuidString: game) != nil, UUID(uuidString: pairing) != nil else {
            throw XCTSkip("Requires the exact identified test-owned phone setup request.")
        }
        executionTimeAllowance = 90; deadline = Date().addingTimeInterval(80)
        let app = XCUIApplication(); app.activate()
        try selectTab("Film", app)
        try wait("Film did not expose its capture state.", seconds: 10) {
            app.buttons["film.start"].exists || app.buttons["film.stop"].exists
        }
        try require(app.buttons["film.start"].exists && !app.buttons["film.stop"].exists && !app.buttons["streaming.stop"].exists,
                    "Preserve any existing recording or stream.")
        // Only after proving capture is idle, launch the installed diagnostic build.
        app.terminate(); app.launch()
        try selectTab("Watch", app)
        let button = app.buttons["phoneWatch.reset"]
        try require(button.waitForExistence(timeout: 10), "No saved phone setup request to reconcile.")
        let encoded = button.value as? String ?? ""
        let attachment = XCTAttachment(string: encoded)
        attachment.name = "Phone-pending-Watch-setup-provenance"; attachment.lifetime = .keepAlways; add(attachment)
        let identity = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
        try require(identity["gameID"] == game && identity["pairingID"]?.lowercased() == pairing.lowercased(),
                    "Saved request is not the identified test request; preserve it.")
        try tap(button, in: app)
        try wait("Saved test setup request did not clear.", seconds: 10) { !button.exists }
        evidence(app, phase: "identified-phone-watch-request-cleared", screenshot: true)
        #else
        throw XCTSkip("Guarded request recovery requires DEBUG identity metadata.")
        #endif
    }

    @MainActor func testPhysicalIPhoneCameraPublishScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone camera smoke is not a simulator test.")
        #else
        try runVertical(watchScoring: false)
        #endif
    }

    @MainActor func testPhysicalIPhoneWhileSeparateNativePhoneScores() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Separate scorer camera lane requires an actual iPhone camera.")
        #else
        guard ProcessInfo.processInfo.environment["SCOREBUG_PHYSICAL_SEPARATE_SCORER"] == "1" else {
            throw XCTSkip("Use the explicit separate native scorer launcher.")
        }
        evidencePrefix = "SeparateScorerCamera"
        try runVertical(watchScoring: false, separateScorer: true)
        #endif
    }

    @MainActor func testNativeCreatedSimulatorCameraWhileOtherPhoneScores() throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCOREBUG_NATIVE_CREATED_SIMULATOR"] == "1",
              environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1" else {
            throw XCTSkip("Use the explicit native-created two-phone simulator launcher.")
        }
        evidencePrefix = "NativeCreatedSimulatorCamera"
        try runVertical(watchScoring: false, ordinarySimulator: true, separateScorer: true)
        #else
        throw XCTSkip("Native-created file capture lane is simulator-only.")
        #endif
    }

    @MainActor func testSeparateNativeScorerWhileOtherPhonePublishes() throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCOREBUG_SEPARATE_NATIVE_SCORER"] == "1" else {
            throw XCTSkip("Use the dedicated disposable separate native scorer simulator launcher.")
        }
        guard let endpoint = explicitValue(environment["SCOREBUG_DEVICE_API_URL"]),
              let token = explicitValue(environment["SCOREBUG_DEVICE_TOKEN"]) else {
            throw SmokeFailure.failed("Separate scorer requires explicit app connection configuration.")
        }
        try require(isPrivateLANEndpoint(endpoint) || (environment["SCOREBUG_SEPARATE_WATCH_SCORER"] == "1" && isSimulatorLoopbackEndpoint(endpoint)), "Separate scorer requires an explicit local endpoint.")
        continueAfterFailure = true
        executionTimeAllowance = 480
        deadline = Date().addingTimeInterval(430)
        evidencePrefix = "SeparateNativeScorer"
        scorerNetworkPermissionOnly = true
        try prepareOrdinarySimulator()
        let app = XCUIApplication()
        app.launch()
        defer { separateScorerCheckpoint(app, role: "scorer", phase: "final-observation") }
        // This is the full app on a fresh owned simulator. Leave Film immediately;
        // no source injection, camera request, or runner-side network request.
        try selectTab("Score", app)
        try replace(app.textFields["scoring.endpoint"], with: endpoint, in: app)
        try replace(app.secureTextFields["scoring.token"], with: token, in: app)
        try tap(app.buttons["scoring.connect"], in: app)
        let nativeCreation = environment["SCOREBUG_NATIVE_CREATED_SIMULATOR"] == "1"
        if nativeCreation {
            try wait("Empty server did not expose native match creation.", seconds: 20) {
                self.allowExpectedPermissions()
                return app.buttons["scoring.create"].exists && app.buttons["scoring.create"].isEnabled
            }
            try require(!app.buttons["scoring.homePoint"].exists, "Unexpected existing match; no creation was attempted.")
            try replace(app.textFields["scoring.homeName"], with: "HOME", in: app)
            try replace(app.textFields["scoring.awayName"], with: "AWAY", in: app)
            try dismissSetupKeyboard(app)
            try tap(app.buttons["scoring.create"], in: app)
        }
        try wait("Separate scorer did not acknowledge its native match connection.", seconds: 20) {
            self.allowExpectedPermissions()
            return app.buttons["scoring.homePoint"].exists
        }
        try validateSeparateScore(app, allowed: ["0:0"])
        if nativeCreation {
            try require(app.buttons["scoring.homePoint"].isEnabled && app.buttons["scoring.awayPoint"].isEnabled,
                        "Native creator did not receive initial scoring ownership.")
        } else {
            try require(app.buttons["scoring.takeover"].exists && !app.buttons["scoring.homePoint"].isEnabled,
                        "Separate scorer must join without owning scoring.")
        }
        separateScorerCheckpoint(app, role: "scorer", phase: "ready", ready: true)
        // The coordinator launches the camera only after the ready attachment.
        try waitForSeparateScore(app, home: 1, away: 0, previous: "0:0", seconds: 240,
                                 requireWorker: true)
        separateScorerCheckpoint(app, role: "scorer", phase: "camera-home-observed", ready: true)
        try tap(app.buttons["scoring.takeover"], in: app)
        try wait("Separate scorer did not gain scoring control.", seconds: 12) {
            app.buttons["scoring.homePoint"].isEnabled && app.buttons["scoring.awayPoint"].isEnabled
        }
        try validateSeparateScore(app, allowed: ["1:0"])
        separateScorerCheckpoint(app, role: "scorer", phase: "takeover-acknowledged", ready: true)
        for (phase, action, away, previous, hold) in [
            ("away-point", "scoring.awayPoint", 1, "1:0", 12.0),
            ("undo", "scoring.undo", 0, "1:1", 12.0),
            ("final-away-point", "scoring.awayPoint", 1, "1:0", 30.0)
        ] {
            try validateSeparateScore(app, allowed: [previous])
            try require(separateWorkerLabel(app) == "Worker encoding video", "Worker was not fresh before the scorer action.")
            // Exactly one tap per action. A timeout fails rather than retrying.
            try tap(app.buttons[action], in: app)
            try waitForSeparateScore(app, home: 1, away: away, previous: previous, seconds: 12, requireWorker: true)
            separateScorerCheckpoint(app, role: "scorer", phase: phase + "-acknowledged", ready: true)
            try holdSeparateScore(app, home: 1, away: away, seconds: hold)
            separateScorerCheckpoint(app, role: "scorer", phase: phase + "-hold-complete", ready: true)
        }
        if environment["SCOREBUG_SEPARATE_WATCH_SCORER"] == "1" {
            separateScorerCheckpoint(app, role: "scorer", phase: "watch-ready", ready: true)
            try waitForSeparateWatchEnd(app, role: "scorer")
        }
        #else
        throw XCTSkip("Separate native scorer requires a disposable simulator.")
        #endif
    }

    @MainActor private func waitForSeparateWatchEnd(_ app: XCUIApplication, role: String) throws {
        try waitForSeparateScore(app, home: 2, away: 1, previous: "1:1", seconds: 90, requireWorker: true)
        try require(!app.buttons["scoring.homePoint"].isEnabled, "Watch takeover did not revoke phone scoring control.")
        separateScorerCheckpoint(app, role: role, phase: "watch-home-observed", ready: true)
        try wait("Watch AWAY point was not observed.", seconds: 90) {
            app.buttons["scoring.homePoint"].value as? String == "1" &&
            app.buttons["scoring.awayPoint"].value as? String == "2"
        }
        try require(separateWorkerLabel(app) == "Worker encoding video", "Worker stopped before Watch finished scoring.")
        separateScorerCheckpoint(app, role: role, phase: "watch-away-observed", ready: true)
        try wait("Watch did not end the match.", seconds: 60) { app.staticTexts["scoring.ended"].exists }
        separateScorerCheckpoint(app, role: role, phase: "watch-end-observed", ready: true)
    }

    @MainActor private func separateWorkerLabel(_ app: XCUIApplication) -> String {
        let status = app.staticTexts["scoring.broadcastStatus"]
        return status.exists ? status.label : "missing"
    }

    @MainActor private func separatePermissionAlertAbsent(_ app: XCUIApplication) -> Bool {
        !app.alerts.firstMatch.exists && !XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists
    }

    @MainActor private func validateSeparateScore(_ app: XCUIApplication, allowed: [String]) throws {
        let home = app.buttons["scoring.homePoint"], away = app.buttons["scoring.awayPoint"]
        try require(home.exists && away.exists && home.label == "Award point to HOME" && away.label == "Award point to AWAY" &&
                    !app.staticTexts["scoring.ended"].exists, "Separate scorer observed an unexpected or ended match.")
        let score = "\(home.value as? String ?? "missing"):\(away.value as? String ?? "missing")"
        try require(allowed.contains(score), "Separate scorer observed an unexpected score; no action was retried.")
        try require(separatePermissionAlertAbsent(app), "A permission or app alert covers the separate scoring workflow.")
    }

    @MainActor private func waitForSeparateScore(_ app: XCUIApplication, home: Int, away: Int, previous: String,
                                               seconds: Double, requireWorker: Bool = false, reserveTerminal: Bool = false, allowImmediatePeerPoint: Bool = false) throws {
        let end = min(deadline.addingTimeInterval(reserveTerminal ? -100 : 0), Date().addingTimeInterval(seconds))
        let target = "\(home):\(away)"
        while Date() < end {
            // Only the camera's initial HOME acknowledgment permits the peer's
            // immediate AWAY response. The subsequent three ordered gates stay exact.
            try validateSeparateScore(app, allowed: [previous, target] + (allowImmediatePeerPoint ? ["1:1"] : []))
            let observedAway = app.buttons["scoring.awayPoint"].value as? String
            let reached = app.buttons["scoring.homePoint"].value as? String == String(home) &&
                (observedAway == String(away) || (allowImmediatePeerPoint && observedAway == "1"))
            if reached && (!requireWorker || separateWorkerLabel(app) == "Worker encoding video") && Date() < end { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw SmokeFailure.failed("Separate scorer transition did not arrive within its finite gate.")
    }

    @MainActor private func holdSeparateScore(_ app: XCUIApplication, home: Int, away: Int, seconds: Double) throws {
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < seconds {
            try require(Date() < deadline, "Separate scorer hold exceeded its finite budget.")
            try validateSeparateScore(app, allowed: ["\(home):\(away)"])
            try require(separateWorkerLabel(app) == "Worker encoding video", "Worker status stopped being fresh during the scorer hold.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        try validateSeparateScore(app, allowed: ["\(home):\(away)"])
    }

    @MainActor private func separateScorerCheckpoint(_ app: XCUIApplication, role: String, phase: String, ready: Bool = false) {
        let statuses = ["Broadcast not requested", "Waiting for worker status", "Worker status unavailable", "Worker idle",
                        "Worker waiting for video source", "Worker starting", "Worker encoding video", "Worker stopping",
                        "Worker retrying", "Worker failed", "Worker closed", "missing"]
        let worker = separateWorkerLabel(app)
        func safeScore(_ id: String) -> String {
            let button = app.buttons[id]
            guard button.exists else { return "missing" }
            let score = button.value as? String ?? "missing"
            return ["0", "1", "2", "missing"].contains(score) ? score : "other"
        }
        let report: [String: Any] = ["role": role, "phase": phase, "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
                                   "home": safeScore("scoring.homePoint"), "away": safeScore("scoring.awayPoint"),
                                   "ready": ready, "status": statuses.contains(worker) ? worker : "other",
                                   "permissionAlertAbsent": separatePermissionAlertAbsent(app)]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "\(evidencePrefix)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor func testPhysicalPairedWatchWhileCameraPublishes() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical paired Watch smoke is not a simulator test.")
        #else
        guard ProcessInfo.processInfo.environment["SCOREBUG_DEVICE_WATCH_SCORING"] == "1" else {
            throw XCTSkip("Set SCOREBUG_DEVICE_WATCH_SCORING=1 and concurrently run the paired Watch companion test.")
        }
        try runVertical(watchScoring: true)
        #endif
    }

    @MainActor func testOrdinarySimulatorPublishScoreAdaptStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1" else {
            throw XCTSkip("Use the dedicated disposable ordinary simulator launcher.")
        }
        evidencePrefix = "OrdinarySimulatorStreaming"
        try runVertical(watchScoring: false, ordinarySimulator: true)
        #else
        throw XCTSkip("Ordinary file-source smoke requires a disposable simulator.")
        #endif
    }

    @MainActor func testOrdinarySimulatorQualify2160ScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_2160"] == "1" else {
            throw XCTSkip("Use the explicit quality2160 simulator lane.")
        }
        quality2160 = true; quality1080 = true; recovery720 = true; evidencePrefix = "Ordinary2160Streaming"
        defer { attachRecoveryEvidence() }
        do { try runVertical(watchScoring: false, ordinarySimulator: true, recovery: true) }
        catch { recoveryFailure = recoveryFailure ?? String(describing: error); throw error }
        #else
        throw XCTSkip("4K file-source qualification requires a disposable simulator.")
        #endif
    }

    @MainActor func testOrdinarySimulatorQualify1080ScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_1080"] == "1" else {
            throw XCTSkip("Use the explicit quality1080 simulator lane.")
        }
        quality1080 = true; recovery720 = true; evidencePrefix = "Ordinary1080Streaming"
        defer { attachRecoveryEvidence() }
        do { try runVertical(watchScoring: false, ordinarySimulator: true, recovery: true) }
        catch { recoveryFailure = recoveryFailure ?? String(describing: error); throw error }
        #else
        throw XCTSkip("1080 file-source qualification requires a disposable simulator.")
        #endif
    }

    @MainActor func testOrdinaryDirectWatchSimulatorAdaptScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_DIRECT_WATCH_SIMULATOR"] == "1" else {
            throw XCTSkip("Use the explicit disposable watch-direct simulator lane.")
        }
        evidencePrefix = "OrdinaryDirectWatchSimulatorStreaming"
        try runVertical(watchScoring: true, ordinarySimulator: true, directWatch: true)
        #else
        throw XCTSkip("Direct Watch fixture setup is simulator-only.")
        #endif
    }

    @MainActor func testOrdinaryPairedSimulatorAdaptWatchScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_PAIRED_ORDINARY_SIMULATOR"] == "1" else {
            throw XCTSkip("Use the explicit disposable paired ordinary simulator lane.")
        }
        evidencePrefix = "OrdinaryPairedSimulatorStreaming"
        try runVertical(watchScoring: true, ordinarySimulator: true)
        #else
        throw XCTSkip("Paired ordinary file-source smoke requires disposable simulators.")
        #endif
    }

    private var recoverySamples: [[String: Any]] = []
    private var recoveryGates: [[String: Any]] = []
    private var recoveryMilestones: [[String: Any]] = []
    private var recoveryExchanges: [[String: Any]] = []
    private var recoveryRecordingStarted: Double = 0
    private var recoveryRecordingDeadline: Double = 0
    private var recoveryLastObserved: Double = 0
    private var recoveryLastReadEnd: Double = 0
    private var recoveryLastSampleStart: Double = 0
    private var recoveryAttempt: String?
    private var recoveryScope: String?
    private var recoveryFailure: String?
    private var quality2160 = false
    private var quality1080 = false
    private var recovery720 = false
    private var physicalRecovery = false
    private var physicalInitialEncoderACK: OrdinaryRecoverySample?
    private var physicalLocalPublishingObserved: Double?
    private var physicalWorkerOutputObserved: Double?
    private var physicalEncoderDiagnosticReceived = false
    private var recoveryControlConfiguration: RecoveryControlConfiguration?
    private var loopbackStarted = false
    private var loopbackStopAttempted = false
    private var loopbackShutdown: [String: Any]?
    private var runnerTransport: String {
        ProcessInfo.processInfo.environment["SCOREBUG_RECOVERY_RUNNER_TRANSPORT"] ?? "direct"
    }

    private func recoveryMilestone(_ phase: String, sample: Bool = false, at uptime: Double? = nil) {
        var record: [String: Any] = ["phase": phase, "uptimeSeconds": uptime ?? ProcessInfo.processInfo.systemUptime]
        if sample { record["sampleIndex"] = recoverySamples.count - 1 }
        recoveryMilestones.append(record)
        print("SCOREBUG_RECOVERY_PHASE \(phase)")
    }
    private func attachRecoveryEvidence() {
        var report: [String: Any] = ["formatVersion": physicalRecovery ? 3 : recovery720 ? 2 : 1,
            "recordingStartedUptimeSeconds": recoveryRecordingStarted,
            "recordingDeadlineUptimeSeconds": recoveryRecordingDeadline,
            "samples": recoverySamples, "gates": recoveryGates,
            "milestones": recoveryMilestones, "exchanges": recoveryExchanges]
        if recovery720 { report["contract"] = physicalRecovery ? "physical-recovery720-v1" : "recovery720" }
        if quality1080 { report["contract"] = quality2160 ? "quality2160-v1" : "quality1080-v1" }
        if physicalRecovery {
            report["captureSource"] = "physical-camera"
            report["localPublishingObservedUptimeSeconds"] = physicalLocalPublishingObserved
            report["workerOutputObservedUptimeSeconds"] = physicalWorkerOutputObserved
        }
        report["runnerTransport"] = runnerTransport
        report["loopbackShutdown"] = loopbackShutdown
        report["failure"] = recoveryFailure
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "\(evidencePrefix)-recovery-phases"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    @MainActor private func recoverySample(_ app: XCUIApplication, phase: String) throws -> OrdinaryRecoverySample? {
        let started = ProcessInfo.processInfo.systemUptime
        if started - recoveryLastSampleStart < 2 { return nil }
        try require(recoverySamples.count < 270, "Recovery evidence sample limit exceeded.")
        recoveryLastSampleStart = started
        let encoded = value(app, "streaming.qualityDiagnostic")
        let ended = ProcessInfo.processInfo.systemUptime
        try require(started >= recoveryLastReadEnd && ended >= started && ended - started <= 5,
                    "Recovery accessibility clock bracket is invalid.")
        let previousEnd = recoveryLastReadEnd
        recoveryLastReadEnd = ended
        // Publishing can precede the first asynchronous diagnostic callback. Only
        // this explicit bootstrap absence may wait; received evidence keeps all guards.
        if physicalRecovery && phase == "initial-encoder-ack" && !physicalEncoderDiagnosticReceived && encoded == "missing" { return nil }
        try require(encoded.utf8.count <= 4096 && encoded != "missing", "Recovery diagnostic missing or oversized.")
        guard let data = encoded.data(using: .utf8),
              let diagnostic = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw SmokeFailure.failed("Recovery diagnostic is not a string dictionary.")
        }
        if physicalRecovery && phase == "initial-encoder-ack" { physicalEncoderDiagnosticReceived = true }
        recoverySamples.append(["phase": phase, "diagnostic": diagnostic,
            "readStartedUptimeSeconds": started, "readEndedUptimeSeconds": ended])
        if quality2160, diagnostic["lastMeasurementCandidateReason"] == "inputRejected",
           let cause = diagnostic["lastMeasurementEncoderFailure"] ?? diagnostic["lastMeasurementTransportFailure"] {
            throw SmokeFailure.failed("UHD candidate rejected input: \(cause)")
        }
        // A constrained path can temporarily leave no current accepted source.
        // Retain such samples but never let them acknowledge or confirm a phase.
        guard let sample = try? OrdinaryRecoverySample(diagnostic, started: started, ended: ended, previousReadEnd: previousEnd, previousObserved: recoveryLastObserved) else { return nil }
        recoveryLastObserved = sample.observedAt
        if let attempt = recoveryAttempt { try require(sample.attempt == attempt, "Publishing attempt restarted during recovery.") }
        else { recoveryAttempt = sample.attempt }
        if !sample.scope.isEmpty {
            if let scope = recoveryScope { try require(sample.scope == scope, "Publishing source scope changed during recovery.") }
            else { recoveryScope = sample.scope }
        }
        return sample
    }
    @MainActor private func recoveryWait(_ app: XCUIApplication, phase: String, seconds: Double, startedAt anchor: Double? = nil,
                                        accepts: (OrdinaryRecoverySample) throws -> Bool) throws -> OrdinaryRecoverySample {
        let now = ProcessInfo.processInfo.systemUptime
        let started = anchor ?? now
        try require(started.isFinite && started >= recoveryRecordingStarted && started <= now,
                    "Recovery gate has an invalid clock anchor.")
        recoveryGates.append(["phase": phase, "startedUptimeSeconds": started, "limitSeconds": seconds])
        // Reserve the existing live hold, stream stop and archive continuation.
        let end = min(started + seconds, recoveryRecordingDeadline - 45)
        while ProcessInfo.processInfo.systemUptime < end {
            if let sample = try recoverySample(app, phase: phase),
               sample.ended < end, try accepts(sample) { return sample }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw SmokeFailure.failed("Recovery \(phase) exceeded its finite gate.")
    }
    @MainActor private func recoveryIncrease(_ app: XCUIApplication, prefix: String, after: Double,
                                            previous: OrdinaryRecoverySample, profile: String = "360p30", bitrate: Int = 600000,
                                            consecutive: Bool = false) throws -> OrdinaryRecoverySample {
        let acknowledged = try recoveryWait(app, phase: "\(prefix)-increase", seconds: 150) { sample in
            if consecutive {
                try self.require(previous.revision < .max && sample.revision <= previous.revision + 1,
                                 "An intervening applied transition invalidated this climb.")
                return sample.acknowledgesNext(profile: profile, bitrate: bitrate, after: after, revision: previous.revision)
            }
            return sample.acknowledges(profile: profile, bitrate: bitrate, after: after, newerThan: previous.revision)
        }
        recoveryMilestone("\(prefix)-increase-acknowledged", sample: true)
        var probation: OrdinaryRecoverySample?
        if acknowledged.isProbation {
            probation = acknowledged; recoveryMilestone("\(prefix)-probation", sample: true)
        }
        let confirmed = try recoveryWait(app, phase: "\(prefix)-confirmation", seconds: 30) { sample in
            try self.require(sample.revision == acknowledged.revision && sample.acknowledgedAt == acknowledged.acknowledgedAt,
                             "Trial revision changed before confirmation.")
            if let probation {
                try self.require(sample.owner == probation.owner, "Trial owner changed before confirmation.")
                return sample.confirms(probation)
            }
            if sample.isProbation {
                probation = sample; self.recoveryMilestone("\(prefix)-probation", sample: true)
            }
            return false
        }
        try require(confirmed.owner != previous.owner, "Changed revision reused the prior trial owner.")
        recoveryMilestone("\(prefix)-confirmed", sample: true)
        return confirmed
    }
    private final class RecoveryResponse: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (Data?, URLResponse?, Error?)?
        func set(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
            lock.lock(); defer { lock.unlock() }; result = (data, response, error)
        }
        func get() -> (Data?, URLResponse?, Error?)? {
            lock.lock(); defer { lock.unlock() }; return result
        }
    }
    private final class NetworkProbeMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let started: Date
        private var records: [[String: Any]] = []
        init(started: Date) { self.started = started }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let records: [[String: Any]] = metrics.transactionMetrics.prefix(4).map { transaction in
                let proto = transaction.networkProtocolName ?? "missing"
                var row: [String: Any] = ["protocol": ["http/1.0", "http/1.1", "h2", "h3"].contains(proto) ? proto : "other",
                                          "isProxyConnection": transaction.isProxyConnection]
                for (key, value) in [("connectStartOffsetSeconds", transaction.connectStartDate),
                                     ("connectEndOffsetSeconds", transaction.connectEndDate),
                                     ("requestStartOffsetSeconds", transaction.requestStartDate),
                                     ("requestEndOffsetSeconds", transaction.requestEndDate),
                                     ("responseStartOffsetSeconds", transaction.responseStartDate),
                                     ("responseEndOffsetSeconds", transaction.responseEndDate)] {
                    if let value { row[key] = value.timeIntervalSince(started) }
                }
                return row
            }
            lock.lock(); self.records = records; lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // Probe only the validated endpoint; never forward credentials.
        }
        func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return records }
    }
    private final class NetworkProbeTCPState: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [[String: Any]] = []
        private var finished = false
        let cancelled = DispatchSemaphore(value: 0)
        func observe(_ state: NWConnection.State, path: NWPath?, started: Double) {
            let label: String
            switch state {
            case .setup: label = "setup"
            case .preparing: label = "preparing"
            case .waiting: label = "waiting"
            case .ready: label = "ready"
            case .failed: label = "failed"
            case .cancelled: label = "cancelled"
            @unknown default: label = "unknown"
            }
            var event: [String: Any] = ["state": label, "offsetSeconds": ProcessInfo.processInfo.systemUptime - started]
            if let path {
                switch path.status {
                case .satisfied: event["pathStatus"] = "satisfied"
                case .unsatisfied: event["pathStatus"] = "unsatisfied"
                case .requiresConnection: event["pathStatus"] = "requiresConnection"
                @unknown default: event["pathStatus"] = "unknown"
                }
                switch path.unsatisfiedReason {
                case .notAvailable: event["unsatisfiedReason"] = "notAvailable"
                case .cellularDenied: event["unsatisfiedReason"] = "cellularDenied"
                case .wifiDenied: event["unsatisfiedReason"] = "wifiDenied"
                case .localNetworkDenied: event["unsatisfiedReason"] = "localNetworkDenied"
                @unknown default: event["unsatisfiedReason"] = "unknown"
                }
            }
            lock.lock()
            if events.count < 12 { events.append(event) }
            if ["ready", "failed", "cancelled"].contains(label) { finished = true }
            lock.unlock()
            if label == "cancelled" { cancelled.signal() }
        }
        func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
        func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return events }
    }
    @MainActor private func probeHTTP(_ url: URL, token: String?, controller: Bool) -> (Bool, [String: Any]) {
        let started = ProcessInfo.processInfo.systemUptime
        let metrics = NetworkProbeMetrics(started: Date())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: metrics, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let response = RecoveryResponse()
        session.dataTask(with: request) { data, value, error in response.set(data, value, error) }.resume()
        while response.get() == nil && ProcessInfo.processInfo.systemUptime - started < 10 {
            allowExpectedPermissions()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let ended = ProcessInfo.processInfo.systemUptime
        let result = response.get()
        let http = result?.1 as? HTTPURLResponse
        var report: [String: Any] = ["operation": controller ? "controller-root" : "api-root",
            "startedUptimeSeconds": started, "endedUptimeSeconds": ended,
            "completed": result != nil, "metrics": metrics.snapshot()]
        if let http { report["httpStatus"] = http.statusCode }
        func errorScalars(_ error: NSError) -> [String: Any] {
            let domains = [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                           "kCFErrorDomainCFNetwork", "kCFErrorDomainPOSIX", "kCFErrorDomainOSStatus"]
            var scalars: [String: Any] = ["domain": domains.contains(error.domain) ? error.domain : "other", "code": error.code]
            for key in ["_kCFStreamErrorDomainKey", "_kCFStreamErrorCodeKey"] {
                if let number = error.userInfo[key] as? NSNumber { scalars[key] = number.intValue }
            }
            return scalars
        }
        if let error = result?.2 as NSError? {
            report["error"] = errorScalars(error)
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                report["underlyingError"] = errorScalars(underlying)
            }
        }
        var accepted = result != nil && result?.2 == nil && http != nil && ended - started <= 10
        if runnerTransport == "app-loopback" {
            let forwarded = http?.value(forHTTPHeaderField: "X-Scorebug-Loopback-Upstream") == "1"
            report["appUpstreamResponse"] = forwarded
            accepted = accepted && forwarded
        }
        if controller {
            let body = result?.0.flatMap { data -> [String: String]? in
                guard data.count <= 4096 else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            }
            accepted = accepted && http?.statusCode == 404 && body == ["error": "Unknown operation"]
        }
        report["accepted"] = accepted
        return (accepted, report)
    }
    @MainActor private func startPhysicalLoopbackIfRequested(_ app: XCUIApplication) throws {
        guard runnerTransport == "app-loopback" else { return }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        _ = try RecoveryLoopbackConfiguration(environment: environment)
        // Relaunch is only safe after observing the normal app's actual idle UI.
        try wait("Capture must be idle before bridge activation.", seconds: 10) {
            app.buttons["film.start"].exists && app.buttons["film.start"].isEnabled
        }
        try require(!app.buttons["film.stop"].exists && !app.buttons["streaming.stop"].exists &&
                    app.buttons["film.start"].isEnabled,
                    "Existing capture prevents bridge activation; existing state was preserved.")
        app.launchArguments = []
        app.launchEnvironment = environment.filter { RecoveryLoopbackConfiguration.environmentKeys.contains($0.key) }
        loopbackStarted = true
        app.launch()
        try selectTab("Film", app)
        try wait("Debug bridge app did not become ready.", seconds: 12) {
            app.state == .runningForeground && app.buttons["film.start"].exists &&
                app.buttons["film.start"].isEnabled && !app.buttons["film.stop"].exists &&
                !app.buttons["streaming.stop"].exists
        }
        #else
        throw SmokeFailure.failed("App loopback requires a Debug app and runner.")
        #endif
    }

    /// Independent from capture cleanup; does not terminate or relaunch the app.
    @MainActor private func stopPhysicalLoopback() {
        guard loopbackStarted, !loopbackStopAttempted else { return }
        loopbackStopAttempted = true
        let started = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = ["attempted": true, "startedUptimeSeconds": started]
        defer {
            report["endedUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
            loopbackShutdown = report
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "PhysicalRecoveryLoopbackShutdown"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        do {
            let control = try RecoveryControlConfiguration(environment: ProcessInfo.processInfo.environment, allowLAN: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 4; configuration.timeoutIntervalForResource = 4
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration, delegate: NetworkProbeMetrics(started: Date()), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: control.endpoint.appendingPathComponent("stop"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(control.token)", forHTTPHeaderField: "Authorization")
            let response = RecoveryResponse()
            session.dataTask(with: request) { data, value, error in response.set(data, value, error) }.resume()
            while response.get() == nil && ProcessInfo.processInfo.systemUptime - started < 5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let result = response.get()
            let acknowledged = result?.2 == nil && (result?.1 as? HTTPURLResponse)?.statusCode == 200 &&
                result?.0 == Data("{\"stopped\":true}".utf8)
            report["acknowledged"] = acknowledged
            try require(acknowledged, "Debug loopback shutdown was not acknowledged.")
            let refused = RecoveryResponse()
            var check = URLRequest(url: control.endpoint)
            check.setValue("Bearer \(control.token)", forHTTPHeaderField: "Authorization")
            session.dataTask(with: check) { data, value, error in refused.set(data, value, error) }.resume()
            let end = ProcessInfo.processInfo.systemUptime + 5
            while refused.get() == nil && ProcessInfo.processInfo.systemUptime < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let error = refused.get()?.2 as NSError?
            let closed = error?.domain == NSURLErrorDomain && error?.code == NSURLErrorCannotConnectToHost
            report["listenerClosed"] = closed
            try require(closed, "Debug loopback listener closure could not be verified.")
        } catch {
            report["failed"] = true
            XCTFail("Debug loopback shutdown failed; inspect shutdown evidence.")
        }
    }

    @MainActor func testPhysicalRecoveryNetworkProbe() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical network probe requires an actual iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCOREBUG_PHYSICAL_NETWORK_PROBE"] == "1" else {
            throw XCTSkip("Use the explicit physical network probe launcher.")
        }
        let control = try RecoveryControlConfiguration(environment: environment, allowLAN: true)
        guard let endpoint = environment["SCOREBUG_DEVICE_API_URL"], isPrivateLANEndpoint(endpoint),
              var api = URLComponents(string: endpoint),
              let runnerID = Bundle.main.bundleIdentifier, runnerID == "live.scorebug.app.uitests.xctrunner" else {
            throw SmokeFailure.failed("Physical network probe configuration invalid.")
        }
        api.path = "/"; api.query = nil; api.fragment = nil
        guard let apiRoot = api.url else { throw SmokeFailure.failed("Physical network probe API root invalid.") }
        deadline = Date().addingTimeInterval(75)
        executionTimeAllowance = 90
        let app = XCUIApplication(); app.activate()
        defer { stopPhysicalLoopback() }
        try selectTab("Film", app)
        try wait("Film did not become ready for network probe.", seconds: 12) {
            app.buttons["film.start"].exists || app.buttons["film.stop"].exists
        }
        try require(!app.buttons["film.stop"].exists && !app.buttons["streaming.stop"].exists,
                    "Existing capture prevents network probe; existing state was preserved.")
        try startPhysicalLoopbackIfRequested(app)
        let runner = XCUIApplication(bundleIdentifier: runnerID)
        try require(runner.state == .runningBackground || runner.state == .runningForeground,
                    "Network probe requires the existing test runner process.")
        defer { app.activate() }
        if runnerTransport == "direct" {
            runner.activate()
            try wait("Network probe runner did not enter foreground.", seconds: 10) { runner.state == .runningForeground }
        }
        let apiProbeURL = runnerTransport == "app-loopback" ? control.endpoint.appendingPathComponent("api-health") : apiRoot
        let apiResult = probeHTTP(apiProbeURL, token: runnerTransport == "app-loopback" ? control.token : nil, controller: false)
        let controllerResult = probeHTTP(control.endpoint, token: control.token, controller: true)
        var report: [String: Any] = ["formatVersion": 1, "runnerTransport": runnerTransport, "requests": [apiResult.1, controllerResult.1]]
        if !controllerResult.0, let host = control.endpoint.host, let port = control.endpoint.port,
           let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) {
            let started = ProcessInfo.processInfo.systemUptime
            let state = NetworkProbeTCPState()
            let queue = DispatchQueue(label: "scorebug.physical-network-probe")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            connection.stateUpdateHandler = { [weak connection] update in
                state.observe(update, path: connection?.currentPath, started: started)
            }
            connection.start(queue: queue)
            while !state.isFinished() && ProcessInfo.processInfo.systemUptime - started < 5 {
                allowExpectedPermissions()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            connection.cancel()
            let joined = state.cancelled.wait(timeout: .now() + 2) == .success
            queue.sync { connection.stateUpdateHandler = nil }
            report["tcp"] = ["startedUptimeSeconds": started, "endedUptimeSeconds": ProcessInfo.processInfo.systemUptime,
                             "events": state.snapshot(), "cancelJoined": joined]
        }
        stopPhysicalLoopback()
        report["loopbackShutdown"] = loopbackShutdown
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try require(data.count <= 16384, "Network probe attachment exceeded its bound.")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "PhysicalRecoveryNetworkProbe-results"; attachment.lifetime = .keepAlways; add(attachment)
        try require(apiResult.0 && controllerResult.0, "Physical network probe HTTP checks failed; inspect bounded diagnostic attachment.")
        #endif
    }
    @MainActor func testPhysicalRunnerNetworkSetting() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Runner network-setting inspection requires an actual iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["SCOREBUG_PHYSICAL_NETWORK_SETTING"] == "1" else {
            throw XCTSkip("Use the explicit physical runner network-setting launcher.")
        }
        executionTimeAllowance = 180
        let totalDeadline = Date().addingTimeInterval(150)
        deadline = totalDeadline.addingTimeInterval(-15) // Reserve foreground restoration.
        runnerNetworkSettingReadOnly = true
        let expectedRunner = "live.scorebug.app.uitests.xctrunner"
        let target = "ScorebugAppUITests-Runner"
        let app = XCUIApplication()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        var visitedSettings = false, found = false, restored = false
        var phase = "runner-identity", normalized = "unknown"
        defer {
            if visitedSettings {
                app.activate()
                let restoreEnd = min(totalDeadline, Date().addingTimeInterval(10))
                while app.state != .runningForeground && Date() < restoreEnd {
                    RunLoop.current.run(until: min(restoreEnd, Date().addingTimeInterval(0.2)))
                }
                restored = app.state == .runningForeground
                if !restored {
                    phase = "foreground-restoration-failed"
                    XCTFail("Scorebug foreground restoration failed after read-only Settings inspection.")
                }
            }
            runnerNetworkSettingReadOnly = false
            let report: [String: Any] = ["phase": phase, "expectedRunnerBundleID": expectedRunner,
                                       "expectedEntry": target, "entryFound": found, "value": normalized,
                                       "settingsVisited": visitedSettings, "scorebugRestored": restored]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), data.count <= 4096 {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "PhysicalRunnerNetworkSetting-result"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        try require(Bundle.main.bundleIdentifier == expectedRunner, "Runner network-setting identity mismatch.")
        phase = "capture-preflight"
        app.activate()
        if app.buttons["streaming.closeSetup"].exists {
            try tap(app.buttons["streaming.closeSetup"], in: app,
                    failure: "Scorebug setup could not be dismissed for read-only inspection.")
        }
        try selectTab("Film", app)
        try wait("Film did not become ready for read-only inspection.", seconds: 12) {
            app.buttons["film.start"].exists || app.buttons["film.stop"].exists
        }
        try require(!app.buttons["film.stop"].exists && !app.buttons["streaming.stop"].exists,
                    "Existing capture prevents Settings inspection; existing state was preserved.")
        try enforceScorerPermissionPolicy()
        phase = "settings-navigation"
        visitedSettings = true
        settings.activate()
        try wait("Settings did not enter foreground for read-only inspection.", seconds: 10) {
            settings.state == .runningForeground
        }
        // Normal navigation only. An unfamiliar page without an allowlisted
        // navigation-bar back control fails closed; no URLs or guessed taps.
        for _ in 0..<5 {
            try enforceScorerPermissionPolicy()
            if settings.navigationBars["Settings"].exists { break }
            let back = settings.navigationBars.buttons.matching(NSPredicate(
                format: "identifier == %@ OR label == %@ OR label == %@", "Back", "Settings", "Privacy & Security"))
            try require(back.count == 1 && back.firstMatch.isEnabled && back.firstMatch.isHittable && Date() < deadline,
                        "Settings navigation is not recognized; inspection is inconclusive.")
            back.firstMatch.tap()
        }
        try require(settings.navigationBars["Settings"].exists, "Settings root was not reached; inspection is inconclusive.")
        try openRunnerNetworkSettingsPage("Privacy & Security", from: "Settings", in: settings)
        phase = "privacy-navigation"
        try openRunnerNetworkSettingsPage("Local Network", from: "Privacy & Security", in: settings)
        phase = "entry-search"
        // Query only the exact runner label, never the Scorebug app's switch or
        // an enumeration of installed apps. Missing after this bound is unknown.
        for direction in [false, true] {
            for step in 0..<9 {
                try require(Date() < deadline, "Runner entry search exceeded its bound; inspection is inconclusive.")
                try enforceScorerPermissionPolicy()
                try require(settings.navigationBars["Local Network"].exists,
                            "Local Network page changed; inspection is inconclusive.")
                let exact = NSPredicate(format: "label == %@", target)
                let direct = settings.switches.matching(exact)
                let rows = settings.cells.containing(.staticText, identifier: target)
                let labels = settings.staticTexts.matching(exact)
                found = direct.count > 0 || labels.count > 0
                if found {
                    var toggle: XCUIElement?
                    if direct.count == 1 { toggle = direct.firstMatch }
                    else if direct.count == 0 && rows.count == 1 && rows.firstMatch.switches.count == 1 {
                        toggle = rows.firstMatch.switches.firstMatch
                    }
                    if let toggle {
                        // Only normalized scalars leave the device UI inspection.
                        switch (toggle.value as? String)?.lowercased() {
                        case "1", "on": normalized = "on"
                        case "0", "off": normalized = "off"
                        default: normalized = "unknown"
                        }
                    }
                    try enforceScorerPermissionPolicy()
                    phase = normalized == "unknown" ? "inconclusive-value" : "observed"
                    return
                }
                if step < 8 { try scrollRunnerNetworkSettings(settings, up: direction) }
            }
        }
        phase = "inconclusive-entry-not-found"
        #endif
    }

    @MainActor private func openRunnerNetworkSettingsPage(_ target: String, from source: String,
                                                         in settings: XCUIApplication) throws {
        for direction in [false, true] {
            for step in 0..<7 {
                try enforceScorerPermissionPolicy()
                try require(Date() < deadline && settings.navigationBars[source].exists,
                            "Settings page is not recognized or timed out; inspection is inconclusive.")
                let label = settings.staticTexts.matching(NSPredicate(format: "label == %@", target)).firstMatch
                if label.exists && label.isHittable {
                    label.tap()
                    try wait("Expected Settings page did not open; inspection is inconclusive.", seconds: 8) {
                        settings.navigationBars[target].exists
                    }
                    return
                }
                if step < 6 { try scrollRunnerNetworkSettings(settings, up: direction) }
            }
        }
        throw SmokeFailure.failed("Expected Settings navigation entry was not found; inspection is inconclusive.")
    }

    @MainActor private func scrollRunnerNetworkSettings(_ settings: XCUIApplication, up: Bool) throws {
        try enforceScorerPermissionPolicy()
        try require(Date() < deadline, "Settings search exceeded its bound; inspection is inconclusive.")
        var recognizedContainer: XCUIElement?
        try wait("Settings list did not become accessible; inspection is inconclusive.", seconds: 8) {
            for candidate in [settings.tables.firstMatch, settings.collectionViews.firstMatch, settings.scrollViews.firstMatch]
                where candidate.exists && candidate.isHittable {
                recognizedContainer = candidate
                return true
            }
            return false
        }
        guard let container = recognizedContainer else {
            throw SmokeFailure.failed("Settings list is not recognized; inspection is inconclusive.")
        }
        if up { container.swipeUp() } else { container.swipeDown() }
    }

    @MainActor private func preflightPhysicalRecoveryControl(_ app: XCUIApplication) throws {
        guard let control = recoveryControlConfiguration,
              let runnerID = Bundle.main.bundleIdentifier,
              runnerID == "live.scorebug.app.uitests.xctrunner",
              runnerID.hasSuffix(".xctrunner") else {
            throw SmokeFailure.failed("Physical recovery controller configuration missing.")
        }
        let runner = XCUIApplication(bundleIdentifier: runnerID)
        try require(app.state == .runningForeground &&
                    (runner.state == .runningBackground || runner.state == .runningForeground),
                    "Physical preflight requires the existing app and test runner processes.")
        // TN3179: an undetermined LAN privilege is denied without a prompt
        // while the requesting process is in the background. Foreground the
        // actual runner for its nonmutating request, then restore this app.
        defer { app.activate() }
        if runnerTransport == "direct" {
            runner.activate()
            try wait("Physical test runner did not enter the foreground.", seconds: 10) {
                runner.state == .runningForeground
            }
        }
        // Resolve the runner's first local-network permission before recording
        // and before any timed mutation. This endpoint cannot change lab state.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: control.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(control.token)", forHTTPHeaderField: "Authorization")
        let response = RecoveryResponse()
        let end = ProcessInfo.processInfo.systemUptime + 20
        session.dataTask(with: request) { data, value, error in
            response.set(data, value, error)
        }.resume()
        while response.get() == nil && ProcessInfo.processInfo.systemUptime < end {
            allowExpectedPermissions()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard ProcessInfo.processInfo.systemUptime <= end,
              let result = response.get(), result.2 == nil,
              let http = result.1 as? HTTPURLResponse, http.statusCode == 404,
              let data = result.0, data.count <= 4096,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: String],
              body == ["error": "Unknown operation"] else {
            throw SmokeFailure.failed("Physical recovery controller preflight failed before recording.")
        }
    }
    @MainActor private func recoveryRequest(_ operation: String, sequence: Int, sample: OrdinaryRecoverySample) throws -> Double {
        let control: RecoveryControlConfiguration
        do {
            if let recoveryControlConfiguration { control = recoveryControlConfiguration }
            else { control = try RecoveryControlConfiguration(environment: ProcessInfo.processInfo.environment) }
        } catch {
            throw SmokeFailure.failed("Private recovery controller configuration missing or invalid.")
        }
        let base = control.endpoint, token = control.token, runID = control.runID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4; configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent(operation))
        request.httpMethod = "POST"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["runID": runID, "sequence": sequence, "diagnostic": sample.diagnostic])
        let response = RecoveryResponse(), done = XCTestExpectation(description: "Owned recovery controller response")
        let started = ProcessInfo.processInfo.systemUptime
        try require(started - sample.ended <= 2, "Recovery mutation diagnostic became stale.")
        session.dataTask(with: request) { data, value, error in
            response.set(data, value, error); done.fulfill()
        }.resume()
        let waitResult = XCTWaiter.wait(for: [done], timeout: 5)
        let ended = ProcessInfo.processInfo.systemUptime
        var exchange: [String: Any] = ["sequence": sequence, "operation": operation, "runnerTransport": runnerTransport,
            "requestStartedUptimeSeconds": started, "responseEndedUptimeSeconds": ended]
        defer { recoveryExchanges.append(exchange) }
        guard waitResult == .completed, ended >= started, ended - started <= 5,
              let result = response.get(), result.2 == nil,
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200,
              let data = result.0, data.count <= 4096,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmokeFailure.failed("Recovery controller failed; uncertain mutations are never retried.")
        }
        exchange["response"] = body
        try require(body["runID"] as? String == runID && body["sequence"] as? Int == sequence &&
                    body["phase"] as? String == (operation == "constrain" ? "constrained" : "restored"),
                    "Recovery controller returned an unexpected phase receipt.")
        return ended
    }
    @MainActor private func runOrdinaryRecovery(_ app: XCUIApplication) throws {
        let minimum: OrdinaryRecoverySample
        if physicalRecovery {
            guard let initial = physicalInitialEncoderACK, let output = physicalWorkerOutputObserved else {
                throw SmokeFailure.failed("Physical startup lacks its encoder ACK or worker-output anchor.")
            }
            // Source ownership needs two completed 5s decoder windows. The explicit
            // 30s acquisition phase leaves production cadence and freshness unchanged.
            minimum = try recoveryWait(app, phase: "initial-source-ready", seconds: 30, startedAt: output) {
                $0.isInitialSourceReady(matching: initial)
            }
            recoveryMilestone("initial-source-ready", sample: true)
        } else {
            minimum = try recoveryWait(app, phase: "initial-minimum", seconds: 10) {
                $0.owner != nil && $0.unencumbered && $0.diagnostic["policyTrialActive"] == "false" &&
                $0.acknowledges(profile: "240p30", bitrate: 350000, after: self.recoveryRecordingStarted, newerThan: nil)
            }
            recoveryMilestone("initial-minimum", sample: true)
        }
        let first = try recoveryIncrease(app, prefix: recovery720 ? "initial-360" : "initial",
            after: recovery720 ? minimum.ended : minimum.acknowledgedAt, previous: minimum, consecutive: recovery720)
        let increased = recovery720 ? try recoveryIncrease(app, prefix: "initial-720", after: first.ended,
            previous: first, profile: "720p30", bitrate: 3000000, consecutive: true) : first
        if quality1080 {
            let fullHD = try recoveryIncrease(app, prefix: "initial-1080", after: increased.ended,
                previous: increased, profile: "1080p30", bitrate: 6000000, consecutive: true)
            if quality2160 {
                _ = try recoveryIncrease(app, prefix: "initial-2160", after: fullHD.ended,
                    previous: fullHD, profile: "2160p30", bitrate: 24000000, consecutive: true)
            }
            return
        }
        let constrainedAt = try recoveryRequest("constrain", sequence: 1, sample: increased)
        var constrainedRevision = increased.revision
        var constrainedBitrate = Int(increased.diagnostic["policyAppliedBitrate"] ?? "") ?? 0
        let fallback = try recoveryWait(app, phase: "fallback", seconds: 60) { sample in
            if self.recovery720, sample.revision > constrainedRevision {
                let bitrate = Int(sample.diagnostic["policyAppliedBitrate"] ?? "") ?? 0
                let witness = sample.diagnostic["appliedTransition"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
                try self.require(bitrate > 0 && bitrate <= constrainedBitrate &&
                    witness?["kind"] != "trial" && witness?["kind"] != "increase",
                    "Observed quality increase while constrained.")
                constrainedRevision = sample.revision; constrainedBitrate = bitrate
                self.recoveryMilestone("fallback-intermediate-acknowledged", sample: true)
            }
            return sample.owner != nil && sample.unencumbered && sample.diagnostic["policyTrialActive"] == "false" &&
                sample.acknowledges(profile: "240p30", bitrate: 350000, after: constrainedAt, newerThan: increased.revision)
        }
        try require(fallback.owner != increased.owner, "Fallback revision reused the increase owner.")
        recoveryMilestone("fallback-acknowledged", sample: true)
        let restoredAt = try recoveryRequest("restore", sequence: 2, sample: fallback)
        let recovered = try recoveryIncrease(app, prefix: recovery720 ? "recovery-360" : "recovery",
            after: restoredAt, previous: fallback, consecutive: recovery720)
        if recovery720 {
            _ = try recoveryIncrease(app, prefix: "recovery-720", after: recovered.ended, previous: recovered,
                profile: "720p30", bitrate: 3000000, consecutive: true)
        }
    }

    @MainActor func testOrdinarySimulatorRecoverScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_RECOVERY"] == "1" else {
            throw XCTSkip("Use the explicit ordinary recovery simulator lane.")
        }
        evidencePrefix = "OrdinaryRecoveryStreaming"
        defer { attachRecoveryEvidence() }
        do { try runVertical(watchScoring: false, ordinarySimulator: true, recovery: true) }
        catch { recoveryFailure = recoveryFailure ?? String(describing: error); throw error }
        #else
        throw XCTSkip("Ordinary recovery requires a disposable simulator.")
        #endif
    }

    @MainActor func testOrdinarySimulatorRecover720ScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_SIMULATOR"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_RECOVERY"] == "1",
              ProcessInfo.processInfo.environment["SCOREBUG_ORDINARY_RECOVERY_720"] == "1" else {
            throw XCTSkip("Use the explicit ordinary recovery720 simulator lane.")
        }
        recovery720 = true; evidencePrefix = "OrdinaryRecovery720Streaming"
        defer { attachRecoveryEvidence() }
        do { try runVertical(watchScoring: false, ordinarySimulator: true, recovery: true) }
        catch { recoveryFailure = recoveryFailure ?? String(describing: error); throw error }
        #else
        throw XCTSkip("Ordinary recovery720 requires a disposable simulator.")
        #endif
    }

    @MainActor func testPhysicalIPhoneRecover720ScoreStopAndExport() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical recovery720 requires an actual iPhone camera.")
        #else
        guard ProcessInfo.processInfo.environment["SCOREBUG_PHYSICAL_RECOVERY_720"] == "1" else {
            throw XCTSkip("Use the explicit physical recovery720 launcher.")
        }
        recovery720 = true; physicalRecovery = true; evidencePrefix = "PhysicalRecovery720Streaming"
        defer { attachRecoveryEvidence() }
        do {
            recoveryControlConfiguration = try RecoveryControlConfiguration(
                environment: ProcessInfo.processInfo.environment, allowLAN: true)
            try runVertical(watchScoring: false, recovery: true)
        } catch { recoveryFailure = recoveryFailure ?? String(describing: error); throw error }
        #endif
    }

    @MainActor private func runVertical(watchScoring: Bool, ordinarySimulator: Bool = false, recovery: Bool = false, separateScorer: Bool = false, directWatch: Bool = false) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = explicitValue(environment["SCOREBUG_DEVICE_API_URL"]),
              let token = explicitValue(environment["SCOREBUG_DEVICE_TOKEN"]) else {
            throw XCTSkip("Set both SCOREBUG_DEVICE_API_URL and SCOREBUG_DEVICE_TOKEN to opt into the physical device smoke.")
        }
        var allowedEndpoint = isPrivateLANEndpoint(endpoint)
        #if targetEnvironment(simulator)
        if environment["SCOREBUG_SEPARATE_WATCH_SCORER"] == "1" {
            allowedEndpoint = ordinarySimulator && separateScorer && isSimulatorLoopbackEndpoint(endpoint)
        }
        if directWatch {
            let url = URLComponents(string: endpoint)
            allowedEndpoint = ordinarySimulator && watchScoring && !recovery && !separateScorer &&
                url?.scheme == "http" && url?.host == "127.0.0.1" && url?.port != nil &&
                (url?.path == "" || url?.path == "/") && url?.user == nil && url?.password == nil && url?.query == nil && url?.fragment == nil
        }
        #else
        try require(!directWatch, "Direct Watch is simulator-only.")
        #endif
        try require(allowedEndpoint, "Device smoke requires its explicit private LAN or direct-simulator loopback endpoint.")
        continueAfterFailure = true // Thrown failures still run the stop cleanup below.
        executionTimeAllowance = recovery ? 780 : (watchScoring ? 600 : ((ordinarySimulator || separateScorer) ? 480 : 240))
        // Reserve 35 seconds for independent stream and recording cleanup,
        // plus a little headroom for final evidence within the 240-second test.
        deadline = Date().addingTimeInterval(recovery ? 735 : (watchScoring ? 550 : ((ordinarySimulator || separateScorer) ? 430 : 200)))
        if ordinarySimulator { try prepareOrdinarySimulator() }
        let app = XCUIApplication()
        // Physical runs preserve an existing process so the prior-capture guard
        // can refuse the run without terminating someone's recording.
        if ordinarySimulator {
            // Source injection alone: the normal publishing/quality factories remain in charge.
            app.launchEnvironment = ["SCOREBUG_TEST_FILE_CAPTURE": "1"]
            app.launch()
        } else {
            app.activate()
        }
        var scoreFailure: Error?, adaptiveFailure: Error?
        var recordingRequested = false
        var streamingRequested = false
        defer {
            cleanup(app, recordingRequested: recordingRequested, streamingRequested: streamingRequested)
            stopPhysicalLoopback()
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
        if physicalRecovery { try startPhysicalLoopbackIfRequested(app) }
        if !ordinarySimulator {
            // A physical rotation during setup invalidates XCTest activation
            // points. Establish portrait only after preserving prior capture.
            XCUIDevice.shared.orientation = .portrait
            var lastFrame = CGRect.zero
            var stableSince = ProcessInfo.processInfo.systemUptime
            try wait("Physical setup did not settle in portrait.", seconds: 10) {
                let frame = app.frame
                let now = ProcessInfo.processInfo.systemUptime
                guard XCUIDevice.shared.orientation == .portrait,
                      !frame.isEmpty, !frame.isNull, !frame.isInfinite,
                      frame.height > frame.width, frame == lastFrame else {
                    lastFrame = frame; stableSince = now
                    return false
                }
                return now - stableSince >= 1
            }
        }
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

        if physicalRecovery {
            try preflightPhysicalRecoveryControl(app)
            try wait("Scorebug did not return to the foreground after controller preflight.", seconds: 10) {
                app.state == .runningForeground
            }
        }
        if recovery {
            recoveryRecordingStarted = ProcessInfo.processInfo.systemUptime
            recoveryRecordingDeadline = recoveryRecordingStarted + 540
            deadline = Date().addingTimeInterval(540)
            recoveryMilestone("recording-requested")
        }
        recordingRequested = true
        if quality2160 { try tap(app.buttons["4K"], in: app) }
        try tap(app.buttons["film.start"], in: app)
        try wait("Recording did not advance.", seconds: 25) {
            self.allowExpectedPermissions()
            return self.elapsed(app) >= 2 && app.buttons["film.stop"].exists
        }
        streamingRequested = true
        try tap(app.buttons["streaming.start"], in: app)
        try wait("Camera did not publish to the LAN worker.", seconds: 25) {
            self.allowExpectedPermissions()
            return self.value(app, "streaming.localStatus") == "publishing"
        }
        if physicalRecovery {
            let local = ProcessInfo.processInfo.systemUptime
            physicalLocalPublishingObserved = local
            recoveryMilestone("local-publishing-observed", at: local)
            try preservingRecoveryFailure {
                physicalInitialEncoderACK = try recoveryWait(app, phase: "initial-encoder-ack", seconds: 10, startedAt: local) {
                    $0.isInitialEncoderACK(after: self.recoveryRecordingStarted)
                }
                recoveryMilestone("initial-encoder-ack", sample: true)
            }
            try preservingRecoveryFailure {
                try wait("Worker did not report producing_output.", seconds: 35) {
                    self.value(app, "streaming.workerStatus") == "producing_output"
                }
                let output = ProcessInfo.processInfo.systemUptime
                physicalWorkerOutputObserved = output
                recoveryMilestone("worker-output-observed", at: output)
            }
        } else {
            try wait("Worker did not report producing_output.", seconds: 35) {
                self.value(app, "streaming.workerStatus") == "producing_output"
            }
        }
        // Observe physical startup before screenshots or scoring can miss the fresh 240p window.
        if physicalRecovery && adaptiveFailure == nil { try adaptiveGate() }
        evidence(app, phase: ordinarySimulator ? "ordinary-publishing" : "hardware-publishing", screenshot: true)
        if ordinarySimulator && !recovery {
            try wait("Ordinary startup did not acknowledge 240p30 at 350000 bps.", seconds: 10) {
                self.value(app, "streaming.appliedQuality") == "240p30:350000"
            }
            evidence(app, phase: "minimum-quality-acknowledged", screenshot: true)
        }

        func preservingRecoveryFailure(_ action: () throws -> Void) throws {
            do { try action() }
            catch {
                guard recovery else { throw error }
                adaptiveFailure = adaptiveFailure ?? error
                recoveryFailure = String(describing: adaptiveFailure ?? error)
            }
        }
        func beginRecoveryTermination() throws {
            guard recovery else { return }
            try preservingRecoveryFailure {
                try require(ProcessInfo.processInfo.systemUptime <= recoveryRecordingDeadline, "Recovery recording exceeded its 540-second deadline.")
            }
            // Terminal actions need time even when the recording budget failed.
            // This does not change the monotonic adaptive or recording limits.
            deadline = Date().addingTimeInterval(quality2160 ? 240 : 90)
            recoveryMilestone("terminal-started")
        }
        func adaptiveGate() throws {
            do {
                if recovery { try runOrdinaryRecovery(app) }
                else { try waitForOrdinaryIncrease(app) }
            } catch {
                adaptiveFailure = error
                if recovery { recoveryFailure = String(describing: error) }
                evidence(app, phase: "adaptive-gate-failed", screenshot: true)
            }
            try preservingRecoveryFailure {
                try require(value(app, "streaming.localStatus") == "publishing" &&
                            value(app, "streaming.workerStatus") == "producing_output" && app.buttons["film.stop"].exists,
                            "Ordinary recording and worker output did not remain live after the adaptive gate.")
            }
            if adaptiveFailure == nil { evidence(app, phase: "increased-quality-acknowledged", screenshot: true) }
        }
        if watchScoring && ordinarySimulator { try adaptiveGate() }

        if watchScoring && adaptiveFailure == nil {
            do {
                if directWatch {
                    try require(value(app, "streaming.localStatus") == "publishing" &&
                                value(app, "streaming.workerStatus") == "producing_output" && app.buttons["film.stop"].exists,
                                "Direct Watch readiness requires adaptive success and live recording/output.")
                    let transport = XCTAttachment(string: "setupTransport=simulator-fixture; scoringTransport=direct-http; watchConnectivityQualified=false")
                    transport.name = "watch-direct-transport"; transport.lifetime = .keepAlways; add(transport)
                    print("SCOREBUG_PHONE_READY_FOR_DIRECT_WATCH")
                } else {
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
                    // SwiftUI propagates the Label identifier to its image and text.
                    // Select the status text; firstMatch across all types picks the icon.
                    let status = app.staticTexts.matching(identifier: "phoneWatch.status").firstMatch
                    try wait("Paired Watch did not confirm native setup.", seconds: 100) {
                        status.exists && status.label.contains("Watch reports connected")
                    }
                    evidence(app, phase: ordinarySimulator ? "ordinary-watch-setup-confirmed" : "physical-watch-setup-confirmed", screenshot: true)
                }
                try selectTab("Score", app)
                // The opt-in physical/paired ordinary Watch runner holds its first point for 30s
                // so the phone can observe both that point and concurrent output.
                try wait("Phone did not observe the Watch's first point before match end.", seconds: directWatch ? 120 : 60) {
                    app.buttons["scoring.homePoint"].value as? String == "1" &&
                        app.buttons["scoring.awayPoint"].value as? String == "0"
                }
                try selectTab("Film", app)
                try require(value(app, "streaming.localStatus") == "publishing" &&
                            value(app, "streaming.workerStatus") == "producing_output" &&
                            app.buttons["film.stop"].exists,
                            "Recording and live output did not remain active during Watch scoring.")
                evidence(app, phase: ordinarySimulator ? "ordinary-watch-point-while-publishing" : "physical-watch-point-while-publishing", screenshot: true)
                try selectTab("Score", app)
                if ordinarySimulator {
                    try wait("Phone did not observe the Watch's final AWAY point during its hold.", seconds: 100) {
                        app.buttons["scoring.homePoint"].value as? String == "0" &&
                            app.buttons["scoring.awayPoint"].value as? String == "1"
                    }
                    try selectTab("Film", app)
                    try require(value(app, "streaming.localStatus") == "publishing" &&
                                value(app, "streaming.workerStatus") == "producing_output" && app.buttons["film.stop"].exists,
                                "Output did not remain live during the Watch's final AWAY hold.")
                    evidence(app, phase: "watch-away-point-while-publishing", screenshot: true)
                    try selectTab("Score", app)
                }
                try wait("Watch did not complete point, undo, away point, and end-match workflow.", seconds: 180) {
                    app.staticTexts["scoring.ended"].exists
                }
                try require(app.buttons["scoring.homePoint"].value as? String == "0" &&
                            app.buttons["scoring.awayPoint"].value as? String == "1",
                            "Phone did not observe the expected Watch 0–1 final score.")
                evidence(app, phase: ordinarySimulator ? "ordinary-watch-score-and-end-observed" : "physical-watch-score-and-end-observed", screenshot: true)
            } catch {
                guard ordinarySimulator else { throw error }
                scoreFailure = error
                evidence(app, phase: "watch-score-gate-failed", screenshot: true)
            }
            try selectTab("Film", app)
            // Remote match end may already stop publishing; the archive must
            // still be active and advance through the common checks below.
            if app.buttons["streaming.stop"].exists {
                try tap(app.buttons["streaming.stop"], in: app)
            }
        } else if separateScorer {
            do {
                let initialDuration = elapsed(app)
                try require(initialDuration.isFinite && initialDuration >= 0, "Camera recording duration is unavailable before scoring.")
                try selectTab("Score", app)
                try validateSeparateScore(app, allowed: ["0:0"])
                try tap(app.buttons["scoring.homePoint"], in: app)
                try waitForSeparateScore(app, home: 1, away: 0, previous: "0:0", seconds: 12, reserveTerminal: true, allowImmediatePeerPoint: true)
                separateScorerCheckpoint(app, role: "camera", phase: "native-home-point-acknowledged", ready: true)
                var previousDuration = initialDuration
                for (phase, away, previous) in [("peer-away-point", 1, "1:0"), ("peer-undo", 0, "1:1"), ("peer-final-away-point", 1, "1:0")] {
                    try waitForSeparateScore(app, home: 1, away: away, previous: previous, seconds: 60, reserveTerminal: true)
                    separateScorerCheckpoint(app, role: "camera", phase: phase + "-observed", ready: true)
                    try selectTab("Film", app)
                    let currentDuration = elapsed(app)
                    try require(app.buttons["film.stop"].exists && currentDuration.isFinite && currentDuration > previousDuration &&
                                value(app, "streaming.localStatus") == "publishing" &&
                                value(app, "streaming.workerStatus") == "producing_output",
                                "Camera recording or live output failed between separate scorer transitions.")
                    previousDuration = currentDuration
                    evidence(app, phase: phase + "-while-publishing", screenshot: false)
                    try selectTab("Score", app)
                }
                try validateSeparateScore(app, allowed: ["1:1"])
                try selectTab("Film", app)
                let holdStarted = ProcessInfo.processInfo.systemUptime
                let initialHoldDuration = elapsed(app)
                try require(initialHoldDuration.isFinite && initialHoldDuration >= 0 && initialHoldDuration >= previousDuration,
                            "Camera final score hold has an invalid recording duration baseline.")
                while true {
                    try require(Date() < deadline.addingTimeInterval(-100), "Camera final score hold exceeded its finite gate.")
                    let currentDuration = elapsed(app)
                    try require(currentDuration.isFinite && currentDuration >= initialHoldDuration,
                                "Camera recording duration became invalid during the final score hold.")
                    try require(app.buttons["film.stop"].exists && value(app, "streaming.localStatus") == "publishing" &&
                                value(app, "streaming.workerStatus") == "producing_output" && separatePermissionAlertAbsent(app),
                                "Camera recording or live output stopped during the final score hold.")
                    if ProcessInfo.processInfo.systemUptime - holdStarted >= 30 && currentDuration >= initialHoldDuration + 30 { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                evidence(app, phase: "final-score-live-hold-complete", screenshot: false)
                try selectTab("Score", app)
                try validateSeparateScore(app, allowed: ["1:1"])
                separateScorerCheckpoint(app, role: "camera", phase: "final-score-hold-complete", ready: true)
                if environment["SCOREBUG_SEPARATE_WATCH_SCORER"] == "1" {
                    separateScorerCheckpoint(app, role: "camera", phase: "watch-ready", ready: true)
                    try waitForSeparateWatchEnd(app, role: "camera")
                }
            } catch {
                scoreFailure = error
                separateScorerCheckpoint(app, role: "camera", phase: "score-gate-failed")
            }
            // Keep the score failure through the existing independent stop,
            // continued archive, actual recording identity, and export checks.
            try selectTab("Film", app)
            if app.buttons["streaming.stop"].exists { try tap(app.buttons["streaming.stop"], in: app) }
        } else if !watchScoring {
            do {
                try selectTab("Score", app)
                try tap(app.buttons["scoring.homePoint"], in: app)
                try wait("Native HOME point was not acknowledged as 1.", seconds: 12) {
                    app.buttons["scoring.homePoint"].value as? String == "1"
                }
            } catch {
                guard ordinarySimulator || recovery else { throw error }
                scoreFailure = error
                evidence(app, phase: "native-score-gate-failed", screenshot: true)
            }
            if scoreFailure == nil { evidence(app, phase: "native-home-point-acknowledged", screenshot: true) }
            try selectTab("Film", app)
            if ordinarySimulator && environment["SCOREBUG_SOURCE_INTERRUPTION"] == "1" {
                try recoverInterruptedSource(app)
            } else if ordinarySimulator && environment["SCOREBUG_SERVER_RECOVERY"] == "1" {
                for component in ["api", "worker"] {
                    let before = elapsed(app)
                    print("SCOREBUG_RESTART_\(component.uppercased())")
                    try wait("Native app did not observe \(component) outage.", seconds: 40) {
                        try self.require(self.value(app, "streaming.localStatus") == "publishing" && app.buttons["film.stop"].exists,
                                         "Server outage stopped native recording or publishing.")
                        return self.value(app, "streaming.workerStatus") != "producing_output"
                    }
                    evidence(app, phase: "\(component)-unavailable", screenshot: false)
                    try wait("Native output did not recover after \(component) restart.", seconds: 60) {
                        try self.require(self.value(app, "streaming.localStatus") == "publishing" && app.buttons["film.stop"].exists,
                                         "Server recovery stopped native recording or publishing.")
                        return self.value(app, "streaming.workerStatus") == "producing_output" && self.elapsed(app) > before + 10
                    }
                    evidence(app, phase: "\(component)-recovered", screenshot: true)
                }
            } else if (ordinarySimulator || recovery) && !physicalRecovery { try adaptiveGate() }
            try preservingRecoveryFailure {
                if recovery { recoveryMilestone("live-hold-started") }
                let holdStarted = Date()
                let initialDuration = elapsed(app)
                try wait("Recording did not advance throughout the 12-second live hold.", seconds: 18) {
                    Date().timeIntervalSince(holdStarted) >= 12 && self.elapsed(app) >= initialDuration + 12
                }
                try require(value(app, "streaming.localStatus") == "publishing" &&
                            value(app, "streaming.workerStatus") == "producing_output",
                            "Live publishing or worker output stopped during the recording hold.")
                if recovery { recoveryMilestone("live-hold-complete") }
                evidence(app, phase: "live-hold-complete", screenshot: true)
            }
            // BEGIN RECOVERY TERMINATION
            try beginRecoveryTermination()
            if !recovery || app.buttons["streaming.stop"].exists {
                try preservingRecoveryFailure { try tap(app.buttons["streaming.stop"], in: app) }
            }
            // END RECOVERY TERMINATION
        } else {
            // A failed adaptive gate never offers Watch setup, but still exports
            // the finite source recording and retains the adaptive failure.
            try tap(app.buttons["streaming.stop"], in: app)
        }
        try preservingRecoveryFailure {
            try wait("Streaming did not return to idle.", seconds: 15) {
                self.value(app, "streaming.localStatus") == "idle"
            }
            if recovery { recoveryMilestone("stream-stopped") }
        }
        let stoppedAt = elapsed(app)
        try preservingRecoveryFailure {
            try wait("Local recording did not continue after streaming stopped.", seconds: 8) {
                self.elapsed(app) >= stoppedAt + 3 && app.buttons["film.stop"].exists
            }
            if recovery { recoveryMilestone("archive-continuation-complete") }
        }
        evidence(app, phase: "recording-continues-after-stream-stop", screenshot: true)
        try tap(app.buttons["film.stop"], in: app)
        if recovery {
            recoveryMilestone("recording-stop-requested")
            try preservingRecoveryFailure {
                try require(ProcessInfo.processInfo.systemUptime <= recoveryRecordingDeadline, "Recovery recording exceeded its 540-second deadline.")
            }
        }
        try wait("Recording did not finish saving.", seconds: 20) {
            app.buttons["film.start"].exists && app.buttons["film.start"].isEnabled
        }
        try selectTab("Recordings", app)
        try wait("No new completed recording appeared; existing recordings were preserved.", seconds: 10) {
            exports.firstMatch.exists && exports.firstMatch.identifier != oldNewestExport
        }
        let exportIdentifier = exports.firstMatch.identifier
        let exportPrefix = "recordings.export."
        let recordingID = String(exportIdentifier.dropFirst(exportPrefix.count))
        guard exportIdentifier != oldNewestExport, exportIdentifier.hasPrefix(exportPrefix),
              let parsedID = UUID(uuidString: recordingID),
              recordingID.lowercased() == parsedID.uuidString.lowercased() else {
            throw SmokeFailure.failed("New recording export has an invalid recording identity.")
        }
        // Preserve the actual folder spelling; collection must not select an
        // earlier recording or infer identity from a timestamp or export order.
        completedRecordingID = recordingID
        try tap(app.buttons[exportIdentifier], in: app)
        try wait("The new recording could not be exported to MP4.", seconds: quality2160 ? 180 : 35) {
            app.staticTexts["recordings.exportReady"].exists
        }
        evidence(app, phase: ordinarySimulator ? "new-ordinary-recording-export-ready" : "new-hardware-recording-export-ready", screenshot: true)
        if recovery { recoveryMilestone("export-ready") }
        // Expired gates stay failed even if score or quality changes while
        // completing the independent stop, archive-continuation and export gates.
        let failures = [scoreFailure, adaptiveFailure].compactMap { $0 }
        if !failures.isEmpty {
            throw SmokeFailure.failed(failures.map { String(describing: $0) }.joined(separator: "; "))
        }
        // No recording/keychain deletion, external share, or Photos-library write.
    }

    @MainActor private func recoverInterruptedSource(_ app: XCUIApplication) throws {
        try wait("Finite source did not interrupt recording and retire publishing.", seconds: 70) {
            app.buttons["film.start"].exists && app.buttons["film.start"].isEnabled &&
                self.value(app, "streaming.localStatus") == "idle"
        }
        try require(app.staticTexts["film.message"].label.contains("Capture interrupted"),
                    "Recording ended for a different reason than source interruption.")
        evidence(app, phase: "source-interrupted-publisher-idle", screenshot: true)
        try selectTab("Recordings", app)
        let recover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordings.recover.")).firstMatch
        try wait("Interrupted source archive was not recoverable.", seconds: 10) { recover.exists }
        let identity = XCTAttachment(string: recover.identifier)
        identity.name = "source-interrupted-recording"; identity.lifetime = .keepAlways; add(identity)
        try tap(recover, in: app)
        try wait("Interrupted archive export failed.", seconds: 35) { app.staticTexts["recordings.exportReady"].exists }
        evidence(app, phase: "source-interrupted-archive-exported", screenshot: true)
        try tap(app.buttons["recordings.closePlayer"], in: app)
        try selectTab("Film", app)
        try tap(app.buttons["film.start"], in: app)
        try wait("New recording did not advance after interruption.", seconds: 20) {
            self.elapsed(app) >= 2 && app.buttons["film.stop"].exists
        }
        try tap(app.buttons["streaming.start"], in: app)
        try wait("New recording did not establish a fresh publishing/output session.", seconds: 30) {
            self.value(app, "streaming.localStatus") == "publishing" &&
                self.value(app, "streaming.workerStatus") == "producing_output"
        }
        evidence(app, phase: "source-restarted-publishing", screenshot: true)
    }

    private func explicitValue(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.hasPrefix("$(") else { return nil }
        return value
    }

    private func isSimulatorLoopbackEndpoint(_ value: String) -> Bool {
        #if targetEnvironment(simulator)
        guard let url = URLComponents(string: value) else { return false }
        return url.scheme == "http" && url.host == "127.0.0.1" && url.port != nil &&
            (url.path.isEmpty || url.path == "/") && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
        #else
        return false
        #endif
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

    @MainActor private func wait(_ message: String, seconds: Double, until condition: () throws -> Bool) throws {
        let end = min(deadline, Date().addingTimeInterval(seconds))
        while Date() < end {
            try enforceScorerPermissionPolicy()
            let satisfied = try condition()
            try enforceScorerPermissionPolicy()
            if satisfied { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw SmokeFailure.failed(message)
    }

    @MainActor private func selectTab(_ name: String, _ app: XCUIApplication) throws {
        try enforceScorerPermissionPolicy()
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
                    try enforceScorerPermissionPolicy()
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
        try require(!runnerNetworkSettingReadOnly, "A keyboard covers read-only inspection; dismiss it manually.")
        let scoreField = app.textFields["scoring.endpoint"]
        let filmField = app.textFields["streaming.endpoint"]
        let creationField = app.textFields["scoring.awayName"]
        let setupVisible = (scoreField.exists && scoreField.isHittable) ||
            (filmField.exists && filmField.isHittable) ||
            (creationField.exists && creationField.isHittable)
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
        guard !runnerNetworkSettingReadOnly else { return }
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
            attachment.name = "\(evidencePrefix)-tab-selection-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        // Crop to the app's tab bar: a full screen may contain setup fields.
        let tabBar = app.tabBars.firstMatch
        if phase == "failed" && tabBar.exists && !tabBar.frame.isEmpty && app.frame.contains(tabBar.frame) &&
            !app.keyboards.firstMatch.exists && !app.alerts.firstMatch.exists {
            let attachment = XCTAttachment(screenshot: tabBar.screenshot())
            attachment.name = "\(evidencePrefix)-tab-bar"; attachment.lifetime = .keepAlways; add(attachment)
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
                try enforceScorerPermissionPolicy()
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

    @MainActor private func prepareOrdinarySimulator() throws {
        // Only the dedicated simulator entry point reaches this preparation.
        // Use the installed Settings UI, never private preference keys or a
        // change to Scorebug's token field, to avoid saving disposable tokens.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        try tap(settings.descendants(matching: .any).matching(identifier: "com.apple.settings.general").firstMatch, in: settings)
        try tap(settings.descendants(matching: .any).matching(identifier: "AUTOFILL").firstMatch, in: settings)
        let autofill = settings.switches["AutoFillToggle"]
        try wait("Disposable simulator AutoFill setting was unavailable.", seconds: 8) { autofill.exists }
        if autofill.value as? String == "1" {
            try require(autofill.isHittable && settings.frame.contains(autofill.frame), "AutoFill switch is not visible.")
            // On iOS 26.2 this switch's AX frame includes its whole labeled row.
            // A center tap lands on inert text; the observed toggle is at its right.
            autofill.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        try wait("Disposable simulator AutoFill was not disabled.", seconds: 5) { autofill.value as? String == "0" }
        let attachment = XCTAttachment(screenshot: settings.screenshot())
        attachment.name = "OrdinarySimulatorStreaming-autofill-disabled"; attachment.lifetime = .keepAlways; add(attachment)
        settings.terminate()
    }

    @MainActor private func enforceScorerPermissionPolicy() throws {
        if runnerNetworkSettingReadOnly {
            try require(Date() < deadline &&
                        !XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
                        "Read-only Settings inspection encountered a prompt or its deadline; no prompt was approved.")
            // Background apps can lose their AX server after foreground changes.
            // State queries are safe during activation; inspect only foreground UI.
            for app in [XCUIApplication(), XCUIApplication(bundleIdentifier: "com.apple.Preferences")]
                where app.state == .runningForeground {
                try require(!app.alerts.firstMatch.exists,
                            "Read-only Settings inspection encountered a prompt; no prompt was approved.")
            }
        }
        guard scorerNetworkPermissionOnly else { return }
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return }
        let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
        try require(!(text.contains("scorebug") && (text.contains("camera") || text.contains("microphone"))),
                    "Separate scorer unexpectedly requested capture permission; the permission was not granted.")
    }

    @MainActor private func allowExpectedPermissions() {
        guard !runnerNetworkSettingReadOnly else { return }
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return }
        let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
        guard text.contains("scorebug") else { return }
        let cameraOrMic = text.contains("camera") || text.contains("microphone")
        // All shared helpers obey the scorer-only policy, including setup and
        // reveal/tap polling. The throwing polling guards report the failure.
        if scorerNetworkPermissionOnly && cameraOrMic { return }
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

    @MainActor private func waitForOrdinaryIncrease(_ app: XCUIApplication) throws {
        let started = ContinuousClock.now
        let end = min(deadline, Date().addingTimeInterval(150))
        var lastSample: ContinuousClock.Instant?
        var samples: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "OrdinarySimulatorStreaming-adaptive-samples"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        while Date() < end {
            let quality = value(app, "streaming.appliedQuality")
            if Date() < end, quality == "360p30:600000" { return }
            let now = ContinuousClock.now
            if Date() < end, samples.count < 76,
               lastSample.map({ $0.duration(to: now) >= .seconds(2) }) ?? true {
                lastSample = now
                let diagnostic = value(app, "streaming.qualityDiagnostic")
                // AX reads consume the existing budget; never extend the gate
                // to finish a sample or accept an acknowledgment after its end.
                if Date() < end {
                    let elapsed = started.duration(to: now).components
                    samples.append([
                        "sampleStartedElapsedSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                        "appliedQuality": ["240p30:350000", "360p30:600000"].contains(quality) ? quality : "unavailable-or-other",
                        "qualityDiagnostic": diagnostic.utf8.count <= 4096 ? diagnostic : "oversized"
                    ])
                }
            }
            RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.2)))
        }
        throw SmokeFailure.failed("Adaptive gate failed: ordinary publishing did not acknowledge 360p30 at 600000 bps within 150 seconds.")
    }

    @MainActor private func evidence(_ app: XCUIApplication, phase: String, screenshot: Bool) {
        // Only allowlisted status values: never dump accessibility trees, setup
        // forms, server errors, process environment, or authentication material.
        let statuses = ["idle", "starting", "publishing", "failed", "producing_output", "unknown", "stale",
                        "not_requested", "waiting_source", "stopping", "retrying", "closed", "missing"]
        let local = value(app, "streaming.localStatus")
        let worker = value(app, "streaming.workerStatus")
        let quality = value(app, "streaming.appliedQuality")
        let safeQuality = quality.range(of: #"^(240p30|360p30):[0-9,. ]{1,16}$"#, options: .regularExpression) != nil
        let diagnostic = value(app, "streaming.qualityDiagnostic")
        var report: [String: Any] = ["phase": phase, "durationSeconds": elapsed(app),
                                   "qualityDiagnostic": diagnostic.utf8.count <= 4096 ? diagnostic : "oversized",
                                   "appliedQuality": safeQuality ? quality : "unavailable-or-other",
                                   "localStatus": statuses.contains(local) ? local : "other",
                                   "workerStatus": statuses.contains(worker) ? worker : "other",
                                   "exportReady": app.staticTexts["recordings.exportReady"].exists]
        if let completedRecordingID { report["recordingID"] = completedRecordingID }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "\(evidencePrefix)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        if screenshot {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(evidencePrefix)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
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

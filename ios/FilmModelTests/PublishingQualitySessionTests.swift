import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming
import XCTest

final class PublishingQualitySessionTests: XCTestCase {
    func testDelayedSourceAdviceCannotInvokeNativeEffectsAfterReceiverReportExpires() async throws {
        for timing in StreamingTimingProfile.allCases {
            for reset in [true, false] {
                for pastBoundary in [false, true] {
                    let native = QualityNative()
                    var operations = native.operations
                    operations.videoStartup = { native.startup }
                    let owner = try PublishingQualitySession(operations: operations,
                        profiles: [.init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 6_000_000)],
                        attemptID: attempt, initial: .init(profileID: "1080p30", videoBitrate: 2_000_000),
                        strategy: .measuredCandidateTrials, behavior: .progressive, timingProfile: timing, uptime: { native.now })
                    try await owner.bootstrap()
                    native.setNow(105.2)
                    let source = QualityController.Window(attemptID: attempt, sequence: 1, appliedRevision: 0, start: 100, end: 105,
                        capturedFreshFrames: 150, encodedFreshFrames: 150,
                        receiver: .init(freshFrames: reset ? 100 : 150, observedAt: 105.1),
                        sourceLoss: .init(expectedFrames: 150, lostFrames: reset ? 50 : 0),
                        meanQueueOccupancy: reset ? 0.1 : 0.8, usableVideoCapacity: nil, connectivity: .connected,
                        thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)
                    let decision = try await owner.evaluate(source)
                    let advice = try XCTUnwrap(decision.recommendation)
                    let deadline = min(105 + timing.maximumCaptureWindowEvaluationAge, 107.1)
                    XCTAssertEqual(advice.validUntil, deadline)
                    native.setNow(deadline + (pastBoundary ? 0.000001 : 0))
                    if pastBoundary {
                        await fails(.staleAdvice) { try await owner.apply(advice) }
                        XCTAssertEqual(native.calls, 1, "Expired source advice must not dispatch a native mutation")
                        let diagnostic = await owner.currentDiagnostic()
                        XCTAssertNil(diagnostic["appliedTransition"])
                        let snapshot = await owner.snapshot
                        XCTAssertEqual(snapshot.revision, 0)
                    } else {
                        try await owner.apply(advice)
                        XCTAssertEqual(native.calls, 2)
                    }
                    await owner.stop()
                }
            }
        }
    }

    func testSuccessfulSourceEvaluationDiagnosticRetainsOriginalDecisionAndSequence() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let source = try XCTUnwrap(f.source), diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let capture = QualityEvaluationTestCapture()
        let result = try await f.owner.evaluate(source: source, diagnostics: diagnostics,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant, observeEvaluation: capture.observer)
        XCTAssertEqual(result.state, .healthy)
        let state = await f.owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 1)
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(capture.values.count, 1)
        let trace = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(trace.input, .source(.init(source)))
        XCTAssertEqual(trace.evaluatedAt, f.native.now)
        XCTAssertEqual(try XCTUnwrap(trace.sourceAgeSeconds), 0.1, accuracy: 0.000000001)
        await f.owner.stop()
    }

    func testSourceEvaluationDiagnosticPreservesTimeErrorAndExactSourceAge() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let source = try XCTUnwrap(f.source), diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        f.native.setNow(source.interval.captureBoundaryEndTime + 2.01)
        let instant = f.native.instant, capture = QualityEvaluationTestCapture()
        do {
            _ = try await f.owner.evaluate(source: source, diagnostics: diagnostics,
                workerLimits: nil, transportLimits: nil, instant: instant, observeEvaluation: capture.observer)
            XCTFail("Instrumentation cannot relax source freshness")
        } catch { XCTAssertEqual(error as? PublishingQualityTelemetry.Failure, .time) }
        XCTAssertEqual(capture.values.count, 1)
        let trace = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(trace.input, .source(.init(source)))
        XCTAssertEqual(trace.evaluatedAt, f.native.now)
        XCTAssertEqual(try XCTUnwrap(trace.sourceAgeSeconds), 2.01, accuracy: 0.000000001)
        let expectedAge = source.freshness.ageUpperBound(at: instant).map {
            Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
        }
        XCTAssertEqual(trace.sampleAgeSeconds, expectedAge)
        await f.owner.stop()
        do {
            _ = try await f.owner.evaluate(source: source, diagnostics: diagnostics,
                workerLimits: nil, transportLimits: nil, instant: instant, observeEvaluation: capture.observer)
            XCTFail("Closed owner cannot evaluate the old source")
        } catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .closed) }
        XCTAssertEqual(capture.values.count, 2)
        let early = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(early.input, .source(.init(source)))
        XCTAssertNil(early.evaluatedAt); XCTAssertNil(early.sampleAgeSeconds); XCTAssertNil(early.sourceAgeSeconds)
    }

    func testAppliedTransitionJoinsDecisionToNativeACKAndSurvivesLaterEvaluation() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        let pending = await owner.currentDiagnostic()
        XCTAssertNil(pending["appliedTransition"])
        try await owner.apply(next)
        let diagnostic = await owner.currentDiagnostic()
        let encoded = try XCTUnwrap(diagnostic["appliedTransition"])
        let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String])
        let state = await owner.snapshot
        XCTAssertEqual(witness["applicationID"], state.application?.id.uuidString.lowercased())
        XCTAssertEqual(witness["fromRevision"], "0")
        XCTAssertEqual(witness["revision"], "1")
        XCTAssertEqual(witness["kind"], "decrease")
        XCTAssertEqual(witness["sequence"], String(next.windowSequence))
        XCTAssertEqual(witness["input"], "window")
        XCTAssertTrue(witness["reasons"]?.contains("sourceLoss") == true)
        XCTAssertEqual(witness["start"], "100.0")
        XCTAssertEqual(witness["end"], "105.0")
        XCTAssertEqual(witness["queue"], "0.1")
        XCTAssertEqual(witness["lossLimit"], "0.01")
        XCTAssertEqual(witness["freshFrameFloor"], "24.0")
        XCTAssertEqual(witness["thermal"], "nominal")
        XCTAssertEqual(witness["transport"], "nominal")
        XCTAssertEqual(witness["ackAt"], String(try XCTUnwrap(state.acknowledgedAt)))
        XCTAssertEqual(witness["nativeAt"], String(try XCTUnwrap(state.receipt).acceptedAt))
        native.setNow(110)
        _ = try await owner.evaluate(window(105, revision: 1, good: true))
        let later = await owner.currentDiagnostic()
        XCTAssertEqual(later["appliedTransition"], encoded)
        await owner.stop()
        let closed = await owner.currentDiagnostic()
        XCTAssertNil(closed["appliedTransition"])
    }

    private let attempt = UUID()
    private var profiles: [QualityController.Profile] {
        [.init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 1_000_000),
         .init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 6_000_000)]
    }
    private func owner(_ native: QualityNative, initial: Int = 2_000_000,
                       guarded: PublishingQualitySession.GuardedMutations? = nil) throws -> PublishingQualitySession {
        var operations = native.operations
        operations.guarded = guarded
        return try .init(operations: operations, profiles: profiles, attemptID: attempt,
            initial: .init(profileID: "hd", videoBitrate: initial), uptime: { native.now })
    }
    private func window(_ start: Double, revision: UInt64 = 0, good: Bool = false, attemptID: UUID? = nil) -> QualityController.Window {
        .init(attemptID: attemptID ?? attempt, sequence: UInt64(start), appliedRevision: revision, start: start, end: start + 5,
            capturedFreshFrames: 150, encodedFreshFrames: 150, receiver: .init(freshFrames: good ? 150 : 100, observedAt: start + 5),
            sourceLoss: .init(expectedFrames: 150, lostFrames: good ? 0 : 50), meanQueueOccupancy: 0.1,
            usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal, workerPressure: .nominal,
            transportPressure: .nominal)
    }
    private func advice(_ owner: PublishingQualitySession, _ native: QualityNative, start: Double = 100, revision: UInt64 = 0) async throws -> QualityController.Recommendation {
        native.setNow(start + 5)
        let decision = try await owner.evaluate(window(start, revision: revision))
        return try XCTUnwrap(decision.recommendation)
    }
    private func fails(_ expected: PublishingQualitySession.Failure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, expected) }
    }
    func testBootstrapRequiresVerifiedWriteAndSuccessAdvancesExactlyOnce() async throws {
        let native = QualityNative(), owner = try owner(native)
        var state = await owner.snapshot
        XCTAssertNil(state.applied)
        try await owner.bootstrap()
        state = await owner.snapshot
        XCTAssertEqual(state.revision, 0); XCTAssertEqual(state.applied?.videoBitrate, 2_000_000)
        XCTAssertEqual(state.receipt?.configuration.bitRate, 2_000_000)
        let next = try await advice(owner, native)
        state = await owner.snapshot
        XCTAssertEqual(state.revision, 0)
        try await owner.apply(next)
        state = await owner.snapshot
        XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.applied, next.settings)
        XCTAssertEqual(state.receipt?.configuration.bitRate, next.settings.videoBitrate)
        await fails(.staleAdvice) { try await owner.apply(next) }
        XCTAssertEqual(native.calls, 2)
        await owner.stop()
        state = await owner.snapshot
        XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 1)
    }
    func testGuardedBitrateOnlyRejectionPreservesPublicationAndAllowsFreshDownwardAdvice() async throws {
        let native = QualityNative()
        let guarded = PublishingQualitySession.GuardedMutations(setBitRate: { _, expected, _ in
            guard case .verified(let receipt) = expected else {
                XCTFail("Bitrate-only application must select verified baseline"); throw PublishingVideoMutationAdmissionError.stale
            }
            XCTAssertEqual(receipt.configuration.bitRate, 2_000_000)
            throw PublishingVideoMutationAdmissionError.stale
        }, setProfile: { _, _, _ in
            XCTFail("Bitrate-only application cannot replace profile"); throw PublishingVideoMutationAdmissionError.stale
        })
        let owner = try owner(native, guarded: guarded)
        try await owner.bootstrap()
        let first = try await advice(owner, native)
        do { try await owner.apply(first); XCTFail("Expected guarded rejection") }
        catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .stale) }
        let state = await owner.snapshot
        XCTAssertFalse(state.isClosed); XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.revision, 0); XCTAssertEqual(native.stops, 0)
        let rejectedDiagnostic = await owner.currentDiagnostic()
        XCTAssertNil(rejectedDiagnostic["appliedTransition"])
        let second = try await advice(owner, native, start: 105)
        XCTAssertEqual(second.kind, .decrease)
        do { try await owner.apply(second); XCTFail("Fresh recommendation should reach guarded writer") }
        catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .stale) }
        XCTAssertEqual(native.stops, 0)
        await owner.stop()
    }

    func testLateGuardedRejectionDoesNotConsumeNewOwnersSuspendedApplication() async throws {
        let native = QualityNative(), oldGate = QualityWriteGate(), newGate = QualityWriteGate()
        defer { oldGate.release(); newGate.release() }
        let oldGuarded = PublishingQualitySession.GuardedMutations(setBitRate: { _, _, _ in
            await oldGate.wait(); throw PublishingVideoMutationAdmissionError.stale
        }, setProfile: { _, _, _ in throw PublishingVideoMutationAdmissionError.unavailable })
        let oldOwner = try owner(native, guarded: oldGuarded)
        try await oldOwner.bootstrap()
        let oldAdvice = try await advice(oldOwner, native)
        let oldTask = Task { try await oldOwner.apply(oldAdvice) }
        try await entered(oldGate)
        await oldOwner.stop()
        let newGuarded = PublishingQualitySession.GuardedMutations(setBitRate: { rate, _, deadline in
            await newGate.wait()
            return try await native.operations.setBitRate(rate, deadline)
        }, setProfile: { _, _, _ in throw PublishingVideoMutationAdmissionError.unavailable })
        let newOwner = try owner(native, guarded: newGuarded)
        try await newOwner.bootstrap()
        let newAdvice = try await advice(newOwner, native, start: 105)
        let newTask = Task { try await newOwner.apply(newAdvice) }
        try await entered(newGate)
        oldGate.release()
        do { try await oldTask.value; XCTFail("Old application is retired") } catch {}
        let suspended = await newOwner.snapshot
        XCTAssertTrue(suspended.isBusy); XCTAssertFalse(suspended.isClosed)
        XCTAssertEqual(suspended.revision, 0); XCTAssertEqual(native.stops, 1)
        newGate.release(); try await newTask.value
        let completed = await newOwner.snapshot
        XCTAssertFalse(completed.isBusy); XCTAssertEqual(completed.revision, 1)
        XCTAssertEqual(completed.applied, newAdvice.settings)
        XCTAssertEqual(native.stops, 1)
        await newOwner.stop()
    }

    func testTypedErrorOnLegacyRouteStillJoinsShutdown() async throws {
        let native = QualityNative(), stopGate = QualityWriteGate(), finished = QualityFinished()
        native.installStop(stopGate)
        defer { stopGate.release() }
        let operations = PublishingQualitySession.Operations(setBitRate: { rate, deadline in
            if native.calls > 0 { throw PublishingVideoMutationAdmissionError.stale }
            return try await native.operations.setBitRate(rate, deadline)
        }, stop: native.operations.stop)
        let owner = try PublishingQualitySession(operations: operations, profiles: profiles, attemptID: attempt,
            initial: .init(profileID: "hd", videoBitrate: 2_000_000), uptime: { native.now })
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        let task = Task {
            defer { finished.increment() }
            do { try await owner.apply(next); XCTFail("Legacy failure") }
            catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .stale) }
        }
        try await entered(stopGate)
        XCTAssertEqual(finished.count, 0); XCTAssertEqual(native.stops, 1)
        stopGate.release(); await task.value
        let state = await owner.snapshot
        XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0)
    }

    func testExpiredAndSupersededAdviceNeverDispatches() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let old = try await advice(owner, native)
        native.setNow(108)
        await fails(.staleAdvice) { try await owner.apply(old) }
        let current = try await advice(owner, native, start: 105)
        await fails(.staleAdvice) { try await owner.apply(old) }
        XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 0)
        try await owner.apply(current)
        XCTAssertEqual(native.calls, 2)
        await owner.stop()
    }
    func testForeignAdviceAndProfileTransitionCannotWrite() async throws {
        let native = QualityNative(), owner = try owner(native, initial: 1_000_000)
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        XCTAssertEqual(next.settings.profileID, "small")
        await fails(.unsupportedProfile) { try await owner.apply(next) }
        let otherAttempt = UUID()
        var foreign = try QualityController(profiles: profiles, attemptID: otherAttempt,
            applied: .init(profileID: "hd", videoBitrate: 2_000_000), at: 100)
        let foreignAdvice = try XCTUnwrap(foreign.evaluate(window(100, attemptID: otherAttempt), at: 105).recommendation)
        await fails(.staleAdvice) { try await owner.apply(foreignAdvice) }
        XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 0)
        await owner.stop()
    }
    func testWrongReceiptsRetireAttemptWithoutAcknowledging() async throws {
        for mode in [QualityNative.Mode.wrongRate, .wrongGeneration, .oldTime, .futureTime, .reusedID, .backwardBoundary, .missingBoundary] {
            let native = QualityNative(), owner = try owner(native)
            try await owner.bootstrap()
            let next = try await advice(owner, native)
            native.setMode(mode)
            await fails(.invalidReceipt) { try await owner.apply(next) }
            let state = await owner.snapshot
            XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0)
            let diagnostic = await owner.currentDiagnostic()
            XCTAssertNil(diagnostic["appliedTransition"])
            XCTAssertEqual(native.stops, 1)
        }
    }
    func testBadBootstrapCannotEstablishInitialSettings() async throws {
        let native = QualityNative(), owner = try owner(native)
        native.setMode(.wrongRate)
        await fails(.invalidReceipt) { try await owner.bootstrap() }
        let state = await owner.snapshot
        XCTAssertNil(state.applied); XCTAssertNil(state.receipt); XCTAssertTrue(state.isClosed)
        XCTAssertEqual(native.stops, 1)
    }
    func testNewEncoderSessionCanResetBoundary() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        native.setMode(.newSession)
        try await owner.apply(next)
        let state = await owner.snapshot
        XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.receipt?.lastSubmittedSourcePTS?.value, 0)
        await owner.stop()
    }
    func testEvaluationAndSecondApplyCannotRaceSuspendedWriteAndStopWins() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        let gate = QualityWriteGate(); native.install(gate)
        defer { gate.release() }
        let task = Task { try await owner.apply(next) }
        try await entered(gate)
        await fails(.busy) { try await owner.apply(next) }
        await fails(.busy) { _ = try await owner.evaluate(self.window(105)) }
        await fails(.busy) { _ = try await owner.checkTrialDeadline() }
        let missing = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: nil, receipt: nil, ingress: nil,
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
        await fails(.busy) { _ = try await owner.evaluateLocalPressure(diagnostics: missing, transportLimits: nil) }
        await owner.stop()
        await fails(.closed) { _ = try await owner.evaluateLocalPressure(diagnostics: missing, transportLimits: nil) }
        await fails(.closed) { try await task.value }
        let state = await owner.snapshot
        XCTAssertEqual(state.revision, 0); XCTAssertTrue(state.isClosed)
    }
    func testCancellationAfterNativeWriteCannotAcknowledge() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        let gate = QualityWriteGate(); native.install(gate)
        defer { gate.release() }
        let task = Task { try await owner.apply(next) }
        try await entered(gate); task.cancel(); gate.release()
        do { try await task.value; XCTFail("Expected cancellation") } catch {}
        let state = await owner.snapshot
        XCTAssertEqual(state.revision, 0); XCTAssertTrue(state.isClosed); XCTAssertEqual(native.stops, 1)
        let diagnostic = await owner.currentDiagnostic()
        XCTAssertNil(diagnostic["appliedTransition"])
    }
    func testTrialDeadlineRollbackReceiptsTrackRevisions() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        var trial: QualityController.Recommendation?
        for start in stride(from: 100.0, through: 125, by: 5) {
            native.setNow(start + 5)
            trial = try await owner.evaluate(window(start, good: true)).recommendation
        }
        let proposed = try XCTUnwrap(trial)
        XCTAssertEqual(proposed.kind, .trial)
        // Polling without a due rollback must preserve the pending trial.
        let premature = try await owner.checkTrialDeadline(); XCTAssertNil(premature)
        try await owner.apply(proposed)
        var state = await owner.snapshot
        XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.applied?.videoBitrate, 2_200_000)
        native.setNow(153)
        let pending = try await owner.checkTrialDeadline()
        let rollback = try XCTUnwrap(pending)
        XCTAssertEqual(rollback.kind, .rollback)
        try await owner.apply(rollback)
        state = await owner.snapshot
        XCTAssertEqual(state.revision, 2); XCTAssertEqual(state.applied?.videoBitrate, 2_000_000)
        XCTAssertEqual(state.receipt?.configuration.bitRate, 2_000_000)
        await owner.stop()
    }
    func testProductionInitializerUsesOwnedPublishingSession() async throws {
        let publisher = QualityMediaPublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let owner = try PublishingQualitySession(session: session, profiles: profiles, attemptID: attempt,
            initial: .init(profileID: "hd", videoBitrate: 2_000_000))
        try await owner.bootstrap()
        let state = await owner.snapshot
        XCTAssertEqual(state.receipt?.configuration, session.snapshot.lastBitRateChange?.configuration)
        XCTAssertEqual(state.revision, 0)
        await owner.stop()
        XCTAssertEqual(session.snapshot.state, .stopped)
    }
    func testInvalidTelemetryRevokesPendingAdvice() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let next = try await advice(owner, native)
        do { _ = try await owner.evaluate(window(100, revision: 42)); XCTFail("Invalid revision") } catch {}
        await fails(.staleAdvice) { try await owner.apply(next) }
        XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 0)
        await owner.stop()
    }
    func testAcknowledgmentUsesCompletionTimeAndExpiryRetiresWrite() async throws {
        for expires in [false, true] {
            let native = QualityNative(), owner = try owner(native)
            try await owner.bootstrap()
            let next = try await advice(owner, native)
            let gate = QualityWriteGate(); native.install(gate)
            defer { gate.release() }
            let task = Task { try await owner.apply(next) }
            try await entered(gate)
            native.setNow(expires ? 108 : 106); gate.release()
            if expires {
                await fails(.invalidReceipt) { try await task.value }
                let state = await owner.snapshot
                XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0)
            } else {
                try await task.value
                native.setNow(110)
                do { _ = try await owner.evaluate(window(105, revision: 1)); XCTFail("Pre-ack window") }
                catch { XCTAssertEqual(error as? QualityController.ValidationError, .invalidWindow) }
                let state = await owner.snapshot; XCTAssertEqual(state.revision, 1)
            }
            await owner.stop()
        }
    }
    func testInvalidClockDuringTrialRequiresRollbackWhenClockRecovers() async throws {
        for usePoll in [false, true] {
            for badTime in [129.0, .nan, .infinity, 1e13] {
                let native = QualityNative(), owner = try owner(native)
                try await owner.bootstrap()
                var proposed: QualityController.Recommendation?
                for start in stride(from: 100.0, through: 125, by: 5) {
                    native.setNow(start + 5)
                    proposed = try await owner.evaluate(window(start, good: true)).recommendation
                }
                try await owner.apply(XCTUnwrap(proposed))
                native.setNow(badTime)
                do {
                    if usePoll { _ = try await owner.checkTrialDeadline() }
                    else { _ = try await owner.evaluate(window(130, revision: 1, good: true)) }
                    XCTFail("Invalid clock")
                } catch {}
                native.setNow(131)
                let rollback = try await owner.checkTrialDeadline()
                XCTAssertEqual(rollback?.kind, .rollback, "Invalid telemetry must preserve sticky rollback")
                await owner.stop()
            }
        }
    }
    func testStopDuringBootstrapCannotEstablishRevisionZero() async throws {
        let native = QualityNative(), owner = try owner(native)
        let gate = QualityWriteGate(); native.install(gate)
        defer { gate.release() }
        let bootstrap = Task { try await owner.bootstrap() }
        try await entered(gate)
        await owner.stop()
        await fails(.closed) { try await bootstrap.value }
        let state = await owner.snapshot
        XCTAssertTrue(state.isClosed); XCTAssertNil(state.applied); XCTAssertNil(state.receipt)
    }
    func testConcurrentStopsJoinOneSuspendedShutdown() async throws {
        let native = QualityNative(), owner = try owner(native)
        try await owner.bootstrap()
        let gate = QualityWriteGate(), finished = QualityFinished()
        native.installStop(gate)
        defer { gate.release() }
        let first = Task { await owner.stop(); finished.increment() }
        try await entered(gate)
        let second = Task { await owner.stop(); finished.increment() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(finished.count, 0); XCTAssertEqual(native.stops, 1)
        gate.release(); await first.value; await second.value
        XCTAssertEqual(finished.count, 2); XCTAssertEqual(native.stops, 1)
    }
    private func entered(_ gate: QualityWriteGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard gate.entered else { XCTFail("Write never entered"); throw PublishingQualitySession.Failure.notReady }
    }
}

private final class QualityWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var seen = false
    var entered: Bool { lock.withLock { seen } }
    func wait() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { seen = true; if released { return true }; continuation = c; return false }
            if ready { c.resume() }
        }
    }
    func release() {
        let c = lock.withLock { released = true; let c = continuation; continuation = nil; return c }
        c?.resume()
    }
}
private final class QualityNative: @unchecked Sendable {
    enum Mode { case normal, wrongRate, wrongGeneration, oldTime, futureTime, reusedID, backwardBoundary, missingBoundary, newSession }
    private let lock = NSLock()
    private var time = 100.0, count = 0, stopped = 0
    private var mode = Mode.normal
    private var gate: QualityWriteGate?
    private var stopGate: QualityWriteGate?
    private let session = UUID(), configuration = UUID()
    var startup: PublishingVideoStartup? {
        .init(profile: .hd1080, width: 1920, height: 1080, publishingGeneration: 7,
            encoderSessionID: session, firstSourcePTS: .zero,
            submittedAt: 99, completedAt: 99.1, observedAt: 99.2)
    }
    var now: Double { lock.withLock { time } }
    var calls: Int { lock.withLock { count } }
    var stops: Int { lock.withLock { stopped } }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func setMode(_ value: Mode) { lock.withLock { mode = value } }
    func install(_ value: QualityWriteGate) { lock.withLock { gate = value } }
    func installStop(_ value: QualityWriteGate) { lock.withLock { stopGate = value } }
    var operations: PublishingQualitySession.Operations { .init(setBitRate: { try await self.write($0, deadline: $1) }, stop: { await self.stop() }) }
    private func write(_ rate: Int, deadline: Double) async throws -> PublishingBitRateChange {
        let (mode, count, time, gate) = lock.withLock { self.count += 1; return (self.mode, self.count, self.time, self.gate) }
        if let gate { await gate.wait() }
        return PublishingBitRateChange(publishingGeneration: mode == .wrongGeneration ? 8 : 7,
            configuration: VideoEncodingConfiguration(id: count == 1 || mode == .reusedID ? configuration : UUID(),
                encoderSessionID: mode == .newSession ? UUID() : session, bitRate: mode == .wrongRate ? rate + 1 : rate)!,
            acceptedAt: mode == .oldTime ? 99 : mode == .futureTime ? time + 1 : time,
            lastSubmittedSourcePTS: mode == .missingBoundary ? nil : CMTime(value: mode == .backwardBoundary || mode == .newSession ? 0 : Int64(count), timescale: 30))!
    }
    private func stop() async {
        let (gate, stopGate) = lock.withLock { self.stopped += 1; return (self.gate, self.stopGate) }
        gate?.release()
        if let stopGate { await stopGate.wait() }
    }
}
private actor QualityMediaPublisher: MediaPublisher {
    private var running = false
    func start() { running = true }
    func append(_ sample: CapturedMediaSample) {}
    var isPublishing: Bool { running }
    func stop() { running = false }
    func setVideoBitRate(_ rate: Int) -> PublishingBitRateChange {
        .init(publishingGeneration: 1, configuration: .init(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!,
              acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: nil)!
    }
}

private final class QualityFinished: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

final class PublishingQualityProfileTests: XCTestCase {
    private let attempt = UUID()
    private func owner(_ native: ProfileQualityNative, width: Int = 960, fps: Int = 30,
                       supportsProfile: Bool = true, guarded: PublishingQualitySession.GuardedMutations? = nil) throws -> PublishingQualitySession {
        var operations = native.operations
        if !supportsProfile { operations.setProfile = nil }
        operations.guarded = guarded
        return try .init(operations: operations, profiles: [
            .init(id: "540p30", width: width, height: 540, targetFPS: fps, minimumBitrate: 1_000_000, maximumBitrate: 2_000_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 2_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, initial: .init(profileID: "1080p30", videoBitrate: 2_000_000), uptime: { native.now })
    }
    private func progressiveOwner(_ native: ProfileQualityNative, startupMode: Int = 0) throws -> PublishingQualitySession {
        var operations = native.operations
        operations.videoStartup = {
            guard startupMode != 1 else { return nil }
            let profile: PublishingVideoProfile = startupMode == 2 ? .low240 : .hd1080
            return .init(profile: profile, width: profile.width, height: profile.height,
                publishingGeneration: startupMode == 4 ? 8 : 7,
                encoderSessionID: startupMode == 3 ? UUID() : native.oldEncoder,
                firstSourcePTS: .init(value: startupMode == 6 ? 101 : 100, timescale: 30),
                submittedAt: 99, completedAt: 99.1, observedAt: startupMode == 5 ? 101 : 99.2)
        }
        return try .init(operations: operations, profiles: [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, initial: .init(profileID: "1080p30", videoBitrate: 6_000_000),
           strategy: .receiverValidatedProfileTrials, behavior: .progressive, uptime: { native.now })
    }
    private func progressiveFailure(_ owner: PublishingQualitySession, _ native: ProfileQualityNative) async throws -> QualityController.Recommendation {
        try await owner.bootstrap()
        native.setNow(101)
        let d = try await owner.evaluate(.init(attemptID: attempt, sequence: 1, appliedRevision: 0,
            start: 100, end: 101, capturedFreshFrames: 30, encodedFreshFrames: 23, receiver: nil,
            sourceLoss: nil, meanQueueOccupancy: 0, usableVideoCapacity: nil,
            connectivity: .connected, thermalPressure: .nominal, workerPressure: .unknown))
        return try XCTUnwrap(d.recommendation)
    }
    func testProgressiveBootstrapRequiresActualFirstFrameBeforeAnyRateWrite() async throws {
        let native = ProfileQualityNative(), owner = try progressiveOwner(native, startupMode: 1)
        do { try await owner.bootstrap(); XCTFail("Missing first compressed frame") }
        catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .startupPending) }
        let state = await owner.snapshot
        XCTAssertNil(state.applied); XCTAssertFalse(state.isClosed)
        XCTAssertEqual(native.calls, []); XCTAssertEqual(native.stops, 0)
        await owner.stop()
    }
    func testProgressiveBootstrapRejectsWrongFirstProfileEncoderGenerationTimeOrSourceBoundary() async throws {
        for mode in 2...6 {
            let native = ProfileQualityNative(), owner = try progressiveOwner(native, startupMode: mode)
            do { try await owner.bootstrap(); XCTFail("Unmatched startup receipt") } catch {}
            let state = await owner.snapshot
            XCTAssertNil(state.applied); XCTAssertTrue(state.isClosed)
            XCTAssertEqual(native.stops, 1)
        }
    }
    func testProgressiveResetSkipsMiddleAndHoldsOnlyAfterJoinedNativeReceipts() async throws {
        let native = ProfileQualityNative(), owner = try progressiveOwner(native)
        let advice = try await progressiveFailure(owner, native)
        XCTAssertEqual(advice.kind, .reset)
        XCTAssertEqual(advice.settings, .init(profileID: "240p30", videoBitrate: 350_000))
        try await owner.apply(advice)
        let state = await owner.snapshot
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.applied, advice.settings)
        XCTAssertEqual(state.profileReceipt?.profile, .low240)
        XCTAssertEqual(state.receipt?.configuration.encoderSessionID, state.profileReceipt?.encoderSessionID)
        XCTAssertEqual(state.acknowledgedAt, 101.5)
        XCTAssertEqual(native.calls, ["rate:6000000", "profile:240p30", "rate:350000"])
        XCTAssertEqual(native.deadlines, [102, 103, 103])
        for i in 0..<10 {
            let start = 101.5 + Double(i)
            native.setNow(start + 1)
            let d = try await owner.evaluate(.init(attemptID: attempt, sequence: UInt64(i + 2), appliedRevision: 1,
                start: start, end: start + 1, capturedFreshFrames: 30, encodedFreshFrames: 30,
                receiver: .init(freshFrames: 30, observedAt: start + 1),
                sourceLoss: .init(expectedFrames: 30, lostFrames: 0), meanQueueOccupancy: 0,
                usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
                workerPressure: .nominal, transportPressure: .nominal))
            if i < 9 { XCTAssertNil(d.recommendation) }
            else { XCTAssertEqual(d.recommendation?.kind, .trial); XCTAssertEqual(d.recommendation?.settings.profileID, "540p30") }
        }
        await owner.stop()
        XCTAssertEqual(native.stops, 1)
    }
    func testProgressiveResetBadNativeReceiptRetiresPublishingWithoutClaimingMinimum() async throws {
        for mode in [ProfileQualityNative.Mode.wrongProfile, .wrongRate, .expiredBitrate] {
            let native = ProfileQualityNative(), owner = try progressiveOwner(native)
            let advice = try await progressiveFailure(owner, native)
            native.setMode(mode)
            do { try await owner.apply(advice); XCTFail("Unverified native reset") } catch {}
            let state = await owner.snapshot
            XCTAssertTrue(state.isClosed)
            XCTAssertEqual(state.revision, 0)
            XCTAssertEqual(state.applied?.profileID, "1080p30")
            XCTAssertEqual(native.stops, 1)
        }
    }
    private func decrease(_ owner: PublishingQualitySession, _ native: ProfileQualityNative) async throws -> QualityController.Recommendation {
        try await owner.bootstrap()
        native.setNow(105)
        let decision = try await owner.evaluate(.init(attemptID: attempt, sequence: 1, appliedRevision: 0,
            start: 100, end: 105, capturedFreshFrames: 150, encodedFreshFrames: 150, receiver: nil,
            sourceLoss: nil, meanQueueOccupancy: 0.9, usableVideoCapacity: nil,
            connectivity: .unknown, thermalPressure: .nominal, workerPressure: .unknown))
        let advice = try XCTUnwrap(decision.recommendation)
        XCTAssertEqual(advice.settings, .init(profileID: "540p30", videoBitrate: 1_600_000))
        return advice
    }
    func testGuardedProfileRejectionPreservesPublicationAndConsumesAdvice() async throws {
        for rejection in [PublishingVideoMutationAdmissionError.stale, .unavailable] {
            let native = ProfileQualityNative()
            let guarded = PublishingQualitySession.GuardedMutations(setBitRate: { _, _, _ in
                XCTFail("Rejected profile cannot dispatch bitrate"); throw rejection
            }, setProfile: { _, expected, _ in
                XCTAssertEqual(expected.configuration.encoderSessionID, native.oldEncoder)
                throw rejection
            })
            let owner = try owner(native, guarded: guarded)
            let advice = try await decrease(owner, native)
            do { try await owner.apply(advice); XCTFail("Expected guarded rejection") }
            catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, rejection) }
            let state = await owner.snapshot
            XCTAssertFalse(state.isClosed); XCTAssertFalse(state.isBusy)
            XCTAssertEqual(state.revision, 0); XCTAssertNil(state.application)
            XCTAssertEqual(native.stops, 0)
            XCTAssertEqual(native.calls, ["rate:2000000"])
            do { try await owner.apply(advice); XCTFail("Rejected advice cannot be replayed") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
            await owner.stop()
        }
    }

    func testGuardedBitrateRejectionAfterProfileSuccessJoinsShutdown() async throws {
        let native = ProfileQualityNative(), stopGate = QualityWriteGate(), finished = QualityFinished()
        native.installStop(stopGate)
        defer { stopGate.release() }
        let guarded = PublishingQualitySession.GuardedMutations(setBitRate: { _, expected, _ in
            guard case .replacement(let replacement) = expected else {
                XCTFail("Followup must select the exact replacement"); throw PublishingVideoMutationAdmissionError.stale
            }
            XCTAssertEqual(replacement.encoderSessionID, native.newEncoder)
            throw PublishingVideoMutationAdmissionError.stale
        }, setProfile: { profile, _, deadline in
            try await native.operations.setProfile!(profile, deadline)
        })
        let owner = try owner(native, guarded: guarded)
        let advice = try await decrease(owner, native)
        let operation = Task {
            defer { finished.increment() }
            do { try await owner.apply(advice); XCTFail("Partially applied change must fail") }
            catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .stale) }
        }
        try await entered(stopGate)
        XCTAssertEqual(finished.count, 0)
        XCTAssertEqual(native.stops, 1)
        let state = await owner.snapshot
        XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0)
        XCTAssertNil(state.profileReceipt)
        stopGate.release(); await operation.value
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(native.calls, ["rate:2000000", "profile:540p30"])
        await owner.stop()
        XCTAssertEqual(native.stops, 1)
    }

    func testStoppedGuardedCompletionCannotStopNewQualityOwner() async throws {
        let native = ProfileQualityNative(), gate = QualityWriteGate()
        defer { gate.release() }
        let guarded = PublishingQualitySession.GuardedMutations(setBitRate: { _, _, _ in
            XCTFail("Rejected profile cannot dispatch bitrate"); throw PublishingVideoMutationAdmissionError.stale
        }, setProfile: { _, _, _ in
            await gate.wait()
            throw PublishingVideoMutationAdmissionError.stale
        })
        let oldOwner = try owner(native, guarded: guarded)
        let oldAdvice = try await decrease(oldOwner, native)
        let oldOperation = Task { try await oldOwner.apply(oldAdvice) }
        try await entered(gate)
        await oldOwner.stop()
        let newOwner = try owner(native)
        try await newOwner.bootstrap()
        let before = await newOwner.snapshot
        gate.release()
        do { try await oldOperation.value; XCTFail("Stopped application cannot succeed") } catch {}
        let after = await newOwner.snapshot
        XCTAssertEqual(native.stops, 1)
        XCTAssertFalse(after.isClosed); XCTAssertFalse(after.isBusy)
        XCTAssertEqual(after.receipt?.configuration, before.receipt?.configuration)
        XCTAssertEqual(after.revision, 0)
        await newOwner.stop()
    }

    private func entered(_ gate: QualityWriteGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard gate.entered else { XCTFail("Operation never entered"); throw PublishingQualitySession.Failure.notReady }
    }

    func testProfileDecreaseCommitsOnlyAfterNewEncoderBitrateAndSharesDeadline() async throws {
        let native = ProfileQualityNative(), owner = try owner(native)
        let advice = try await decrease(owner, native)
        try await owner.apply(advice)
        let state = await owner.snapshot
        XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.applied, advice.settings)
        XCTAssertEqual(state.profileReceipt?.profile, .sd540)
        XCTAssertEqual(state.receipt?.configuration.encoderSessionID, state.profileReceipt?.encoderSessionID)
        XCTAssertEqual(state.receipt?.configuration.bitRate, 1_600_000)
        XCTAssertEqual(state.acknowledgedAt, 105.5)
        XCTAssertEqual(native.calls, ["rate:2000000", "profile:540p30", "rate:1600000"])
        XCTAssertEqual(native.deadlines, [102, 107, 107])
        await owner.stop()
    }
    func testFreshProfileChangeGetsBoundedExecutionTimeAfterAdmission() async throws {
        let native = ProfileQualityNative(), owner = try owner(native)
        let advice = try await decrease(owner, native)
        // The native run had 227 ms left on fresh source-window advice. The
        // deterministic publisher needs 250 ms per profile/bitrate operation.
        native.setNow(106.772759)
        XCTAssertEqual(advice.validUntil, 107)
        try await owner.apply(advice)
        let state = await owner.snapshot
        XCTAssertFalse(state.isClosed); XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.applied, advice.settings)
        XCTAssertEqual(state.acknowledgedAt ?? 0, 107.272759, accuracy: 0.000001)
        XCTAssertEqual(native.deadlines, [102, 108.772759, 108.772759])
        XCTAssertEqual(native.stops, 0)
        await owner.stop()
    }
    func testIncorrectNativeProfileDescriptorRejectsBeforeDispatch() async throws {
        for (width, fps) in [(640, 30), (958, 30)] {
            let native = ProfileQualityNative(), owner = try owner(native, width: width, fps: fps)
            let advice = try await decrease(owner, native)
            do { try await owner.apply(advice); XCTFail("Unsupported descriptor") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .unsupportedProfile) }
            XCTAssertEqual(native.calls.count, 1); XCTAssertEqual(native.stops, 0)
            await owner.stop()
        }
        XCTAssertThrowsError(try owner(ProfileQualityNative(), fps: 24)) {
            XCTAssertEqual($0 as? QualityController.ValidationError, .invalidProfiles)
        }
    }
    func testAbsentProfileOperationRejectsBeforeDispatch() async throws {
        let native = ProfileQualityNative(), owner = try owner(native, supportsProfile: false)
        let advice = try await decrease(owner, native)
        do { try await owner.apply(advice); XCTFail("Missing native operation") }
        catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .unsupportedProfile) }
        XCTAssertEqual(native.calls.count, 1); XCTAssertEqual(native.stops, 0)
        await owner.stop()
    }
    func testProductionAdapterCarriesProfileAndBitrateThroughPublishingSession() async throws {
        try await checkProductionAdapter(guarded: false)
    }
    func testProductionGuardedAdapterRejectsMissingCapabilityWithoutLegacyFallback() async throws {
        try await checkProductionAdapter(guarded: true)
    }
    private func checkProductionAdapter(guarded: Bool) async throws {
        let publisher = QualityProfilePublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let owner = try PublishingQualitySession(session: session, profiles: [
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_000_000, maximumBitrate: 2_000_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 2_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, initial: .init(profileID: "1080p30", videoBitrate: 2_000_000),
           usesGuardedMutations: guarded)
        try await owner.bootstrap()
        let baseline = await owner.snapshot, start = try XCTUnwrap(baseline.acknowledgedAt)
        try await Task.sleep(for: .milliseconds(1050))
        let advice = try await owner.evaluate(.init(attemptID: attempt, sequence: 1, appliedRevision: 0,
            start: start, end: start + 1, capturedFreshFrames: 30, encodedFreshFrames: 30, receiver: nil,
            sourceLoss: nil, meanQueueOccupancy: 0.9, usableVideoCapacity: nil, connectivity: .unknown,
            thermalPressure: .nominal, workerPressure: .unknown)).recommendation
        if guarded {
            do { try await owner.apply(XCTUnwrap(advice)); XCTFail("Guarded capability is absent") }
            catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .unavailable) }
            let state = await owner.snapshot
            XCTAssertFalse(state.isClosed); XCTAssertFalse(state.isBusy)
            XCTAssertEqual(state.revision, 0); XCTAssertNil(state.profileReceipt)
            XCTAssertEqual(session.snapshot.state, .publishing)
            XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, baseline.receipt?.configuration)
            await owner.stop()
            return
        }
        try await owner.apply(XCTUnwrap(advice))
        let state = await owner.snapshot
        XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.profileReceipt?.profile, .sd540)
        XCTAssertEqual(state.receipt?.configuration, session.snapshot.lastBitRateChange?.configuration)
        XCTAssertEqual(state.profileReceipt?.encoderSessionID, session.snapshot.lastVideoProfileChange?.encoderSessionID)
        await owner.stop()
        XCTAssertEqual(session.snapshot.state, .stopped)
    }
    func testMalformedFormatReceiptsNeverDispatchFollowupBitrate() async throws {
        for mode in [ProfileQualityNative.Mode.wrongProfile, .wrongProfileGeneration, .oldProfileTime,
                     .futureProfileTime, .oldProfileSource, .reusedEncoder, .expiredProfile] {
            let native = ProfileQualityNative(), owner = try owner(native)
            let advice = try await decrease(owner, native); native.setMode(mode)
            do { try await owner.apply(advice); XCTFail("Invalid profile: \(mode)") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .invalidReceipt) }
            let state = await owner.snapshot
            XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0)
            XCTAssertNil(state.profileReceipt); XCTAssertEqual(native.calls.count, 2); XCTAssertEqual(native.stops, 1)
        }
    }
    func testBitrateMustBelongToNewFormatAndPostdateItsAcknowledgment() async throws {
        for mode in [ProfileQualityNative.Mode.wrongBitrateEncoder, .oldBitrateSource, .missingBitrateSource,
                     .oldBitrateTime, .wrongBitrateGeneration, .wrongRate, .expiredBitrate] {
            let native = ProfileQualityNative(), owner = try owner(native)
            let advice = try await decrease(owner, native); native.setMode(mode)
            do { try await owner.apply(advice); XCTFail("Invalid bitrate: \(mode)") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .invalidReceipt) }
            let state = await owner.snapshot
            let diagnostic = await owner.currentDiagnostic()
            XCTAssertNil(diagnostic["appliedTransition"])
            XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0); XCTAssertNil(state.profileReceipt)
            XCTAssertEqual(state.receipt?.configuration.encoderSessionID, native.oldEncoder)
            XCTAssertEqual(native.calls.count, 3); XCTAssertEqual(native.stops, 1)
        }
    }
    func testStopAndCancellationDuringEitherWriteCannotCommitIntermediateState() async throws {
        for stage in ["profile", "bitrate"] {
            for cancel in [false, true] {
                let native = ProfileQualityNative(), owner = try owner(native)
                let advice = try await decrease(owner, native)
                let gate = QualityWriteGate(); native.install(gate, stage: stage)
                defer { gate.release() }
                let operation = Task { try await owner.apply(advice) }
                let deadline = ContinuousClock.now + .seconds(2)
                while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
                guard gate.entered else { gate.release(); _ = try? await operation.value; XCTFail("Write did not enter"); continue }
                let suspended = await owner.snapshot
                let pendingDiagnostic = await owner.currentDiagnostic()
                XCTAssertNil(pendingDiagnostic["appliedTransition"])
                XCTAssertTrue(suspended.isBusy); XCTAssertEqual(suspended.revision, 0); XCTAssertNil(suspended.profileReceipt)
                do { try await owner.apply(advice); XCTFail("Concurrent write") }
                catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .busy) }
                if cancel { operation.cancel(); gate.release() } else { await owner.stop() }
                do { try await operation.value; XCTFail("Stopped write acknowledged") } catch {}
                let state = await owner.snapshot
                XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0); XCTAssertNil(state.profileReceipt)
                XCTAssertEqual(native.calls.count, stage == "profile" ? 2 : 3)
                XCTAssertEqual(native.stops, 1)
            }
        }
    }
}

private actor QualityProfilePublisher: MediaPublisher {
    private var running = false, encoder = UUID(), source: Int64 = 0
    func start() { running = true }
    func append(_ sample: CapturedMediaSample) {}
    var isPublishing: Bool { running }
    func stop() { running = false }
    func setVideoBitRate(_ rate: Int) -> PublishingBitRateChange {
        source += 1
        return .init(publishingGeneration: 1, configuration: .init(id: UUID(), encoderSessionID: encoder, bitRate: rate)!,
                     acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: .init(value: source, timescale: 30))!
    }
    func setVideoProfile(_ profile: PublishingVideoProfile) -> PublishingVideoProfileChange {
        let previous = encoder, last = source
        encoder = UUID(); source += 1
        return .init(profile: profile, publishingGeneration: 1, previousEncoderSessionID: previous, encoderSessionID: encoder,
                     lastOldSourcePTS: .init(value: last, timescale: 30), firstNewSourcePTS: .init(value: source, timescale: 30),
                     width: profile.width, height: profile.height, rawVideoFramesDropped: 0,
                     acknowledgedAt: ProcessInfo.processInfo.systemUptime)!
    }
}

private final class ProfileQualityNative: @unchecked Sendable {
    enum Mode {
        case normal, wrongProfile, wrongProfileGeneration, oldProfileTime, futureProfileTime,
             oldProfileSource, reusedEncoder, expiredProfile, wrongBitrateEncoder, oldBitrateSource,
             missingBitrateSource, oldBitrateTime, wrongBitrateGeneration, wrongRate, expiredBitrate
    }
    private let lock = NSLock()
    let oldEncoder = UUID(), newEncoder = UUID()
    private var time = 100.0, mode = Mode.normal, stopped = 0
    private var history: [String] = [], limits: [Double] = []
    private var gate: QualityWriteGate?, stage: String?
    private var stopGate: QualityWriteGate?
    func installStop(_ value: QualityWriteGate) { lock.withLock { stopGate = value } }
    var now: Double { lock.withLock { time } }
    var calls: [String] { lock.withLock { history } }
    var deadlines: [Double] { lock.withLock { limits } }
    var stops: Int { lock.withLock { stopped } }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func setMode(_ value: Mode) { lock.withLock { mode = value } }
    func install(_ value: QualityWriteGate, stage: String) { lock.withLock { gate = value; self.stage = stage } }
    var operations: PublishingQualitySession.Operations {
        .init(setBitRate: { await self.bitrate($0, deadline: $1) }, stop: { await self.stop() },
              setProfile: { await self.profile($0, deadline: $1) })
    }
    private func bitrate(_ rate: Int, deadline: Double) async -> PublishingBitRateChange {
        let (bootstrap, mode, gate) = lock.withLock {
            let bootstrap = history.isEmpty
            history.append("rate:\(rate)"); limits.append(deadline)
            return (bootstrap, self.mode, stage == "bitrate" ? self.gate : nil)
        }
        if let gate { await gate.wait() }
        let at = lock.withLock { if !bootstrap { time += mode == .expiredBitrate ? 3 : 0.25 }; return time }
        return .init(publishingGeneration: !bootstrap && mode == .wrongBitrateGeneration ? 8 : 7,
            configuration: .init(id: UUID(), encoderSessionID: bootstrap || mode == .wrongBitrateEncoder ? oldEncoder : newEncoder,
                                 bitRate: !bootstrap && mode == .wrongRate ? rate + 1 : rate)!,
            acceptedAt: !bootstrap && mode == .oldBitrateTime ? 105 : at,
            lastSubmittedSourcePTS: !bootstrap && mode == .missingBitrateSource ? nil :
                CMTime(value: bootstrap ? 100 : mode == .oldBitrateSource ? 150 : 152, timescale: 30))!
    }
    private func profile(_ requested: PublishingVideoProfile, deadline: Double) async -> PublishingVideoProfileChange {
        let (mode, gate) = lock.withLock {
            history.append("profile:\(requested.rawValue)"); limits.append(deadline)
            return (self.mode, stage == "profile" ? self.gate : nil)
        }
        if let gate { await gate.wait() }
        let at = lock.withLock { time += mode == .expiredProfile ? 3 : 0.25; return time }
        let profile: PublishingVideoProfile = mode == .wrongProfile ? .hd1080 : requested
        return .init(profile: profile, publishingGeneration: mode == .wrongProfileGeneration ? 8 : 7,
            previousEncoderSessionID: mode == .reusedEncoder ? UUID() : oldEncoder,
            encoderSessionID: mode == .reusedEncoder ? oldEncoder : newEncoder,
            lastOldSourcePTS: .init(value: mode == .oldProfileSource ? 99 : 150, timescale: 30),
            firstNewSourcePTS: .init(value: 151, timescale: 30), width: profile.width, height: profile.height,
            rawVideoFramesDropped: 0, acknowledgedAt: mode == .oldProfileTime ? 104 : mode == .futureProfileTime ? at + 1 : at)!
    }
    private func stop() async {
        let (gate, stopGate) = lock.withLock { stopped += 1; return (self.gate, self.stopGate) }
        gate?.release()
        await stopGate?.wait()
    }
}

final class PublishingMeasuredCandidateSessionTests: XCTestCase {
    func testSharedRecoveryWaitsForDeliveryThenFreshSourceWithoutMovingCompletedPrefix() async throws {
        for mode in ["healthy", "suppressedBatch", "foreignWorker"] {
            let f = try await CandidateQualityFixture.make(requiresSharedCandidateRecovery: true)
            let trial = try await f.owner.evaluateCandidate(f.admission)
            try await f.owner.apply(XCTUnwrap(trial.recommendation))
            f.native.setNow(116)
            try await f.owner.noteUnavailableCadence(diagnostics: try f.diagnostics())
            let reset = try await f.owner.checkTrialDeadline()
            try await f.owner.apply(XCTUnwrap(reset))
            f.native.setNow(116.5)
            _ = try await f.owner.evaluateDecoderStall(cadence: f.freshCadence(), diagnostics: f.diagnostics(), instant: f.native.instant)
            var current: PublishingQualityTelemetry.Diagnostics?
            var authority: PublishingDeliveryAuthority?
            // Nonintegral five-second source windows require both partial delivery
            // tails. The second lane's tail arrives after the source's 2s freshness.
            var events: [(at: Double, sourceSequence: Int64?, deliveryEnd: Int?)] = [
                (122.6, 3, nil), (127.6, 4, nil), (132.6, 5, nil)]
            events += (118...129).map { (Double($0) + 1.8, nil, $0) }
            for event in events.sorted(by: { $0.at < $1.at }) {
                f.native.setNow(event.at)
                if let sequence = event.sourceSequence {
                    let health = try await f.freshSource(start: 117.5 + Double(sequence - 3) * 5, sequence: sequence)
                    _ = try await f.owner.evaluate(source: health.0, diagnostics: health.1,
                        workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                        transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                        instant: f.native.instant)
                    current = health.1
                    let context = await f.owner.candidateMeasurementContext(diagnostics: health.1)
                    if sequence == 4 { XCTAssertNil(context, "Source-only ten seconds cannot start the repeated campaign before both delivery tails") }
                    if sequence == 5 {
                        XCTAssertEqual(context != nil, mode == "healthy",
                            "Only owned completed117.5...127.5 delivery can accompany fresh source through132.5; mode=\(mode)")
                    }
                } else if let end = event.deliveryEnd {
                    let one = try await f.delivery(start: Double(end - 1), authority: authority, foreignWorker: mode == "foreignWorker")
                    authority = try XCTUnwrap(one.authority)
                    _ = try await f.owner.evaluateDeliveryFailure(one, authority: XCTUnwrap(authority), recordCandidateRecovery: mode != "suppressedBatch", instant: f.native.instant)
                    if (end - 117) % 2 == 0 {
                        let two = try await f.delivery(start: Double(end - 2), duration: 2, authority: authority, foreignWorker: mode == "foreignWorker")
                        _ = try await f.owner.evaluateDeliveryFailure(two, authority: XCTUnwrap(authority), recordCandidateRecovery: mode != "suppressedBatch", instant: f.native.instant)
                    }
                    if end == 129 {
                        let stale = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(current))
                        XCTAssertNil(stale, "Completed delivery does not renew stale source readiness")
                    }
                }
            }
            let before = await f.owner.snapshot
            XCTAssertEqual(before.revision, 2)
            XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000", "profile:240p30", "rate:350000"])
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(current))
            }
            let cancelledContext = try await cancelled.value
            XCTAssertNil(cancelledContext)
            authority?.revoke()
            let revoked = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(current))
            XCTAssertNil(revoked, "Historical coverage cannot retain retired delivery authority")
            await f.owner.stop()
            let stopped = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(current))
        XCTAssertNil(stopped)
        }
    }

    func testMixedDeliveryBatchSuppressionPreservesExistingDownwardAction() async throws {
        let f = try await CandidateQualityFixture.make(requiresSharedCandidateRecovery: true)
        let trial = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(trial.recommendation))
        f.native.setNow(117)
        let failure = try await f.delivery(start: 115.2, missing: Set(0..<30))
        f.owner.invalidateCandidateRecovery()
        let decision = try await f.owner.evaluateDeliveryFailure(failure, authority: XCTUnwrap(failure.authority),
            recordCandidateRecovery: false, instant: f.native.instant)
        XCTAssertEqual(decision?.recommendation?.kind, .reset)
        await f.owner.stop()
    }

    func testSharedRecoveryOptInPreservesInitialAndLegacyButBlocksRecoveredSourceAlone() async throws {
        for enabled in [false, true] {
            let f = try await CandidateQualityFixture.make(requiresSharedCandidateRecovery: enabled)
            let initial = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics))
            XCTAssertNotNil(initial, "Initial campaign stays source-only")
            let trial = try await f.owner.evaluateCandidate(f.admission)
            try await f.owner.apply(XCTUnwrap(trial.recommendation))
            f.native.setNow(116)
            try await f.owner.noteUnavailableCadence(diagnostics: try f.diagnostics())
            let reset = try await f.owner.checkTrialDeadline()
            try await f.owner.apply(XCTUnwrap(reset))
            var current: PublishingQualityTelemetry.Diagnostics?
            for (start, sequence) in [(117.0, Int64(3)), (122.0, Int64(4))] {
                f.native.setNow(start + 5.1)
                let health = try await f.freshSource(start: start, sequence: sequence)
                _ = try await f.owner.evaluate(source: health.0, diagnostics: health.1,
                    workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                    transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                    instant: f.native.instant)
                current = health.1
            }
            let recovered = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(current))
            XCTAssertEqual(recovered == nil, enabled)
            await f.owner.stop()
            let stopped = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(current))
            XCTAssertNil(stopped)
        }
    }

    func testOwnedReadinessExpiryBeforeRegistrationSkipsWithoutClosingPublisher() async throws {
        let f = try await CandidateQualityFixture.make()
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics), gate = OwnedProbeCaptureGate()
        let wrapper = NativeOwnedCandidatePublisher(publisher: gate, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner(), probes: gate.probes)
        try await f.owner.installOwnedMeasurementPublisher(wrapper)
        f.native.enqueueTimes([116.999, 117.001])
        let started = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertFalse(started)
        let state = await f.owner.snapshot
        XCTAssertFalse(state.isClosed)
        XCTAssertEqual(f.native.stops, 0)
        await f.owner.stop(); await wrapper.stop()
    }

    func testOwnedAllocationFailureJoinsBeforeSettlementAndNeverBlocksSourceEvaluation() async throws {
        let f = try await CandidateQualityFixture.make()
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let gate = OwnedProbeCaptureGate()
        let native = NativeOwnedCandidatePublisher(publisher: gate, scope: try XCTUnwrap(diagnostics.ingress).scope,
            campaignOwner: PublishingCandidateCampaignOwner(), probes: gate.probes)
        try await f.owner.installOwnedMeasurementPublisher(native)
        let started = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertTrue(started)
        await gate.waitUntilEntered()
        let state = await f.owner.snapshot
        XCTAssertFalse(state.isBusy)
        let duplicate = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertFalse(duplicate)
        gate.release()
        await f.owner.joinOwnedMeasurement()
        let ready = await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertNil(ready, "Joined failure clears source and strong health")
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        let diagnostic = await f.owner.currentDiagnostic()
        XCTAssertEqual(diagnostic["lastMeasurementOutcome"], "runFailed")
        XCTAssertEqual(diagnostic["lastMeasurementPhase"], "contextRequested")
        XCTAssertEqual(diagnostic["lastMeasurementCostReady"], "false")
        XCTAssertNotNil(diagnostic["lastMeasurementFailure"])
        await f.owner.stop()
        let stopped = await f.owner.currentDiagnostic()
        XCTAssertNil(stopped["lastMeasurementOutcome"])
    }

    func testCompletedCandidateCostWithoutApplicationIsNotReportedAsRunFailure() {
        var diagnostic = PublishingOwnedMeasurementLease.CurrentDiagnostic()
        diagnostic.phase = "costReady"
        diagnostic.costReady = true
        XCTAssertEqual(diagnostic.fields(settlement: "unapplied", at: 10)["lastMeasurementOutcome"], "costReadyWithoutApplication")
        diagnostic.failure = "cancelled"
        XCTAssertEqual(diagnostic.fields(settlement: "unapplied", at: 10)["lastMeasurementOutcome"], "runFailedAfterCostReady")
        XCTAssertEqual(diagnostic.fields(settlement: "acknowledged", at: 10)["lastMeasurementOutcome"], "acknowledged")
    }

    func testMeasurementReadinessBindsAuthenticatedSourceAndVerifiedCurrentReceiptWithoutWrites() async throws {
        let f = try await CandidateQualityFixture.make()
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let state = await f.owner.snapshot
        let context = await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        let value = try XCTUnwrap(context)
        XCTAssertEqual(value.readiness.attemptID, f.attempt)
        XCTAssertEqual(value.readiness.appliedRevision, 0)
        XCTAssertEqual(value.readiness.baseline.profileID, "240p30")
        XCTAssertEqual(value.readiness.settings.profileID, "360p30")
        XCTAssertEqual(value.readiness.validUntil, 117)
        XCTAssertEqual(value.applied.receipt.configuration, state.receipt?.configuration)
        XCTAssertEqual(value.applied.acknowledgedAt, state.acknowledgedAt)
        XCTAssertEqual(value.scope, diagnostics.ingress?.scope)
        XCTAssertEqual(value.clock, diagnostics.clock)
        let again = await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertEqual(again?.readiness, value.readiness)
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        let decision = try await f.owner.evaluateCandidate(f.admission)
        XCTAssertNotNil(decision.recommendation, "Readiness reads must not consume admission or health")
        let pending = await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertNil(pending, "Do not start competing work while advice is pending")
        await f.owner.stop()
        let stopped = await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertNil(stopped)
    }
    func testMeasurementContextAfterFallbackUsesAcknowledgedEncoderInsteadOfStartupEncoder() async throws {
        let f = try await CandidateQualityFixture.make(initialProfile: .low360, unhealthySource: true)
        let startup = try XCTUnwrap(f.native.operations.videoStartup())
        let advice = try XCTUnwrap(f.sourceAdvice)
        try await f.owner.apply(advice)
        let state = await f.owner.snapshot
        XCTAssertEqual(state.applied?.profileID, "240p30")
        XCTAssertNotEqual(state.receipt?.configuration.encoderSessionID, startup.encoderSessionID)
        f.native.setNow(121.1)
        let health = try await f.freshSource(start: 116, sequence: 3)
        _ = try await f.owner.evaluate(source: health.0, diagnostics: health.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant)
        let context = await f.owner.candidateMeasurementContext(diagnostics: health.1)
        let value = try XCTUnwrap(context)
        XCTAssertEqual(value.applied.revision, 1)
        XCTAssertEqual(value.applied.receipt.configuration, state.receipt?.configuration)
        XCTAssertEqual(value.readiness.settings.profileID, "360p30")
        XCTAssertNotEqual(value.applied.receipt.configuration.encoderSessionID, startup.encoderSessionID)
        XCTAssertEqual(f.native.calls, ["rate:600000", "profile:240p30", "rate:350000"])
        await f.owner.stop()
    }
    func testMeasurementQueryRejectsCancellationAndSuspendedNativeApplication() async throws {
        let f = try await CandidateQualityFixture.make()
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let cancelledGate = QualityWriteGate()
        let cancelled = Task {
            await cancelledGate.wait()
            return await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        }
        cancelled.cancel(); cancelledGate.release()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        let gate = QualityWriteGate()
        f.native.installProfileGate(gate)
        defer { gate.release() }
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let advice = try XCTUnwrap(decision.recommendation)
        let applying = Task { try await f.owner.apply(advice) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.entered)
        let duringWrite = await f.owner.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertNil(duringWrite)
        let inflight = await f.owner.currentDiagnostic()
        XCTAssertEqual(inflight["policyApplicationPending"], "true")
        XCTAssertEqual(inflight["policyApplicationKind"], "trial")
        XCTAssertEqual(inflight["policyApplicationProfile"], "360p30")
        XCTAssertEqual(inflight["policyApplicationBitrate"], "600000")
        XCTAssertEqual(inflight["policyTrialActive"], "false")
        XCTAssertNil(inflight["policyOwnerKey"])
        gate.release(); try await applying.value
        await f.owner.stop()
    }
    func testChangedRecordingScopeRestartsRecoveryCreditFromItsOwnSource() async throws {
        let f = try await CandidateQualityFixture.make()
        f.native.setNow(120.1)
        let health = try await f.freshSource(start: 115, sequence: 3, recordingID: "replacement")
        _ = try await f.owner.evaluate(source: health.0, diagnostics: health.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant)
        let context = await f.owner.candidateMeasurementContext(diagnostics: health.1)
        let value = try XCTUnwrap(context)
        XCTAssertEqual(value.scope.recordingID, "replacement")
        XCTAssertEqual(value.readiness.healthySince, 115, "Do not carry the earlier recording's recovery credit")
        await f.owner.stop()
    }
    func testMeasurementReadinessCannotUseUnboundHealthOrChangedNativeOwner() async throws {
        let unbound = try await CandidateQualityFixture.make(sourceHealth: false)
        let absent = await unbound.owner.candidateMeasurementContext(diagnostics: try unbound.diagnostics())
        XCTAssertNil(absent)
        let diagnostic = await unbound.owner.currentDiagnostic()
        XCTAssertNil(diagnostic["policyOwnerKey"])
        XCTAssertNil(diagnostic["policyAcceptedSourceSequence"])
        await unbound.owner.stop()
        let f = try await CandidateQualityFixture.make()
        let original = try XCTUnwrap(f.sourceDiagnostics)
        for fault in ["receipt", "clock", "origin", "recording", "revision", "match", "generation", "attempt", "closed", "missingIngress", "notPublishing"] {
            var diagnostic = original
            if fault == "receipt" {
                f.native.replaceReceipt(); diagnostic.receipt = f.native.receipt
            } else if fault == "clock" {
                diagnostic.clock = .init(sourceOrigin: .zero, publishingGeneration: 8)
            } else if fault == "origin" {
                diagnostic.clock = .init(sourceOrigin: .init(value: 1, timescale: 30), publishingGeneration: 7)
            } else if fault == "notPublishing" { diagnostic.isPublishing = false }
            else if fault == "missingIngress" { diagnostic.ingress = nil }
            else {
                let old = try XCTUnwrap(original.ingress).scope
                let scope = VideoFrameObservationScope(recordingID: fault == "recording" ? "other" : old.recordingID,
                    matchID: fault == "match" ? "other" : old.matchID,
                    broadcastGeneration: fault == "generation" ? old.broadcastGeneration + 1 : old.broadcastGeneration,
                    publishingAttemptID: fault == "attempt" ? UUID() : old.publishingAttemptID,
                    appliedProfileRevision: fault == "revision" ? old.appliedProfileRevision + 1 : old.appliedProfileRevision)
                var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
                diagnostic.ingress = fault == "closed" ? ingress.close(at: f.native.now) : ingress.poll(at: f.native.now)
            }
            let result = await f.owner.candidateMeasurementContext(diagnostics: diagnostic)
            XCTAssertNil(result, fault)
        }
        for time in [117.0001, 114, Double.nan, Double.infinity, 1e12 + 1] {
            f.native.setNow(time)
            let result = await f.owner.candidateMeasurementContext(diagnostics: original)
            XCTAssertNil(result)
        }
        f.native.setNow(115.1)
        let restored = await f.owner.candidateMeasurementContext(diagnostics: original)
        XCTAssertNotNil(restored, "A read-only rejected clock must not advance or poison policy")
        await f.owner.stop()
    }
    func testCandidateNoOpAndStaleAuthorityPreservePendingDownwardAdvice() async throws {
        for revoked in [false, true] {
            let f = try await CandidateQualityFixture.make(initialProfile: .low360, unhealthySource: true)
            let downward = try XCTUnwrap(f.sourceAdvice)
            XCTAssertEqual(downward.kind, .decrease)
            if revoked {
                f.admission.authority.revoke()
                do { _ = try await f.owner.evaluateCandidate(f.admission); XCTFail("Revoked gate accepted") }
                catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
            } else {
                let candidate = try await f.owner.evaluateCandidate(f.admission)
                XCTAssertNil(candidate.recommendation)
            }
            try await f.owner.apply(downward)
            let state = await f.owner.snapshot
            XCTAssertEqual(state.applied?.profileID, "240p30")
            XCTAssertEqual(state.revision, 1)
            XCTAssertEqual(f.native.stops, 0)
            await f.owner.stop()
        }
    }
    func testAbsentOrDifferentHealthPublicationCannotAuthorizeCandidate() async throws {
        for sourceHealth in [false, true] {
            let f = try await CandidateQualityFixture.make(sourceHealth: sourceHealth, foreignPublication: sourceHealth)
            do { _ = try await f.owner.evaluateCandidate(f.admission); XCTFail("Unrelated health admitted") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
            XCTAssertEqual(f.native.calls.count, 1)
            XCTAssertEqual(f.native.stops, 0)
            await f.owner.stop()
        }
    }
    func testProductionLadderMeasuresNextRungAndAcknowledgesActualFormat() async throws {
        let profiles = PublishingQualityDriver.productionProfiles
        XCTAssertEqual(profiles.map(\.id), ["240p30", "360p30", "720p30"])
        XCTAssertEqual(profiles.map(\.width), [426, 640, 1280])
        XCTAssertEqual(profiles.map(\.height), [240, 360, 720])
        XCTAssertEqual(profiles.map(\.minimumBitrate), [350_000, 600_000, 3_000_000])
        XCTAssertEqual(profiles.map(\.maximumBitrate), [350_000, 600_000, 3_000_000])
        for (initial, next) in [(PublishingVideoProfile.low240, PublishingVideoProfile.low360), (.low360, .hd720)] {
            let f = try await CandidateQualityFixture.make(initialProfile: initial, useProductionProfiles: true)
            let context = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics))
            XCTAssertEqual(context?.readiness.settings.profileID, next.rawValue)
            let decision = try await f.owner.evaluateCandidate(f.admission)
            let advice = try XCTUnwrap(decision.recommendation)
            XCTAssertEqual(advice.settings.profileID, next.rawValue)
            let pending = await f.owner.currentDiagnostic()
            XCTAssertNil(pending["appliedTransition"])
            try await f.owner.apply(advice)
            let state = await f.owner.snapshot, diagnostic = await f.owner.currentDiagnostic()
            let format = try XCTUnwrap(state.profileReceipt), rate = try XCTUnwrap(state.receipt)
            let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(diagnostic["appliedTransition"]).utf8)) as? [String: String])
            XCTAssertEqual(witness["formatWidth"], String(format.width))
            XCTAssertEqual(witness["formatHeight"], String(format.height))
            XCTAssertEqual(witness["profileGeneration"], String(format.publishingGeneration))
            XCTAssertEqual(witness["oldEncoder"], format.previousEncoderSessionID.uuidString.lowercased())
            XCTAssertEqual(witness["newEncoder"], format.encoderSessionID.uuidString.lowercased())
            XCTAssertNotEqual(witness["oldEncoder"], witness["newEncoder"])
            XCTAssertEqual(witness["oldPTS"], "\(format.lastOldSourcePTS.value)/\(format.lastOldSourcePTS.timescale)")
            XCTAssertEqual(witness["newPTS"], "\(format.firstNewSourcePTS.value)/\(format.firstNewSourcePTS.timescale)")
            XCTAssertEqual(witness["rateEncoder"], rate.configuration.encoderSessionID.uuidString.lowercased())
            XCTAssertEqual(witness["rateGeneration"], String(rate.publishingGeneration))
            XCTAssertEqual(witness["nativeBitrate"], String(rate.configuration.bitRate))
            let pts = try XCTUnwrap(rate.lastSubmittedSourcePTS)
            XCTAssertEqual(witness["ratePTS"], "\(pts.value)/\(pts.timescale)")
            XCTAssertEqual(witness["rateEncoder"], witness["newEncoder"])
            XCTAssertEqual(witness["rateGeneration"], witness["profileGeneration"])
            XCTAssertEqual(witness["profileNativeAt"], String(format.acknowledgedAt))
            XCTAssertEqual(witness["nativeAt"], String(rate.acceptedAt))
            XCTAssertEqual(witness["ackAt"], state.acknowledgedAt.map { String($0) })
            await f.owner.stop()
        }
    }

    func testCandidateOnlyEventAdmitsExactProfileAndDoesNotReconsumeHealth() async throws {
        let f = try await CandidateQualityFixture.make()
        let before = await f.owner.snapshot
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let advice = try XCTUnwrap(decision.recommendation)
        XCTAssertEqual(advice.candidateID, f.admission.value.id)
        XCTAssertEqual(advice.settings.profileID, "360p30")
        let evaluated = await f.owner.snapshot
        XCTAssertEqual(evaluated.lastWindow?.sequence, before.lastWindow?.sequence)
        XCTAssertEqual(evaluated.revision, 0)
        try await f.owner.apply(advice)
        let applied = await f.owner.snapshot
        XCTAssertEqual(applied.revision, 1)
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
        XCTAssertEqual(f.native.stops, 0)
        await f.owner.stop()
    }
    func testRevokedOrExpiredCandidateNeverWritesOrStopsPublishing() async throws {
        for expire in [false, true] {
            let f = try await CandidateQualityFixture.make()
            let decision = try await f.owner.evaluateCandidate(f.admission)
            let advice = try XCTUnwrap(decision.recommendation)
            if expire { f.native.setNow(115.31) } else { f.admission.authority.revoke() }
            do { try await f.owner.apply(advice); XCTFail("Stale candidate dispatched") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
            XCTAssertEqual(f.native.calls, ["rate:350000"])
            XCTAssertEqual(f.native.stops, 0)
            let state = await f.owner.snapshot
            XCTAssertFalse(state.isClosed)
            await f.owner.stop()
        }
    }
    func testNativeReceiptChangeAndScheduledAuthorityRevocationRejectBeforeAdmission() async throws {
        for receiptChanged in [false, true] {
            let f = try await CandidateQualityFixture.make()
            if receiptChanged { f.native.replaceReceipt() } else { f.admission.authority.revoke() }
            do { _ = try await f.owner.evaluateCandidate(f.admission); XCTFail("Revoked input admitted") }
            catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
            XCTAssertEqual(f.native.calls.count, 1)
            XCTAssertEqual(f.native.stops, 0)
            await f.owner.stop()
        }
    }
    func testNewHealthSupersedesCandidateWitness() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let advice = try XCTUnwrap(decision.recommendation)
        f.native.setNow(116)
        _ = try await f.owner.evaluate(f.window(start: 115, duration: 1, sequence: 2))
        do { try await f.owner.apply(advice); XCTFail("Superseded candidate dispatched") }
        catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
        XCTAssertEqual(f.native.calls.count, 1)
        XCTAssertEqual(f.native.stops, 0)
        await f.owner.stop()
    }
    func testPostAcknowledgmentDeliveryStillResetsForRealAuthorityChangesUncertaintyAndFailure() async throws {
        for fault in ["replacement", "uncertain", "failure", "oldRevision"] {
            let f = try await CandidateQualityFixture.make()
            let before = try await f.delivery(start: 113)
            let original = try XCTUnwrap(before.authority)
            _ = try await f.owner.evaluateDeliveryFailure(before, authority: original, instant: f.native.instant)
            let decision = try await f.owner.evaluateCandidate(f.admission)
            try await f.owner.apply(XCTUnwrap(decision.recommendation))
            f.native.setNow(117.6)
            var after = try await f.delivery(start: 116, authority: fault == "replacement" ? nil : original,
                missing: fault == "failure" ? Set(0..<10) : [], uncertain: fault == "uncertain")
            if fault == "oldRevision" {
                after = .init(source: after.source, delivery: after.delivery, appliedRevision: 0, result: after.result,
                    classifiedAt: after.classifiedAt, observedAtLowerBound: after.observedAtLowerBound, authority: after.authority)
            }
            let authority = try XCTUnwrap(after.authority)
            if fault == "uncertain" { XCTAssertGreaterThan(after.result.uncertainFrames, 0) }
            if fault == "oldRevision" {
                do { _ = try await f.owner.evaluateDeliveryFailure(after, authority: authority, instant: f.native.instant); XCTFail("Old revision") }
                catch { XCTAssertEqual(error as? PublishingQualityTelemetry.Failure, .ownership) }
            } else {
                let delivery = try await f.owner.evaluateDeliveryFailure(after, authority: authority, instant: f.native.instant)
                if fault == "failure" { XCTAssertEqual(delivery?.recommendation?.kind, .reset) }
            }
            let reset = try await f.owner.checkTrialDeadline()
            XCTAssertEqual(reset?.kind, .reset, fault)
            await f.owner.stop()
        }
    }

    func testAppliedTransportRollbackRetainsSelectedIntervalAndActualDelayLimit() async throws {
        let f = try await CandidateQualityFixture.make()
        let trial = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(trial.recommendation))
        f.native.setNow(120.2)
        var diagnostics = try await f.freshSource(start: 115.1, sequence: 3).1
        var transport = PublishingTransportStatisticsTracker()
        for (index, time) in [119.8, 120.2].enumerated() {
            transport.observe(.init(publishingGeneration: 7, sampledAt: time,
                elapsedMilliseconds: Int64(time * 1000), sentBytes: UInt64(10000 + index * 1000),
                retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 300,
                estimatedBandwidthMbps: 10, senderBufferedBytes: 0, senderBufferMilliseconds: 0,
                availableSenderBytes: 10000, senderDeliveryDelayMilliseconds: 1000))
        }
        diagnostics.transport = transport.snapshot
        let decision = try await f.owner.evaluateLocalPressure(diagnostics: diagnostics,
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500,
                maximumRetransmittedFraction: 0.01, policy: .recoveryBudget))
        let advice = try XCTUnwrap(decision?.recommendation)
        XCTAssertEqual(advice.kind, .reset)
        try await f.owner.apply(advice)
        let diagnostic = await f.owner.currentDiagnostic()
        let encoded = try XCTUnwrap(diagnostic["appliedTransition"])
        let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String])
        XCTAssertEqual(witness["input"], "localPressure")
        XCTAssertEqual(witness["transport"], "elevated")
        XCTAssertEqual(witness["start"].flatMap(Double.init), 119.95)
        XCTAssertEqual(witness["end"], "120.2")
        XCTAssertEqual(witness["transportStart"], "119.8")
        XCTAssertEqual(witness["transportEnd"], "120.2")
        XCTAssertEqual(witness["maxRTTMs"], "500.0")
        XCTAssertEqual(witness["rttMs"], "300.0")
        XCTAssertEqual(witness["delayRTTMs"], "300.0")
        XCTAssertEqual(witness["delayRTTLimitMs"], "250.0")
        XCTAssertEqual(witness["rttDelayMs"], "1000")
        XCTAssertEqual(witness["drops"], "0")
        XCTAssertEqual(witness["revision"], "2")
        await f.owner.stop()
    }

    func testResetEpisodeRetainsPressureCauseAfterStaleAdmissionAndHealthyReissue() async throws {
        let f = try await CandidateQualityFixture.make()
        let trial = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(trial.recommendation))
        f.native.setNow(120.2)
        var diagnostics = try await f.freshSource(start: 115.1, sequence: 3).1
        var transport = PublishingTransportStatisticsTracker()
        for (index, time) in [119.8, 120.2].enumerated() {
            transport.observe(.init(publishingGeneration: 7, sampledAt: time,
                elapsedMilliseconds: Int64(time * 1000), sentBytes: UInt64(10000 + index * 1000),
                retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 300,
                estimatedBandwidthMbps: 10, senderBufferedBytes: 0, senderBufferMilliseconds: 0,
                availableSenderBytes: 10000, senderDeliveryDelayMilliseconds: 1000))
        }
        diagnostics.transport = transport.snapshot
        let decision = try await f.owner.evaluateLocalPressure(diagnostics: diagnostics,
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500,
                maximumRetransmittedFraction: 0.01, policy: .recoveryBudget))
        let advice = try XCTUnwrap(decision?.recommendation)
        XCTAssertEqual(advice.kind, .reset)
        let prior = await f.owner.currentDiagnostic()
        f.native.setNow(advice.validUntil + 0.01)
        do { try await f.owner.apply(advice); XCTFail("Expired reset cannot reach native mutation") }
        catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
        let rejected = await f.owner.currentDiagnostic()
        XCTAssertEqual(prior["appliedTransition"], rejected["appliedTransition"])
        f.native.setNow(125.3)
        let healthy = try await f.freshSource(start: 120.2, sequence: 4)
        let renewed = try await f.owner.evaluate(source: healthy.0, diagnostics: healthy.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant)
        let replacement = try XCTUnwrap(renewed.recommendation)
        XCTAssertEqual(replacement.kind, .reset)
        XCTAssertFalse(renewed.reasons.contains(.transportPressure))
        XCTAssertNotEqual(replacement, advice)
        try await f.owner.apply(replacement)
        let diagnostic = await f.owner.currentDiagnostic()
        let encoded = try XCTUnwrap(diagnostic["appliedTransition"])
        let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String])
        XCTAssertEqual(witness["sequence"], String(replacement.windowSequence))
        XCTAssertEqual(witness["causeSequence"], String(advice.windowSequence))
        XCTAssertEqual(witness["validUntil"], String(replacement.validUntil))
        XCTAssertEqual(witness["input"], "localPressure")
        XCTAssertEqual(witness["transport"], "elevated")
        XCTAssertEqual(witness["start"].flatMap(Double.init), 119.95)
        XCTAssertEqual(witness["end"], "120.2")
        XCTAssertEqual(witness["transportStart"], "119.8")
        XCTAssertEqual(witness["transportEnd"], "120.2")
        XCTAssertEqual(witness["maxRTTMs"], "500.0")
        XCTAssertEqual(witness["rttMs"], "300.0")
        XCTAssertEqual(witness["delayRTTMs"], "300.0")
        XCTAssertEqual(witness["delayRTTLimitMs"], "250.0")
        XCTAssertEqual(witness["rttDelayMs"], "1000")
        XCTAssertEqual(witness["drops"], "0")
        XCTAssertEqual(witness["revision"], "2")
        await f.owner.stop()
    }

    func testAppliedWorkerPressureContainsClassifiedProcessingValuesAndLimits() async throws {
        for cause in ["omitted", "filter", "processing"] {
            let f = try await CandidateQualityFixture.make()
            let trial = try await f.owner.evaluateCandidate(f.admission)
            try await f.owner.apply(XCTUnwrap(trial.recommendation))
            f.native.setNow(120.2)
            let (source, diagnostics) = try await f.freshSource(start: 115.1, sequence: 3)
            let report = try XCTUnwrap(source.processing), interval = report.interval
            let replacement = WorkerProcessingReport(scopeID: report.scopeID, encoder: report.encoder,
                previousSequence: report.previousSequence, sequence: report.sequence, firstPTS: report.firstPTS,
                interval: .init(sourceStartExclusive: interval.sourceStartExclusive, sourceEndInclusive: interval.sourceEndInclusive,
                    decodedFrames: 150, submittedFrames: cause == "omitted" ? 149 : 150,
                    completedFrames: cause == "omitted" ? 149 : 150, pendingFrames: 0,
                    omittedBeforeEncoderFrames: cause == "omitted" ? 1 : 0,
                    filterDuration: .init(meanMs: 1, maximumMs: cause == "filter" ? 251 : 4),
                    processingDuration: .init(meanMs: 20, maximumMs: cause == "processing" ? 1001 : 30)))
            let input = WorkerSourceIntervalObservation(interval: source.interval, nativeClock: source.nativeClock,
                workerId: source.workerId, workerEpoch: source.workerEpoch, workerAttempt: source.workerAttempt,
                publication: source.publication, previousSequence: source.previousSequence, sequence: source.sequence,
                previousDecodedPTS: source.previousDecodedPTS, firstDecodedPTS: source.firstDecodedPTS,
                lastDecodedPTS: source.lastDecodedPTS, freshness: source.freshness, processing: replacement)
            let decision = try await f.owner.evaluate(source: input, diagnostics: diagnostics,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            XCTAssertTrue(decision.reasons.contains(.workerPressure))
            try await f.owner.apply(XCTUnwrap(decision.recommendation))
            let diagnostic = await f.owner.currentDiagnostic()
            let encoded = try XCTUnwrap(diagnostic["appliedTransition"])
            let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String])
            XCTAssertEqual(witness["worker"], "elevated")
            XCTAssertEqual(witness["workerOmitted"], cause == "omitted" ? "1" : "0")
            XCTAssertEqual(witness["workerFilterMs"], cause == "filter" ? "251.0" : "4.0")
            XCTAssertEqual(witness["workerProcessingMs"], cause == "processing" ? "1001.0" : "30.0")
            XCTAssertEqual(witness["maxFilterMs"], "250.0")
            XCTAssertEqual(witness["maxProcessingMs"], "1000.0")
            await f.owner.stop()
        }
    }

    func testAppliedQueuePressureContainsUsedThreshold() async throws {
        let f = try await CandidateQualityFixture.make()
        let trial = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(trial.recommendation))
        f.native.setNow(120.2)
        let (source, diagnostics) = try await f.freshSource(start: 115.1, sequence: 3, unhealthy: true)
        let decision = try await f.owner.evaluate(source: source, diagnostics: diagnostics,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant)
        XCTAssertTrue(decision.reasons.contains(.queuePressure))
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        let diagnostic = await f.owner.currentDiagnostic()
        let encoded = try XCTUnwrap(diagnostic["appliedTransition"])
        let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String])
        XCTAssertEqual(witness["queue"], "1.0")
        XCTAssertEqual(witness["queueLimit"], "0.75")
        await f.owner.stop()
    }

    func testAppliedTransitionKeepsFirstInvalidationCauseThroughResetACK() async throws {
        for input in ["cadenceUnavailable", "sourceRejected", "deliveryRejected", "windowRejected"] {
            let f = try await CandidateQualityFixture.make()
            let decision = try await f.owner.evaluateCandidate(f.admission)
            try await f.owner.apply(XCTUnwrap(decision.recommendation))
            let before = await f.owner.currentDiagnostic()
            if input == "cadenceUnavailable" {
                try? await f.owner.noteUnavailableCadence(diagnostics: XCTUnwrap(f.sourceDiagnostics))
            } else if input == "sourceRejected" {
                _ = try? await f.owner.evaluate(source: XCTUnwrap(f.source), diagnostics: XCTUnwrap(f.sourceDiagnostics),
                    workerLimits: nil, transportLimits: nil, instant: f.native.instant)
            } else if input == "windowRejected" {
                let snapshot = await f.owner.snapshot
                _ = try? await f.owner.evaluate(.init(attemptID: snapshot.attemptID, sequence: 999,
                    appliedRevision: 0, start: 110, end: 115, capturedFreshFrames: 150,
                    encodedFreshFrames: 150, receiver: .init(freshFrames: 150, observedAt: 115),
                    sourceLoss: .init(expectedFrames: 150, lostFrames: 0), meanQueueOccupancy: 0.1,
                    usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
                    workerPressure: .nominal, transportPressure: .nominal))
            } else {
                f.native.setNow(117.6)
                let delivery = try await f.delivery(start: 116)
                let stale = PublishingDeliveryObservation(source: delivery.source, delivery: delivery.delivery,
                    appliedRevision: 0, result: delivery.result, classifiedAt: delivery.classifiedAt,
                    observedAtLowerBound: delivery.observedAtLowerBound, authority: delivery.authority)
                _ = try? await f.owner.evaluateDeliveryFailure(stale, authority: XCTUnwrap(delivery.authority), instant: f.native.instant)
            }
            // Later invalidations and deadline polling cannot relabel the first cause.
            try? await f.owner.noteUnavailableCadence(diagnostics: XCTUnwrap(f.sourceDiagnostics))
            let pending = try await f.owner.checkTrialDeadline()
            let during = await f.owner.currentDiagnostic()
            XCTAssertEqual(during["appliedTransition"], before["appliedTransition"])
            try await f.owner.apply(XCTUnwrap(pending))
            let after = await f.owner.currentDiagnostic()
            let encoded = try XCTUnwrap(after["appliedTransition"])
            let witness = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String])
            XCTAssertEqual(witness["input"], input)
            XCTAssertEqual(witness["reasons"], "telemetryInvalidated")
            XCTAssertEqual(witness["fromRevision"], "1")
            XCTAssertEqual(witness["revision"], "2")
            XCTAssertEqual(witness["kind"], "reset")
            XCTAssertNotNil(witness["error"])
            await f.owner.stop()
        }
    }

    func testCurrentTrialDiagnosticTimeoutIsResetNotConfirmation() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        f.native.setNow(138)
        let recommendation = try await f.owner.checkTrialDeadline()
        let reset = try XCTUnwrap(recommendation)
        let timedOut = await f.owner.currentDiagnostic()
        XCTAssertEqual(timedOut["policyTrialActive"], "false")
        XCTAssertEqual(timedOut["policyMinimumResetRequired"], "true")
        XCTAssertEqual(timedOut["policyPendingKind"], "reset")
        XCTAssertEqual(timedOut["policyAppliedRevision"], "1")
        try await f.owner.apply(reset)
        let fallback = await f.owner.currentDiagnostic()
        XCTAssertEqual(fallback["policyMinimumResetRequired"], "false")
        XCTAssertEqual(fallback["policyAppliedRevision"], "2")
        XCTAssertEqual(fallback["policyAppliedProfile"], "240p30")
        XCTAssertNil(fallback["policyOwnerKey"])
        await f.owner.stop()
    }

    func testCurrentOwnerDigestChangesForAcceptedWorkerPublicationAndProcessingScopes() async throws {
        for variant in ["epoch", "worker", "attempt", "reader", "publisher", "processing", "profileRevision", "pipelineReadKey"] {
            let f = try await CandidateQualityFixture.make()
            let before = await f.owner.currentDiagnostic()
            let original = try XCTUnwrap(before["policyOwnerKey"])
            f.native.setNow(120.1)
            let changed = try await f.freshSource(start: 115, sequence: 3, identityVariant: variant)
            _ = try await f.owner.evaluate(source: changed.0, diagnostics: changed.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            let after = await f.owner.currentDiagnostic()
            let replacement = try XCTUnwrap(after["policyOwnerKey"], variant)
            XCTAssertNotEqual(original, replacement, variant)
            if variant == "profileRevision" {
                XCTAssertEqual(before["policySourceScopeKey"], after["policySourceScopeKey"])
            } else {
                XCTAssertNotEqual(before["policySourceScopeKey"], after["policySourceScopeKey"], variant)
            }
            XCTAssertEqual(after["policyAppliedRevision"], before["policyAppliedRevision"])
            await f.owner.stop()
        }
    }

    func testDecodedPipelineCoordinatesComeOnlyFromExactAcceptedInterval() async throws {
        let f = try await CandidateQualityFixture.make()
        let initial = await f.owner.currentDiagnostic()
        XCTAssertNil(initial["policyPipelineReadKey"])
        let initialSource = try XCTUnwrap(f.source)
        XCTAssertEqual(initial["policyDecodedPreviousPTS"], String(initialSource.previousDecodedPTS))
        XCTAssertEqual(initial["policyDecodedFirstPTS"], String(initialSource.firstDecodedPTS))
        XCTAssertEqual(initial["policyDecodedLastPTS"], String(initialSource.lastDecodedPTS))
        XCTAssertEqual(initial["policyDecodedFrameCount"], String(initialSource.interval.decodedFrames))
        let key = "5d75f38b3e289ae59af50a3cf51905342960e21554535120e565416c63d0e4f2"
        f.native.setNow(120.1)
        let first = try await f.freshSource(start: 115, sequence: 3, pipelineReadKey: key)
        // Merely obtaining a newer status cannot re-label the accepted mapping.
        let beforeAcceptance = await f.owner.currentDiagnostic()
        XCTAssertNil(beforeAcceptance["policyPipelineReadKey"])
        _ = try await f.owner.evaluate(source: first.0, diagnostics: first.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
        let accepted = await f.owner.currentDiagnostic()
        XCTAssertEqual(accepted["policyPipelineReadKey"], key)
        XCTAssertNotEqual(initial["policySourceScopeKey"], accepted["policySourceScopeKey"])
        XCTAssertEqual(accepted["policyDecodedPreviousPTS"], String(first.0.previousDecodedPTS))
        XCTAssertEqual(accepted["policyDecodedFirstPTS"], String(first.0.firstDecodedPTS))
        XCTAssertEqual(accepted["policyDecodedLastPTS"], String(first.0.lastDecodedPTS))
        XCTAssertEqual(accepted["policyDecodedFrameCount"], "150")
        f.native.setNow(125.2)
        let missing = try await f.freshSource(start: 120.1, sequence: 4)
        _ = try await f.owner.evaluate(source: missing.0, diagnostics: missing.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
        let legacy = await f.owner.currentDiagnostic()
        XCTAssertNil(legacy["policyPipelineReadKey"])
        XCTAssertEqual(legacy["policySourceScopeKey"], initial["policySourceScopeKey"], "Missing key preserves legacy hash")
        XCTAssertEqual(legacy["policyDecodedLastPTS"], String(missing.0.lastDecodedPTS))
        do {
            _ = try await f.owner.evaluate(source: first.0, diagnostics: first.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
            XCTFail("Stale source must be rejected")
        } catch {}
        for state in [await f.owner.currentDiagnostic()] {
            for key in ["policyPipelineReadKey", "policyDecodedPreviousPTS", "policyDecodedFirstPTS", "policyDecodedLastPTS", "policyDecodedFrameCount"] { XCTAssertNil(state[key]) }
        }
        await f.owner.stop()
        let closed = await f.owner.currentDiagnostic()
        XCTAssertNil(closed["policyDecodedLastPTS"])
        XCTAssertNil(closed["policyPipelineReadKey"])
    }

    func testCurrentTrialDiagnosticUsesBoundSourceAndStableOwnerThroughConfirmation() async throws {
        let f = try await CandidateQualityFixture.make()
        let initial = await f.owner.currentDiagnostic()
        XCTAssertNotNil(initial["policyOwnerKey"])
        XCTAssertEqual(initial["policySourceScopeKey"]?.count, 64)
        XCTAssertNotNil(initial["policySourceStartPTSSeconds"])
        XCTAssertNotNil(initial["policyCaptureStartUptimeSeconds"])
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let pending = await f.owner.currentDiagnostic()
        XCTAssertEqual(pending["policyPendingKind"], "trial")
        XCTAssertEqual(pending["policyPendingProfile"], "360p30")
        XCTAssertEqual(pending["policyTrialActive"], "false")
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        let acknowledged = await f.owner.currentDiagnostic()
        XCTAssertEqual(acknowledged["policyTrialActive"], "true")
        XCTAssertNil(acknowledged["policyOwnerKey"], "Application invalidates the old source binding")
        XCTAssertEqual(acknowledged["policyApplicationPending"], "false")
        let retained = await f.owner.snapshot
        XCTAssertNotNil(retained.application, "Historical receipt must not appear in flight")
        var observations: [[String: String]] = []
        for (start, sequence) in [(115.1, Int64(3)), (120.1, Int64(4))] {
            f.native.setNow(start + 5.1)
            let source = try await f.freshSource(start: start, sequence: sequence)
            _ = try await f.owner.evaluate(source: source.0, diagnostics: source.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            let diagnostic = await f.owner.currentDiagnostic()
            let repeated = await f.owner.currentDiagnostic()
            XCTAssertEqual(diagnostic, repeated)
            XCTAssertEqual(diagnostic["policySourceStartPTSSeconds"].flatMap(Double.init), CMTimeGetSeconds(source.0.interval.sourceStartExclusive))
            XCTAssertEqual(diagnostic["policySourceEndPTSSeconds"].flatMap(Double.init), CMTimeGetSeconds(source.0.interval.sourceEndInclusive))
            observations.append(diagnostic)
        }
        let probing = observations[0], confirmed = observations[1]
        XCTAssertEqual(probing["policyTrialActive"], "true")
        XCTAssertEqual(probing["policyTrialHealthyCoverageSeconds"], "5.0")
        XCTAssertEqual(confirmed["policyTrialActive"], "false")
        XCTAssertEqual(probing["policyOwnerKey"]?.count, 64)
        XCTAssertEqual(probing["policyOwnerKey"], confirmed["policyOwnerKey"])
        XCTAssertEqual(initial["policySourceScopeKey"], confirmed["policySourceScopeKey"])
        XCTAssertEqual(confirmed["policyCaptureStartUptimeSeconds"], "120.1")
        XCTAssertEqual(confirmed["policyCaptureEndUptimeSeconds"], confirmed["policyAcceptedSourceWindowEnd"])
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: confirmed).count, 4096)
        XCTAssertNotEqual(initial["policyOwnerKey"], confirmed["policyOwnerKey"])
        XCTAssertEqual(confirmed["policyAppliedRevision"], "1")
        XCTAssertEqual(confirmed["policyAppliedProfile"], "360p30")
        XCTAssertEqual(confirmed["policyRecommendationPending"], "false")
        XCTAssertEqual(confirmed["policyApplicationPending"], "false")
        XCTAssertEqual(confirmed["policyMinimumResetRequired"], "false")
        XCTAssertNotEqual(probing["policyAcceptedSourceSequence"], confirmed["policyAcceptedSourceSequence"])
        XCTAssertNotEqual(probing["policyAcceptedSourceWindowEnd"], confirmed["policyAcceptedSourceWindowEnd"])
        f.native.setNow(130.2)
        let replacement = try await f.freshSource(start: 125.1, sequence: 5, recordingID: "replacement")
        _ = try await f.owner.evaluate(source: replacement.0, diagnostics: replacement.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant)
        let changed = await f.owner.currentDiagnostic()
        XCTAssertNotEqual(confirmed["policyOwnerKey"], changed["policyOwnerKey"])
        try await f.owner.noteUnavailableCadence(diagnostics: replacement.1)
        let invalidated = await f.owner.currentDiagnostic()
        XCTAssertNil(invalidated["policyOwnerKey"])
        XCTAssertNil(invalidated["policySourceScopeKey"])
        XCTAssertNil(invalidated["policySourceStartPTSSeconds"])
        await f.owner.stop()
        let closed = await f.owner.currentDiagnostic()
        XCTAssertNil(closed["policyOwnerKey"])
        XCTAssertNil(closed["policyTrialActive"])
        XCTAssertNil(closed["policyAppliedRevision"])
    }

    func testAcknowledgedTrialKeepsSameDeliveryAuthorityWithoutResettingProbation() async throws {
        for hadDeliveryBeforeTrial in [false, true] {
        let f = try await CandidateQualityFixture.make()
        let before = try await f.delivery(start: 113)
        let authority = try XCTUnwrap(before.authority)
        if hadDeliveryBeforeTrial {
            _ = try await f.owner.evaluateDeliveryFailure(before, authority: authority, instant: f.native.instant)
        }
        let decision = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        f.native.setNow(117.6)
        let after = try await f.delivery(start: 116, authority: authority)
        XCTAssertEqual(after.appliedRevision, 1)
        XCTAssertEqual(after.result.onTimeFrames, 30)
        let deliveryDecision = try await f.owner.evaluateDeliveryFailure(after, authority: authority, instant: f.native.instant)
        XCTAssertNil(deliveryDecision)
        let deadline = try await f.owner.checkTrialDeadline()
        XCTAssertNil(deadline, "An acknowledged encoding revision is not a worker-context replacement")
        f.native.setNow(120.1)
        let probing = try await f.owner.evaluate(f.window(start: 115.1, duration: 5, sequence: 2, revision: 1))
        XCTAssertEqual(probing.state, .probing)
        f.native.setNow(125.1)
        let confirmed = try await f.owner.evaluate(f.window(start: 120.1, duration: 5, sequence: 3, revision: 1))
        XCTAssertTrue(confirmed.reasons.contains(.trialConfirmed))
        await f.owner.stop()
        }
    }

    func testOwnedApplicationOutlivesCandidateAuthorityAndConfirmsTrial() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let advice = try XCTUnwrap(decision.recommendation)
        f.native.setProfileAction { f.admission.authority.revoke(); f.native.setNow(115.6) }
        try await f.owner.apply(advice)
        let acknowledged = await f.owner.currentDiagnostic()
        XCTAssertEqual(acknowledged["policyTrialActive"], "true")
        XCTAssertEqual(acknowledged["policyApplicationPending"], "false")
        XCTAssertEqual(acknowledged["policyAppliedRevision"], "1")
        XCTAssertEqual(acknowledged["policyAttemptID"], f.attempt.uuidString.lowercased())
        XCTAssertEqual(acknowledged["policyAcknowledgedAtUptimeSeconds"], "115.6")
        f.native.setNow(120.6)
        let probing = try await f.owner.evaluate(f.window(start: 115.6, duration: 5, sequence: 2, revision: 1))
        XCTAssertEqual(probing.state, .probing)
        f.native.setNow(125.6)
        let confirmed = try await f.owner.evaluate(f.window(start: 120.6, duration: 5, sequence: 3, revision: 1))
        XCTAssertTrue(confirmed.reasons.contains(.trialConfirmed))
        XCTAssertEqual(f.native.stops, 0)
        await f.owner.stop()
    }
}

/// Shared real-admission fixture for session and driver boundary tests.
struct CandidateQualityFixture: Sendable {
    let native: CandidateQualityNative
    let owner: PublishingQualitySession
    let admission: PublishingCandidateAdmission
    let source: WorkerSourceIntervalObservation?
    let sourceDiagnostics: PublishingQualityTelemetry.Diagnostics?
    let sourceAdvice: QualityController.Recommendation?
    var attempt: UUID { admission.value.attemptID }
    func window(start: Double, duration: Double, sequence: UInt64, revision: UInt64 = 0) -> QualityController.Window {
        Self.window(attempt: attempt, start: start, duration: duration, sequence: sequence, revision: revision)
    }
    static func window(attempt: UUID, start: Double, duration: Double, sequence: UInt64, revision: UInt64 = 0) -> QualityController.Window {
        let frames = Int((duration * 30).rounded())
        return .init(attemptID: attempt, sequence: sequence, appliedRevision: revision, start: start, end: start + duration,
            capturedFreshFrames: frames, encodedFreshFrames: frames, receiver: .init(freshFrames: frames, observedAt: start + duration),
            sourceLoss: .init(expectedFrames: frames, lostFrames: 0), meanQueueOccupancy: 0.1,
            usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)
    }
    func diagnostics() throws -> PublishingQualityTelemetry.Diagnostics {
        var ingress = try LiveIngressObservationAccumulator(scope: admissionMeasurementScope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        ingress.updateOccupancy(items: 0, bytes: 0, phase: .admitting, at: 100)
        return .init(isPublishing: true, clock: .init(sourceOrigin: .zero, publishingGeneration: 7),
            receipt: native.receipt, ingress: ingress.poll(at: native.now),
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
    }
    func delivery(start: Double, duration: Double = 1, authority suppliedAuthority: PublishingDeliveryAuthority? = nil,
                  missing: Set<Int> = [], uncertain: Bool = false, foreignWorker: Bool = false) async throws -> PublishingDeliveryObservation {
        let state = await owner.snapshot, receipt = try XCTUnwrap(state.receipt)
        let applied = PublishingQualityTelemetry.Applied(attemptID: attempt, revision: try XCTUnwrap(state.revision),
            settings: try XCTUnwrap(state.applied), receipt: receipt, acknowledgedAt: try XCTUnwrap(state.acknowledgedAt))
        let scope = admissionMeasurementScope
        var history = try VideoSourceHistory(scope: scope, capacity: 128)
        var arrivals: [[Any]] = []
        for i in -1...Int(duration * 30) {
            let time = start + Double(i) / 30, pts = CMTime(value: Int64(1000 + i), timescale: 30)
            history.observe(.captureVideo, sourcePTS: pts, at: time)
            history.observe(.encodedVideo, sourcePTS: pts, at: time,
                encoding: VideoEncodingObservation(encoderSessionID: receipt.configuration.encoderSessionID,
                    configuration: receipt.configuration, submittedAt: time, completedAt: time))
            if !missing.contains(i) {
                arrivals.append([Int64(1000 + i) * 3000 + 9000 - Int64(admission.receiver.publication.clock.originPTS)!, (time + (uncertain ? 0.55 : 0.01)) * 1000])
            }
        }
        let wire: [String: Any] = ["formatVersion": 1, "scopeID": "55555555-5555-4555-8555-555555555555",
            "sampledAtMs": native.now * 1000, "coverageAtMs": 0,
            "afterOrdinal": 0, "lastOrdinal": arrivals.count, "arrivals": arrivals,
            "invalidReason": NSNull(), "ended": false]
        let packet = try JSONDecoder().decode(DecoderDeliveryPacket.self, from: JSONSerialization.data(withJSONObject: wire))
        var observation = WorkerObservation(gameId: scope.matchID, generation: scope.broadcastGeneration,
            state: .producingOutput, reason: nil, attempt: 1, frame: 32, outTimeUs: 1_000_000, scoreRevision: 1,
            decodedVideo: .init(completed: nil, invalidReason: nil, ended: false, clock: "mpegts-pts-90k-v1"))
        observation.decoderDelivery = packet
        let publication = admission.receiver.publication
        var response = WorkerMediaStatusResponse(status: .init(gameId: scope.matchID, generation: scope.broadcastGeneration,
            workerId: foreignWorker ? "foreign" : "mac", state: .producingOutput, observation: observation, observedAt: "2040-01-01T00:00:00Z",
            expiresAt: "2040-01-01T00:00:05Z", workerEpoch: admission.receiver.workerEpoch, publication: publication),
            serverTime: "2040-01-01T00:00:00Z")
        response.status.decoderDeliveryAgeUpperBoundMs = uncertain ? 100 : 0
        var tracker = WorkerDecoderDeliveryTracker()
        let delivery = try XCTUnwrap(tracker.observe(response: response, expectedPublishingAttemptID: attempt,
            receivedAt: native.instant, requestDuration: .zero))
        let authority = suppliedAuthority ?? PublishingDeliveryAuthority(delivery: delivery)
        let clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: receipt.publishingGeneration)!
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: clock, receipt: receipt,
            ingress: ingress.poll(at: native.now), transport: PublishingTransportStatisticsTracker().snapshot,
            thermal: PublishingThermalTracker().snapshot)
        return try PublishingDeliveryObservation.classify(history: history.snapshot,
            clock: .init(scope: scope, transportClock: clock, isClosed: false), applied: applied,
            diagnostics: diagnostics, delivery: delivery, windowStart: start, windowEnd: start + duration,
            at: native.now, instant: native.instant, maximumSampleAge: 0.25, latencyBudget: 0.5, authority: authority)
    }

    func freshCadence() throws -> WorkerDecoderCadenceFreshness {
        let publication = String(data: try JSONEncoder().encode(admission.receiver.publication), encoding: .utf8)!
        let json = """
        {"status":{"gameId":"match","generation":2,"workerId":"mac","workerEpoch":"\(admission.receiver.workerEpoch)","state":"producing_output",
        "observation":{"gameId":"match","generation":2,"state":"producing_output","reason":null,"attempt":1,"frame":12,"outTimeUs":400000,"scoreRevision":1,
        "decodedVideo":{"clock":"mpegts-pts-90k-v1","completed":null,"invalidReason":null,"ended":false},
        "decoderCadence":{"formatVersion":1,"scopeID":"11111111-1111-4111-8111-111111111111","oneSecond":null,"twoSeconds":null,"progress":{"lastFreshPTS":180000,"ageMs":50,"stalled":false},"invalidReason":null,"ended":false}},
        "observedAt":"2040-01-01T00:00:00Z","expiresAt":"2040-01-01T00:00:05Z",
        "publication":\(publication),"decoderCadenceAgeUpperBoundMs":0},"serverTime":"2040-01-01T00:00:01Z"}
        """
        return try XCTUnwrap(WorkerDecoderCadenceFreshness(response: JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(json.utf8)),
            expectedPublishingAttemptID: attempt, receivedAt: native.instant, requestDuration: .zero))
    }

    private var admissionMeasurementScope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 2, publishingAttemptID: attempt, appliedProfileRevision: 1)
    }
    func freshSource(start: Double, sequence: Int64, recordingID: String = "recording", unhealthy: Bool = false, identityVariant: String? = nil, pipelineReadKey: String? = nil) async throws -> (WorkerSourceIntervalObservation, PublishingQualityTelemetry.Diagnostics) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/receiver-probe-status-v1.json")
        let template = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
        let state = await owner.snapshot
        let applied = PublishingQualityTelemetry.Applied(attemptID: attempt, revision: try XCTUnwrap(state.revision),
            settings: try XCTUnwrap(state.applied), receipt: try XCTUnwrap(state.receipt), acknowledgedAt: try XCTUnwrap(state.acknowledgedAt))
        let afterReceipt = applied.receipt.lastSubmittedSourcePTS.map { Int64((CMTimeGetSeconds($0) * 30).rounded(.up)) + 1 } ?? 300
        let firstFrame = max(300 + Int64(max(0, start - 110) * 30), afterReceipt)
        return try Self.source(native: native, template: template, applied: applied, unhealthy: unhealthy, start: start, sequence: sequence, recordingID: recordingID, firstFrame: firstFrame, identityVariant: identityVariant, pipelineReadKey: pipelineReadKey)
    }
    private static func source(native: CandidateQualityNative, template: WorkerMediaStatusResponse,
                               applied: PublishingQualityTelemetry.Applied, unhealthy: Bool = false, start: Double = 110, sequence: Int64 = 2, recordingID: String = "recording", firstFrame: Int64 = 300, identityVariant: String? = nil, pipelineReadKey: String? = nil) throws -> (WorkerSourceIntervalObservation, PublishingQualityTelemetry.Diagnostics) {
        var template = template
        template.status.publication?.pipelineReadKey = identityVariant == "pipelineReadKey" ? String(repeating: "b", count: 64) : pipelineReadKey
        if identityVariant == "epoch" { template.status.workerEpoch = "10000000-0000-4000-8000-000000000098" }
        if identityVariant == "worker" { template.status.workerId = "replacement" }
        if identityVariant == "attempt" { template.status.observation?.attempt = 2 }
        if identityVariant == "reader" { template.status.publication?.readerId = "10000000-0000-4000-8000-000000000099" }
        if identityVariant == "publisher" { template.status.publication?.publisherId = "10000000-0000-4000-8000-000000000097" }
        let scope = VideoFrameObservationScope(recordingID: recordingID, matchID: "match", broadcastGeneration: 2,
            publishingAttemptID: applied.attemptID, appliedProfileRevision: identityVariant == "profileRevision" ? 2 : 1)
        var history = try VideoSourceHistory(scope: scope, capacity: 1024)
        for index in 0...150 {
            let time = start + Double(index) / 30, pts = CMTime(value: firstFrame + Int64(index), timescale: 30)
            history.observe(.captureVideo, sourcePTS: pts, at: time)
            let encoding = VideoEncodingObservation(encoderSessionID: applied.receipt.configuration.encoderSessionID,
                configuration: applied.receipt.configuration, submittedAt: time, completedAt: time + 0.01)!
            history.observe(.encodedVideo, sourcePTS: pts, at: time + 0.01, encoding: encoding)
        }
        let clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7)!
        let previous = firstFrame * 3000 - 81000, first = previous + 3000, last = previous + 450000
        let interval = try XCTUnwrap(PublishingSourceInterval.match(history: history.snapshot, clock: clock,
            relayOriginPTS: 90000, previousDecodedPTS: previous, firstDecodedPTS: first, lastDecodedPTS: last, decodedFrames: 150))
        var response = template
        response.status.decodedVideoAgeUpperBoundMs = 10
        response.status.observation?.decodedVideo = .init(completed: .init(sequence: sequence, durationMs: 5000, ageMs: 0,
            firstPTS: first, lastPTS: last, freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true),
            invalidReason: nil, ended: false, clock: "mpegts-pts-90k-v1")
        let freshness = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: native.instant,
            requestDuration: .milliseconds(10)))
        let processing = WorkerProcessingReport(scopeID: identityVariant == "processing" ? "10000000-0000-4000-8000-000000000096" : "55555555-5555-4555-8555-555555555555", encoder: "videotoolbox",
            previousSequence: sequence - 1, sequence: sequence, firstPTS: first,
            interval: .init(sourceStartExclusive: previous, sourceEndInclusive: last, decodedFrames: 150,
                submittedFrames: 150, completedFrames: 150, pendingFrames: 0, omittedBeforeEncoderFrames: 0,
                filterDuration: .init(meanMs: 1, maximumMs: 4), processingDuration: .init(meanMs: 20, maximumMs: 30)))
        let source = WorkerSourceIntervalObservation(interval: interval, nativeClock: clock, workerId: template.status.workerId!,
            workerEpoch: template.status.workerEpoch!, workerAttempt: template.status.observation!.attempt, publication: template.status.publication!,
            previousSequence: sequence - 1, sequence: sequence, previousDecodedPTS: previous, firstDecodedPTS: first, lastDecodedPTS: last,
            freshness: freshness, processing: processing)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        ingress.updateOccupancy(items: unhealthy ? 4 : 0, bytes: unhealthy ? 40 : 0, phase: .admitting, at: 100)
        var thermal = PublishingThermalTracker(), transport = PublishingTransportStatisticsTracker()
        for index in max(100, Int(native.now.rounded(.down)) - 7)...Int(max(115, native.now.rounded(.down))) {
            let time = Double(index)
            thermal.observe(.init(state: .nominal, sampledAt: time))
            transport.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(index * 1000),
                sentBytes: UInt64(index * 10000), retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 1,
                estimatedBandwidthMbps: 100, senderBufferedBytes: 0, senderBufferMilliseconds: 0, availableSenderBytes: 10000))
        }
        // Complete pressure coverage for source windows ending between integer
        // samples; a window must not borrow a future/missing right bracket.
        if native.now > native.now.rounded(.down) {
            thermal.observe(.init(state: .nominal, sampledAt: native.now))
            transport.observe(.init(publishingGeneration: 7, sampledAt: native.now,
                elapsedMilliseconds: Int64((native.now * 1000).rounded()),
                sentBytes: UInt64((native.now * 10000).rounded()), retransmittedBytes: 0, droppedPackets: 0,
                rttMilliseconds: 1, estimatedBandwidthMbps: 100, senderBufferedBytes: 0,
                senderBufferMilliseconds: 0, availableSenderBytes: 10000))
        }
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: clock, receipt: applied.receipt,
            ingress: ingress.poll(at: native.now), transport: transport.snapshot, thermal: thermal.snapshot)
        return (source, diagnostics)
    }
    static func make(sourceHealth: Bool = true, foreignPublication: Bool = false,
                     deferHealthEvaluation: Bool = false, initialProfile: PublishingVideoProfile = .low240,
                     unhealthySource: Bool = false, priorHealthEnd: Double? = nil, includeHighProfiles: Bool = false, useProductionProfiles: Bool = false,
                     requiresSharedCandidateRecovery: Bool = false,
                     guarded: PublishingQualitySession.GuardedMutations? = nil) async throws -> Self {
        let native = CandidateQualityNative(initialProfile: initialProfile)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/receiver-probe-status-v1.json")
        let template = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
        let attempt = try XCTUnwrap(UUID(uuidString: template.status.publication!.publishingAttemptId))
        let probeID = try XCTUnwrap(UUID(uuidString: template.status.receiverProbe!.snapshot.id))
        var operations = native.operations
        operations.guarded = guarded
        let owner = try PublishingQualitySession(operations: operations, profiles: useProductionProfiles ? PublishingQualityDriver.productionProfiles : [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "360p30", width: 640, height: 360, minimumBitrate: 600_000, maximumBitrate: 600_000),
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000)] + (includeHighProfiles ? [
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000),
            .init(id: "2160p30", width: 3840, height: 2160, minimumBitrate: 24_000_000, maximumBitrate: 24_000_000)] : []),
            attemptID: attempt, initial: .init(profileID: initialProfile.rawValue, videoBitrate: initialProfile.bitRate),
            strategy: .measuredCandidateTrials, behavior: .progressive, requiresSharedCandidateRecovery: requiresSharedCandidateRecovery,
            uptime: { native.now }, instant: { native.instant })
        try await owner.bootstrap()
        let state = await owner.snapshot
        let applied = PublishingQualityTelemetry.Applied(attemptID: attempt, revision: 0, settings: try XCTUnwrap(state.applied),
            receipt: try XCTUnwrap(state.receipt), acknowledgedAt: 100)
        if let priorHealthEnd {
            native.setNow(priorHealthEnd + 0.1)
            let prior = try source(native: native, template: template, applied: applied, start: priorHealthEnd - 5, sequence: 1)
            _ = try await owner.evaluate(source: prior.0, diagnostics: prior.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: native.instant)
        }
        native.setNow(115.1)
        var sourceObservation: WorkerSourceIntervalObservation?
        var sourceDiagnostics: PublishingQualityTelemetry.Diagnostics?
        var sourceAdvice: QualityController.Recommendation?
        if sourceHealth {
            var healthTemplate = template
            if foreignPublication {
                healthTemplate.status.publication?.readerId = "10000000-0000-4000-8000-000000000099"
            }
            let health = try source(native: native, template: healthTemplate, applied: applied, unhealthy: unhealthySource)
            sourceObservation = health.0; sourceDiagnostics = health.1
            if !deferHealthEvaluation {
                let healthDecision = try await owner.evaluate(source: health.0, diagnostics: health.1,
                    workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                    transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                    instant: native.instant)
                sourceAdvice = healthDecision.recommendation
                if !unhealthySource { XCTAssertEqual(healthDecision.state, .healthy, "Fixture health: \(healthDecision.reasons)") }
            }
        } else {
            _ = try await owner.evaluate(window(attempt: attempt, start: 110, duration: 5, sequence: 1))
        }
        var tracker = WorkerReceiverProbeTracker()
        for (time, messages) in [(111.0, 100), (113.0, 2200), (115.0, 4400)] {
            var response = template, p = template.status.receiverProbe!.snapshot
            p.publishingGeneration = "7"; p.convention = "mpegts-null-probe-v2"; p.stage = 3; p.bitRate = 12_000_000
            p.deliveredMessages = String(messages); p.deliveredPayloadBytes = String(messages * 1316)
            p.totalDeliveredPayloadBytes = p.deliveredPayloadBytes; p.nextSequence = p.deliveredMessages; p.pendingPackets = 0
            p.observedAtNanoseconds = String(Int64(time * 1e9)); p.firstDeliveredAtNanoseconds = "109500000000"
            p.lastDeliveredAtNanoseconds = String(Int64((time - 0.01) * 1e9))
            response.status.receiverProbe = .init(snapshot: p, ageUpperBoundMs: 10)
            let evidence = try XCTUnwrap(WorkerReceiverProbeFreshness(response: response,
                expected: .init(gameId: "match", generation: 2, workerId: "mac", publishingAttemptId: attempt.uuidString.lowercased(),
                    probeId: probeID.uuidString.lowercased(), publishingGeneration: 7, bitRate: 12_000_000, stage: 3),
                receivedAt: native.anchor + .seconds(time - 100), requestDuration: .milliseconds(10)))
            tracker.observe(evidence, acceptedPayloadBytes: UInt64(messages * 1316), senderActive: true,
                at: native.anchor + .seconds(time - 100))
        }
        let pair = try XCTUnwrap(tracker.latestPair)
        let binding = PublishingProbeObservation(id: probeID, publishingGeneration: 7, bitRate: 12_000_000, startedAt: 109,
            leaseDeadline: 109.9, acceptedPayloadBytes: 100 * 1316, lastAcceptedAt: 109.59, reason: nil, stage: 3,
            permitsCurrentOwner: { _, _, _, _ in true })
        var probe = binding
        probe.leaseDeadline = 115.3; probe.acceptedPayloadBytes = 6000 * 1316; probe.lastAcceptedAt = 115.09
        let admission = try XCTUnwrap(PublishingCandidateAdmission.laboratoryIPv4(measurement: .init(id: UUID(),
            scope: .init(recordingID: "recording", matchID: "match", broadcastGeneration: 2, publishingAttemptID: attempt, appliedProfileRevision: 1),
            profile: initialProfile == .low240 ? .low360 : (useProductionProfiles ? .hd720 : .sd540), publishingGeneration: 7, startedAt: 110, endedAt: 114.06, firstInputAt: 110, lastInputAt: 114,
            sourceDuration: 4, submissionDuration: 4, transportBytes: 376000, transportMessageCount: 400),
            applied: applied, binding: binding, boundAt: 109.6, completedAt: 114.07, probe: probe, pair: pair,
            authority: PublishingCandidateAuthority(pair.newer.end),
            clock: .init(before: 115.1, instant: native.instant, after: 115.1), currentReceipt: { native.receipt }, candidateIsCurrent: { true }))
        return .init(native: native, owner: owner, admission: admission, source: sourceObservation,
                     sourceDiagnostics: sourceDiagnostics, sourceAdvice: sourceAdvice)
    }
}
final class CandidateQualityNative: @unchecked Sendable {
    let initialProfile: PublishingVideoProfile
    init(initialProfile: PublishingVideoProfile = .low240) { self.initialProfile = initialProfile }
    // Driver source evaluation samples the real clock; align the fixture's
    // active 115.1-second observation with its construction instant.
    let anchor = ContinuousClock.now - .seconds(15.1)
    private let lock = NSLock()
    private let firstEncoder = UUID()
    private var activeEncoder: UUID?, profileChanges = 0
    private var time = 100.0, stopped = 0
    private var history: [String] = []
    private var current: PublishingBitRateChange?
    private var onProfile: (@Sendable () -> Void)?
    private var profileGate: QualityWriteGate?
    fileprivate func installProfileGate(_ value: QualityWriteGate) { lock.withLock { profileGate = value } }
    private var queuedTimes: [Double] = []
    func enqueueTimes(_ values: [Double]) { lock.withLock { queuedTimes = values } }
    var now: Double { lock.withLock { if !queuedTimes.isEmpty { time = queuedTimes.removeFirst() }; return time } }
    private var actualInstant = false
    func useActualInstant() { lock.withLock { actualInstant = true } }
    var instant: ContinuousClock.Instant { lock.withLock({ actualInstant }) ? .now : anchor + .seconds(now - 100) }
    var receipt: PublishingBitRateChange? { lock.withLock { current } }
    var calls: [String] { lock.withLock { history } }
    var stops: Int { lock.withLock { stopped } }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func setProfileAction(_ value: @escaping @Sendable () -> Void) { lock.withLock { onProfile = value } }
    func replaceReceipt() { lock.withLock {
        current = .init(publishingGeneration: 7, configuration: .init(id: UUID(), encoderSessionID: firstEncoder, bitRate: 350_000)!,
                        acceptedAt: time, lastSubmittedSourcePTS: .zero)
    } }
    var operations: PublishingQualitySession.Operations {
        .init(setBitRate: { rate, _ in
            self.lock.withLock {
                let first = self.history.isEmpty
                self.history.append("rate:\(rate)")
                let receipt = PublishingBitRateChange(publishingGeneration: 7,
                    configuration: .init(id: UUID(), encoderSessionID: self.activeEncoder ?? self.firstEncoder, bitRate: rate)!,
                    acceptedAt: self.time, lastSubmittedSourcePTS: .init(value: first ? 100 : Int64(101 + self.profileChanges * 100), timescale: 30))!
                self.current = receipt
                return receipt
            }
        }, stop: { self.lock.withLock { self.stopped += 1 } }, videoStartup: {
            .init(profile: self.initialProfile, width: self.initialProfile.width, height: self.initialProfile.height,
                  publishingGeneration: 7, encoderSessionID: self.firstEncoder,
                  firstSourcePTS: .zero, submittedAt: 99, completedAt: 99.5, observedAt: 100)
        }, setProfile: { profile, _ in
            let gate = self.lock.withLock { self.profileGate }
            await gate?.wait()
            let (action, previous, encoder, ordinal) = self.lock.withLock {
                self.history.append("profile:\(profile.rawValue)")
                let previous = self.activeEncoder ?? self.firstEncoder, encoder = UUID()
                self.activeEncoder = encoder; self.profileChanges += 1
                return (self.onProfile, previous, encoder, self.profileChanges)
            }
            action?()
            return .init(profile: profile, publishingGeneration: 7, previousEncoderSessionID: previous,
                encoderSessionID: encoder, lastOldSourcePTS: .init(value: Int64(50 + ordinal * 100), timescale: 30),
                firstNewSourcePTS: .init(value: Int64(100 + ordinal * 100), timescale: 30), width: profile.width, height: profile.height,
                rawVideoFramesDropped: 0, acknowledgedAt: self.now)!
        })
    }
}

/// Test-only storage for immutable synchronous actor evaluation callbacks.
final class QualityEvaluationTestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PublishingQualitySession.EvaluationDiagnostic] = []
    var values: [PublishingQualitySession.EvaluationDiagnostic] { lock.withLock { records } }
    var observer: @Sendable (PublishingQualitySession.EvaluationDiagnostic) -> Void {
        { [self] value in lock.withLock { records.append(value) } }
    }
}

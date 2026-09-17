import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming
import XCTest

final class PublishingQualitySessionTests: XCTestCase {
    private let attempt = UUID()
    private var profiles: [QualityController.Profile] {
        [.init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 1_000_000),
         .init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 6_000_000)]
    }
    private func owner(_ native: QualityNative, initial: Int = 2_000_000) throws -> PublishingQualitySession {
        try .init(operations: native.operations, profiles: profiles, attemptID: attempt,
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
                       supportsProfile: Bool = true) throws -> PublishingQualitySession {
        var operations = native.operations
        if !supportsProfile { operations.setProfile = nil }
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
        let publisher = QualityProfilePublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let owner = try PublishingQualitySession(session: session, profiles: [
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_000_000, maximumBitrate: 2_000_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 2_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, initial: .init(profileID: "1080p30", videoBitrate: 2_000_000))
        try await owner.bootstrap()
        let baseline = await owner.snapshot, start = try XCTUnwrap(baseline.acknowledgedAt)
        try await Task.sleep(for: .milliseconds(1050))
        let advice = try await owner.evaluate(.init(attemptID: attempt, sequence: 1, appliedRevision: 0,
            start: start, end: start + 1, capturedFreshFrames: 30, encodedFreshFrames: 30, receiver: nil,
            sourceLoss: nil, meanQueueOccupancy: 0.9, usableVideoCapacity: nil, connectivity: .unknown,
            thermalPressure: .nominal, workerPressure: .unknown)).recommendation
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
    var now: Double { lock.withLock { time } }
    var calls: [String] { lock.withLock { history } }
    var deadlines: [Double] { lock.withLock { limits } }
    var stops: Int { lock.withLock { stopped } }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func setMode(_ value: Mode) { lock.withLock { mode = value } }
    func install(_ value: QualityWriteGate, stage: String) { lock.withLock { gate = value; self.stage = stage } }
    var operations: PublishingQualitySession.Operations {
        .init(setBitRate: { await self.bitrate($0, deadline: $1) }, stop: { self.stop() },
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
    private func stop() {
        let gate = lock.withLock { stopped += 1; return self.gate }
        gate?.release()
    }
}

final class PublishingMeasuredCandidateSessionTests: XCTestCase {
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
    func testOwnedApplicationOutlivesCandidateAuthorityAndConfirmsTrial() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let advice = try XCTUnwrap(decision.recommendation)
        f.native.setProfileAction { f.admission.authority.revoke(); f.native.setNow(115.6) }
        try await f.owner.apply(advice)
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
    private var admissionMeasurementScope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 2, publishingAttemptID: attempt, appliedProfileRevision: 1)
    }
    private static func source(native: CandidateQualityNative, template: WorkerMediaStatusResponse,
                               applied: PublishingQualityTelemetry.Applied, unhealthy: Bool = false) throws -> (WorkerSourceIntervalObservation, PublishingQualityTelemetry.Diagnostics) {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match", broadcastGeneration: 2,
            publishingAttemptID: applied.attemptID, appliedProfileRevision: 1)
        var history = try VideoSourceHistory(scope: scope, capacity: 1024)
        for index in 0...150 {
            let time = 110 + Double(index) / 30, pts = CMTime(value: Int64(300 + index), timescale: 30)
            history.observe(.captureVideo, sourcePTS: pts, at: time)
            let encoding = VideoEncodingObservation(encoderSessionID: applied.receipt.configuration.encoderSessionID,
                configuration: applied.receipt.configuration, submittedAt: time, completedAt: time + 0.01)!
            history.observe(.encodedVideo, sourcePTS: pts, at: time + 0.01, encoding: encoding)
        }
        let clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7)!
        let previous: Int64 = 819000, first: Int64 = 822000, last: Int64 = 1269000
        let interval = try XCTUnwrap(PublishingSourceInterval.match(history: history.snapshot, clock: clock,
            relayOriginPTS: 90000, previousDecodedPTS: previous, firstDecodedPTS: first, lastDecodedPTS: last, decodedFrames: 150))
        var response = template
        response.status.decodedVideoAgeUpperBoundMs = 10
        response.status.observation?.decodedVideo = .init(completed: .init(sequence: 2, durationMs: 5000, ageMs: 0,
            firstPTS: first, lastPTS: last, freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true),
            invalidReason: nil, ended: false, clock: "mpegts-pts-90k-v1")
        let freshness = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: native.instant,
            requestDuration: .milliseconds(10)))
        let processing = WorkerProcessingReport(scopeID: "55555555-5555-4555-8555-555555555555", encoder: "videotoolbox",
            previousSequence: 1, sequence: 2, firstPTS: first,
            interval: .init(sourceStartExclusive: previous, sourceEndInclusive: last, decodedFrames: 150,
                submittedFrames: 150, completedFrames: 150, pendingFrames: 0, omittedBeforeEncoderFrames: 0,
                filterDuration: .init(meanMs: 1, maximumMs: 4), processingDuration: .init(meanMs: 20, maximumMs: 30)))
        let source = WorkerSourceIntervalObservation(interval: interval, nativeClock: clock, workerId: "mac",
            workerEpoch: template.status.workerEpoch!, workerAttempt: 1, publication: template.status.publication!,
            previousSequence: 1, sequence: 2, previousDecodedPTS: previous, firstDecodedPTS: first, lastDecodedPTS: last,
            freshness: freshness, processing: processing)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        ingress.updateOccupancy(items: unhealthy ? 4 : 0, bytes: unhealthy ? 40 : 0, phase: .admitting, at: 100)
        var thermal = PublishingThermalTracker(), transport = PublishingTransportStatisticsTracker()
        for index in 100...115 {
            let time = Double(index)
            thermal.observe(.init(state: .nominal, sampledAt: time))
            transport.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(index * 1000),
                sentBytes: UInt64(index * 10000), retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 1,
                estimatedBandwidthMbps: 100, senderBufferedBytes: 0, senderBufferMilliseconds: 0, availableSenderBytes: 10000))
        }
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: clock, receipt: applied.receipt,
            ingress: ingress.poll(at: native.now), transport: transport.snapshot, thermal: thermal.snapshot)
        return (source, diagnostics)
    }
    static func make(sourceHealth: Bool = true, foreignPublication: Bool = false,
                     deferHealthEvaluation: Bool = false, initialProfile: PublishingVideoProfile = .low240,
                     unhealthySource: Bool = false) async throws -> Self {
        let native = CandidateQualityNative(initialProfile: initialProfile)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/receiver-probe-status-v1.json")
        let template = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
        let attempt = try XCTUnwrap(UUID(uuidString: template.status.publication!.publishingAttemptId))
        let probeID = try XCTUnwrap(UUID(uuidString: template.status.receiverProbe!.snapshot.id))
        let owner = try PublishingQualitySession(operations: native.operations, profiles: [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "360p30", width: 640, height: 360, minimumBitrate: 600_000, maximumBitrate: 600_000),
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000)],
            attemptID: attempt, initial: .init(profileID: initialProfile.rawValue, videoBitrate: initialProfile.bitRate),
            strategy: .measuredCandidateTrials, behavior: .progressive, uptime: { native.now }, instant: { native.instant })
        try await owner.bootstrap()
        let state = await owner.snapshot
        let applied = PublishingQualityTelemetry.Applied(attemptID: attempt, revision: 0, settings: try XCTUnwrap(state.applied),
            receipt: try XCTUnwrap(state.receipt), acknowledgedAt: 100)
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
            permitsCurrentOwner: { _, _, _ in true })
        var probe = binding
        probe.leaseDeadline = 115.3; probe.acceptedPayloadBytes = 6000 * 1316; probe.lastAcceptedAt = 115.09
        let admission = try XCTUnwrap(PublishingCandidateAdmission.laboratoryIPv4(measurement: .init(id: UUID(),
            scope: .init(recordingID: "recording", matchID: "match", broadcastGeneration: 2, publishingAttemptID: attempt, appliedProfileRevision: 1),
            profile: initialProfile == .low240 ? .low360 : .sd540, publishingGeneration: 7, startedAt: 110, endedAt: 114.06, firstInputAt: 110, lastInputAt: 114,
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
    private let firstEncoder = UUID(), secondEncoder = UUID()
    private var time = 100.0, stopped = 0
    private var history: [String] = []
    private var current: PublishingBitRateChange?
    private var onProfile: (@Sendable () -> Void)?
    var now: Double { lock.withLock { time } }
    var instant: ContinuousClock.Instant { anchor + .seconds(now - 100) }
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
                    configuration: .init(id: UUID(), encoderSessionID: first ? self.firstEncoder : self.secondEncoder, bitRate: rate)!,
                    acceptedAt: self.time, lastSubmittedSourcePTS: .init(value: first ? 100 : 201, timescale: 30))!
                self.current = receipt
                return receipt
            }
        }, stop: { self.lock.withLock { self.stopped += 1 } }, videoStartup: {
            .init(profile: self.initialProfile, width: self.initialProfile.width, height: self.initialProfile.height,
                  publishingGeneration: 7, encoderSessionID: self.firstEncoder,
                  firstSourcePTS: .zero, submittedAt: 99, completedAt: 99.5, observedAt: 100)
        }, setProfile: { profile, _ in
            let action = self.lock.withLock { self.history.append("profile:\(profile.rawValue)"); return self.onProfile }
            action?()
            return .init(profile: profile, publishingGeneration: 7, previousEncoderSessionID: self.firstEncoder,
                encoderSessionID: self.secondEncoder, lastOldSourcePTS: .init(value: 150, timescale: 30),
                firstNewSourcePTS: .init(value: 200, timescale: 30), width: profile.width, height: profile.height,
                rawVideoFramesDropped: 0, acknowledgedAt: self.now)!
        })
    }
}

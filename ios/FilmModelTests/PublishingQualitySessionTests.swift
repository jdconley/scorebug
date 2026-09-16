import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
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

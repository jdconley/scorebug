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

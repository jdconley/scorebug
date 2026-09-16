import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingBitRateUpdateTests: XCTestCase {
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    func testReceiptRejectsInvalidGenerationTimeAndSourcePTS() throws {
        let config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 2_000_000))
        XCTAssertNil(PublishingBitRateChange(publishingGeneration: 0, configuration: config, acceptedAt: 1, lastSubmittedSourcePTS: nil))
        for time in [-1.0, .nan, .infinity, 1e13] {
            XCTAssertNil(PublishingBitRateChange(publishingGeneration: 1, configuration: config, acceptedAt: time, lastSubmittedSourcePTS: nil))
        }
        for pts in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1)] {
            XCTAssertNil(PublishingBitRateChange(publishingGeneration: 1, configuration: config, acceptedAt: 1, lastSubmittedSourcePTS: pts))
        }
        XCTAssertNotNil(PublishingBitRateChange(publishingGeneration: 1, configuration: config, acceptedAt: 1, lastSubmittedSourcePTS: CMTime(value: -1, timescale: 30)))
    }
    func testInvalidAndInactiveRequestsNeverDispatchOrStopPublishing() async throws {
        let publisher = RatePublisher(), session = try PublishingSession(publisher: publisher)
        await fails(.invalidState) { _ = try await session.setVideoBitRate(2_000_000) }
        try await session.start()
        for rate in [0, -1, Int.max] { await fails(.invalidBitRate) { _ = try await session.setVideoBitRate(rate) } }
        for deadline in [now - 1, .nan, .infinity] {
            await fails(.invalidBitRateDeadline) { _ = try await session.setVideoBitRate(2_000_000, before: deadline) }
        }
        XCTAssertEqual(publisher.calls, 0); XCTAssertEqual(publisher.stops, 0)
        XCTAssertEqual(session.snapshot.state, .publishing)
        await session.stop()
        await fails(.invalidState) { _ = try await session.setVideoBitRate(2_000_000) }
    }
    func testAlreadyCancelledCallerDoesNotDispatch() async throws {
        let publisher = RatePublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.setVideoBitRate(2_000_000)
        }
        await fails(.cancelled) { _ = try await task.value }
        XCTAssertEqual(publisher.calls, 0); XCTAssertEqual(publisher.stops, 0)
        await session.stop()
    }
    func testSuccessfulReceiptIsHistoricalAfterJoinedStop() async throws {
        let publisher = RatePublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let first = try await session.setVideoBitRate(2_000_000)
        XCTAssertEqual(first.configuration.bitRate, 2_000_000)
        XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, first.configuration)
        let second = try await session.setVideoBitRate(3_000_000)
        XCTAssertNotEqual(first.configuration.id, second.configuration.id)
        await session.stop()
        XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, second.configuration)
        XCTAssertEqual(publisher.stops, 1)
    }
    func testConcurrentRequestCannotReachPublisher() async throws {
        let gate = RateGate(), publisher = RatePublisher(gate: gate), session = try PublishingSession(publisher: publisher)
        defer { gate.release() }
        try await session.start()
        let first = Task { try await session.setVideoBitRate(2_000_000) }
        await eventually { gate.entered }
        await fails(.bitRateUpdateInProgress) { _ = try await session.setVideoBitRate(3_000_000) }
        XCTAssertEqual(publisher.calls, 1)
        gate.release(); _ = try await first.value
        await session.stop()
    }
    func testNativeFailureAndInvalidReceiptsRetireLiveAttempt() async throws {
        for mode in [RatePublisher.Mode.failure, .wrongRate, .oldTime, .futureTime, .wrongGeneration, .unhealthyReceipt] {
            let publisher = RatePublisher(mode: mode)
            let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
            try await session.start()
            await eventually { session.snapshot.transportClock != nil }
            await fails(.bitRateUpdateFailed) { _ = try await session.setVideoBitRate(2_000_000) }
            await session.stop()
            XCTAssertEqual(session.snapshot.failure, .bitRateUpdateFailed)
            XCTAssertNil(session.snapshot.lastBitRateChange)
            XCTAssertEqual(publisher.stops, 1)
        }
    }
    func testReusedConfigurationAndReversedSameSessionBoundaryCannotCommit() async throws {
        for mode in [RatePublisher.Mode.reusedID, .backwardBoundary, .missingBoundary] {
            let publisher = RatePublisher(mode: mode), session = try PublishingSession(publisher: publisher)
            try await session.start()
            let first = try await session.setVideoBitRate(2_000_000)
            await fails(.bitRateUpdateFailed) { _ = try await session.setVideoBitRate(3_000_000) }
            XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, first.configuration)
            await session.stop()
        }
    }
    func testDeadlineStopsBlockedWriteAndRejectsLateReceipt() async throws {
        let gate = RateGate(), publisher = RatePublisher(gate: gate), session = try PublishingSession(publisher: publisher)
        defer { gate.release() }
        try await session.start()
        let deadline = now + 0.05
        let task = Task { try await session.setVideoBitRate(2_000_000, before: deadline) }
        await eventually { gate.entered }
        await eventually { session.snapshot.failure == .bitRateUpdateTimedOut }
        await session.stop()
        await fails(.bitRateUpdateTimedOut) { _ = try await task.value }
        XCTAssertNil(session.snapshot.lastBitRateChange)
        XCTAssertEqual(publisher.stops, 1)
    }
    func testStopJoinsOperationAfterPublisherUnblocksIt() async throws {
        let gate = RateGate(), completion = RateGate(), publisher = RatePublisher(gate: gate, completion: completion)
        let session = try PublishingSession(publisher: publisher)
        defer { gate.release(); completion.release() }
        try await session.start()
        let task = Task { try await session.setVideoBitRate(2_000_000) }
        await eventually { gate.entered }
        let stop = Task { await session.stop() }
        await eventually { completion.entered }
        XCTAssertEqual(session.snapshot.state, .stopping)
        XCTAssertFalse(publisher.returned)
        completion.release()
        await stop.value
        XCTAssertTrue(publisher.returned)
        await fails(.cancelled) { _ = try await task.value }
        XCTAssertNil(session.snapshot.lastBitRateChange)
    }
    func testCallerCancellationStopsAndJoinsDispatchedMutation() async throws {
        let gate = RateGate(), publisher = RatePublisher(gate: gate), session = try PublishingSession(publisher: publisher)
        defer { gate.release() }
        try await session.start()
        let task = Task { try await session.setVideoBitRate(2_000_000) }
        await eventually { gate.entered }
        task.cancel()
        await eventually { publisher.stops == 1 }
        await session.stop()
        await fails(.cancelled) { _ = try await task.value }
        XCTAssertNil(session.snapshot.lastBitRateChange)
        XCTAssertTrue(publisher.returned)
    }
    func testReceiptBeforeFirstClockQuarantinesContradictoryGeneration() async throws {
        let publisher = RatePublisher(clockGeneration: nil)
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        try await session.start()
        let receipt = try await session.setVideoBitRate(2_000_000)
        XCTAssertNil(session.snapshot.transportClock)
        let reads = publisher.clockReads
        publisher.setClockGeneration(8)
        await eventually { publisher.clockReads >= reads + 2 }
        XCTAssertNil(session.snapshot.transportClock)
        XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, receipt.configuration)
        await session.stop()
    }
    func testExpiryDuringAdmissionNeverDispatchesOrStopsLiveAttempt() async throws {
        let base = now, clock = AdmissionClock(base: now)
        let publisher = RatePublisher(), session = try PublishingSession(publisher: publisher, bitRateClock: { clock.read() })
        try await session.start()
        await fails(.invalidBitRateDeadline) { _ = try await session.setVideoBitRate(2_000_000, before: base + 0.5) }
        XCTAssertEqual(publisher.calls, 0); XCTAssertEqual(publisher.stops, 0)
        await session.stop()
    }
    func testSessionReplacementPermitsResetSourceBoundary() async throws {
        let publisher = RatePublisher(mode: .newSessionBoundary), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let first = try await session.setVideoBitRate(2_000_000)
        let second = try await session.setVideoBitRate(3_000_000)
        XCTAssertNotEqual(first.configuration.encoderSessionID, second.configuration.encoderSessionID)
        XCTAssertEqual(second.lastSubmittedSourcePTS, .zero)
        await session.stop()
    }
    func testFirstSuccessfulDeadlineCannotStopSecondPendingRequest() async throws {
        let gate = RateGate(), publisher = RatePublisher(gate: gate, gatedCall: 2)
        let session = try PublishingSession(publisher: publisher)
        defer { gate.release() }
        try await session.start()
        _ = try await session.setVideoBitRate(2_000_000, before: now + 0.05)
        let second = Task { try await session.setVideoBitRate(3_000_000) }
        await eventually { gate.entered }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.snapshot.state, .publishing); XCTAssertEqual(publisher.stops, 0)
        gate.release(); _ = try await second.value
        await session.stop()
    }
    func testFarFutureCallerDeadlineIsCappedAtTwoSeconds() async throws {
        let gate = RateGate(), publisher = RatePublisher(gate: gate), session = try PublishingSession(publisher: publisher)
        defer { gate.release() }
        try await session.start()
        let requested = now + 60
        let task = Task { try await session.setVideoBitRate(2_000_000, before: requested) }
        let limit = ContinuousClock.now + .seconds(3)
        while publisher.stops == 0, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.snapshot.failure, .bitRateUpdateTimedOut)
        await session.stop()
        await fails(.bitRateUpdateTimedOut) { _ = try await task.value }
    }
    private func fails(_ expected: PublishingSessionError, _ body: () async throws -> Void,
                       file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PublishingSessionError, expected, file: file, line: line) }
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private final class RateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    private var enteredValue = false
    var entered: Bool { lock.withLock { enteredValue } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                enteredValue = true
                if open { return true }
                self.continuation = continuation; return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { open = true; defer { continuation = nil }; return continuation }
        pending?.resume()
    }
}
private final class RatePublisher: MediaPublisher, @unchecked Sendable {
    enum Mode { case normal, failure, wrongRate, oldTime, futureTime, wrongGeneration, reusedID, backwardBoundary, missingBoundary, newSessionBoundary, unhealthyReceipt }
    private let lock = NSLock()
    private let gate: RateGate?, completion: RateGate?, mode: Mode
    private let sessionID = UUID(), repeatedID = UUID()
    private let gatedCall: Int
    private var clockGeneration: UInt64?
    private var clockReadCount = 0
    private var healthy = false, returnedValue = false
    private var callCount = 0, stopCount = 0
    init(mode: Mode = .normal, gate: RateGate? = nil, completion: RateGate? = nil, gatedCall: Int = 1, clockGeneration: UInt64? = 7) {
        self.mode = mode; self.gate = gate; self.completion = completion
        self.gatedCall = gatedCall; self.clockGeneration = clockGeneration
    }
    var calls: Int { lock.withLock { callCount } }
    var stops: Int { lock.withLock { stopCount } }
    var returned: Bool { lock.withLock { returnedValue } }
    func start() async throws { lock.withLock { healthy = true } }
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { get async { lock.withLock { healthy } } }
    func stop() async { lock.withLock { stopCount += 1; healthy = false }; gate?.release() }
    var clockReads: Int { lock.withLock { clockReadCount } }
    func setClockGeneration(_ value: UInt64?) { lock.withLock { clockGeneration = value } }
    func transportClock() async -> PublishingTransportClock? {
        lock.withLock { clockReadCount += 1; return clockGeneration.flatMap { .init(sourceOrigin: .zero, publishingGeneration: $0) } }
    }
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange {
        let count = lock.withLock { callCount += 1; return callCount }
        if count == gatedCall { await gate?.wait() }; await completion?.wait()
        defer { lock.withLock { returnedValue = true } }
        if mode == .failure { throw NSError(domain: "private native details", code: -1) }
        let accepted = ProcessInfo.processInfo.systemUptime + (mode == .oldTime ? -10 : mode == .futureTime ? 10 : 0)
        guard let configuration = VideoEncodingConfiguration(id: mode == .reusedID ? repeatedID : UUID(), encoderSessionID: mode == .newSessionBoundary && count > 1 ? UUID() : sessionID,
            bitRate: mode == .wrongRate ? rate + 1 : rate) else { throw PublishingSessionError.invalidBitRate }
        if mode == .unhealthyReceipt { lock.withLock { healthy = false } }
        return PublishingBitRateChange(publishingGeneration: mode == .wrongGeneration ? 8 : 7, configuration: configuration,
            acceptedAt: accepted, lastSubmittedSourcePTS: mode == .missingBoundary && count > 1 ? nil : CMTime(value: (mode == .backwardBoundary || mode == .newSessionBoundary) && count > 1 ? 0 : Int64(count), timescale: 30))!
    }
}

private final class AdmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: Double
    private var reads = 0
    init(base: Double) { self.base = base }
    func read() -> Double { lock.withLock { reads += 1; return reads == 1 ? base : base + 1 } }
}

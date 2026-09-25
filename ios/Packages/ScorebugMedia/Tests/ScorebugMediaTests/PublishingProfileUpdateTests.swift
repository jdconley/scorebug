import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingProfileUpdateTests: XCTestCase {
    func testProfileReplacesBitRateHistoryAndRetainsItsOwnHistoricalReceipt() async throws {
        let publisher = ProfilePublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        _ = try await session.setVideoBitRate(3_000_000)
        XCTAssertNotNil(session.snapshot.lastBitRateChange)
        let first = try await session.setVideoProfile(.sd540)
        XCTAssertEqual(first.profile, .sd540)
        XCTAssertNil(session.snapshot.lastBitRateChange)
        XCTAssertEqual(session.snapshot.lastVideoProfileChange?.encoderSessionID, first.encoderSessionID)
        let second = try await session.setVideoProfile(.hd1080)
        XCTAssertEqual(second.previousEncoderSessionID, first.encoderSessionID)
        await session.stop()
        XCTAssertEqual(session.snapshot.lastVideoProfileChange?.encoderSessionID, second.encoderSessionID)
        XCTAssertEqual(publisher.stops, 1)
    }
    func testCrossKindReceiptsCannotRewindSourceHistoryOrResurrectRetiredEncoder() async throws {
        for mode in [ProfilePublisher.Mode.profileRewind, .rateRewind, .rateMissing, .rateRetired, .profileReuseRate] {
            let publisher = ProfilePublisher(mode: mode), session = try PublishingSession(publisher: publisher)
            try await session.start()
            if mode == .profileRewind || mode == .profileReuseRate {
                _ = try await session.setVideoBitRate(3_000_000)
                await fails(.profileUpdateFailed) { _ = try await session.setVideoProfile(.sd540) }
                XCTAssertNil(session.snapshot.lastVideoProfileChange)
            } else {
                _ = try await session.setVideoProfile(.sd540)
                await fails(.bitRateUpdateFailed) { _ = try await session.setVideoBitRate(2_000_000) }
                XCTAssertNil(session.snapshot.lastBitRateChange)
            }
            await session.stop()
        }
    }
    func testAdmissionRejectsInactiveExpiredAndCancelledProfileRequests() async throws {
        let publisher = ProfilePublisher(), session = try PublishingSession(publisher: publisher)
        await fails(.invalidState) { _ = try await session.setVideoProfile(.sd540) }
        try await session.start()
        for deadline in [ProcessInfo.processInfo.systemUptime - 1, .nan, .infinity] {
            await fails(.invalidProfileDeadline) { _ = try await session.setVideoProfile(.sd540, before: deadline) }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.setVideoProfile(.sd540)
        }
        await fails(.cancelled) { _ = try await cancelled.value }
        XCTAssertEqual(publisher.calls, 0); XCTAssertEqual(publisher.stops, 0)
        await session.stop()
    }
    func testBitRateAndProfileMutationsShareOneAdmissionSlot() async throws {
        for rateFirst in [false, true] {
            let gate = ProfileGate(), publisher = ProfilePublisher(gate: gate, gateRate: rateFirst)
            let session = try PublishingSession(publisher: publisher)
            defer { gate.release() }
            try await session.start()
            let first = Task {
                if rateFirst { _ = try await session.setVideoBitRate(3_000_000) }
                else { _ = try await session.setVideoProfile(.sd540) }
            }
            await eventually { gate.entered }
            await fails(.profileUpdateInProgress) { _ = try await session.setVideoProfile(.hd1080) }
            await fails(.bitRateUpdateInProgress) { _ = try await session.setVideoBitRate(4_000_000) }
            XCTAssertEqual(publisher.calls, 1)
            gate.release(); try await first.value
            await session.stop()
        }
    }
    func testProfileCancellationDeadlineAndStopJoinNativeOperation() async throws {
        for reason in ["cancel", "deadline", "stop"] {
            let gate = ProfileGate(), completion = ProfileGate()
            let publisher = ProfilePublisher(gate: gate, completion: completion)
            let session = try PublishingSession(publisher: publisher)
            defer { gate.release(); completion.release() }
            try await session.start()
            let change = Task {
                try await session.setVideoProfile(.sd540, before: reason == "deadline" ? ProcessInfo.processInfo.systemUptime + 0.05 : nil)
            }
            await eventually { gate.entered }
            if reason == "cancel" { change.cancel() }
            var stop: Task<Void, Never>?
            if reason == "stop" { stop = Task { await session.stop() }; stop?.cancel() }
            await eventually { completion.entered }
            XCTAssertFalse(publisher.returned)
            XCTAssertEqual(publisher.stops, 1)
            XCTAssertNil(session.snapshot.lastVideoProfileChange)
            completion.release()
            await stop?.value
            await fails(reason == "deadline" ? .profileUpdateTimedOut : .cancelled) { _ = try await change.value }
            await session.stop()
            XCTAssertTrue(publisher.returned)
            XCTAssertNil(session.snapshot.lastVideoProfileChange)
        }
    }
    func testInvalidProfileReceiptTimeScopeProfileAndNativeFailureRetireAttempt() async throws {
        for mode in [ProfilePublisher.Mode.failure, .wrongProfile, .oldTime, .futureTime, .wrongGeneration, .unhealthy] {
            // Hold the monitor after its initial healthy read/clock so this
            // test specifically exercises mutation validation winning first.
            let diagnostics = ProfileGate()
            defer { diagnostics.release() }
            let publisher = ProfilePublisher(mode: mode, diagnostics: diagnostics)
            let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
            try await session.start()
            await eventually { session.snapshot.transportClock != nil && diagnostics.entered }
            await fails(.profileUpdateFailed) { _ = try await session.setVideoProfile(.sd540) }
            XCTAssertNil(session.snapshot.lastVideoProfileChange)
            XCTAssertEqual(publisher.stops, 1)
            await session.stop()
        }
    }
    func testHealthMonitorFailureWinsAndJoinsPendingProfileWrite() async throws {
        let dispatch = ProfileGate(), completion = ProfileGate()
        defer { dispatch.release(); completion.release() }
        let publisher = ProfilePublisher(gate: dispatch, completion: completion)
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        try await session.start()
        let change = Task { try await session.setVideoProfile(.sd540) }
        await eventually { dispatch.entered }
        publisher.becomeUnhealthy()
        await eventually { session.snapshot.failure == .publisherUnhealthy && completion.entered }
        XCTAssertEqual(publisher.stops, 1)
        XCTAssertFalse(publisher.returned)
        completion.release()
        await fails(.publisherUnhealthy) { _ = try await change.value }
        await session.stop()
        XCTAssertTrue(publisher.returned)
        XCTAssertNil(session.snapshot.lastVideoProfileChange)
    }
    func testReusedProfileEncoderAndBackwardBoundaryCannotCommit() async throws {
        for mode in [ProfilePublisher.Mode.reusedID, .backwardBoundary, .profileReuseRetired] {
            let publisher = ProfilePublisher(mode: mode), session = try PublishingSession(publisher: publisher)
            try await session.start()
            let first = try await session.setVideoProfile(.sd540)
            await fails(.profileUpdateFailed) { _ = try await session.setVideoProfile(.hd1080) }
            XCTAssertEqual(session.snapshot.lastVideoProfileChange?.encoderSessionID, first.encoderSessionID)
            await session.stop()
        }
    }
    private func fails(_ expected: PublishingSessionError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? PublishingSessionError, expected) }
    }
    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition())
    }

}

private final class ProfilePublisher: MediaPublisher, @unchecked Sendable {
    enum Mode { case normal, profileReuseRate, profileReuseRetired, profileRewind, rateRewind, rateMissing, rateRetired, failure, wrongProfile, oldTime, futureTime, wrongGeneration, unhealthy, reusedID, backwardBoundary }
    private let lock = NSLock()
    private let gate: ProfileGate?, completion: ProfileGate?, diagnostics: ProfileGate?, gateRate: Bool, mode: Mode
    private var healthy = false, stopCount = 0, callCount = 0, profileCount = 0, didReturn = false
    private var encoderID = UUID(), retiredID = UUID()
    private let repeatOld = UUID(), repeatNew = UUID()
    init(mode: Mode = .normal, gate: ProfileGate? = nil, completion: ProfileGate? = nil, gateRate: Bool = false, diagnostics: ProfileGate? = nil) {
        self.mode = mode; self.gate = gate; self.completion = completion; self.gateRate = gateRate; self.diagnostics = diagnostics
    }
    var stops: Int { lock.withLock { stopCount } }
    var calls: Int { lock.withLock { callCount } }
    var returned: Bool { lock.withLock { didReturn } }
    func start() async throws { lock.withLock { healthy = true } }
    func stop() async { lock.withLock { stopCount += 1; healthy = false }; gate?.release(); diagnostics?.release() }
    func becomeUnhealthy() { lock.withLock { healthy = false } }
    func transportStatistics() async -> PublishingTransportStatistics? { await diagnostics?.wait(); return nil }
    var isPublishing: Bool { get async { lock.withLock { healthy } } }
    func append(_ sample: CapturedMediaSample) async throws {}
    func transportClock() async -> PublishingTransportClock? { .init(sourceOrigin: .zero, publishingGeneration: 7) }
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange {
        lock.withLock { callCount += 1 }
        if gateRate { await gate?.wait() }
        return lock.withLock {
            let pts: CMTime? = mode == .rateMissing ? nil : CMTime(value: mode == .rateRewind ? 0 : mode == .profileRewind ? 40 : Int64(profileCount * 30), timescale: 30)
            return .init(publishingGeneration: 7,
                  configuration: .init(id: UUID(), encoderSessionID: mode == .rateRetired ? retiredID : encoderID, bitRate: rate)!,
                  acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: pts)!
        }
    }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        lock.withLock { callCount += 1; profileCount += 1 }
        if !gateRate { await gate?.wait() }
        await completion?.wait()
        defer { lock.withLock { didReturn = true } }
        if mode == .failure { throw NSError(domain: "private native profile error", code: -1) }
        return lock.withLock {
            let old = encoderID, earlierRetired = retiredID; retiredID = old; encoderID = UUID()
            if mode == .profileReuseRate { encoderID = old }
            if mode == .profileReuseRetired && profileCount > 1 { encoderID = earlierRetired }
            if mode == .unhealthy { healthy = false }
            let selected: PublishingVideoProfile = mode == .wrongProfile ? .hd1080 : profile
            let boundary = mode == .backwardBoundary && profileCount > 1 ? 1 : profileCount * 30
            return .init(profile: selected, publishingGeneration: mode == .wrongGeneration ? 8 : 7,
                previousEncoderSessionID: mode == .reusedID ? repeatOld : mode == .profileReuseRate ? UUID() : old,
                encoderSessionID: mode == .reusedID ? repeatNew : encoderID,
                lastOldSourcePTS: CMTime(value: Int64(boundary - 1), timescale: 30),
                firstNewSourcePTS: CMTime(value: Int64(boundary), timescale: 30),
                width: selected.width, height: selected.height, rawVideoFramesDropped: 0,
                acknowledgedAt: ProcessInfo.processInfo.systemUptime + (mode == .oldTime ? -10 : mode == .futureTime ? 10 : 0))!
        }
    }
}
private final class ProfileGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false, enteredValue = false
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

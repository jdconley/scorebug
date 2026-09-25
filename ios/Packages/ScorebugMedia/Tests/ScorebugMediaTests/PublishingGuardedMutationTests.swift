import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingGuardedMutationTests: XCTestCase {
    func testSafeGuardedRejectionPreservesHistoryAndAllowsNextRequest() async throws {
        for kind in GuardedSessionRequest.allCases {
            for rejection in [PublishingVideoMutationAdmissionError.stale, .unavailable] {
                let publisher = GuardedSessionPublisher()
                let session = try PublishingSession(publisher: publisher)
                try await session.start()
                let baseline = try await session.setVideoBitRate(600_000)
                publisher.setMode(.safe(rejection))
                await rejects(rejection) { try await performGuardedSessionChange(kind, session, selected: baseline) }
                XCTAssertEqual(session.snapshot.state, .publishing)
                XCTAssertNil(session.snapshot.failure)
                XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, baseline.configuration)
                XCTAssertNil(session.snapshot.lastVideoProfileChange)
                XCTAssertEqual(publisher.stops, 0)
                XCTAssertEqual(publisher.legacyCalls, 1)
                XCTAssertEqual(publisher.guardedCalls, 1)
                if kind != .replacement { XCTAssertEqual(publisher.selected?.configuration, baseline.configuration) }
                else { XCTAssertEqual(publisher.selected?.configuration.encoderSessionID, baseline.configuration.encoderSessionID) }
                publisher.setMode(.success)
                _ = try await session.setVideoBitRate(800_000, expecting: .verified(baseline))
                XCTAssertEqual(publisher.guardedCalls, 2)
                await session.stop()
            }
        }
    }

    func testMissingCapabilityIsSafeAndNeverInvokesLegacyMethod() async throws {
        for profile in [false, true] {
            let publisher = LegacySessionPublisher()
            let session = try PublishingSession(publisher: publisher)
            try await session.start()
            let selected = publisher.fixture.selector
            await rejects(.unavailable) {
                if profile { _ = try await session.setVideoProfile(.low240, expecting: selected) }
                else { _ = try await session.setVideoBitRate(800_000, expecting: .verified(selected)) }
            }
            XCTAssertEqual(publisher.fixture.legacyCalls, 0)
            XCTAssertEqual(publisher.fixture.stops, 0)
            XCTAssertEqual(session.snapshot.state, .publishing)
            _ = try await session.setVideoBitRate(600_000)
            await session.stop()
        }
    }

    func testSameTypedErrorFromLegacyMethodRemainsTerminal() async throws {
        for profile in [false, true] {
            for error in [PublishingVideoMutationAdmissionError.stale, .unavailable] {
                let publisher = GuardedSessionPublisher(mode: .safe(error))
                let session = try PublishingSession(publisher: publisher)
                try await session.start()
                await fails(profile ? .profileUpdateFailed : .bitRateUpdateFailed) {
                    if profile { _ = try await session.setVideoProfile(.low240) }
                    else { _ = try await session.setVideoBitRate(800_000) }
                }
                XCTAssertEqual(publisher.stops, 1)
                XCTAssertEqual(session.snapshot.state, .failed)
                await session.stop()
            }
        }
    }

    func testExplicitExpectationChecksMalformedSuccessWithoutSessionHistory() async throws {
        for kind in GuardedSessionRequest.allCases {
            let modes: [GuardedSessionPublisher.Mode] = kind == .profile
                ? [.wrongGeneration, .wrongPreviousEncoder, .wrongProfile, .backwardSource]
                : [.wrongGeneration, .wrongEncoder, .wrongRate, .backwardSource, .missingSource] + (kind == .rate ? [.reusedConfiguration] : [])
            for mode in modes {
                let publisher = GuardedSessionPublisher(mode: mode)
                let session = try PublishingSession(publisher: publisher)
                try await session.start()
                await fails(kind.failure) { try await performGuardedSessionChange(kind, session, selected: publisher.selector) }
                XCTAssertEqual(session.snapshot.state, .failed)
                XCTAssertNil(session.snapshot.lastBitRateChange)
                XCTAssertNil(session.snapshot.lastVideoProfileChange)
                XCTAssertEqual(publisher.stops, 1)
                await session.stop()
            }
        }
    }

    func testExplicitExpectationTimeCannotRewindWithoutSessionHistory() async throws {
        for kind in GuardedSessionRequest.allCases {
            let clock = GuardedSessionClock()
            let publisher = GuardedSessionPublisher(clock: { clock.now })
            let session = try PublishingSession(publisher: publisher, bitRateClock: { clock.now })
            try await session.start()
            let baseline = publisher.selector
            let selected = PublishingBitRateChange(publishingGeneration: baseline.publishingGeneration,
                configuration: baseline.configuration, acceptedAt: 11, lastSubmittedSourcePTS: baseline.lastSubmittedSourcePTS)!
            await fails(kind.failure) { try await performGuardedSessionChange(kind, session, selected: selected) }
            XCTAssertNil(session.snapshot.lastBitRateChange)
            XCTAssertNil(session.snapshot.lastVideoProfileChange)
            XCTAssertEqual(publisher.stops, 1)
            await session.stop()
        }
    }

    func testSuccessfulGuardedProfileThenReplacementWriteRetainsValidatedHistory() async throws {
        let publisher = GuardedSessionPublisher()
        let session = try PublishingSession(publisher: publisher)
        try await session.start()
        let selected = publisher.selector
        let replaced = try await session.setVideoProfile(.low240, expecting: selected)
        let written = try await session.setVideoBitRate(350_000, expecting: .replacement(replaced))
        XCTAssertEqual(written.configuration.encoderSessionID, replaced.encoderSessionID)
        XCTAssertEqual(session.snapshot.lastVideoProfileChange?.encoderSessionID, replaced.encoderSessionID)
        XCTAssertEqual(session.snapshot.lastBitRateChange?.configuration, written.configuration)
        XCTAssertEqual(publisher.legacyCalls, 0)
        await session.stop()
    }

    func testSessionDoesNotInferApplicationRollbackFromReplacementSelector() async throws {
        let publisher = GuardedSessionPublisher()
        let session = try PublishingSession(publisher: publisher)
        try await session.start()
        let replaced = try await session.setVideoProfile(.low240, expecting: publisher.selector)
        publisher.setMode(.safe(.stale))
        await rejects(.stale) { _ = try await session.setVideoBitRate(350_000, expecting: .replacement(replaced)) }
        XCTAssertEqual(session.snapshot.state, .publishing)
        XCTAssertEqual(session.snapshot.lastVideoProfileChange?.encoderSessionID, replaced.encoderSessionID)
        XCTAssertNil(session.snapshot.lastBitRateChange)
        XCTAssertEqual(publisher.stops, 0, "Application owner, not an arbitrary selector, decides partial-application shutdown")
        await session.stop()
    }

    func testResolvedRejectionSurvivesClockExpiryAndJoinsItsHeldTimer() async throws {
        for kind in GuardedSessionRequest.allCases {
            let clock = GuardedSessionClock(), timer = GuardedSessionSleeper(), dispatch = GuardedSessionGate()
            defer { timer.gate.release(); dispatch.release() }
            let publisher = GuardedSessionPublisher(mode: .safe(.stale), clock: { clock.now })
            publisher.holdDispatch(dispatch)
            let session = try PublishingSession(publisher: publisher, bitRateClock: { clock.now }, mutationSleep: { try await timer.sleep($0) })
            try await session.start()
            let completed = GuardedSessionFlag()
            let pending = Task {
                defer { completed.set() }
                try await performGuardedSessionChange(kind, session, selected: publisher.selector)
            }
            await eventually { dispatch.entered && timer.gate.entered }
            dispatch.release()
            await eventually { timer.gate.cancelled }
            XCTAssertFalse(completed.value, "Safe return must join its cancelled timer")
            clock.advance(to: 20)
            XCTAssertEqual(session.snapshot.state, .publishing)
            XCTAssertEqual(publisher.stops, 0)
            await fails(.bitRateUpdateInProgress) { _ = try await session.setVideoBitRate(900_000) }
            timer.gate.release()
            await rejects(.stale) { try await pending.value }
            XCTAssertEqual(session.snapshot.state, .publishing)
            publisher.setMode(.success)
            _ = try await session.setVideoBitRate(800_000, expecting: .verified(publisher.selector))
            XCTAssertEqual(publisher.stops, 0)
            await session.stop()
        }
    }

    func testExpiredClockWinsOverSafeErrorBeforeTimerRuns() async throws {
        for kind in GuardedSessionRequest.allCases {
            let clock = GuardedSessionClock(), timer = GuardedSessionSleeper(), dispatch = GuardedSessionGate()
            defer { timer.gate.release(); dispatch.release() }
            let publisher = GuardedSessionPublisher(mode: .safe(.stale), clock: { clock.now })
            publisher.holdDispatch(dispatch)
            let session = try PublishingSession(publisher: publisher, bitRateClock: { clock.now }, mutationSleep: { try await timer.sleep($0) })
            try await session.start()
            let pending = Task { try await performGuardedSessionChange(kind, session, selected: publisher.selector, before: 11) }
            await eventually { dispatch.entered && timer.gate.entered }
            clock.advance(to: 11)
            dispatch.release()
            await eventually { publisher.stops == 1 }
            XCTAssertEqual(session.snapshot.failure, kind.timeout)
            timer.gate.release()
            await fails(kind.timeout) { try await pending.value }
            await session.stop()
        }
    }

    func testTimerWinningFirstCannotBeOverwrittenByLateSafeError() async throws {
        for kind in GuardedSessionRequest.allCases {
            let clock = GuardedSessionClock(), timer = GuardedSessionSleeper(), dispatch = GuardedSessionGate()
            defer { timer.gate.release(); dispatch.release() }
            let completion = GuardedSessionGate()
            defer { completion.release() }
            let publisher = GuardedSessionPublisher(mode: .safe(.stale), clock: { clock.now })
            publisher.holdDispatch(dispatch, completion: completion)
            let session = try PublishingSession(publisher: publisher, bitRateClock: { clock.now }, mutationSleep: { try await timer.sleep($0) })
            try await session.start()
            let pending = Task { try await performGuardedSessionChange(kind, session, selected: publisher.selector) }
            await eventually { dispatch.entered && timer.gate.entered }
            clock.advance(to: 12); timer.gate.release()
            await eventually { publisher.stops == 1 && completion.entered }
            XCTAssertEqual(session.snapshot.failure, kind.timeout)
            XCTAssertFalse(publisher.returned)
            completion.release()
            await fails(kind.timeout) { try await pending.value }
            XCTAssertTrue(publisher.returned)
            await session.stop()
        }
    }

    func testStopAndCancellationDuringDispatchJoinLateSafeRejection() async throws {
        for kind in GuardedSessionRequest.allCases {
            for cancel in [false, true] {
                let dispatch = GuardedSessionGate(), completion = GuardedSessionGate()
                defer { dispatch.release(); completion.release() }
                let publisher = GuardedSessionPublisher(mode: .safe(.stale))
                publisher.holdDispatch(dispatch, completion: completion)
                let session = try PublishingSession(publisher: publisher)
                try await session.start()
                let finished = GuardedSessionFlag()
                let pending = Task {
                    defer { finished.set() }
                    try await performGuardedSessionChange(kind, session, selected: publisher.selector)
                }
                await eventually { dispatch.entered }
                let stop: Task<Void, Never>?
                if cancel { pending.cancel(); stop = nil }
                else { stop = Task { await session.stop() } }
                await eventually { publisher.stops == 1 && completion.entered }
                XCTAssertFalse(finished.value)
                XCTAssertFalse(publisher.returned)
                completion.release()
                await fails(.cancelled) { try await pending.value }
                await stop?.value
                XCTAssertTrue(publisher.returned)
                XCTAssertEqual(session.snapshot.failure, cancel ? .cancelled : nil)
                await session.stop()
            }
        }
    }

    func testStopAndCancellationDuringResolvedTimerJoinRemainTerminal() async throws {
        for kind in GuardedSessionRequest.allCases {
            for cancel in [false, true] {
                let clock = GuardedSessionClock(), timer = GuardedSessionSleeper(), dispatch = GuardedSessionGate()
                defer { timer.gate.release(); dispatch.release() }
                let publisher = GuardedSessionPublisher(mode: .safe(.stale), clock: { clock.now })
                publisher.holdDispatch(dispatch)
                let session = try PublishingSession(publisher: publisher, bitRateClock: { clock.now }, mutationSleep: { try await timer.sleep($0) })
                try await session.start()
                let finished = GuardedSessionFlag()
                let pending = Task {
                    defer { finished.set() }
                    try await performGuardedSessionChange(kind, session, selected: publisher.selector)
                }
                await eventually { dispatch.entered && timer.gate.entered }
                dispatch.release()
                await eventually { timer.gate.cancelled }
                let stop: Task<Void, Never>?
                if cancel { pending.cancel(); stop = nil }
                else { stop = Task { await session.stop() } }
                await eventually { publisher.stops == 1 }
                XCTAssertFalse(finished.value)
                clock.advance(to: 20); timer.gate.release()
                await fails(.cancelled) { try await pending.value }
                await stop?.value
                XCTAssertEqual(session.snapshot.failure, cancel ? .cancelled : nil)
                await session.stop()
            }
        }
    }

    func testUncertainFailureAndPostSuccessHealthFailureJoinShutdown() async throws {
        for kind in GuardedSessionRequest.allCases {
            for mode in [GuardedSessionPublisher.Mode.uncertain, .unhealthy, .oldTime] {
                let stopGate = GuardedSessionGate(), finished = GuardedSessionFlag()
                defer { stopGate.release() }
                let publisher = GuardedSessionPublisher(mode: mode)
                publisher.holdStop(stopGate)
                let session = try PublishingSession(publisher: publisher)
                try await session.start()
                let pending = Task {
                    defer { finished.set() }
                    try await performGuardedSessionChange(kind, session, selected: publisher.selector)
                }
                await eventually { stopGate.entered }
                XCTAssertFalse(finished.value)
                stopGate.release()
                await fails(kind.failure) { try await pending.value }
                XCTAssertEqual(session.snapshot.state, .failed)
                await session.stop()
            }
        }
    }

    private func rejects(_ expected: PublishingVideoMutationAdmissionError, _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected safe rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, expected, file: file, line: line) }
    }
    private func fails(_ expected: PublishingSessionError, _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected terminal rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? PublishingSessionError, expected, file: file, line: line) }
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private func performGuardedSessionChange(_ kind: GuardedSessionRequest, _ session: PublishingSession,
    selected: PublishingBitRateChange, before deadline: Double? = nil) async throws {
    switch kind {
    case .rate: _ = try await session.setVideoBitRate(800_000, expecting: .verified(selected), before: deadline)
    case .profile: _ = try await session.setVideoProfile(.low240, expecting: selected, before: deadline)
    case .replacement: _ = try await session.setVideoBitRate(800_000, expecting: .replacement(guardedReplacement(selected)), before: deadline)
    }
}

private enum GuardedSessionRequest: CaseIterable, Sendable {
    case rate, profile, replacement
    var failure: PublishingSessionError { self == .profile ? .profileUpdateFailed : .bitRateUpdateFailed }
    var timeout: PublishingSessionError { self == .profile ? .profileUpdateTimedOut : .bitRateUpdateTimedOut }
}
private func guardedReplacement(_ selected: PublishingBitRateChange) -> PublishingVideoProfileChange {
    .init(profile: .low240, publishingGeneration: selected.publishingGeneration,
        previousEncoderSessionID: UUID(), encoderSessionID: selected.configuration.encoderSessionID,
        lastOldSourcePTS: CMTime(value: 10, timescale: 30), firstNewSourcePTS: CMTime(value: 11, timescale: 30),
        width: 426, height: 240, rawVideoFramesDropped: 0, acknowledgedAt: selected.acceptedAt)!
}

private final class GuardedSessionPublisher: MediaPublisher, @unchecked Sendable {
    enum Mode { case success, safe(PublishingVideoMutationAdmissionError), uncertain, wrongGeneration,
        wrongEncoder, wrongPreviousEncoder, wrongProfile, wrongRate, reusedConfiguration, unhealthy, oldTime, backwardSource, missingSource }
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private let configurationID = UUID()
    private var encoderID = UUID()
    private var sourceValue: Int64 = 10
    private var mode: Mode
    private var healthy = false, didReturn = false
    private var stopCount = 0, legacyCount = 0, guardedCount = 0
    private var selectedValue: PublishingBitRateChange?
    private var dispatch: GuardedSessionGate?, completion: GuardedSessionGate?, stopGate: GuardedSessionGate?
    init(mode: Mode = .success, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.mode = mode; self.clock = clock
    }
    var selector: PublishingBitRateChange {
        lock.withLock { .init(publishingGeneration: 7, configuration: .init(id: configurationID, encoderSessionID: encoderID, bitRate: 600_000)!,
            acceptedAt: clock(), lastSubmittedSourcePTS: CMTime(value: sourceValue, timescale: 30))! }
    }
    var stops: Int { lock.withLock { stopCount } }
    var legacyCalls: Int { lock.withLock { legacyCount } }
    var guardedCalls: Int { lock.withLock { guardedCount } }
    var returned: Bool { lock.withLock { didReturn } }
    var selected: PublishingBitRateChange? { lock.withLock { selectedValue } }
    func setMode(_ value: Mode) { lock.withLock { mode = value } }
    func holdDispatch(_ gate: GuardedSessionGate, completion: GuardedSessionGate? = nil) {
        lock.withLock { dispatch = gate; self.completion = completion }
    }
    func holdStop(_ gate: GuardedSessionGate) { lock.withLock { stopGate = gate } }
    func start() async throws { lock.withLock { healthy = true } }
    var isPublishing: Bool { get async { lock.withLock { healthy } } }
    func append(_ sample: CapturedMediaSample) async throws {}
    func stop() async {
        let gates = lock.withLock { stopCount += 1; healthy = false; return (dispatch, stopGate) }
        gates.0?.release(); await gates.1?.wait()
    }
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange {
        lock.withLock { legacyCount += 1 }
        return try await write(rate)
    }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        lock.withLock { legacyCount += 1 }
        return try await replace(profile)
    }
    func setVideoBitRate(_ rate: Int, expecting expected: PublishingVideoMutationExpectation) async throws -> PublishingBitRateChange {
        lock.withLock {
            guardedCount += 1
            switch expected {
            case .verified(let value): selectedValue = value
            case .replacement(let value):
                selectedValue = .init(publishingGeneration: value.publishingGeneration,
                    configuration: .init(id: configurationID, encoderSessionID: value.encoderSessionID, bitRate: 600_000)!,
                    acceptedAt: value.acknowledgedAt, lastSubmittedSourcePTS: value.firstNewSourcePTS)
            }
        }
        return try await write(rate)
    }
    func setVideoProfile(_ profile: PublishingVideoProfile, expecting expected: PublishingBitRateChange) async throws -> PublishingVideoProfileChange {
        lock.withLock { guardedCount += 1; selectedValue = expected }
        return try await replace(profile)
    }
    private func prepare() async throws -> Mode {
        let gates = lock.withLock { (dispatch, completion) }
        await gates.0?.wait(); await gates.1?.wait()
        let mode = lock.withLock { didReturn = true; return self.mode }
        if case .safe(let error) = mode { throw error }
        if case .uncertain = mode { throw NSError(domain: "private encoder details", code: 1) }
        return mode
    }
    private func write(_ rate: Int) async throws -> PublishingBitRateChange {
        let mode = try await prepare()
        return lock.withLock {
            if case .unhealthy = mode { healthy = false }
            var generation: UInt64 = 7, encoder = encoderID, configuration = UUID(), actualRate = rate, acceptedAt = clock()
            if case .wrongGeneration = mode { generation = 8 }
            if case .wrongEncoder = mode { encoder = UUID() }
            if case .reusedConfiguration = mode { configuration = selectedValue?.configuration.id ?? configurationID }
            if case .wrongRate = mode { actualRate += 1 }
            if case .oldTime = mode { acceptedAt -= 1 }
            sourceValue += 1
            var pts: CMTime? = CMTime(value: sourceValue, timescale: 30)
            if case .backwardSource = mode { pts = .zero }
            if case .missingSource = mode { pts = nil }
            return .init(publishingGeneration: generation, configuration: .init(id: configuration, encoderSessionID: encoder, bitRate: actualRate)!,
                acceptedAt: acceptedAt, lastSubmittedSourcePTS: pts)!
        }
    }
    private func replace(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        let mode = try await prepare()
        return lock.withLock {
            if case .unhealthy = mode { healthy = false }
            var generation: UInt64 = 7, previous = encoderID, target = profile, acceptedAt = clock()
            encoderID = UUID()
            if case .wrongGeneration = mode { generation = 8 }
            if case .wrongPreviousEncoder = mode { previous = UUID() }
            if case .wrongProfile = mode { target = .low360 }
            if case .oldTime = mode { acceptedAt -= 1 }
            if case .backwardSource = mode { sourceValue = 0 }
            let lastOldSource = sourceValue
            sourceValue += 1
            return .init(profile: target, publishingGeneration: generation,
                previousEncoderSessionID: previous, encoderSessionID: encoderID,
                lastOldSourcePTS: CMTime(value: lastOldSource, timescale: 30), firstNewSourcePTS: CMTime(value: sourceValue, timescale: 30),
                width: target.width, height: target.height, rawVideoFramesDropped: 0, acknowledgedAt: acceptedAt)!
        }
    }
}

private final class LegacySessionPublisher: MediaPublisher, Sendable {
    let fixture = GuardedSessionPublisher()
    func start() async throws { try await fixture.start() }
    func stop() async { await fixture.stop() }
    var isPublishing: Bool { get async { await fixture.isPublishing } }
    func append(_ sample: CapturedMediaSample) async throws {}
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange { try await fixture.setVideoBitRate(rate) }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange { try await fixture.setVideoProfile(profile) }
}
private final class GuardedSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 10.0
    var now: Double { lock.withLock { value } }
    func advance(to value: Double) { lock.withLock { self.value = value } }
}
private final class GuardedSessionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
private final class GuardedSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false, didEnter = false, didCancel = false
    var entered: Bool { lock.withLock { didEnter } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    didEnter = true
                    if open { return true }
                    waiters.append(continuation); return false
                }
                if resume { continuation.resume() }
            }
        } onCancel: { self.lock.withLock { self.didCancel = true } }
    }
    func release() {
        let pending = lock.withLock { open = true; defer { waiters.removeAll() }; return waiters }
        for waiter in pending { waiter.resume() }
    }
}
private final class GuardedSessionSleeper: @unchecked Sendable {
    let gate = GuardedSessionGate()
    private let lock = NSLock()
    private var calls = 0
    func sleep(_ duration: Duration) async throws {
        let first = lock.withLock { calls += 1; return calls == 1 }
        if first { await gate.wait() } // Intentionally ignores cancellation until the test releases the exact timer.
        else { try await Task.sleep(for: duration) }
    }
}

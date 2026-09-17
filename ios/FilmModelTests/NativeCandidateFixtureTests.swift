import Foundation
import ScorebugMedia
@testable import ScorebugStreaming
import XCTest

final class NativeCandidateFixtureTests: XCTestCase {
    @MainActor func testSerializationPreservesActualRawBytesAndAdmissionTime() async throws {
        let scope = VideoFrameObservationScope(recordingID: "record", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low360)
        try await candidate.start()
        let sample = try candidateVideo().sampleBuffer
        let before = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(candidate.offer(sample))
        let after = ProcessInfo.processInfo.systemUptime
        let result = await candidate.finish()
        XCTAssertEqual(result.encoding.outcome, .completed)
        let measurement = PublishingCandidateMeasurement.Result(id: candidate.id, scope: scope, profile: .low360,
            reason: .completed, startedAt: before, endedAt: ProcessInfo.processInfo.systemUptime,
            acceptedInputCount: 1, firstInputPTS: sample.presentationTimeStamp,
            lastInputPTS: sample.presentationTimeStamp, encoding: result)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: NativeCandidateFixture.data(measurement)) as? [String: Any])
        let encoding = try XCTUnwrap(object["encoding"] as? [String: Any])
        let frames = try XCTUnwrap(encoding["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame["rawByteCount"] as? Int, CVPixelBufferGetDataSize(try XCTUnwrap(sample.imageBuffer)))
        let admitted = try XCTUnwrap(frame["admittedAt"] as? Double)
        XCTAssertGreaterThanOrEqual(admitted, before)
        XCTAssertLessThanOrEqual(admitted, after)
    }

    func testFlagsRequireExclusiveHigherCandidateAndFullFixedProfileFixture() throws {
        let valid = ["SCOREBUG_TEST_CANDIDATE_PROFILE": "540p30", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
        XCTAssertEqual(try NativeCandidateFixture.requested(environment: valid), .sd540)
        XCTAssertNil(try NativeCandidateFixture.requested(environment: [:]))
        for (key, value) in [("SCOREBUG_TEST_CANDIDATE_PROFILE", "240p30"), ("SCOREBUG_TEST_CANDIDATE_PROFILE", ""),
            ("SCOREBUG_TEST_CANDIDATE_PROFILE", "bogus"), ("SCOREBUG_TEST_VIDEO_OBSERVATIONS", ""),
            ("SCOREBUG_TEST_STREAM_HOLD_SECONDS", "89"), ("SCOREBUG_TEST_NATIVE_QUALITY", "1"),
            ("SCOREBUG_TEST_ADAPTIVE_PROFILES", "1"), ("SCOREBUG_TEST_PROFILE_TRANSITIONS", "1"),
            ("SCOREBUG_TEST_BANDWIDTH_PROBE", "staged"), ("SCOREBUG_TEST_SOURCE_CADENCE_PACING", "1"),
            ("SCOREBUG_TEST_UPLINK_PROXY_PORT", "1234"), ("SCOREBUG_TEST_DECODER_STALL", "reset540")] {
            var bad = valid; bad[key] = value
            XCTAssertThrowsError(try NativeCandidateFixture.requested(environment: bad), "\(key)=\(value)")
        }
    }
}

extension NativeCandidateFixtureTests {
    func testPrimaryAppendPrecedesOptionalVideoAndStopJoinsOnce() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start()
        await wait { fake.waiting }
        try await wrapper.append(candidateVideo())
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        fake.finish()
        await wrapper.waitForMeasurement()
        XCTAssertEqual(fake.exports, 0)
        async let one: Void = wrapper.stop()
        async let two: Void = wrapper.stop()
        _ = await (one, two)
        XCTAssertEqual(fake.stops, 1); XCTAssertEqual(fake.exports, 1)
        XCTAssertEqual(fake.object?["invalidReason"] is NSNull, true)
        XCTAssertEqual(fake.object?["formatVersion"] as? Int, 2)
        XCTAssertEqual(fake.object?["resourceLimits"] as? [String: Int],
            ["rawQueueCount": 4, "unresolvedInputCount": 16, "unresolvedRawBytes": 64 * 1024 * 1024,
             "rawBytesPerInput": 16 * 1024 * 1024])
    }
    func testNewDropsStaleThermalAndMissingDiagnosticsRevokeOptionalOnly() async throws {
        for fault in 0..<5 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start()
            await wait { fake.waiting }
            fake.setFault(fault)
            try await wrapper.append(candidateVideo())
            XCTAssertFalse(fake.events.contains("candidate"))
            XCTAssertTrue(fake.reasons.contains(.pressure))
            XCTAssertEqual(fake.stops, 0)
            await wrapper.stop()
            XCTAssertEqual(fake.object?["invalidReason"] as? String, "pressure")
        }
    }
    func testPrimaryFailureAndEncoderMutationRevokeWithoutWaitingForCandidateJoin() async throws {
        for mutation in 0..<3 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            do {
                if mutation == 0 { fake.failAppend = true; try await wrapper.append(candidateVideo()) }
                if mutation == 1 { _ = try await wrapper.setVideoBitRate(123) }
                if mutation == 2 { _ = try await wrapper.setVideoProfile(.low360) }
                XCTFail("primary fake throws")
            } catch {}
            XCTAssertFalse(fake.events.contains("candidate"))
            XCTAssertEqual(fake.reasons.first, mutation == 0 ? .pressure : .ownerChanged)
            XCTAssertEqual(fake.stops, 0)
            await wrapper.stop()
        }
    }
    func testStopBeforeDelayNeverStartsCandidateAndMissingDiagnosticsCannotStart() async throws {
        for missing in [false, true] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, delay: missing ? .zero : .seconds(20))
            if !missing { await wrapper.setDiagnostics { fake.pressure } }
            try await wrapper.start()
            if missing { await wait { !fake.reasons.isEmpty } }
            await wrapper.stop()
            XCTAssertFalse(fake.events.contains("candidateStart")); XCTAssertEqual(fake.exports, 1)
            XCTAssertNotNil(fake.object?["invalidReason"] as? String)
        }
    }
    func testMutationAfterMeasurementCannotExportCurrentOwnerProof() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.finish(); await wrapper.waitForMeasurement()
        _ = try? await wrapper.setVideoProfile(.low360)
        await wrapper.stop()
        XCTAssertEqual(fake.object?["invalidReason"] as? String, "ownerChanged")
    }
    func testPressureMonitorRevokesWithoutAnotherFrame() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.setFault(1)
        await wait { fake.reasons.contains(.pressure) }
        XCTAssertEqual(fake.stops, 0)
        await wrapper.stop()
    }
    func testFrameAlreadyInsidePrimaryCannotBecomeCandidateAfterDelayedStart() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, delay: .milliseconds(50))
        fake.blockAppend = true
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start()
        let append = Task { try await wrapper.append(candidateVideo()) }
        await wait { fake.events.contains("primary") }
        await wait { fake.waiting }
        fake.releaseAppend()
        try await append.value
        XCTAssertFalse(fake.events.contains("candidate"))
        await wrapper.stop()
    }
    func testStopJoinsDelayedPrimaryStartupBeforeExportingClosedEvidence() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        fake.blockStart = true
        await wrapper.setDiagnostics { fake.pressure }
        let startup = Task { try await wrapper.start() }
        await wait { fake.events.contains("primaryStart") }
        let stop = Task { await wrapper.stop() }
        await wait { fake.stops > 0 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fake.exports, 0, "closed evidence must await the primary startup join")
        fake.releaseStart()
        await stop.value
        do { try await startup.value; XCTFail("stopped startup cannot succeed") } catch {}
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(fake.exports, 1)
        XCTAssertFalse(fake.events.contains("candidateStart"))
    }
    private func makeCandidate(_ fake: CandidateFixtureFake, delay: Duration = .zero) -> NativeCandidatePublisher {
        .init(publisher: fake, scope: .init(recordingID: "record", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1), liveProfile: .low240,
            operations: fake.operations, timing: .init(delay: delay, poll: .milliseconds(10), maximumPolls: 50))
    }
    private func wait(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
        XCTFail("bounded fixture wait expired")
    }
}

import CoreMedia
import CoreVideo
private final class CandidateFixtureFake: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var storedEvents: [String] = [], storedReasons: [PublishingCandidateMeasurement.Reason] = []
    private var storedWaiting = false, storedStops = 0, storedExports = 0, storedData: Data?
    private var fault: Int?, storedFail = false, storedBlockAppend = false
    private let appendGate = AsyncStream<Void>.makeStream()
    private let startGate = AsyncStream<Void>.makeStream()
    private var storedBlockStart = false
    init() { let pair = AsyncStream<Void>.makeStream(); stream = pair.stream; continuation = pair.continuation }
    var events: [String] { lock.withLock { storedEvents } }
    var reasons: [PublishingCandidateMeasurement.Reason] { lock.withLock { storedReasons } }
    var waiting: Bool { lock.withLock { storedWaiting } }
    var stops: Int { lock.withLock { storedStops } }
    var exports: Int { lock.withLock { storedExports } }
    var object: [String: Any]? { lock.withLock { storedData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } } }
    var failAppend: Bool { get { lock.withLock { storedFail } } set { lock.withLock { storedFail = newValue } } }
    var blockStart: Bool { get { lock.withLock { storedBlockStart } } set { lock.withLock { storedBlockStart = newValue } } }
    func releaseStart() { startGate.continuation.finish() }
    var blockAppend: Bool { get { lock.withLock { storedBlockAppend } } set { lock.withLock { storedBlockAppend = newValue } } }
    func releaseAppend() { appendGate.continuation.finish() }
    func setFault(_ value: Int) { lock.withLock { fault = value } }
    var pressure: NativeCandidatePublisher.Pressure? {
        lock.withLock {
            if fault == 4 { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            return .init(observedAt: now, sampledAt: now - (fault == 2 ? 3 : 0), thermal: fault == 1 ? 2 : 0,
                dropped: fault == 0 ? 1 : 0, rejected: fault == 3 ? 1 : 0, publishing: true)
        }
    }
    var operations: NativeCandidatePublisher.Operations {
        .init(start: { self.lock.withLock { self.storedEvents.append("candidateStart") } },
            offer: { _ in self.lock.withLock { self.storedEvents.append("candidate") }; return true },
            cancel: { reason in self.lock.withLock { self.storedReasons.append(reason) } },
            result: { self.lock.withLock { self.storedWaiting = true }; for await _ in self.stream {}; return Data("{}".utf8) },
            export: { data in self.lock.withLock { self.storedExports += 1; self.storedData = data } })
    }
    func finish() { continuation.finish() }
    func start() async throws {
        lock.withLock { storedEvents.append("primaryStart") }
        if blockStart { for await _ in startGate.stream {} }
    }
    func append(_ sample: CapturedMediaSample) async throws {
        lock.withLock { storedEvents.append("primary") }
        if blockAppend { for await _ in appendGate.stream {} }
        if failAppend { throw PublishingSessionError.appendFailed }
    }
    var isPublishing: Bool { get async { true } }
    func stop() async { lock.withLock { storedStops += 1 }; releaseAppend(); finish() }
}
private func candidateVideo() throws -> CapturedMediaSample {
    var pixel: CVPixelBuffer?, format: CMVideoFormatDescription?, sample: CMSampleBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
}

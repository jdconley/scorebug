import CoreMedia
import Foundation
import ScorebugMedia
import XCTest

final class NativeProfileTransitionFixtureTests: XCTestCase {
    private func evidence() -> NativeProfileTransitionEvidence {
        .init(scope: .init(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1))
    }
    private func record(_ evidence: NativeProfileTransitionEvidence, _ frame: Int,
                        _ profile: PublishingVideoProfile, generation: UInt64 = 1, valid: Bool = true) {
        evidence.record(generation: generation, pts: CMTime(value: Int64(frame), timescale: 30),
            width: Int32(profile.width), height: Int32(profile.height), valid: valid)
    }
    private func snapshot(_ evidence: NativeProfileTransitionEvidence) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: evidence.data()) as? [String: Any])
    }
    func testKeepsThreeActualFormatIntervalsAndTwoReceiptsUntilJoinedClose() throws {
        let proof = evidence()
        let ids = [UUID(), UUID(), UUID()]
        for frame in 0..<90 {
            let phase = frame / 30, profile: PublishingVideoProfile = phase == 1 ? .sd540 : .hd1080
            record(proof, frame, profile)
            if frame == 30 || frame == 60 {
                proof.receipt(.init(profile: profile, publishingGeneration: 1,
                    previousEncoderSessionID: ids[phase - 1], encoderSessionID: ids[phase],
                    lastOldSourcePTS: CMTime(value: Int64(frame - 1), timescale: 30),
                    firstNewSourcePTS: CMTime(value: Int64(frame), timescale: 30),
                    width: profile.width, height: profile.height, rawVideoFramesDropped: 0, acknowledgedAt: Double(frame))!)
            }
        }
        XCTAssertEqual(try snapshot(proof)["isClosed"] as? Bool, false)
        proof.close()
        let result = try snapshot(proof)
        XCTAssertEqual(result["isClosed"] as? Bool, true)
        XCTAssertEqual(result["invalid"] as? Bool, false)
        XCTAssertEqual(result["frames"] as? Int, 90)
        let phases = try XCTUnwrap(result["phases"] as? [[String: Any]])
        XCTAssertEqual(phases.map { $0["width"] as? Int }, [1920, 960, 1920])
        XCTAssertEqual(phases.map { $0["frames"] as? Int }, [30, 30, 30])
        XCTAssertEqual((result["receipts"] as? [[String: Any]])?.count, 2)
    }
    func testRejectsInvalidSamplesGenerationRewindExtraPhaseAndPostCloseCallback() throws {
        for mode in 0..<5 {
            let proof = evidence(); record(proof, 0, .hd1080)
            switch mode {
            case 0: record(proof, 1, .hd1080, valid: false)
            case 1: record(proof, 1, .hd1080, generation: 2)
            case 2: record(proof, 0, .hd1080)
            case 3:
                record(proof, 1, .sd540); record(proof, 2, .hd1080); record(proof, 3, .sd540)
            default: proof.close(); record(proof, 1, .hd1080)
            }
            XCTAssertEqual(try snapshot(proof)["invalid"] as? Bool, true)
        }
    }
    @MainActor func testDriverRunsBothChangesAndClosesBeforeExport() async throws {
        let publisher = TransitionPublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        var exported: Data?
        let proof = evidence()
        let driver = NativeProfileTransitionDriver(session: session, evidence: proof,
            waits: [.milliseconds(1), .milliseconds(1)], export: { exported = $0 })
        await driver.waitForSchedule()
        let profiles = await publisher.profiles
        XCTAssertEqual(profiles, [.sd540, .hd1080])
        XCTAssertNil(exported)
        await driver.stop()
        let stopCount1 = await publisher.stops
        XCTAssertEqual(stopCount1, 1)
        let data = try XCTUnwrap(exported)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["isClosed"] as? Bool, true)
        await driver.stop()
        let stopCount2 = await publisher.stops
        XCTAssertEqual(stopCount2, 1)
    }
    @MainActor func testDriverCancelledDuringWaitCannotDispatchAfterStop() async throws {
        let publisher = TransitionPublisher(), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let driver = NativeProfileTransitionDriver(session: session, evidence: evidence(),
            waits: [.seconds(60), .seconds(60)], export: { _ in })
        driver.cancel()
        await driver.stop()
        let profiles = await publisher.profiles
        XCTAssertEqual(profiles, [])
        let stopCount = await publisher.stops
        XCTAssertEqual(stopCount, 1)
    }
    @MainActor func testStopJoinsDelayedNativeResultBeforeClosingOrExporting() async throws {
        let publisher = TransitionPublisher(gated: true), session = try PublishingSession(publisher: publisher)
        try await session.start()
        let proof = evidence()
        var exported: Data?, stopped = false
        let driver = NativeProfileTransitionDriver(session: session, evidence: proof,
            waits: [.zero, .seconds(60)], export: { exported = $0 })
        let deadline = ContinuousClock.now + .seconds(2)
        while await publisher.profiles.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let entered = await publisher.profiles
        XCTAssertEqual(entered, [.sd540])
        let stop = Task { await driver.stop(); stopped = true }
        stop.cancel()
        while await publisher.stops == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(stopped); XCTAssertNil(exported)
        XCTAssertEqual(try snapshot(proof)["isClosed"] as? Bool, false)
        await publisher.release()
        await stop.value
        XCTAssertTrue(stopped); XCTAssertNotNil(exported)
        XCTAssertEqual(try snapshot(proof)["isClosed"] as? Bool, true)
        XCTAssertEqual((try snapshot(proof)["receipts"] as? [Any])?.count, 0)
    }
    func testExplicitAppFlagsRejectMixedExperiments() throws {
        let env = ["SCOREBUG_TEST_PROFILE_TRANSITIONS": "1", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
        XCTAssertTrue(try NativeProfileTransitionEvidence.requested(environment: env))
        XCTAssertFalse(try NativeProfileTransitionEvidence.requested(environment: [:]))
        for (key, value) in [("SCOREBUG_TEST_PROFILE_TRANSITIONS", "true"), ("SCOREBUG_TEST_NATIVE_QUALITY", "1"),
                            ("SCOREBUG_TEST_NATIVE_CONFIRMATION", "1"), ("SCOREBUG_TEST_LIVE_PROFILE", "540p30"),
                            ("SCOREBUG_TEST_VIDEO_OBSERVATIONS", "0"), ("SCOREBUG_TEST_MOTION_FIXTURE", "1"),
                            ("SCOREBUG_TEST_STREAM_HOLD_SECONDS", "89"), ("SCOREBUG_TEST_UPLINK_PROXY_PORT", "50000")] {
            var invalid = env; invalid[key] = value
            XCTAssertThrowsError(try NativeProfileTransitionEvidence.requested(environment: invalid))
        }
    }
    func testIndependentEncoderCallbacksRetainSourceIdentityAndCompletionGaps() throws {
        let proof = evidence(), ids = [UUID(), UUID(), UUID()]
        for frame in 0..<90 {
            proof.recordEncoder(id: ids[frame / 30], pts: CMTime(value: Int64(frame), timescale: 30),
                submittedAt: 100 + Double(frame) / 30, completedAt: 100.2 + Double(frame) / 30)
        }
        let sessions = try XCTUnwrap(try snapshot(proof)["encoderSessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.map { $0["encoderSessionID"] as? String }, ids.map(\.uuidString))
        XCTAssertEqual(sessions.map { $0["frames"] as? Int }, [30, 30, 30])
        XCTAssertEqual(sessions[1]["firstCompletedAt"] as? Double, 101.2)
        XCTAssertEqual(try XCTUnwrap(sessions[1]["maximumCompletionGapSeconds"] as? Double), 1.0 / 30, accuracy: 0.000001)
        proof.recordEncoder(id: UUID(), pts: CMTime(value: 90, timescale: 30), submittedAt: 103, completedAt: 103.2)
        XCTAssertEqual(try snapshot(proof)["invalid"] as? Bool, true)
    }
    func testFrameOverflowKeepsEvidenceBounded() throws {
        let proof = evidence()
        for frame in 0...25_000 { record(proof, frame, .hd1080) }
        let result = try snapshot(proof)
        XCTAssertEqual(result["frames"] as? Int, 25_000)
        XCTAssertEqual(result["invalid"] as? Bool, true)
        XCTAssertLessThan(try proof.data().count, 12_000)
    }
}

private actor TransitionPublisher: MediaPublisher {
    var profiles: [PublishingVideoProfile] = []
    var stops = 0
    var isPublishing = false
    private var encoder = UUID()
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    init(gated: Bool = false) { self.gated = gated }
    func release() { gate?.resume(); gate = nil }
    func start() { isPublishing = true }
    func stop() { stops += 1; isPublishing = false }
    func append(_ sample: CapturedMediaSample) {}
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        let old = encoder; encoder = UUID(); profiles.append(profile)
        if gated { await withCheckedContinuation { gate = $0 } }
        let source = Int64(profiles.count * 30)
        return .init(profile: profile, publishingGeneration: 1,
            previousEncoderSessionID: old, encoderSessionID: encoder,
            lastOldSourcePTS: CMTime(value: source - 1, timescale: 30), firstNewSourcePTS: CMTime(value: source, timescale: 30),
            width: profile.width, height: profile.height, rawVideoFramesDropped: 0,
            acknowledgedAt: ProcessInfo.processInfo.systemUptime)!
    }
}

import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

final class VideoObservationFixtureTests: XCTestCase {
    func testExportPreservesExactRationalTimeAndScopeWithoutSetupData() throws {
        let attempt = UUID()
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
            broadcastGeneration: 4, publishingAttemptID: attempt, appliedProfileRevision: .max)
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        let pts = CMTime(value: 9_007_199_254_740_993, timescale: 60,
            flags: .valid, epoch: 9_007_199_254_740_995)
        accumulator.observe(.captureVideo, sourcePTS: pts, at: 0)
        let data = try VideoObservationFixture.data(for: accumulator.close(at: 2), captureDetachedAt: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        XCTAssertEqual(json["isClosed"] as? Bool, true)
        XCTAssertEqual(json["captureDetachedAt"] as? Double, 1)
        XCTAssertTrue(json["omittedThroughMonotonicTime"] is NSNull)
        let identity = try XCTUnwrap(json["scope"] as? [String: Any])
        XCTAssertEqual(identity["appliedProfileRevision"] as? String, "18446744073709551615")
        XCTAssertEqual(identity["publishingAttemptID"] as? String, attempt.uuidString)
        XCTAssertEqual(Set(identity.keys), ["recordingID", "matchID", "broadcastGeneration", "publishingAttemptID", "appliedProfileRevision"])
        let current = try XCTUnwrap(json["current"] as? [String: Any])
        XCTAssertEqual(current["monotonicStart"] as? Double, 0)
        XCTAssertEqual(current["monotonicEnd"] as? Double, 2)
        let capture = try XCTUnwrap(current["captureVideo"] as? [String: Any])
        XCTAssertEqual(capture["callbackCount"] as? String, "1")
        let time = try XCTUnwrap(capture["firstSourcePTS"] as? [String: Any])
        XCTAssertEqual(time["value"] as? String, "9007199254740993")
        XCTAssertEqual(time["epoch"] as? String, "9007199254740995")
        XCTAssertEqual(time["timescale"] as? Int, 60)
        let encoded = try XCTUnwrap(current["encodedVideo"] as? [String: Any])
        XCTAssertTrue(encoded["firstSourcePTS"] is NSNull)
        XCTAssertEqual(encoded["callbackCount"] as? String, "0")
        XCTAssertEqual(Set(json.keys), ["formatVersion", "scope", "captureDetachedAt", "monotonicAnchor", "windowDuration", "current", "completed", "omittedCompletedWindowCount", "omittedThroughMonotonicTime", "rejectedClockOperationCount", "invalidity", "isClosed"])
    }

    func testFixtureRequiresExactExplicitFlag() {
        XCTAssertFalse(VideoObservationFixture.requested(environment: [:]))
        XCTAssertFalse(VideoObservationFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "true"]))
        XCTAssertFalse(VideoObservationFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "0"]))
        XCTAssertTrue(VideoObservationFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1"]))
    }

    func testExtendedHistoryRequiresExplicitFixtureAndCanonicalBoundedHold() {
        XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: [:]), 8)
        XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_STREAM_HOLD_SECONDS": "180"]), 8)
        for raw in ["", " 180", "0180", "+180", "180.0", "11", "181", "NaN"] {
            XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": raw]), 8)
        }
        for raw in ["12", "90", "180"] {
            XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": raw]), 64)
        }
    }

    func testExtendedFixtureRetainsThreeMinutesWithoutEviction() throws {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match", broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let limit = VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "180"])
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0, completedWindowLimit: limit)
        for frame in 0..<5400 {
            let pts = CMTime(value: Int64(frame), timescale: 30)
            accumulator.observe(.captureVideo, sourcePTS: pts, at: Double(frame) / 30)
            accumulator.observe(.encodedVideo, sourcePTS: pts, at: Double(frame) / 30)
        }
        let snapshot = accumulator.close(at: 180)
        XCTAssertEqual(snapshot.completed.count, 36)
        XCTAssertEqual(snapshot.omittedCompletedWindowCount, 0)
        XCTAssertNil(snapshot.omittedThroughMonotonicTime)
    }
}

private let proofAttempt = UUID(uuidString: "12345678-1234-4234-9234-123456789ABC")!
private func proofScope(recording: String = "recording", attempt: UUID = proofAttempt, game: String = "game", generation: Int = 3) -> VideoFrameObservationScope {
    .init(recordingID: recording, matchID: game, broadcastGeneration: generation,
          publishingAttemptID: attempt, appliedProfileRevision: 1)
}


final class WorkerReportAgeProofTests: XCTestCase {
    private func proof(sequence: Int64 = 1, scope: VideoFrameObservationScope = proofScope(),
                       worker: String = "worker", attempt: Int = 2, residence: Duration = .nanoseconds(789)) throws -> WorkerReportAgeProof {
        let received = ContinuousClock.now
        let request = Duration.milliseconds(123)
        let window = DecodedVideoWindow(sequence: sequence, durationMs: 5000, ageMs: 250,
            firstPTS: 0, lastPTS: 447000, freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true)
        let response = WorkerMediaStatusResponse(status: .init(gameId: scope.matchID, generation: scope.broadcastGeneration, workerId: worker,
            state: .producingOutput, observation: .init(gameId: scope.matchID, generation: scope.broadcastGeneration, state: .producingOutput,
            reason: nil, attempt: attempt, frame: nil, outTimeUs: nil, scoreRevision: nil,
            decodedVideo: .init(completed: window, invalidReason: nil, ended: false)), observedAt: nil,
            expiresAt: "2040-01-01T00:00:05Z", decodedVideoAgeUpperBoundMs: 550), serverTime: "2040-01-01T00:00:00Z")
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: received, requestDuration: request))
        let actual = helper.ageUpperBound(at: received.advanced(by: residence))
        return try XCTUnwrap(WorkerReportAgeProof(scope: scope, helper: helper, serverUpperBoundMs: 550,
            requestDuration: request, residenceDuration: residence, helperAgeUpperBound: actual))
    }

    func testHistoryReplacesSameSequenceAdvancesAtTwoAndResetsOnRewind() throws {
        var history = WorkerReportAgeProofHistory()
        history.record(try proof())
        history.record(try proof(residence: .microseconds(2)))
        XCTAssertEqual(history.proofs.count, 1)
        XCTAssertEqual(history.proofs.first?.residenceDuration.attoseconds, "2000000000000")
        history.record(try proof(sequence: 2)); history.record(try proof(sequence: 3))
        XCTAssertEqual(history.proofs.map { $0.completed.sequence }, [2, 3])
        history.record(try proof(sequence: 1))
        XCTAssertEqual(history.proofs.map { $0.completed.sequence }, [1])
    }

    func testHistoryResetsForLocalOrRemoteScopeAndNilOrLifecycleClear() throws {
        for replacement in [try proof(scope: proofScope(recording: "other")),
                            try proof(scope: proofScope(attempt: UUID())),
                            try proof(worker: "other"), try proof(attempt: 3),
                            try proof(scope: proofScope(game: "other")),
                            try proof(scope: proofScope(generation: 4))] {
            var history = WorkerReportAgeProofHistory()
            history.record(try proof()); history.record(try proof(sequence: 2)); history.record(replacement)
            XCTAssertEqual(history.proofs, [replacement])
            history.record(nil)
            XCTAssertTrue(history.proofs.isEmpty)
            history.record(replacement); history.clear()
            XCTAssertTrue(history.proofs.isEmpty)
        }
    }

    func testExportPreservesActualExactDurationReturnAndImmutableWindow() throws {
        let evidence = try proof(residence: Duration(secondsComponent: 0, attosecondsComponent: 789123456789))
        var accumulator = try VideoFrameObservationAccumulator(scope: proofScope(), monotonicAnchor: 0)
        let data = try VideoObservationFixture.data(for: accumulator.close(at: 1), captureDetachedAt: 1,
            workerReportAgeProofs: [evidence])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proofs = try XCTUnwrap(json["workerReportAgeProofs"] as? [[String: Any]])
        XCTAssertEqual(proofs.count, 1)
        let p = proofs[0]
        XCTAssertEqual(p["evaluatedAt"] as? String, "pollControl")
        XCTAssertEqual(p["decodedVideoAgeUpperBoundMs"] as? Int64, 550)
        XCTAssertEqual(p["requestDuration"] as? [String: String], ["seconds": "0", "attoseconds": "123000000000000000"])
        XCTAssertEqual(p["residenceDuration"] as? [String: String], ["seconds": "0", "attoseconds": "789123456789"])
        XCTAssertEqual(p["helperAgeUpperBound"] as? [String: String], ["seconds": "0", "attoseconds": "673000789123456789"])
        XCTAssertTrue(p["invalidReason"] is NSNull)
        XCTAssertEqual((p["completed"] as? [String: Any])?["freshFrames"] as? Int, 150)
    }
}

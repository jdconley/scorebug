import CoreMedia
import Foundation
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
}

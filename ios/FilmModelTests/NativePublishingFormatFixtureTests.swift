import CoreMedia
import Foundation
import ScorebugMedia
import XCTest

final class NativePublishingFormatFixtureTests: XCTestCase {
    private func fixture() -> NativePublishingFormatFixture {
        .init(scope: .init(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1), profile: .sd540)
    }
    private func record(_ fixture: NativePublishingFormatFixture, frame: Int, generation: UInt64 = 1,
                        width: Int32 = 960, valid: Bool = true) {
        fixture.record(generation: generation, pts: CMTime(value: Int64(frame), timescale: 30),
                       width: width, height: 540, valid: valid)
    }
    private func snapshot(_ fixture: NativePublishingFormatFixture) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.data()) as? [String: Any])
    }
    func testCostExportCannotClaimJoinedCloseBeforeOwnerCloses() throws {
        let fixture = fixture()
        var data = try JSONSerialization.jsonObject(with: fixture.costData()) as! [String: Any]
        XCTAssertEqual(data["isClosed"] as? Bool, false)
        fixture.videoCost.close()
        data = try JSONSerialization.jsonObject(with: fixture.costData()) as! [String: Any]
        XCTAssertEqual(data["isClosed"] as? Bool, true)
        XCTAssertTrue(data["invalidReason"] is NSNull)
        XCTAssertEqual((data["intervals"] as? [Any])?.count, 0)
    }

    func testRetainsActualSizeAndRejectsCrossedFormatsGenerationsAndTimestamps() throws {
        for mode in 0..<5 {
            let proof = fixture(); record(proof, frame: 1)
            switch mode {
            case 0: record(proof, frame: 2, width: 1920)
            case 1: record(proof, frame: 2, generation: 2)
            case 2: record(proof, frame: 1)
            case 3: record(proof, frame: 2, valid: false)
            default: record(proof, frame: 2)
            }
            let result = try snapshot(proof)
            XCTAssertEqual(result["invalid"] as? Bool, mode != 4)
            XCTAssertEqual(result["frames"] as? Int, 2)
            XCTAssertEqual(result["width"] as? Int, 960)
        }
        let wrong = fixture(); record(wrong, frame: 1, width: 1920)
        XCTAssertEqual(try snapshot(wrong)["width"] as? Int, 1920, "Report actual size, never expected profile size")
    }
    func testEvidenceHasConstantSizeAndLatchesOverflow() throws {
        let proof = fixture()
        for frame in 0...25_000 { record(proof, frame: frame) }
        let result = try snapshot(proof)
        XCTAssertEqual(result["frames"] as? Int, 25_000)
        XCTAssertEqual(result["invalid"] as? Bool, true)
        XCTAssertLessThan(try proof.data().count, 2048)
    }
    func testLow360FixtureUsesExplicitGateAndLeavesArchiveUnchanged() throws {
        let environment = ["SCOREBUG_TEST_LIVE_PROFILE":"360p30", "SCOREBUG_TEST_VIDEO_OBSERVATIONS":"1",
            "SCOREBUG_TEST_MOTION_FIXTURE":"blocks16", "SCOREBUG_TEST_STREAM_HOLD_SECONDS":"180",
            "SCOREBUG_TEST_UPLINK_PROXY_PORT":"55555"]
        let profile = try VideoObservationFixture.liveProfile(environment: environment)
        XCTAssertEqual(profile.rawValue, "360p30")
        XCTAssertEqual(profile.width, 640); XCTAssertEqual(profile.height, 360)
        XCTAssertEqual(ArchiveProfile().width, 1920); XCTAssertEqual(ArchiveProfile().height, 1080)
        XCTAssertEqual(try VideoObservationFixture.publishingURL(URL(string: "srt://127.0.0.1:8890?streamid=publish%3Afixture")!, environment: environment).port, 55555)
        for key in ["SCOREBUG_TEST_VIDEO_OBSERVATIONS", "SCOREBUG_TEST_MOTION_FIXTURE", "SCOREBUG_TEST_STREAM_HOLD_SECONDS"] {
            var invalid = environment; invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try VideoObservationFixture.liveProfile(environment: invalid))
        }
    }
    func testReducedFixtureRequiresExplicitModeAndIndependentRecordingHold() throws {
        let environment = ["SCOREBUG_TEST_LIVE_PROFILE":"540p30", "SCOREBUG_TEST_VIDEO_OBSERVATIONS":"1",
            "SCOREBUG_TEST_MOTION_FIXTURE":"blocks16", "SCOREBUG_TEST_STREAM_HOLD_SECONDS":"90"]
        XCTAssertEqual(try VideoObservationFixture.liveProfile(environment: environment), .sd540)
        XCTAssertEqual(try VideoObservationFixture.liveProfile(environment: [:]), .hd1080)
        for (key,value) in [("SCOREBUG_TEST_NATIVE_QUALITY","1"),("SCOREBUG_TEST_LIVE_PROFILE","720p30"),
                            ("SCOREBUG_TEST_VIDEO_OBSERVATIONS","0"),("SCOREBUG_TEST_MOTION_FIXTURE","1"),
                            ("SCOREBUG_TEST_STREAM_HOLD_SECONDS","89")] {
            var invalid = environment; invalid[key] = value
            XCTAssertThrowsError(try VideoObservationFixture.liveProfile(environment: invalid))
        }
        var proxy = environment; proxy["SCOREBUG_TEST_UPLINK_PROXY_PORT"] = "55555"
        let routed = try VideoObservationFixture.publishingURL(URL(string:"srt://127.0.0.1:8890?streamid=publish%3Afixture")!,environment:proxy)
        XCTAssertEqual(routed.port,55555)
    }
}

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
    private func audio(_ fixture: NativePublishingFormatFixture, frame: Int, generation: UInt64 = 1,
                       observedAt: Double = 1, valid: Bool = true) {
        fixture.recordAudio(generation: generation, pts: CMTime(value: Int64(frame * 1024), timescale: 48_000),
            hostTime: UInt64(frame + 1), observedAt: observedAt, sampleRate: 48_000, channels: 2,
            framesPerPacket: 1024, audioObjectType: 2, bytes: 200, wasEncoded: true, valid: valid)
    }
    func testAudioStartupRetainsExactFirstEightScalarPacketsAndCountsWithoutPayload() throws {
        let proof = fixture()
        for frame in 0..<100 { audio(proof, frame: frame) }
        let result = try snapshot(proof)
        let startup = try XCTUnwrap(result["audioStartup"] as? [String: Any])
        XCTAssertEqual(startup["frames"] as? Int, 100)
        XCTAssertEqual(startup["invalid"] as? Bool, false)
        let rows = try XCTUnwrap(startup["first"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows[0]["hostTime"] as? String, "1")
        XCTAssertEqual(rows[0]["publishingGeneration"] as? String, "1")
        XCTAssertEqual(rows[0]["sampleRate"] as? Double, 48_000)
        XCTAssertEqual(rows[0]["bytes"] as? Int, 200)
        XCTAssertEqual((rows[7]["sourcePTS"] as? [String: Any])?["value"] as? String, "7168")
        XCTAssertEqual((rows[7]["sourcePTS"] as? [String: Any])?["timescale"] as? Int, 48_000)
        XCTAssertNil(rows[0]["payload"])
        XCTAssertLessThan(try proof.data().count, 12_000)
    }
    func testAudioInvalidityIsLatchedAndDoesNotChangeVideoValidity() throws {
        for mode in 0..<5 {
            let proof = fixture(); record(proof, frame: 1); audio(proof, frame: 1)
            switch mode {
            case 0: audio(proof, frame: 2, generation: 2)
            case 1: audio(proof, frame: 1)
            case 2: audio(proof, frame: 2, valid: false)
            case 3: audio(proof, frame: 2, observedAt: .nan)
            default: audio(proof, frame: 2)
            }
            let result = try snapshot(proof)
            let startup = try XCTUnwrap(result["audioStartup"] as? [String: Any])
            XCTAssertEqual(startup["invalid"] as? Bool, mode != 4)
            XCTAssertEqual(result["invalid"] as? Bool, false)
        }
    }
    func testAudioStartupLatchesGenerationMismatchWithVideoRegardlessOfCallbackOrder() throws {
        for audioFirst in [true, false] {
            let proof = fixture()
            if audioFirst { audio(proof, frame: 1, generation: 2) }
            record(proof, frame: 1)
            if !audioFirst { audio(proof, frame: 1, generation: 2) }
            let startup = try XCTUnwrap(try snapshot(proof)["audioStartup"] as? [String: Any])
            XCTAssertEqual(startup["invalid"] as? Bool, true)
        }
    }
    private func mux(_ fixture: NativePublishingFormatFixture, frame: Int, media: String = "audio",
                     generation: UInt64 = 1, pts: CMTime? = nil, observedAt: Double = 1) {
        fixture.recordMux(generation: generation, media: media,
            pts: pts ?? CMTime(value: Int64(frame), timescale: 30), dts: .invalid,
            transportPTS: UInt64(9000 + frame * 3000), transportDTS: nil, observedAt: observedAt)
    }
    func testMuxStartupRetainsFirstEightPerMediaAndExactUnwrappedTransportCoordinates() throws {
        let proof = fixture()
        for frame in 0..<100 { mux(proof, frame: frame); mux(proof, frame: frame, media: "video") }
        let startup = try XCTUnwrap(try snapshot(proof)["muxStartup"] as? [String: Any])
        XCTAssertEqual(startup["frames"] as? Int, 200)
        XCTAssertEqual(startup["invalid"] as? Bool, false)
        for media in ["audio", "video"] {
            let rows = try XCTUnwrap(startup[media] as? [[String: Any]])
            XCTAssertEqual(rows.count, 8)
            XCTAssertEqual(rows[0]["transportPTS"] as? String, "9000")
            XCTAssertTrue(rows[0]["transportDTS"] is NSNull)
            XCTAssertEqual(rows[7]["transportPTS"] as? String, "30000")
            XCTAssertEqual(rows[0]["publishingGeneration"] as? String, "1")
        }
        XCTAssertLessThan(try proof.data().count, 14_000)
        let unwrapped = fixture()
        unwrapped.recordMux(generation: 1, media: "video", pts: CMTime(value: 100000, timescale: 1),
            dts: CMTime(value: 99999, timescale: 1), transportPTS: 9_000_009_000,
            transportDTS: 8_999_919_000, observedAt: 1)
        let rows = (try snapshot(unwrapped)["muxStartup"] as? [String: Any])?["video"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["transportPTS"] as? String, "9000009000")
        XCTAssertEqual(rows?.first?["transportDTS"] as? String, "8999919000")
    }
    func testMuxStartupRejectsInvalidMetadataWithoutChangingVideoValidityOrJSONEncoding() throws {
        for mode in 0..<5 {
            let proof = fixture(); record(proof, frame: 1); mux(proof, frame: 1)
            switch mode {
            case 0: mux(proof, frame: 2, generation: 2)
            case 1: mux(proof, frame: 2, media: "subtitle")
            case 2: mux(proof, frame: 2, pts: .invalid)
            case 3: mux(proof, frame: 2, observedAt: .infinity)
            default: mux(proof, frame: 2)
            }
            let result = try snapshot(proof)
            XCTAssertEqual((result["muxStartup"] as? [String: Any])?["invalid"] as? Bool, mode != 4)
            XCTAssertEqual(result["invalid"] as? Bool, false)
        }
    }
    func testAudioAndMuxCountsSaturateAndKeepFirstEvidence() throws {
        let proof = fixture()
        for frame in 0...25_000 { audio(proof, frame: frame); mux(proof, frame: frame) }
        let result = try snapshot(proof)
        for key in ["audioStartup", "muxStartup"] {
            let startup = try XCTUnwrap(result[key] as? [String: Any])
            XCTAssertEqual(startup["frames"] as? Int, 25_000)
            XCTAssertEqual(startup["invalid"] as? Bool, true)
        }
        XCTAssertLessThan(try proof.data().count, 14_000)
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
    func testLow240FixtureUsesExplicitGateAndLeavesArchiveUnchanged() throws {
        let environment = ["SCOREBUG_TEST_LIVE_PROFILE":"240p30", "SCOREBUG_TEST_VIDEO_OBSERVATIONS":"1",
            "SCOREBUG_TEST_MOTION_FIXTURE":"blocks16", "SCOREBUG_TEST_STREAM_HOLD_SECONDS":"180",
            "SCOREBUG_TEST_UPLINK_PROXY_PORT":"55555"]
        let profile = try VideoObservationFixture.liveProfile(environment: environment)
        XCTAssertEqual(profile.rawValue, "240p30")
        XCTAssertEqual(profile.width, 426); XCTAssertEqual(profile.height, 240)
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
        XCTAssertEqual(try VideoObservationFixture.liveProfile(environment: [:]), .low240)
        XCTAssertEqual(try VideoObservationFixture.liveProfile(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1"]), .hd1080)
        for (key,value) in [("SCOREBUG_TEST_NATIVE_QUALITY","1"),("SCOREBUG_TEST_LIVE_PROFILE","720p30"),
                            ("SCOREBUG_TEST_LIVE_PROFILE","2160p30"),
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

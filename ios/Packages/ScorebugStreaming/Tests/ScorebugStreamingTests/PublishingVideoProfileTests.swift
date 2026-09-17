import XCTest
@testable import ScorebugStreaming

final class PublishingVideoProfileTests: XCTestCase {
    func testLow360CandidateHasIndependentRealTimeSettings() throws {
        let profile = try XCTUnwrap(PublishingVideoProfile(rawValue: "360p30"))
        XCTAssertEqual(profile.width, 640); XCTAssertEqual(profile.height, 360)
        XCTAssertEqual(profile.bitRate, 600_000)
        XCTAssertEqual(profile.settings.videoSize.width, 640)
        XCTAssertEqual(profile.settings.videoSize.height, 360)
        XCTAssertEqual(profile.settings.expectedFrameRate, 30)
    }

    func testLow240CandidateHasIndependentRealTimeSettings() throws {
        let profile = try XCTUnwrap(PublishingVideoProfile(rawValue: "240p30"))
        XCTAssertEqual(profile.width, 426); XCTAssertEqual(profile.height, 240)
        XCTAssertEqual(profile.bitRate, 350_000)
        XCTAssertEqual(profile.settings.videoSize.width, 426)
        XCTAssertEqual(profile.settings.videoSize.height, 240)
        XCTAssertEqual(profile.settings.expectedFrameRate, 30)
    }

    func testProfilesPreserveRateAndSizeWhileSharingRealTimeDefaults() {
        let full = PublishingVideoProfile.hd1080.settings
        let reduced = PublishingVideoProfile.sd540.settings
        XCTAssertEqual(full.videoSize.width, 1920); XCTAssertEqual(full.videoSize.height, 1080)
        XCTAssertEqual(full.bitRate, 6_000_000)
        XCTAssertEqual(reduced.videoSize.width, 960); XCTAssertEqual(reduced.videoSize.height, 540)
        XCTAssertEqual(reduced.bitRate, 1_500_000)
        for profile in PublishingVideoProfile.allCases {
            let settings = profile.settings
            XCTAssertEqual(settings.expectedFrameRate, 30)
            XCTAssertEqual(settings.allowFrameReordering, false)
            XCTAssertEqual(settings.maxKeyFrameIntervalDuration, 2)
            XCTAssertFalse(settings.isLowLatencyRateControlEnabled)
        }
    }
}

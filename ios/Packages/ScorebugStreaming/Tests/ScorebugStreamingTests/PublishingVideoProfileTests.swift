import XCTest
@testable import ScorebugStreaming

final class PublishingVideoProfileTests: XCTestCase {
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

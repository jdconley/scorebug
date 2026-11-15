import VideoToolbox
import XCTest
@testable import ScorebugStreaming

final class PublishingVideoProfileTests: XCTestCase {
    func testEveryLadderRungUsesRealtimeH264Settings() {
        for profile in PublishingVideoProfile.allCases {
            let settings = profile.settings
            XCTAssertEqual(Int(settings.videoSize.width), profile.width)
            XCTAssertEqual(Int(settings.videoSize.height), profile.height)
            XCTAssertEqual(settings.bitRate, profile.bitRate)
            XCTAssertEqual(settings.profileLevel, kVTProfileLevel_H264_High_AutoLevel as String)
            XCTAssertEqual(settings.expectedFrameRate, 30)
            XCTAssertEqual(settings.allowFrameReordering, false)
            XCTAssertEqual(settings.maxKeyFrameIntervalDuration, 2)
        }
    }
}

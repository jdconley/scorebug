import XCTest
@testable import SDKProbe

final class DualOutputConfigurationTests: XCTestCase {
    func testDefaultKeepsIndependent1080ArchiveAndLiveLimits() throws {
        let value = try DualOutputConfiguration()
        XCTAssertEqual(value.liveProfile.rawValue, "1080p30")
        XCTAssertEqual(value.archiveProfile.width, 1920)
        XCTAssertEqual(value.archiveProfile.height, 1080)
        XCTAssertEqual(value.archiveProfile.videoBitRate, 12_000_000)
        XCTAssertEqual(value.liveQueueMaxBytes, 12 * 1024 * 1024)
        XCTAssertEqual(value.archiveQueueMaxBytes, 24 * 1024 * 1024)
        XCTAssertEqual(value.changedBitRate, 2_000_000)
    }

    func testExplicit4KConfiguresBothBranchesWithBoundedRawMemory() throws {
        let value = try DualOutputConfiguration(profileID: "2160p30")
        XCTAssertEqual(value.liveProfile.width, 3840)
        XCTAssertEqual(value.liveProfile.height, 2160)
        XCTAssertEqual(value.liveProfile.bitRate, 24_000_000)
        XCTAssertEqual(value.archiveProfile.width, 3840)
        XCTAssertEqual(value.archiveProfile.height, 2160)
        XCTAssertEqual(value.archiveProfile.framesPerSecond, 30)
        XCTAssertEqual(value.archiveProfile.videoBitRate, 24_000_000)
        XCTAssertEqual(value.liveQueueMaxBytes, 48 * 1024 * 1024)
        XCTAssertEqual(value.archiveQueueMaxBytes, 96 * 1024 * 1024)
        XCTAssertEqual(value.changedBitRate, 8_000_000)
        XCTAssertNoThrow(try value.archiveProfile.validate())
    }

    func testRejectsUnspecifiedExperimentRecipes() {
        for raw in ["", "4k", "2160p60", "360p30", " 2160p30"] {
            XCTAssertThrowsError(try DualOutputConfiguration(profileID: raw), raw)
        }
    }
}

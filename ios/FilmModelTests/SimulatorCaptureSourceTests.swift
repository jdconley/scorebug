import Foundation
import ScorebugMedia
import XCTest

final class SimulatorCaptureSourceTests: XCTestCase {
    func testAbsentFlagKeepsSyntheticSource() throws {
        let root = testRecordingRoot()
        let source = try SimulatorCaptureSource.make(environment: [:], supportDirectory: root)
        XCTAssertTrue(source is FixtureCameraSource)
    }

    func testExactOptInUsesFileSourceAndMissingInputNeverFallsBack() async throws {
        let source = try SimulatorCaptureSource.make(environment: ["SCOREBUG_TEST_FILE_CAPTURE": "1"], supportDirectory: testRecordingRoot())
        XCTAssertTrue(source is FileFixtureCameraSource)
        let failed = expectation(description: "Missing staged file failed")
        do {
            _ = try await source.prepare(callbacks: .init(sample: { _ in XCTFail("Unexpected synthetic fallback") }, event: {
                XCTAssertEqual($0, .failed); failed.fulfill()
            }))
            XCTFail("Missing staged input accepted")
        } catch {}
        await fulfillment(of: [failed], timeout: 1)
        await source.stop()
    }

    func testMalformedOptInAndConflictingSyntheticControlsThrow() {
        let root = testRecordingRoot()
        for flag in ["", "0", "true", "01", " 1"] {
            XCTAssertThrowsError(try SimulatorCaptureSource.make(environment: ["SCOREBUG_TEST_FILE_CAPTURE": flag], supportDirectory: root))
        }
        for key in ["SCOREBUG_TEST_MOTION_FIXTURE", "SCOREBUG_FIXTURE_FAIL_AFTER"] {
            XCTAssertThrowsError(try SimulatorCaptureSource.make(environment: ["SCOREBUG_TEST_FILE_CAPTURE": "1", key: "1"], supportDirectory: root))
        }
    }
}

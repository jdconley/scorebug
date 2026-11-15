import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingVideoProfileChangeTests: XCTestCase {
    private let old = UUID(), new = UUID()
    private func receipt(generation: UInt64 = 7, sameSession: Bool = false,
                         oldPTS: CMTime = CMTime(value: 29, timescale: 30),
                         newPTS: CMTime = CMTime(value: 30, timescale: 30),
                         width: Int = 960, height: Int = 540, at: Double = 123) -> PublishingVideoProfileChange? {
        .init(profile: .sd540, publishingGeneration: generation, previousEncoderSessionID: old,
              encoderSessionID: sameSession ? old : new, lastOldSourcePTS: oldPTS, firstNewSourcePTS: newPTS,
              width: width, height: height, rawVideoFramesDropped: 3, acknowledgedAt: at)
    }
    func test720ReceiptRequiresActual720FormatAndDistinctIncreasingBoundary() throws {
        let profile = try XCTUnwrap(PublishingVideoProfile(rawValue: "720p30"))
        func make(width: Int = 1280, height: Int = 720, sameSession: Bool = false,
                  firstNewPTS: CMTime = CMTime(value: 30, timescale: 30)) -> PublishingVideoProfileChange? {
            .init(profile: profile, publishingGeneration: 7, previousEncoderSessionID: old,
                encoderSessionID: sameSession ? old : new, lastOldSourcePTS: CMTime(value: 29, timescale: 30),
                firstNewSourcePTS: firstNewPTS, width: width, height: height, rawVideoFramesDropped: 0, acknowledgedAt: 123)
        }
        let receipt = try XCTUnwrap(make())
        XCTAssertEqual(receipt.profile, profile)
        XCTAssertEqual(receipt.width, 1280); XCTAssertEqual(receipt.height, 720)
        XCTAssertNotEqual(receipt.previousEncoderSessionID, receipt.encoderSessionID)
        XCTAssertLessThan(CMTimeCompare(receipt.lastOldSourcePTS, receipt.firstNewSourcePTS), 0)
        XCTAssertNil(make(width: 1920, height: 1080))
        XCTAssertNil(make(width: 1920)); XCTAssertNil(make(height: 1080))
        XCTAssertNil(make(sameSession: true))
        XCTAssertNil(make(firstNewPTS: CMTime(value: 29, timescale: 30)))
        XCTAssertNil(make(firstNewPTS: CMTime(value: 28, timescale: 30)))
    }

    func testCarriesActualFormatBoundaryWithoutConflatingRequestedBitRate() throws {
        let value = try XCTUnwrap(receipt())
        XCTAssertEqual(value.profile, .sd540)
        XCTAssertEqual(value.publishingGeneration, 7)
        XCTAssertEqual(value.previousEncoderSessionID, old); XCTAssertEqual(value.encoderSessionID, new)
        XCTAssertEqual(value.lastOldSourcePTS, CMTime(value: 29, timescale: 30))
        XCTAssertEqual(value.firstNewSourcePTS, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(value.rawVideoFramesDropped, 3); XCTAssertEqual(value.acknowledgedAt, 123)
        XCTAssertEqual(value.width, 960); XCTAssertEqual(value.height, 540)
    }
    func testRejectsWrongFormatSessionGenerationTimestampOrClock() {
        XCTAssertNil(receipt(generation: 0)); XCTAssertNil(receipt(sameSession: true))
        XCTAssertNil(receipt(width: 1920)); XCTAssertNil(receipt(height: 1080))
        for pts in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 30), CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1)] {
            XCTAssertNil(receipt(oldPTS: pts)); XCTAssertNil(receipt(newPTS: pts))
        }
        XCTAssertNil(receipt(newPTS: CMTime(value: 29, timescale: 30)))
        XCTAssertNil(receipt(newPTS: .zero))
        for at in [Double.nan, .infinity, -1, 1e12 + 1] { XCTAssertNil(receipt(at: at)) }
    }
}

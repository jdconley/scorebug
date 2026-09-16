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

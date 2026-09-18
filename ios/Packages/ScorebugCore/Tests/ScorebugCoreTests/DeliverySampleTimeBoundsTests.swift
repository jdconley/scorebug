import XCTest
@testable import ScorebugCore

final class DeliverySampleTimeBoundsTests: XCTestCase {
    func testFiniteOrderedBoundedClockValues() throws {
        for (lower, upper) in [(0.0, 0.0), (0.0, 1e12), (123.0, 124.0)] {
            let timing = try XCTUnwrap(DeliveryRequestTiming(startedAt: lower, receivedAt: upper))
            let bounds = try XCTUnwrap(DeliverySampleTimeBounds(lower: lower, upper: upper))
            XCTAssertEqual(timing.startedAt, lower); XCTAssertEqual(timing.receivedAt, upper)
            XCTAssertEqual(bounds.lower, lower); XCTAssertEqual(bounds.upper, upper)
            XCTAssertEqual(timing, DeliveryRequestTiming(startedAt: lower, receivedAt: upper))
            XCTAssertEqual(bounds, DeliverySampleTimeBounds(lower: lower, upper: upper))
        }
        for (lower, upper) in [(-1.0, 1.0), (2.0, 1.0), (0.0, 1e12 + 1),
                                (Double.nan, 1.0), (0.0, Double.nan),
                                (Double.infinity, Double.infinity), (0.0, Double.infinity)] {
            XCTAssertNil(DeliveryRequestTiming(startedAt: lower, receivedAt: upper))
            XCTAssertNil(DeliverySampleTimeBounds(lower: lower, upper: upper))
        }
    }
}

import XCTest
@testable import ScorebugMedia

final class CaptureSourceDiagnosticsTests: XCTestCase {
    func testDropReasonsRemainDistinctAndDoNotChangeDeliveredCounts() {
        var counters = CaptureSourceDiagnostics()
        counters.delivered(video: true); counters.delivered(video: false)
        counters.dropped(.frameWasLate); counters.dropped(.outOfBuffers)
        counters.dropped(.discontinuity)
        for _ in 0..<1000 { counters.dropped(.unknown) }
        XCTAssertEqual(counters.videoFrames, 1); XCTAssertEqual(counters.audioBuffers, 1)
        XCTAssertEqual(counters.frameWasLate, 1); XCTAssertEqual(counters.outOfBuffers, 1)
        XCTAssertEqual(counters.discontinuity, 1); XCTAssertEqual(counters.unknownDrops, 1000)
    }
}

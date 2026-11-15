import Foundation
import XCTest
@testable import ScorebugStreaming

final class SRTPublishingHealthTests: XCTestCase {
    func testHealthRequiresEveryExistingPublishingBoundary() {
        let healthy = SRTPublisher.HealthSnapshot(connected: true, streamPublishing: true,
            muxerError: nil, streamError: nil, transportError: nil)
        XCTAssertTrue(healthy.isPublishing)
        for failed in [
            SRTPublisher.HealthSnapshot(connected: false, streamPublishing: true, muxerError: nil, streamError: nil, transportError: nil),
            .init(connected: true, streamPublishing: false, muxerError: nil, streamError: nil, transportError: nil),
            .init(connected: true, streamPublishing: true, muxerError: .invalidTimestamp, streamError: nil, transportError: nil),
            .init(connected: true, streamPublishing: true, muxerError: nil, streamError: .codecFailed(status: -1), transportError: nil),
            .init(connected: true, streamPublishing: true, muxerError: nil, streamError: nil, transportError: .transportWriteFailed)
        ] { XCTAssertFalse(failed.isPublishing) }
    }

    func testObserverSeesTheSameUnconnectedHealthThatReturnsFalse() async {
        let evidence = HealthEvidence()
        let publisher = SRTPublisher(healthObserver: { evidence.record($0) })
        let result = await publisher.isPublishing()
        XCTAssertFalse(result)
        let values = evidence.snapshot
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.connected, false)
        XCTAssertEqual(values.first?.streamPublishing, false)
        XCTAssertEqual(values.first?.isPublishing, result)
        XCTAssertNil(values.first?.streamError)
        await publisher.stop()
    }
}
private final class HealthEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SRTPublisher.HealthSnapshot] = []
    func record(_ value: SRTPublisher.HealthSnapshot) { lock.withLock { values.append(value) } }
    var snapshot: [SRTPublisher.HealthSnapshot] { lock.withLock { values } }
}

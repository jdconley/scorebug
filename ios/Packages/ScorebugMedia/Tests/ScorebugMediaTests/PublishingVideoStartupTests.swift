import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingVideoStartupTests: XCTestCase {
    private func receipt() -> PublishingVideoStartup {
        .init(profile: .low240, width: 426, height: 240, publishingGeneration: 1,
            encoderSessionID: UUID(), firstSourcePTS: CMTime(value: 1, timescale: 30),
            submittedAt: 1, completedAt: 1.1, observedAt: 1.2)!
    }
    func testSessionExposesOnlyItsCurrentPublishingStartupAndNeverAfterStop() async throws {
        let proof = receipt(), publisher = StartupPublisher(proof: receipt())
        let session = try PublishingSession(publisher: publisher)
        XCTAssertNil(session.videoStartup)
        try await session.start()
        XCTAssertEqual(session.videoStartup, publisher.videoStartup)
        XCTAssertNotEqual(session.videoStartup?.encoderSessionID, proof.encoderSessionID)
        await session.stop()
        XCTAssertNil(session.videoStartup)
    }
    func testReceiptRejectsWrongProfileClockGenerationAndSourceCoordinates() {
        for mode in 0..<7 {
            let value = PublishingVideoStartup(profile: .low240, width: mode == 0 ? 1920 : 426,
                height: mode == 1 ? 1080 : 240, publishingGeneration: mode == 2 ? 0 : 1,
                encoderSessionID: UUID(), firstSourcePTS: mode == 3 ? .invalid : mode == 4 ? CMTime(value: -1, timescale: 30) : .zero,
                submittedAt: 1, completedAt: mode == 5 ? 0 : 1.1, observedAt: mode == 6 ? .nan : 1.2)
            XCTAssertNil(value)
        }
    }
}
private actor StartupPublisher: MediaPublisher {
    nonisolated let videoStartup: PublishingVideoStartup?
    private var running = false
    init(proof: PublishingVideoStartup) { videoStartup = proof }
    func start() { running = true }
    func append(_ sample: CapturedMediaSample) {}
    var isPublishing: Bool { running }
    func stop() { running = false }
}

import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingGuardedCapabilityTests: XCTestCase {
    func testGuardedProtocolDefaultsNeverInvokeLegacyMethods() async throws {
        let concrete = LegacyOnlyPublisher()
        let publisher: any MediaPublisher = concrete
        let selected = PublishingBitRateChange(publishingGeneration: 1,
            configuration: .init(id: UUID(), encoderSessionID: UUID(), bitRate: 600_000)!,
            acceptedAt: 10, lastSubmittedSourcePTS: nil)!
        do { _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(selected)); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .unavailable) }
        do { _ = try await publisher.setVideoProfile(.sd540, expecting: selected); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .unavailable) }
        let calls = await concrete.legacyCalls
        XCTAssertEqual(calls, 0)
    }
}
private actor LegacyOnlyPublisher: MediaPublisher {
    var legacyCalls = 0
    var isPublishing: Bool { true }
    func start() {}
    func stop() {}
    func append(_ sample: CapturedMediaSample) {}
    func setVideoBitRate(_ rate: Int) throws -> PublishingBitRateChange {
        legacyCalls += 1
        throw PublishingSessionError.bitRateUpdateFailed
    }
    func setVideoProfile(_ profile: PublishingVideoProfile) throws -> PublishingVideoProfileChange {
        legacyCalls += 1
        throw PublishingSessionError.profileUpdateFailed
    }
}

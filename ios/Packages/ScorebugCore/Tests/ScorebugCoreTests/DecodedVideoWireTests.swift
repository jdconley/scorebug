import Foundation
import ScorebugCore
import XCTest

final class DecodedVideoWireTests: XCTestCase {
    func testClockConventionRoundTripsKnownUnknownAndLegacyWithoutLosingSignedPTS() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoded-video-clock-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: data)
        XCTAssertEqual(Set(fixture.keys), ["known", "legacy", "unknown"])
        for response in fixture.values {
            XCTAssertEqual(response.status.observation?.decodedVideo?.completed?.firstPTS, -126_000)
            XCTAssertEqual(response.status.observation?.decodedVideo?.completed?.lastPTS, 321_000)
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testOnlyExactKnownClockCanEstablishTransportConvention() throws {
        for label in [nil, "", "future-clock-v2", "MPEGTS-PTS-90K-V1", "mpegts-pts-90k-v1 ", "mpegts-pts-90k-v1"] as [String?] {
            let snapshot = DecodedVideoSnapshot(completed: nil, invalidReason: nil, ended: false, clock: label)
            XCTAssertEqual(snapshot.usesTransportClock, label == "mpegts-pts-90k-v1")
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(DecodedVideoSnapshot.self, from: data)
            XCTAssertEqual(decoded, snapshot)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(object["completed"] is NSNull)
            XCTAssertTrue(object["invalidReason"] is NSNull)
            XCTAssertEqual(object["clock"] as? String, label)
            if label == nil { XCTAssertNil(object["clock"]) }
        }
        let legacy = DecodedVideoSnapshot(completed: nil, invalidReason: nil, ended: false)
        XCTAssertNil(legacy.clock)
        XCTAssertFalse(legacy.usesTransportClock)
    }

    func testSharedWorkerReportAgeGoldenRoundTrip() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-report-age-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: data)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testSharedDecoderEvidenceRoundTripsLargePTSEmptyWindowsInvalidityAndLegacyOmission() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoded-video-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: data)
        XCTAssertEqual(Set(fixture.keys), ["legacy", "current", "stalled", "invalid"])
        let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary
        XCTAssertEqual(actual, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}

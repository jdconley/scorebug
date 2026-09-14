import Foundation
import ScorebugCore
import XCTest

final class DecodedVideoWireTests: XCTestCase {
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

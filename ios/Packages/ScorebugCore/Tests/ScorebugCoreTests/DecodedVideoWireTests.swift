import Foundation
import ScorebugCore
import XCTest

final class DecodedVideoWireTests: XCTestCase {
    func testSharedDecoderEvidenceRoundTripsLargePTSEmptyWindowsInvalidityAndLegacyOmission() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoded-video-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: data)
        XCTAssertEqual(Set(fixture.keys), ["legacy", "current", "stalled", "invalid"])
        let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary
        XCTAssertEqual(actual, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}

import XCTest
@testable import SDKProbe

final class EncoderHardwareSelectionEvidenceTests: XCTestCase {
    func testExportPreservesAllDiagnosticOutcomesWithoutGrantingAuthority() throws {
        let cases: [(SRTPublisher.EncoderHardwareSelection, String, Int32?)] = [
            (.hardware, "hardware", nil), (.software, "software", nil),
            (.readFailed(status: -123), "readFailed", -123),
            (.missingValue, "missingValue", nil), (.invalidType, "invalidType", nil),
            (.notQueriedOnPlatform, "notQueriedOnPlatform", nil),
        ]
        for (selection, state, status) in cases {
            let evidence = try XCTUnwrap(encoderHardwareSelectionEvidence(selection))
            let data = try JSONSerialization.data(withJSONObject: evidence)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["state", "nativeStatus"])
            XCTAssertEqual(object["state"] as? String, state)
            if let status { XCTAssertEqual((object["nativeStatus"] as? NSNumber)?.int32Value, status) }
            else { XCTAssertTrue(object["nativeStatus"] is NSNull) }
            XCTAssertLessThan(data.count, 128)
        }
    }
    func testDisabledEvidenceIsMissingRatherThanSoftware() {
        XCTAssertNil(encoderHardwareSelectionEvidence(nil))
    }
}

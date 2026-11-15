import Foundation
import XCTest
@testable import ScorebugCore

final class WatchCompanionTests: XCTestCase {
    func testRoundTripsOnlyTypedIdentityAndPairingSetup() throws {
        let notice = WatchCompanionNotice(deviceId: WatchPairingClientTests.deviceId, phase: .unpaired)
        do {
            XCTAssertEqual(try WatchCompanionCodec.decodeNotice(WatchCompanionCodec.encodeNotice(notice)), notice)
            let envelope = WatchPairingEnvelope(endpoint: "https://example.com/control", offer: WatchPairingClientTests.offer)
            XCTAssertEqual(try WatchCompanionCodec.decodeEnvelope(WatchCompanionCodec.encodeEnvelope(envelope)), envelope)
        } catch { XCTFail("Typed companion setup should round trip: \(error)") }
    }

    func testRejectsOversizeWrongVersionUnexpectedFieldsAndInconsistentNotice() throws {
        let notice = WatchCompanionNotice(deviceId: WatchPairingClientTests.deviceId, phase: .unpaired)
        let original = try JSONEncoder().encode(notice)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        for patch in [["version": 2], ["installationToken": "do-not-relay"], ["phase": "paired"], ["deviceId": "not-a-uuid"]] as [[String: Any]] {
            let bad = object.merging(patch) { _, new in new }
            XCTAssertThrowsError(try WatchCompanionCodec.decodeNotice(JSONSerialization.data(withJSONObject: bad)))
        }
        object["junk"] = String(repeating: "x", count: 8192)
        XCTAssertThrowsError(try WatchCompanionCodec.decodeNotice(JSONSerialization.data(withJSONObject: object)))
        let envelope = WatchPairingEnvelope(endpoint: "https://example.com", offer: WatchPairingClientTests.offer)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as! [String: Any]
        for patch in [["endpoint": "http://public.example"], ["recoveryKey": "secret"], ["version": 2]] as [[String: Any]] {
            XCTAssertThrowsError(try WatchCompanionCodec.decodeEnvelope(JSONSerialization.data(withJSONObject: value.merging(patch) { _, new in new })))
        }
        var nested = value
        var offer = nested["offer"] as! [String: Any]
        offer["installationToken"] = "forbidden"; nested["offer"] = offer
        XCTAssertThrowsError(try WatchCompanionCodec.decodeEnvelope(JSONSerialization.data(withJSONObject: nested)))
    }
}

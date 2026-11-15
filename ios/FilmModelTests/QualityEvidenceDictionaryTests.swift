import Foundation
import XCTest

@MainActor final class QualityEvidenceDictionaryTests: XCTestCase {
    private func row(_ start: Int = 0, count: Int = 2) -> [String: Any] {
        ["kind": "localPressure", "evidence": [
            "thermal": ["isClosed": false, "samples": (start..<(start + count)).map { ["sampledAt": $0, "state": 0] }],
            "transport": ["samples": [["sampledAt": 0, "sentBytes": "42"]]],
            "queue": ["coveredThrough": 10, "states": [["at": 0, "itemFraction": 0, "byteFraction": 0, "phase": "open"]]]]]
    }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    func testMutableFoundationScalarCannotRewriteCapturedEvidence() throws {
        let store = QualityEvidenceDictionary(), mutable = NSMutableString(string: "original")
        var input = row()
        var evidence = try XCTUnwrap(input["evidence"] as? [String: Any])
        evidence["transport"] = ["samples": [["sentBytes": mutable]]]
        input["evidence"] = evidence
        XCTAssertNotNil(store.encode(input))
        let checkpoint = store.dictionary, before = try data(checkpoint)
        mutable.setString(String(repeating: "changed", count: 1000))
        XCTAssertEqual(try data(checkpoint), before)
        XCTAssertEqual(try data(store.dictionary), before)
    }

    func testNumericInterningMatchesJSONNumberSemanticsWithoutMixingBooleanOrString() throws {
        let store = QualityEvidenceDictionary()
        var input = row(), evidence = try XCTUnwrap(input["evidence"] as? [String: Any])
        evidence["thermal"] = ["samples": [["value": -0.0], ["value": 0], ["value": 1],
            ["value": 1.0], ["value": true], ["value": "1"], ["value": "18446744073709551615"], ["value": NSNull()]]]
        input["evidence"] = evidence
        XCTAssertNotNil(store.encode(input))
        XCTAssertEqual((store.dictionary["thermal"] as? [[String: Any]])?.count, 6)
    }

    func testRepeatedHistoriesAreReplacedByExactStableRanges() throws {
        let store = QualityEvidenceDictionary()
        let first = try XCTUnwrap(store.encode(row()))
        let captured = store.dictionary
        let second = try XCTUnwrap(store.encode(row(1)))
        let firstHistory = try XCTUnwrap((first["evidence"] as? [String: Any])?["thermal"] as? [String: Any])
        let secondHistory = try XCTUnwrap((second["evidence"] as? [String: Any])?["thermal"] as? [String: Any])
        XCTAssertNil(firstHistory["samples"])
        XCTAssertEqual(firstHistory["sampleCount"] as? Int, 2)
        XCTAssertEqual(firstHistory["sampleRanges"] as? [[Int]], [[0, 2]])
        XCTAssertEqual(secondHistory["sampleRanges"] as? [[Int]], [[1, 2]])
        XCTAssertEqual((captured["thermal"] as? [[String: Any]])?.count, 2, "Old checkpoints remain immutable")
        XCTAssertEqual((store.dictionary["thermal"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((store.dictionary["transport"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(store.isOverflow)
    }

    func testBoundedFailureRollsBackPartialRowAndRemainsFailClosed() throws {
        let store = QualityEvidenceDictionary(maximumBytes: 1500)
        XCTAssertNotNil(store.encode(row()))
        let before = try data(store.dictionary)
        XCTAssertNil(store.encode(row(10, count: 64)))
        XCTAssertTrue(store.isOverflow)
        XCTAssertEqual(try data(store.dictionary), before)
        XCTAssertNil(store.encode(["kind": "stopped"]))
    }

    func testFullEventBudgetKeepsRepeatedHistoriesBelowFileLimit() throws {
        let store = QualityEvidenceDictionary()
        var rows: [[String: Any]] = []
        for _ in 0..<512 { rows.append(try XCTUnwrap(store.encode(row(count: 64)))) }
        let encoded = try data(["events": rows, "evidenceDictionary": store.dictionary])
        XCTAssertLessThan(encoded.count, 512 * 1024)
        XCTAssertEqual((store.dictionary["thermal"] as? [[String: Any]])?.count, 64)
        XCTAssertFalse(store.isOverflow)
    }

    func testInvalidOrAlreadyEncodedHistoryCannotBeSilentlyOmitted() throws {
        for input: [String: Any] in [
            ["kind": "localPressure", "evidence": ["thermal": ["samples": [], "sampleRanges": []]]],
            ["kind": "localPressure", "evidence": ["thermal": ["samples": [["nested": ["value": 1]]]]]],
            row(count: 65),
        ] {
            let store = QualityEvidenceDictionary()
            XCTAssertNil(store.encode(input))
            XCTAssertTrue(store.isOverflow)
        }
    }
}

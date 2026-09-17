import Foundation
import XCTest
@testable import ScorebugCore

final class DecoderDeliveryPacketTests: XCTestCase {
    static let scope = "11111111-1111-4111-8111-111111111111"
    static func packet(_ n: Int64 = 3, after: Int64? = nil) throws -> DecoderDeliveryPacket {
        let base = max(0, n - 256), start = after ?? base
        let rows = (start..<n).map { "[\($0 * 3000),\(($0 + 1) * 40)]" }.joined(separator: ",")
        return try JSONDecoder().decode(DecoderDeliveryPacket.self, from: Data("""
        {"formatVersion":1,"scopeID":"\(scope)","sampledAtMs":\(n * 40 + 10),"coverageAtMs":\(base * 40),"afterOrdinal":\(start),"lastOrdinal":\(n),"arrivals":[\(rows)],"invalidReason":null,"ended":false}
        """.utf8))
    }
    func testActualFFmpegHTTPReplayMatchesEveryRetainedTuple() throws {
        struct Replay: Decodable { let sourceRows: [DecoderDeliveryPacket.Arrival]; let packets: [DecoderDeliveryPacket] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder-delivery-replay-v1", withExtension: "json", subdirectory: "Fixtures"))
        let replay = try JSONDecoder().decode(Replay.self, from: Data(contentsOf: url))
        XCTAssertEqual(replay.packets.count, 161); XCTAssertEqual(replay.sourceRows.count, 478)
        var history = DecoderDeliveryHistory()
        for packet in replay.packets {
            try history.accept(packet)
            let full = try XCTUnwrap(history.packet)
            guard full.lastOrdinal <= Int64(replay.sourceRows.count) else { return XCTFail("Replay exceeds captured source history") }
            XCTAssertEqual(full.arrivals, Array(replay.sourceRows[Int(full.afterOrdinal)..<Int(full.lastOrdinal)]))
            XCTAssertEqual(full.coverageAtMs, full.afterOrdinal == 0 ? 0 : replay.sourceRows[Int(full.afterOrdinal - 1)].atMs)
        }
        XCTAssertEqual(history.packet?.lastOrdinal, 478)
    }
    func testFullDeltaOverlapAndRetirement() throws {
        var h = DecoderDeliveryHistory()
        try h.accept(Self.packet())
        for n: Int64 in [6, 9, 260, 300, 600] {
            let after = max(n - 256, try XCTUnwrap(h.packet).lastOrdinal)
            let p = try Self.packet(n, after: after)
            try h.accept(p); try h.accept(p)
            XCTAssertEqual(h.packet, try Self.packet(n))
        }
        let s = try XCTUnwrap(h.snapshot)
        XCTAssertEqual(s.arrivals.count, 256); XCTAssertEqual(s.arrivals.first?.ordinal, 345)
        XCTAssertEqual(s.arrivals.last?.ageMs, 10)
        XCTAssertEqual(s.coverageAgeMs, 10250)
    }
    func testPartialHistoryNeedsBaseAndFailedUpdateDoesNotMutateHistory() throws {
        var h = DecoderDeliveryHistory()
        XCTAssertThrowsError(try h.accept(Self.packet(6, after: 3))); XCTAssertNil(h.packet)
        try h.accept(Self.packet(260)); let before = h.packet
        XCTAssertThrowsError(try h.accept(Self.packet(270, after: 265))); XCTAssertEqual(h.packet, before)
    }
    func testRejectsOverlapClockCoverageScopeAndTerminalRegression() throws {
        let clean = try Self.packet(260)
        for damage in 0..<6 {
            var h = DecoderDeliveryHistory(); try h.accept(clean); var next = clean
            switch damage {
            case 0: next.arrivals[0].pts += 1
            case 1: next.arrivals[0].atMs += 1
            case 2: next.sampledAtMs -= 1
            case 3: next.coverageAtMs += 1
            case 4: next.scopeID = "22222222-2222-4222-8222-222222222222"
            default: next.afterOrdinal += 1
            }
            XCTAssertThrowsError(try h.accept(next)); XCTAssertEqual(h.packet, clean)
        }
        for terminal in ["ended", "clock"] {
            var old = clean; if terminal == "ended" { old.ended = true } else { old.invalidReason = "clock" }
            var h = DecoderDeliveryHistory(); try h.accept(old)
            XCTAssertThrowsError(try h.accept(Self.packet(270)))
        }
    }
    func testStrictBoundedDecodingAndOptionalExplicitNullRoundTrip() throws {
        let clean = try Self.packet()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(clean)) as? [String: Any])
        XCTAssertTrue(object["invalidReason"] is NSNull)
        for field in ["extra", "afterOrdinal", "lastOrdinal", "sampledAtMs", "arrivals", "invalidReason"] {
            var bad = object
            switch field {
            case "extra": bad[field] = true
            case "afterOrdinal": bad[field] = -1
            case "lastOrdinal": bad[field] = 9_007_199_254_740_992 as Int64
            case "sampledAtMs": bad[field] = -1
            case "arrivals": bad[field] = [[0, 40, 50]]
            default: bad.removeValue(forKey: field)
            }
            XCTAssertThrowsError(try JSONDecoder().decode(DecoderDeliveryPacket.self, from: JSONSerialization.data(withJSONObject: bad)))
        }
        var bad = object; bad["lastOrdinal"] = 257; bad["arrivals"] = Array(repeating: [0, 40], count: 257)
        XCTAssertThrowsError(try JSONDecoder().decode(DecoderDeliveryPacket.self, from: JSONSerialization.data(withJSONObject: bad)))
    }
}

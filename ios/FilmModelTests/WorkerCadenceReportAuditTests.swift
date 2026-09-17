import Foundation
import ScorebugCore
import XCTest

final class WorkerCadenceReportAuditTests: XCTestCase {
    func testClosedBoundedAuditPreservesMissingEvidenceAndRejectsOverflow() throws {
        var audit = WorkerCadenceReportAudit()
        let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data("""
        {"status":{"gameId":"match","generation":1,"workerId":null,"state":"unknown","observation":null,"observedAt":null,"expiresAt":null},"serverTime":"2040-01-01T00:00:00Z"}
        """.utf8))
        let instant = ContinuousClock.now, attempt = UUID()
        for _ in 0..<2049 {
            audit.record(response: response, expectedAttempt: attempt, helper: nil,
                receivedAt: instant, requestDuration: .milliseconds(20), receivedUptime: 100,
                instant: instant + .milliseconds(10), evaluatedUptime: 100.01)
        }
        audit.close()
        audit.record(response: response, expectedAttempt: attempt, helper: nil,
            receivedAt: instant, requestDuration: .zero, receivedUptime: 100,
            instant: instant, evaluatedUptime: 100)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        XCTAssertEqual(value["closed"] as? Bool, true); XCTAssertEqual(value["overflow"] as? Bool, true)
        let rows = try XCTUnwrap(value["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2048)
        XCTAssertEqual(rows[0]["requestSeconds"] as? Double, 0.02)
        XCTAssertEqual(rows[0]["residenceSeconds"] as? Double, 0.01)
        XCTAssertTrue(rows[0]["sampleAgeSeconds"] is NSNull)
        XCTAssertEqual(rows[0]["expectedAttempt"] as? String, attempt.uuidString.lowercased())
    }
}

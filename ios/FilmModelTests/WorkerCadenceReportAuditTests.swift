import Foundation
import ScorebugCore
import XCTest

final class WorkerCadenceReportAuditTests: XCTestCase {
    private func response() throws -> WorkerMediaStatusResponse {
        try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data("""
        {"status":{"gameId":"match","generation":1,"workerId":null,"state":"unknown","observation":null,"observedAt":null,"expiresAt":null},"serverTime":"2040-01-01T00:00:00Z"}
        """.utf8))
    }

    func testCadenceReceiptIDIdentifiesExactHelperRatherThanEquivalentResponse() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/receiver-probe-status-v1.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var status = try XCTUnwrap(raw["status"] as? [String: Any])
        var observation = try XCTUnwrap(status["observation"] as? [String: Any])
        observation["decodedVideo"] = ["clock": "mpegts-pts-90k-v1", "completed": NSNull(), "invalidReason": NSNull(), "ended": false]
        observation["decoderCadence"] = ["formatVersion": 1, "scopeID": "11111111-1111-4111-8111-111111111111",
            "oneSecond": NSNull(), "twoSeconds": NSNull(),
            "progress": ["lastFreshPTS": 180000, "ageMs": 50, "stalled": false], "invalidReason": NSNull(), "ended": false]
        status["observation"] = observation; status["decoderCadenceAgeUpperBoundMs"] = 50; raw["status"] = status
        let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONSerialization.data(withJSONObject: raw))
        let attempt = try XCTUnwrap(UUID(uuidString: response.status.publication!.publishingAttemptId))
        let instant = ContinuousClock.now
        let helper = try XCTUnwrap(WorkerDecoderCadenceFreshness(response: response,
            expectedPublishingAttemptID: attempt, receivedAt: instant, requestDuration: .milliseconds(20)))
        let other = try XCTUnwrap(WorkerDecoderCadenceFreshness(response: response,
            expectedPublishingAttemptID: attempt, receivedAt: instant, requestDuration: .milliseconds(20)))
        XCTAssertNotEqual(helper.receiptID, other.receiptID)
        var audit = WorkerCadenceReportAudit()
        for value in [helper, other] {
            audit.record(response: response, expectedAttempt: attempt, helper: value,
                receivedAt: instant, requestDuration: .milliseconds(20), receivedUptime: 100,
                instant: instant + .milliseconds(10), evaluatedUptime: 100.01)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["cadenceReceiptID"] as? String },
            [helper.receiptID.uuidString.lowercased(), other.receiptID.uuidString.lowercased()])
        XCTAssertEqual(rows[0]["sampleAgeSeconds"] as? Double, 0.08)
    }

    func testStageTimingSeparatesMaintenanceHTTPNativeReadAndProcessing() throws {
        var audit = WorkerCadenceReportAudit()
        let instant = ContinuousClock.now
        audit.record(response: try response(), expectedAttempt: UUID(), helper: nil,
            receivedAt: instant, requestDuration: .milliseconds(20), receivedUptime: 100,
            instant: instant + .milliseconds(10), evaluatedUptime: 100.01,
            timing: .init(controlStartedUptime: 99.5, statusRequestStartedUptime: 99.98,
                responseReceivedUptime: 100, probeReadStartedUptime: 100.001,
                probeReadFinishedUptime: 100.008, auditEvaluatedUptime: 100.01))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        XCTAssertEqual(value["invalid"] as? Bool, false)
        let rows = try XCTUnwrap(value["rows"] as? [[String: Any]])
        let timing = try XCTUnwrap(rows.first?["timing"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(timing["maintenanceSeconds"]), 0.48, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(timing["statusHTTPSeconds"]), 0.02, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(timing["responseProcessingSeconds"]), 0.001, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(timing["nativeProbeSeconds"]), 0.007, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(timing["postProbeProcessingSeconds"]), 0.002, accuracy: 0.000001)
        XCTAssertEqual(rows.first?["requestSeconds"] as? Double, 0.02)
        XCTAssertEqual(rows.first?["residenceSeconds"] as? Double, 0.01)
    }

    func testPresentInvalidTimingInvalidatesAuditWithoutAppendingMisboundRow() throws {
        let baseline: [Double] = [99.5, 99.98, 100, 100.001, 100.008, 100.01]
        var invalid: [[Double]] = []
        for index in baseline.indices {
            for bad in [Double.nan, Double.infinity, -1] {
                var values = baseline; values[index] = bad; invalid.append(values)
            }
            if index > 0 {
                var values = baseline; values.swapAt(index - 1, index); invalid.append(values)
            }
        }
        var wrongReceive = baseline; wrongReceive[2] = 99.999; invalid.append(wrongReceive)
        var wrongEvaluation = baseline; wrongEvaluation[5] = 100.02; invalid.append(wrongEvaluation)
        for values in invalid {
            var audit = WorkerCadenceReportAudit()
            let instant = ContinuousClock.now
            audit.record(response: try response(), expectedAttempt: UUID(), helper: nil,
                receivedAt: instant, requestDuration: .milliseconds(20), receivedUptime: 100,
                instant: instant + .milliseconds(10), evaluatedUptime: 100.01,
                timing: .init(controlStartedUptime: values[0], statusRequestStartedUptime: values[1],
                    responseReceivedUptime: values[2], probeReadStartedUptime: values[3],
                    probeReadFinishedUptime: values[4], auditEvaluatedUptime: values[5]))
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
            XCTAssertEqual(value["invalid"] as? Bool, true, "\(values)")
            XCTAssertEqual((value["rows"] as? [Any])?.count, 0)
        }
    }
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
        XCTAssertTrue(rows[0]["cadenceReceiptID"] is NSNull)
        XCTAssertEqual(rows[0]["expectedAttempt"] as? String, attempt.uuidString.lowercased())
        XCTAssertNil(rows[0]["timing"], "Legacy rows can omit optional stage timing")
    }
}

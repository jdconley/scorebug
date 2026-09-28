#if DEBUG
import Foundation
import ScorebugCore
import XCTest

final class PublishingAppliedTransitionAuditTests: XCTestCase {
    private let attempt = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testClosedAuditRetainsDetachedPrefixAndDeclaredScope() throws {
        var audit = PublishingAppliedTransitionAudit(attemptID: attempt, timingProfile: .broadcastReliability3000)
        var row = ["revision": "1", "cause": "transport"]
        audit.append(row); row["cause"] = "later mutable cause"
        audit.append(["revision": "2", "cause": "queue"])
        let closed = try audit.close()
        audit.append(["revision": "3"])
        XCTAssertEqual(try audit.close(), closed)
        let value = try object(closed)
        XCTAssertEqual(value["formatVersion"] as? Int, 1)
        XCTAssertEqual(value["scope"] as? String, "successful applications only")
        XCTAssertEqual(value["attemptID"] as? String, attempt.uuidString.lowercased())
        XCTAssertEqual(value["maximumRecords"] as? Int, 16)
        XCTAssertEqual(value["maximumRecordBytes"] as? Int, 8192)
        XCTAssertEqual(value["closed"] as? Bool, true)
        XCTAssertEqual(value["overflow"] as? Bool, false)
        let timing = try XCTUnwrap(value["timingContract"] as? [String: Any])
        XCTAssertEqual(timing["scope"] as? String, "ordinary-successful-applications")
        XCTAssertEqual(timing["profileId"] as? String, "broadcast-reliability3000-v1")
        XCTAssertEqual(timing["decoderBudgetMs"] as? Int, 3000)
        XCTAssertEqual(value["records"] as? [[String: String]], [["revision": "1", "cause": "transport"], ["revision": "2", "cause": "queue"]])
    }
    func testSeventeenthRecordFlagsOverflowWithoutEvictingPrefix() throws {
        var audit = PublishingAppliedTransitionAudit(attemptID: attempt, timingProfile: .strict1500)
        for revision in 1...18 { audit.append(["revision": String(revision)]) }
        let value = try object(audit.close())
        XCTAssertEqual(value["overflow"] as? Bool, true)
        XCTAssertEqual(value["records"] as? [[String: String]], (1...16).map { ["revision": String($0)] })
    }
    func testEncodedByteLimitAcceptsBoundaryAndRejectsOversizeWithoutSkippingHole() throws {
        var audit = PublishingAppliedTransitionAudit(attemptID: attempt, timingProfile: .strict1500)
        // {"x":""} uses eight encoded bytes; the boundary is encoded UTF-8,
        // including escaping, rather than Swift character count.
        let boundary = ["x": String(repeating: "a", count: 8184)]
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: boundary).count, 8192)
        audit.append(boundary)
        audit.append(["x": String(repeating: "\\", count: 4093)])
        audit.append(["revision": "must not follow omitted record"])
        let value = try object(audit.close())
        XCTAssertEqual(value["overflow"] as? Bool, true)
        XCTAssertEqual(value["records"] as? [[String: String]], [boundary])
    }
    func testEveryProfileHasExplicitOrdinaryTimingContract() throws {
        for profile in StreamingTimingProfile.allCases {
            var audit = PublishingAppliedTransitionAudit(attemptID: attempt, timingProfile: profile)
            let timing = try XCTUnwrap(try object(audit.close())["timingContract"] as? [String: Any])
            XCTAssertEqual(timing.count, 8)
            XCTAssertEqual(timing["formatVersion"] as? Int, 1)
            XCTAssertEqual(timing["scope"] as? String, "ordinary-successful-applications")
            XCTAssertEqual(timing["profileId"] as? String, profile.rawValue)
            XCTAssertEqual(timing["decoderBudgetMs"] as? Int, profile.decoderBudgetMs)
            XCTAssertEqual(timing["maximumCaptureWindowEvaluationAgeMs"] as? Int, profile.maximumCaptureWindowEvaluationAgeMs)
            XCTAssertEqual(timing["maximumCompletedDecoderWindowReportAgeMs"] as? Int, 2000)
            XCTAssertEqual(timing["maximumCadenceDeliveryReportAgeMs"] as? Int, profile.maximumCadenceDeliveryReportAgeMs)
            XCTAssertEqual(timing["decoderStallThresholdMs"] as? Int, 1000)
        }
    }
    func testEmptyClosedAuditDoesNotInventApplications() throws {
        var audit = PublishingAppliedTransitionAudit(attemptID: attempt, timingProfile: .strict1500)
        let value = try object(audit.close())
        XCTAssertEqual(value["closed"] as? Bool, true)
        XCTAssertEqual(value["overflow"] as? Bool, false)
        XCTAssertEqual(value["records"] as? [[String: String]], [])
    }
}
#endif

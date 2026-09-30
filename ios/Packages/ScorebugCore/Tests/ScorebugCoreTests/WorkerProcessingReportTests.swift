import Foundation
import ScorebugCore
import XCTest
final class WorkerProcessingReportTests: XCTestCase {
    private func fixture() throws -> [String: WorkerMediaStatusResponse] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-processing-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: Data(contentsOf: url))
    }
    func testSharedWireExamplesRoundTripAndValidatePendingCompleteUnknownAndWideCoordinates() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-processing-v1", withExtension: "json", subdirectory: "Fixtures"))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        let responses = try fixture()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(responses)) as? NSDictionary, wire)
        for (name, response) in responses {
            let evidence = try XCTUnwrap(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .milliseconds(100)), name)
            XCTAssertEqual(evidence.report, response.status.observation?.processing)
        }
    }
    func testMalformedOptionalMetadataDoesNotBreakStatus() throws {
        let original = try XCTUnwrap(fixture()["complete"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for bad: Any in [NSNull(), "bad", [1], ["scopeID": "incomplete"]] {
            var status = object["status"] as! [String: Any], observation = status["observation"] as! [String: Any]
            observation["processing"] = bad; status["observation"] = observation; object["status"] = status
            let response = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(response.status.state, .producingOutput)
            XCTAssertNil(response.status.observation?.processing)
        }
    }
    func testRejectsWrongWindowScopeCountsAndDurations() throws {
        let original = try XCTUnwrap(fixture()["complete"])
        let mutations: [(inout WorkerProcessingReport) -> Void] = [
            { $0.scopeID = "bad" }, { $0.encoder = "future" }, { $0.previousSequence = 0 }, { $0.sequence += 1 },
            { $0.firstPTS += 1 }, { $0.interval.sourceEndInclusive += 1 }, { $0.interval.sourceStartExclusive = $0.firstPTS },
            { $0.interval.decodedFrames += 1 }, { $0.interval.submittedFrames = -1 }, { $0.interval.completedFrames = Int64.max },
            { $0.interval.pendingFrames = 1 }, { $0.interval.omittedBeforeEncoderFrames = 1 },
            { $0.interval.filterDuration = .init(meanMs: 3, maximumMs: 2) }, { $0.interval.processingDuration = .init(meanMs: .nan, maximumMs: 1) },
            { $0.interval.processingDuration = .init(meanMs: 1, maximumMs: .infinity) },
            { $0.firstPTS = Int64.min }, { $0.interval.sourceStartExclusive = -9_007_199_254_740_992 },
        ]
        for mutation in mutations {
            var response = original; var report = try XCTUnwrap(response.status.observation?.processing)
            mutation(&report); response.status.observation?.processing = report
            XCTAssertNil(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .zero))
        }
    }
    func testOptionalCapAttributionRoundTripsAndRejectsContradictoryCounts() throws {
        var response = try XCTUnwrap(fixture()["complete"])
        response.status.observation?.processing?.interval.submittedFrames = 149
        response.status.observation?.processing?.interval.completedFrames = 149
        response.status.observation?.processing?.interval.omittedBeforeEncoderFrames = 1
        response.status.observation?.processing?.interval.intentionalFrameCapOmissions = 1
        let decoded = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.status.observation?.processing?.interval.intentionalFrameCapOmissions, 1)
        XCTAssertNotNil(WorkerProcessingEvidence(response: decoded, receivedAt: .now, requestDuration: .zero))
        for bad: Int64 in [-1, 2, Int64.max] {
            response.status.observation?.processing?.interval.intentionalFrameCapOmissions = bad
            XCTAssertNil(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .zero))
        }
    }
    func testRequiresPublicationClockAndProvenUnexpiredAge() throws {
        let original = try XCTUnwrap(fixture()["complete"])
        let mutations: [(inout WorkerMediaStatusResponse) -> Void] = [
            { $0.status.publication = nil }, { $0.status.workerEpoch = nil }, { $0.status.decodedVideoAgeUpperBoundMs = nil },
            { $0.status.observation?.decodedVideo?.clock = nil }, { $0.status.observation?.decodedVideo?.ended = true },
            { $0.status.observation?.decodedVideo?.completed?.duplicateFrames = 1 },
            { $0.status.observation?.decodedVideo?.completed?.reorderedFrames = 1 }, { $0.status.expiresAt = $0.serverTime },
        ]
        for mutation in mutations {
            var response = original; mutation(&response)
            XCTAssertNil(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .zero))
        }
        let now = ContinuousClock.now
        let evidence = try XCTUnwrap(WorkerProcessingEvidence(response: original, receivedAt: now, requestDuration: .milliseconds(100)))
        XCTAssertEqual(evidence.freshness.ageUpperBound(at: now), .milliseconds(350))
        XCTAssertNil(evidence.freshness.ageUpperBound(at: now + .seconds(5)))
    }
    func testPendingAndZeroSubmissionCannotCarryKnownCompletionDuration() throws {
        var response = try XCTUnwrap(fixture()["pending"])
        response.status.observation?.processing?.interval.processingDuration = .init(meanMs: 1, maximumMs: 1)
        XCTAssertNil(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .zero))
        var interval = try XCTUnwrap(response.status.observation?.processing?.interval)
        interval.submittedFrames = 0; interval.completedFrames = 0; interval.pendingFrames = 0
        interval.omittedBeforeEncoderFrames = interval.decodedFrames; interval.processingDuration = nil
        response.status.observation?.processing?.interval = interval
        XCTAssertNil(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .zero))
        response.status.observation?.processing?.interval.filterDuration = nil
        XCTAssertNotNil(WorkerProcessingEvidence(response: response, receivedAt: .now, requestDuration: .zero))
    }
}

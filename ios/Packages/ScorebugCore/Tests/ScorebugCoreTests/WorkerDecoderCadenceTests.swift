import Foundation
import XCTest
@testable import ScorebugCore

final class WorkerDecoderCadenceTests: XCTestCase {
    private func fixture() throws -> WorkerMediaStatusResponse {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder-cadence-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
    }
    func testSharedGoldenCadenceRoundTripsWithoutLosingMeasurements() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder-cadence-v1", withExtension: "json", subdirectory: "Fixtures"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }
    private let expected = UUID(uuidString: "30000000-0000-0000-0000-00000000000c")!
    func testAgesIncludeRequestAndResidenceWithoutManufacturingAStall() throws {
        let now = ContinuousClock.now
        let value = try XCTUnwrap(WorkerDecoderCadenceFreshness(response: fixture(), expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .milliseconds(200)))
        XCTAssertEqual(value.sampleAgeUpperBound(at: now), .milliseconds(250))
        XCTAssertEqual(value.windowAgeUpperBound(.oneSecond, at: now), .milliseconds(350))
        XCTAssertEqual(value.windowAgeUpperBound(.twoSeconds, at: now + .milliseconds(300)), .milliseconds(650))
        XCTAssertEqual(value.observedStall(maximumSampleAge: .milliseconds(250), at: now), false)
        XCTAssertNil(value.observedStall(maximumSampleAge: .milliseconds(250), at: now + .nanoseconds(1)))
        XCTAssertEqual(value.observedStall(maximumSampleAge: .seconds(2), at: now + .seconds(1)), false)
        XCTAssertNil(value.sampleAgeUpperBound(at: now - .nanoseconds(1)))
        XCTAssertNil(value.sampleAgeUpperBound(at: now + .seconds(4)))
    }
    func testObservedStallRequiresWorkerEvidenceAndExpectedPublication() throws {
        var response = try fixture(); let now = ContinuousClock.now
        response.status.observation?.decoderCadence?.progress?.ageMs = 1000
        response.status.observation?.decoderCadence?.progress?.stalled = true
        let value = try XCTUnwrap(WorkerDecoderCadenceFreshness(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        XCTAssertEqual(value.observedStall(maximumSampleAge: .milliseconds(50), at: now), true)
        XCTAssertNil(WorkerDecoderCadenceFreshness(response: response, expectedPublishingAttemptID: UUID(), receivedAt: now, requestDuration: .zero))
        response.status.publication = nil
        XCTAssertNil(WorkerDecoderCadenceFreshness(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
    }
    func testRejectsUnknownStaleMalformedAndContradictoryEvidence() throws {
        let now = ContinuousClock.now
        let changes: [(inout WorkerMediaStatusResponse) -> Void] = [
            { $0.status.decoderCadenceAgeUpperBoundMs = nil }, { $0.status.decoderCadenceAgeUpperBoundMs = .nan },
            { $0.status.decoderCadenceAgeUpperBoundMs = -1 }, { $0.status.decoderCadenceAgeUpperBoundMs = 0.5 },
            { $0.status.workerEpoch = "wrong" }, { $0.status.state = .stale },
            { $0.status.observation?.decoderCadence?.scopeID = "wrong" },
            { $0.status.observation?.decoderCadence?.formatVersion = 2 },
            { $0.status.observation?.decoderCadence?.ended = true },
            { $0.status.observation?.decoderCadence?.invalidReason = .clock },
            { $0.status.observation?.decoderCadence?.progress = nil },
            { $0.status.observation?.decoderCadence?.progress?.stalled = true },
            { $0.status.observation?.decoderCadence?.progress?.ageMs = .infinity },
            { $0.status.observation?.decoderCadence?.progress?.lastFreshPTS = 0 },
            { $0.status.observation?.decoderCadence?.oneSecond?.sequence = Int64.max },
            { $0.status.observation?.decoderCadence?.oneSecond?.durationMs = 5000 },
            { $0.status.observation?.decoderCadence?.oneSecond?.freshFrames = -1 },
            { $0.status.observation?.decoderCadence?.oneSecond?.firstPTS = nil },
            { $0.status.observation?.decoderCadence?.oneSecond?.valid = false },
            { $0.status.observation?.decoderCadence?.twoSeconds?.ageMs = 101 },
            { $0.status.observation?.decodedVideo?.clock = nil }
        ]
        for change in changes {
            var response = try fixture(); change(&response)
            XCTAssertNil(WorkerDecoderCadenceFreshness(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        }
        for duration: Duration in [.nanoseconds(-1), .seconds(4), .seconds(Int64.max)] {
            XCTAssertNil(try WorkerDecoderCadenceFreshness(response: fixture(), expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: duration))
        }
    }
    func testMalformedAdditiveMetadataDoesNotBreakStatusAndLegacyIsUnknown() throws {
        let data = try JSONEncoder().encode(fixture())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var status = try XCTUnwrap(object["status"] as? [String: Any])
        var observation = try XCTUnwrap(status["observation"] as? [String: Any])
        observation["decoderCadence"] = ["formatVersion": "bad"]
        status["observation"] = observation; status["decoderCadenceAgeUpperBoundMs"] = "bad"; object["status"] = status
        let decoded = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.status.state, .producingOutput)
        XCTAssertNil(decoded.status.observation?.decoderCadence); XCTAssertNil(decoded.status.decoderCadenceAgeUpperBoundMs)
    }

    func testEmptyWindowEncodesExplicitNullCoordinatesAndAgeAdditionCannotOverflow() throws {
        var response = try fixture()
        response.status.observation?.decoderCadence?.oneSecond?.firstPTS = nil
        response.status.observation?.decoderCadence?.oneSecond?.lastPTS = nil
        response.status.observation?.decoderCadence?.oneSecond?.freshFrames = 0
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.status.observation?.decoderCadence)) as? [String: Any])
        let window = try XCTUnwrap(object["oneSecond"] as? [String: Any])
        XCTAssertTrue(window["firstPTS"] is NSNull); XCTAssertTrue(window["lastPTS"] is NSNull)
        let now = ContinuousClock.now
        response.status.observation?.decoderCadence?.oneSecond?.ageMs = 9_007_199_254_740_991
        response.status.observation?.decoderCadence?.twoSeconds?.ageMs = 9_007_199_254_740_991
        let value = try XCTUnwrap(WorkerDecoderCadenceFreshness(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        XCTAssertNil(value.windowAgeUpperBound(.oneSecond, at: now))
    }

}

import Foundation
import ScorebugCore
import XCTest

final class WorkerDecodedVideoFreshnessTests: XCTestCase {
    private let maximum: Int64 = 9_007_199_254_740_991
    private func fixture() throws -> WorkerMediaStatusResponse {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-report-age-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
    }

    func testSharedGoldenResponseRoundTripsAndLegacyOmitsBound() throws {
        let response = try fixture()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-report-age-v1", withExtension: "json", subdirectory: "Fixtures"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        var legacy = response
        legacy.status.decodedVideoAgeUpperBoundMs = nil
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil((object["status"] as? [String: Any])?["decodedVideoAgeUpperBoundMs"])
        XCTAssertNil(try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONEncoder().encode(legacy)).status.decodedVideoAgeUpperBoundMs)
    }

    func testAgeAddsEntireRequestAndResidenceWithoutResettingAnchor() throws {
        let receipt = ContinuousClock.now
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: fixture(), receivedAt: receipt, requestDuration: .milliseconds(200)))
        XCTAssertEqual(helper.ageUpperBound(at: receipt), .milliseconds(750))
        XCTAssertEqual(helper.ageUpperBound(at: receipt + .milliseconds(300)), .milliseconds(1050))
        XCTAssertEqual(helper.ageUpperBound(at: receipt + .milliseconds(600)), .milliseconds(1350))
        XCTAssertEqual(helper.ageUpperBound(at: receipt + .milliseconds(300)), .milliseconds(1050))
        XCTAssertNil(helper.ageUpperBound(at: receipt - .nanoseconds(1)))
    }

    func testTTLExactBoundaryAndRequestBudgetExhaustion() throws {
        var response = try fixture()
        response.status.expiresAt = "2026-09-14T04:00:04.000Z"
        let receipt = ContinuousClock.now
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .milliseconds(200)))
        XCTAssertNotNil(helper.ageUpperBound(at: receipt + .milliseconds(3799)))
        XCTAssertNil(helper.ageUpperBound(at: receipt + .milliseconds(3800)))
        for duration: Duration in [.seconds(4), .seconds(5), .nanoseconds(-1), .seconds(Int64.max)] {
            XCTAssertNil(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: duration))
        }
        for expiry in [nil, "bad", response.serverTime] {
            response.status.expiresAt = expiry
            XCTAssertNil(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero))
        }
    }

    func testRejectsAbsentNonfiniteFractionalNegativeContradictoryAndOverflowBounds() throws {
        let receipt = ContinuousClock.now
        for bound: Double? in [nil, .nan, .infinity, -.infinity, -1, 550.5, 249, Double(maximum) + 1] {
            var response = try fixture()
            response.status.decodedVideoAgeUpperBoundMs = bound
            XCTAssertNil(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero), "bound: \(String(describing: bound))")
        }
        for lower: Double in [.nan, .infinity, -.infinity, -1, 551] {
            var response = try fixture()
            response.status.observation?.decodedVideo?.completed?.ageMs = lower
            XCTAssertNil(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero))
        }
    }

    func testExactDurationArithmeticAtMaximumSafeMillisecondBoundary() throws {
        let receipt = ContinuousClock.now
        var response = try fixture()
        response.status.decodedVideoAgeUpperBoundMs = Double(maximum)
        XCTAssertNil(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .nanoseconds(1)))
        let maximumHelper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero))
        XCTAssertEqual(maximumHelper.ageUpperBound(at: receipt), .milliseconds(maximum))
        XCTAssertNil(maximumHelper.ageUpperBound(at: receipt + .nanoseconds(1)))
        response.status.decodedVideoAgeUpperBoundMs = Double(maximum - 1)
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .microseconds(500)))
        XCTAssertEqual(helper.ageUpperBound(at: receipt + .microseconds(500)), .milliseconds(maximum))
        XCTAssertNil(helper.ageUpperBound(at: receipt + .microseconds(501)))
    }

    func testRejectsScopeStatesAndInvalidWindowInvariants() throws {
        let faults: [(inout WorkerMediaStatusResponse) -> Void] = [
            { $0.status.observation?.gameId = "other" },
            { $0.status.observation?.generation += 1 },
            { $0.status.workerId = nil }, { $0.status.workerId = "" },
            { $0.status.workerId = String(repeating: "w", count: 129) },
            { $0.status.workerId = "bad worker" },
            { $0.status.workerId = "worker\n" },
            { $0.status.state = .stale }, { $0.status.observation?.state = .starting },
            { $0.status.observation = nil }, { $0.status.observation?.decodedVideo = nil },
            { $0.status.observation?.decodedVideo?.completed = nil },
            { $0.status.observation?.decodedVideo?.invalidReason = .clock },
            { $0.status.observation?.decodedVideo?.ended = true },
            { $0.status.observation?.decodedVideo?.completed?.valid = false },
            { $0.status.observation?.decodedVideo?.completed?.sequence = 0 },
            { $0.status.observation?.decodedVideo?.completed?.sequence = Int64.max },
            { $0.status.observation?.decodedVideo?.completed?.durationMs = 4999 },
            { $0.status.observation?.decodedVideo?.completed?.freshFrames = -1 },
            { $0.status.observation?.decodedVideo?.completed?.duplicateFrames = -1 },
            { $0.status.observation?.decodedVideo?.completed?.reorderedFrames = -1 },
            { $0.status.observation?.decodedVideo?.completed?.freshFrames = Int64.max },
            { $0.status.observation?.decodedVideo?.completed?.duplicateFrames = 9_007_199_254_740_991 },
            { $0.status.observation?.decodedVideo?.completed?.firstPTS = Int64.min },
            { $0.status.observation?.decodedVideo?.completed?.lastPTS = Int64.max },
            { $0.status.observation?.decodedVideo?.completed?.firstPTS = nil },
            { $0.status.observation?.decodedVideo?.completed?.lastPTS = nil },
            { $0.status.observation?.decodedVideo?.completed?.firstPTS = 447000 },
            { $0.status.observation?.decodedVideo?.completed?.firstPTS = 447001 },
            { $0.status.observation?.decodedVideo?.completed?.freshFrames = 1 },
            { $0.status.observation?.decodedVideo?.completed?.freshFrames = 0 }
        ]
        for (index, fault) in faults.enumerated() {
            var response = try fixture(); fault(&response)
            XCTAssertNil(WorkerDecodedVideoFreshness(response: response, receivedAt: .now, requestDuration: .zero), "fault \(index)")
        }
    }

    func testImmutableScopeAndWindowSurviveMutationOfSourceResponse() throws {
        var response = try fixture()
        let original = response
        let receipt = ContinuousClock.now
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero))
        response.status.gameId = "other"; response.status.generation = 9; response.status.workerId = "other"
        response.status.observation?.attempt = 10
        response.status.observation?.decodedVideo?.completed?.sequence = 20
        response.status.decodedVideoAgeUpperBoundMs = 0
        XCTAssertEqual(helper.gameId, "match"); XCTAssertEqual(helper.generation, 1)
        XCTAssertEqual(helper.workerId, "mac"); XCTAssertEqual(helper.attempt, 1)
        XCTAssertEqual(helper.completed, original.status.observation?.decodedVideo?.completed)
        XCTAssertEqual(helper.ageUpperBound(at: receipt), .milliseconds(550))
    }

    func testEmptyWindowRetainsAgeWithoutImplyingProgressAndOneFrameAllowsEqualPTS() throws {
        var response = try fixture()
        response.status.observation?.decodedVideo?.completed?.freshFrames = 0
        response.status.observation?.decodedVideo?.completed?.firstPTS = nil
        response.status.observation?.decodedVideo?.completed?.lastPTS = nil
        let receipt = ContinuousClock.now
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero))
        XCTAssertEqual(helper.completed.freshFrames, 0)
        XCTAssertEqual(helper.ageUpperBound(at: receipt), .milliseconds(550))
        response.status.observation?.decodedVideo?.completed?.freshFrames = 1
        response.status.observation?.decodedVideo?.completed?.firstPTS = -9_007_199_254_740_991
        response.status.observation?.decodedVideo?.completed?.lastPTS = -9_007_199_254_740_991
        XCTAssertNotNil(WorkerDecodedVideoFreshness(response: response, receivedAt: receipt, requestDuration: .zero))
    }
}

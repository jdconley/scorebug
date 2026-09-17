import Foundation
import XCTest
@testable import ScorebugCore

final class DeliveryDeadlineTests: XCTestCase {
    private let scope = "11111111-1111-4111-8111-111111111111"
    private func expected(_ count: Int = 60) -> [DeliveryDeadlineFrame] {
        (0..<count).map { .init(pts: Int64($0 * 3000), capturedAt: 100 + Double($0) / 30) }
    }
    private func timeline(_ frames: [DeliveryDeadlineFrame], now: Double = 104,
                          delay: (Int) -> Double? = { _ in 0.5 }) -> DecoderDeliverySnapshot {
        let rows = frames.enumerated().compactMap { i, f -> (Int64, Double)? in
            delay(i).map { (f.pts, now - f.capturedAt - $0) }
        }.sorted { $0.1 > $1.1 }
        return .init(formatVersion: 1, scopeID: scope, coverageAgeMs: 5000,
            lastOrdinal: Int64(rows.count), arrivals: rows.enumerated().map { i, r in
                .init(ordinal: Int64(i + 1), pts: r.0, ageMs: r.1 * 1000)
            }, invalidReason: nil, ended: false)
    }
    private func evaluate(_ value: DecoderDeliverySnapshot, frames: [DeliveryDeadlineFrame]? = nil,
                          now: Double = 104, age: Double = 0.2, duration: Double = 2) throws -> DeliveryDeadlineResult {
        try DeliveryDeadlineClassifier.classify(timeline: value, expectedScopeID: scope,
            frames: frames ?? expected(), windowStart: 100, windowEnd: 100 + duration,
            evaluatedAt: now, sampleAgeUpperBound: age, maximumSampleAge: 0.25, latencyBudget: 1.5)
    }
    func testSharedGoldenTimelineMatchesNativeDeadlineArithmetic() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder-delivery-v1", withExtension: "json", subdirectory: "Fixtures"))
        let t = try JSONDecoder().decode(DecoderDeliverySnapshot.self, from: Data(contentsOf: url))
        let frames = (0..<3).map { DeliveryDeadlineFrame(pts: Int64($0 * 3000), capturedAt: 100.1 + Double($0) / 30) }
        let r = try evaluate(t, frames: frames, now: 103, duration: 1)
        XCTAssertEqual(r.onTimeFrames, 2); XCTAssertEqual(r.lateFrames, 1)
        XCTAssertEqual(r.uncertainFrames, 0); XCTAssertEqual(r.missingFrames, 0)
    }
    func testAllFramesOnTimeUseCaptureDeadlinesWithoutSharedClockEpoch() throws {
        let r = try evaluate(timeline(expected()))
        XCTAssertEqual(r.onTimeFrames, 60); XCTAssertEqual(r.knownFailureFrames, 0)
        XCTAssertEqual(r.onTimeFPS, 30); XCTAssertEqual(r.failureFraction, 0)
    }
    func testMissingAndLateFramesCountOnceAtThreeAndFourOfSixty() throws {
        for count in [3, 4] {
            let missing = try evaluate(timeline(expected(), delay: { $0 < count ? nil : 0.5 }))
            let late = try evaluate(timeline(expected(), delay: { $0 < count ? 1.8 : 0.5 }))
            XCTAssertEqual(missing.missingFrames, count); XCTAssertEqual(late.lateFrames, count)
            XCTAssertEqual(missing.failureFraction, Double(count) / 60)
            XCTAssertEqual(late.failureFraction, Double(count) / 60)
            XCTAssertEqual(missing.knownFailureFraction > 0.05, count == 4)
        }
    }
    func testTwentyThreeAndTwentyFourAreNotRoundedIntoTheSameFloor() throws {
        let frames = expected(30)
        for n in [23, 24] {
            let r = try evaluate(timeline(frames, now: 103, delay: { $0 < n ? 0.5 : nil }),
                frames: frames, now: 103, duration: 1)
            XCTAssertEqual(r.onTimeFPS, Double(n))
        }
    }
    func testCatchUpBurstAndLaterDuplicatesCannotRepairOldDeadlines() throws {
        var t = timeline(expected(), delay: { 103.8 - 100 - Double($0) / 30 })
        let result = try evaluate(t)
        XCTAssertEqual(result.lateFrames, 60); XCTAssertEqual(result.onTimeFPS, 0)
        t.arrivals.append(.init(ordinal: 61, pts: 0, ageMs: 100)); t.lastOrdinal = 61
        XCTAssertEqual(try evaluate(t).lateFrames, 60)
    }
    func testFirstArrivalWinsEvenWithDuplicatesAndReordering() throws {
        var t = timeline(expected());t.arrivals.append(.init(ordinal: 61, pts: 0, ageMs: 0));t.lastOrdinal = 61
        XCTAssertEqual(try evaluate(t).onTimeFrames, 60)
    }
    func testBoundaryAndUncertaintyBlockCompleteHealthyEvidence() throws {
        let onTime = try evaluate(timeline(expected(), delay: { $0 == 0 ? 1.5 : 0.5 }))
        XCTAssertEqual(onTime.onTimeFrames, 60)
        let uncertain = try evaluate(timeline(expected(), delay: { $0 == 0 ? 1.6 : 0.5 }))
        XCTAssertEqual(uncertain.uncertainFrames, 1); XCTAssertNil(uncertain.onTimeFPS)
        XCTAssertNil(uncertain.failureFraction); XCTAssertEqual(uncertain.knownFailureFrames, 0)
        let boundary = try evaluate(timeline(expected(), delay: { $0 == 0 ? 1.7 : 0.5 }))
        XCTAssertEqual(boundary.uncertainFrames, 1, "Lower bound equal to deadline is not proven late")
    }
    func testIncompleteOrExpiredEvidenceCannotProveMissingFrames() throws {
        var t = timeline(expected(), delay: { _ in nil })
        t.coverageAgeMs = 4000 // coverage starts exactly at first capture, exclusive
        XCTAssertThrowsError(try evaluate(t))
        t.coverageAgeMs = 5000
        XCTAssertThrowsError(try evaluate(t, now: 103.5)) // last deadline not definitely elapsed
        XCTAssertThrowsError(try evaluate(t, age: 0.251))
        t.ended = true; XCTAssertThrowsError(try evaluate(t))
    }
    func testMissingFrameRequiresDeadlineToBeStrictlyPast() throws {
        let frames = expected(1)
        let empty = timeline(frames, now: 101.5, delay: { _ in nil })
        XCTAssertThrowsError(try evaluate(empty, frames: frames, now: 101.5, age: 0, duration: 1)) {
            XCTAssertEqual($0 as? DeliveryDeadlineClassifier.Failure, .incompleteCoverage)
        }
        let after = try evaluate(empty, frames: frames, now: 101.5001, age: 0, duration: 1)
        XCTAssertEqual(after.missingFrames, 1)
        // A later sample may include an arrival timestamped exactly at the deadline.
        let arrived = timeline(frames, now: 101.5001, delay: { _ in 1.5 })
        XCTAssertEqual(try evaluate(arrived, frames: frames, now: 101.5001, age: 0, duration: 1).onTimeFrames, 1)
    }
    func testInvalidScopeTimelineOrderingAndClockReject() throws {
        let clean = timeline(expected())
        for damage in 0..<8 {
            var t = clean
            switch damage {
            case 0: t.scopeID = "other"
            case 1: t.invalidReason = "clock"
            case 2: t.arrivals[5].ordinal += 1
            case 3: t.arrivals[0].ageMs = -1
            case 4: t.arrivals[3].ageMs = t.arrivals[0].ageMs + 1
            case 5: t.lastOrdinal += 1
            case 6: t.coverageAgeMs = .infinity
            default: t.arrivals[0].ageMs = 5001
            }
            XCTAssertThrowsError(try evaluate(t))
        }
        XCTAssertThrowsError(try evaluate(clean, now: .nan))
        var frames = expected();frames[1] = frames[0]
        XCTAssertThrowsError(try evaluate(clean, frames: frames))
    }
}

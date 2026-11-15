import Foundation
import XCTest
@testable import ScorebugCore

final class DecoderStallPolicyTests: XCTestCase {
    private let attempt = UUID()
    private let minimum = QualityController.Settings(profileID: "low", videoBitrate: 350_000)
    private let high = QualityController.Settings(profileID: "high", videoBitrate: 6_000_000)
    private func controller(low: Bool = false, progressive: Bool = true) throws -> QualityController {
        try .init(profiles: [
            .init(id: "low", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "high", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, applied: low ? minimum : high, at: 100,
           recoveryStrategy: .receiverValidatedProfileTrials, behavior: progressive ? .progressive : .legacy)
    }
    private func stall(at time: Double = 101, sequence: UInt64 = 1, revision: UInt64 = 0,
                       attemptID: UUID? = nil) -> QualityController.DecoderStall {
        .init(attemptID: attemptID ?? attempt, appliedRevision: revision, sequence: sequence,
              observedAtLowerBound: time)
    }
    private func healthy(_ start: Double, revision: UInt64 = 0) -> QualityController.Window {
        .init(attemptID: attempt, sequence: UInt64(start), appliedRevision: revision, start: start, end: start + 1,
            capturedFreshFrames: 30, encodedFreshFrames: 30,
            receiver: .init(freshFrames: 30, observedAt: start + 1),
            sourceLoss: .init(expectedFrames: 30, lostFrames: 0), meanQueueOccupancy: 0,
            usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
            workerPressure: .nominal, transportPressure: .nominal)
    }
    func testFreshPostAcknowledgmentStallResetsWithoutAFrameWindow() throws {
        var p = try controller()
        let d = try p.evaluateDecoderStall(stall(), at: 101.25)
        XCTAssertEqual(d.state, .stalled)
        let reset = try XCTUnwrap(d.recommendation)
        XCTAssertEqual(reset.kind, .reset); XCTAssertEqual(reset.settings, minimum)
        XCTAssertEqual(reset.validUntil, 101.25)
        XCTAssertEqual(p.applied, high)
        let a = try p.beginApplication(reset, at: 101.25)
        try p.acknowledge(a, applied: minimum, at: 102)
        XCTAssertEqual(p.appliedRevision, 1)
    }
    func testNoFabricatedWindowAndMinimumStallOnlyStartsHealthyHold() throws {
        var p = try controller(low: true)
        XCTAssertNil(try p.evaluateDecoderStall(stall(), at: 101).recommendation)
        for i in 0..<10 {
            let t = 101 + Double(i)
            let d = try p.evaluate(healthy(t), at: t + 1)
            XCTAssertEqual(d.recommendation != nil, i == 9)
        }
    }
    func testLateHealthyWindowCannotCreditTimeBeforeObservedStall() throws {
        var p = try controller(low: true)
        _ = try p.evaluateDecoderStall(stall(at: 101), at: 101.25)
        for i in 101..<112 {
            let d = try p.evaluate(healthy(Double(i)), at: Double(i + 1))
            // The first window crosses the stall receipt boundary. Ten complete
            // later seconds (102...112) are required before an increase.
            XCTAssertEqual(d.recommendation != nil, i == 111)
        }
    }
    func testWrongAttemptRevisionTooOldFutureAndPreTransitionReportsReject() throws {
        for (signal, now) in [(stall(attemptID: UUID()), 101.0), (stall(revision: 1), 101),
                              (stall(), 101.250001), (stall(at: 101.1), 101),
                              (stall(at: 100.999), 101), (stall(at: .nan), 101)] {
            var p = try controller()
            XCTAssertThrowsError(try p.evaluateDecoderStall(signal, at: now))
            XCTAssertNil(try p.checkTrialDeadline(at: 102))
            XCTAssertEqual(p.applied, high)
        }
        var legacy = try controller(progressive: false)
        XCTAssertThrowsError(try legacy.evaluateDecoderStall(stall(), at: 101))
    }
    func testStallSharesSequenceAdmissionAndCannotReplayAfterAcknowledgment() throws {
        var p = try controller()
        _ = try p.evaluate(healthy(100), at: 101)
        XCTAssertThrowsError(try p.evaluateDecoderStall(stall(sequence: 100), at: 101))
        let d = try p.evaluateDecoderStall(stall(sequence: 101), at: 101)
        let reset = try XCTUnwrap(d.recommendation)
        try p.acknowledge(reset, applied: minimum, at: 101)
        XCTAssertThrowsError(try p.evaluateDecoderStall(stall(sequence: 102), at: 101))
        XCTAssertThrowsError(try p.evaluateDecoderStall(stall(at: 101.999, sequence: 102, revision: 1), at: 102))
    }
    func testStallRevokesUpwardApplicationAndPersistsEvenAtHistoricalMinimum() throws {
        var p = try controller(low: true), advice: QualityController.Recommendation?
        for i in 100..<104 { advice = try p.evaluate(healthy(Double(i)), at: Double(i + 1)).recommendation }
        let up = try XCTUnwrap(advice), a = try p.beginApplication(up, at: 104)
        let d = try p.evaluateDecoderStall(stall(at: 104, sequence: 104), at: 104)
        XCTAssertEqual(d.recommendation?.kind, .reset)
        XCTAssertEqual(d.recommendation?.settings, minimum)
        XCTAssertThrowsError(try p.acknowledge(a, applied: up.settings, at: 104.1))
        p.invalidateTelemetry()
        XCTAssertEqual(try p.checkTrialDeadline(at: 110)?.settings, minimum)
    }
}

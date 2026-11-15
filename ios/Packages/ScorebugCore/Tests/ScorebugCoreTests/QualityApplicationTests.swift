import Foundation
import XCTest
@testable import ScorebugCore

final class QualityApplicationTests: XCTestCase {
    private let attempt = UUID()
    private func policy() throws -> QualityController {
        try .init(profiles: [
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000),
            .init(id: "1080p30", width: 1920, height: 1080, minimumBitrate: 6_000_000, maximumBitrate: 6_000_000)
        ], attemptID: attempt, applied: .init(profileID: "540p30", videoBitrate: 1_500_000), at: 0,
           recoveryStrategy: .receiverValidatedProfileTrials)
    }
    private func window(_ start: Double, duration: Double = 5, revision: UInt64 = 0, sequence: UInt64? = nil) -> QualityController.Window {
        let frames = Int(duration * 30)
        return .init(attemptID: attempt, sequence: sequence ?? UInt64(start + 1), appliedRevision: revision,
            start: start, end: start + duration, capturedFreshFrames: frames, encodedFreshFrames: frames,
            receiver: .init(freshFrames: frames, observedAt: start + duration),
            sourceLoss: .init(expectedFrames: frames, lostFrames: 0), meanQueueOccupancy: 0,
            usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
            workerPressure: .nominal, transportPressure: .nominal)
    }
    private func ready(_ policy: inout QualityController) throws -> QualityController.Recommendation {
        var advice: QualityController.Recommendation?
        for start in stride(from: 0.0, to: 30, by: 5) {
            advice = try policy.evaluate(window(start), at: start + 5).recommendation
        }
        return try XCTUnwrap(advice)
    }
    func testFreshAdmissionCanFinishAfterAdviceExpiryWithoutExtendingTrialCoverage() throws {
        var p = try policy(); let advice = try ready(&p)
        let application = try p.beginApplication(advice, at: 31.772759)
        XCTAssertEqual(advice.validUntil, 32)
        XCTAssertEqual(application.admittedAt, 31.772759)
        XCTAssertEqual(application.completionDeadline, 33.772759)
        XCTAssertEqual(application.recommendation, advice)
        try p.acknowledge(application, applied: advice.settings, at: 32.272759)
        XCTAssertEqual(p.appliedRevision, 1)
        // Actual healthy coverage begins after acknowledgment, not admission.
        XCTAssertEqual(try p.evaluate(window(32.272759, revision: 1), at: 37.272759).state, .probing)
        XCTAssertTrue(try p.evaluate(window(37.272759, revision: 1), at: 42.272759).reasons.contains(.trialConfirmed))
    }
    func testExpiredAdviceCannotStartNativeWork() throws {
        var p = try policy(); let advice = try ready(&p)
        XCTAssertThrowsError(try p.beginApplication(advice, at: 32.000001)) {
            XCTAssertEqual($0 as? QualityController.ValidationError, .staleRecommendation)
        }
        XCTAssertEqual(p.appliedRevision, 0)
    }
    func testSecondAdmissionCannotRenewCompletionBudget() throws {
        var p = try policy(); let advice = try ready(&p)
        let application = try p.beginApplication(advice, at: 31)
        XCTAssertThrowsError(try p.beginApplication(advice, at: 31.9))
        XCTAssertThrowsError(try p.acknowledge(application, applied: advice.settings, at: 33.000001))
        XCTAssertEqual(p.appliedRevision, 0)
        XCTAssertThrowsError(try p.acknowledge(application, applied: advice.settings, at: 33.1))
    }
    func testCompletedOrFailedAuthorizationCannotReplay() throws {
        for success in [false, true] {
            var p = try policy(); let advice = try ready(&p)
            let application = try p.beginApplication(advice, at: 31)
            try p.acknowledge(application, applied: success ? advice.settings : nil, at: 31.5)
            XCTAssertEqual(p.appliedRevision, success ? 1 : 0)
            XCTAssertThrowsError(try p.acknowledge(application, applied: advice.settings, at: 31.6))
            XCTAssertThrowsError(try p.beginApplication(advice, at: 31.7))
        }
    }
    func testNewWindowOrInvalidationRevokesAuthorization() throws {
        for invalidate in [false, true] {
            var p = try policy(); let advice = try ready(&p)
            let application = try p.beginApplication(advice, at: 30.5)
            if invalidate { p.invalidateTelemetry() }
            else { _ = try p.evaluate(window(30, duration: 1, sequence: 31), at: 31) }
            XCTAssertThrowsError(try p.acknowledge(application, applied: advice.settings, at: 31.2))
            XCTAssertEqual(p.appliedRevision, 0)
        }
    }
    func testLegacyAcknowledgmentKeepsExpiryAndCannotBypassAdmittedWork() throws {
        var p = try policy(); let advice = try ready(&p)
        XCTAssertThrowsError(try p.acknowledge(advice, applied: advice.settings, at: 32.1))
        p = try policy(); let next = try ready(&p)
        let application = try p.beginApplication(next, at: 31)
        XCTAssertThrowsError(try p.acknowledge(next, applied: next.settings, at: 31.1))
        try p.acknowledge(application, applied: next.settings, at: 31.2)
        XCTAssertEqual(p.appliedRevision, 1)
    }
    func testMatchingFailedCompletionConsumesAuthorizationEvenOnInvalidClock() throws {
        for invalid in [Double.nan, Double.infinity, 30.9] {
            var p = try policy(); let advice = try ready(&p)
            let application = try p.beginApplication(advice, at: 31)
            XCTAssertThrowsError(try p.acknowledge(application, applied: advice.settings, at: invalid))
            XCTAssertThrowsError(try p.acknowledge(application, applied: advice.settings, at: 31.5))
            XCTAssertEqual(p.appliedRevision, 0)
            XCTAssertNil(try p.evaluate(window(30), at: 35).recommendation)
        }
    }
    func testForeignAuthorizationAndSupersededAdviceCannotCommit() throws {
        var first = try policy(), second = try policy()
        let a = try ready(&first), b = try ready(&second)
        let one = try first.beginApplication(a, at: 31)
        let two = try second.beginApplication(b, at: 31)
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertThrowsError(try first.acknowledge(two, applied: b.settings, at: 31.1))
        try first.acknowledge(one, applied: a.settings, at: 31.2)
        _ = try second.evaluate(window(30, duration: 1, sequence: 31), at: 31.2)
        XCTAssertThrowsError(try second.beginApplication(b, at: 31.3))
    }
}

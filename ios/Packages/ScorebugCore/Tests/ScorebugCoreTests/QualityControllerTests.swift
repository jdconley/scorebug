import Foundation
import ScorebugCore
import XCTest

final class QualityControllerTests: XCTestCase {
    private let attempt = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private var ladder: [QualityController.Profile] {
        [.init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 1_000_000),
         .init(id: "medium", width: 1280, height: 720, minimumBitrate: 1_500_000, maximumBitrate: 3_000_000),
         .init(id: "large", width: 1920, height: 1080, minimumBitrate: 3_000_000, maximumBitrate: 6_000_000)]
    }
    private func controller(profile: String = "medium", bitrate: Int = 2_000_000) throws -> QualityController {
        try .init(profiles: ladder, attemptID: attempt, applied: .init(profileID: profile, videoBitrate: bitrate), at: 0)
    }
    private func window(_ start: Double = 0, duration: Double = 5, sequence: UInt64? = nil,
                        revision: UInt64 = 0, capture: Int? = 150, encoded: Int? = 150,
                        received: Int? = 150, capacity: Double? = 20_000_000, queue: Double? = 0.1,
                        loss: QualityController.SourceLoss? = .init(expectedFrames: 150, lostFrames: 0),
                        connectivity: QualityController.Connectivity = .connected,
                        thermal: QualityController.Pressure = .nominal,
                        worker: QualityController.Pressure = .nominal,
                        receiverAt: Double? = nil, attemptID: UUID? = nil) -> QualityController.Window {
        .init(attemptID: attemptID ?? attempt, sequence: sequence ?? UInt64(start + 1), appliedRevision: revision,
              start: start, end: start + duration, capturedFreshFrames: capture, encodedFreshFrames: encoded,
              receiver: received.map { .init(freshFrames: $0, observedAt: receiverAt ?? start + duration) },
              sourceLoss: loss, meanQueueOccupancy: queue, usableVideoCapacity: capacity,
              connectivity: connectivity, thermalPressure: thermal, workerPressure: worker)
    }

    func testQuarterSecondPressureRequiresExplicitDownwardOnlyEntryPoint() throws {
        let pressure = window(duration: 0.25, capture: nil, encoded: nil, received: nil,
            capacity: nil, queue: 0.75, loss: nil, connectivity: .unknown,
            thermal: .unknown, worker: .unknown)
        var normal = try controller()
        XCTAssertThrowsError(try normal.evaluate(pressure, at: 0.25))
        var local = try controller()
        let decision = try local.evaluateLocalPressure(pressure, at: 0.25)
        XCTAssertEqual(decision.recommendation?.kind, .decrease)
        XCTAssertEqual(decision.recommendation?.settings.videoBitrate, 1_600_000)
        XCTAssertTrue(decision.reasons.contains(.missingReceiver))
        XCTAssertThrowsError(try local.evaluateLocalPressure(pressure, at: 0.25))
    }

    func testLocalEntryRejectsHealthyMixedAndTooShortEvidence() throws {
        let cases = [
            window(duration: 0.25),
            window(duration: 0.25, capture: nil, encoded: nil, received: nil,
                capacity: nil, queue: 0.1, loss: nil, connectivity: .unknown, worker: .unknown),
            window(duration: 0.25, capture: 1, encoded: nil, received: nil,
                capacity: nil, queue: 0.75, loss: nil, connectivity: .unknown, worker: .unknown),
            window(duration: 0.249, capture: nil, encoded: nil, received: nil,
                capacity: nil, queue: 0.75, loss: nil, connectivity: .unknown, worker: .unknown),
        ]
        for sample in cases {
            var policy = try controller()
            XCTAssertThrowsError(try policy.evaluateLocalPressure(sample, at: 0.25))
        }
    }

    func testRejectsInvalidLaddersAndInitialSettings() throws {
        let malformed: [[QualityController.Profile]] = [[], [ladder[0], ladder[0]], Array(ladder.reversed()),
            [.init(id: " ", width: 640, height: 360, minimumBitrate: 1, maximumBitrate: 2)],
            [.init(id: "odd", width: 641, height: 360, minimumBitrate: 1, maximumBitrate: 2)],
            [.init(id: "rate", width: 640, height: 360, minimumBitrate: 2, maximumBitrate: 1)],
            [.init(id: "fps", width: 640, height: 360, targetFPS: 24, minimumBitrate: 1, maximumBitrate: 2)]]
        for profiles in malformed {
            XCTAssertThrowsError(try QualityController(profiles: profiles, attemptID: attempt,
                applied: .init(profileID: "small", videoBitrate: 500_000), at: 0))
        }
        XCTAssertThrowsError(try controller(profile: "missing"))
        XCTAssertThrowsError(try controller(bitrate: 3_000_001))
        XCTAssertThrowsError(try QualityController(profiles: ladder, attemptID: attempt,
            applied: .init(profileID: "small", videoBitrate: 500_000), at: .nan))
    }

    func testHealthyStartupDoesNotImmediatelyIncrease() throws {
        var policy = try controller()
        let result = try policy.evaluate(window(), at: 5)
        XCTAssertEqual(result.state, .healthy)
        XCTAssertNil(result.recommendation)
        XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
    }

    func testEachFreshFrameBoundaryBelow24PromptsReduction() throws {
        for counts in [(119, 150, 150), (150, 119, 150), (150, 150, 119)] {
            var policy = try controller()
            let result = try policy.evaluate(window(capture: counts.0, encoded: counts.1, received: counts.2), at: 5)
            XCTAssertEqual(result.state, .degraded)
            XCTAssertTrue(result.reasons.contains(.freshFrameFloor))
            XCTAssertEqual(result.recommendation?.settings.videoBitrate, 1_600_000)
            XCTAssertEqual(policy.applied.videoBitrate, 2_000_000, "A recommendation is not an applied change")
        }
        var policy = try controller()
        XCTAssertEqual(try policy.evaluate(window(received: 120), at: 5).state, .healthy)
    }

    func testSourceLossQueueCapacityAndPressureEachReducePromptly() throws {
        let bad = [window(loss: .init(expectedFrames: 150, lostFrames: 2)), window(queue: 0.75),
                   window(capacity: 2_400_000), window(thermal: .elevated), window(worker: .elevated)]
        let reasons: [QualityController.Reason] = [.sourceLoss, .queuePressure, .capacityHeadroom, .thermalPressure, .workerPressure]
        for (sample, reason) in zip(bad, reasons) {
            var policy = try controller()
            let result = try policy.evaluate(sample, at: 5)
            XCTAssertEqual(result.state, .degraded)
            XCTAssertTrue(result.reasons.contains(reason))
            XCTAssertLessThan(try XCTUnwrap(result.recommendation).settings.videoBitrate, 2_000_000)
        }
    }

    func testDownshiftRespectsSupportedProfileAndBitrateBounds() throws {
        var policy = try controller(bitrate: 1_500_000)
        let result = try policy.evaluate(window(received: 100), at: 5)
        XCTAssertEqual(result.recommendation?.settings, .init(profileID: "small", videoBitrate: 1_000_000))
        var capped = try controller(profile: "small", bitrate: 600_000)
        XCTAssertEqual(try capped.evaluate(window(received: 100), at: 5).recommendation?.settings.videoBitrate, 500_000)
    }

    func testOverlappingProfileRangesNeverRaiseBitrateOnDownshift() throws {
        let profiles: [QualityController.Profile] = [
            .init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 3_000_000),
            .init(id: "large", width: 1280, height: 720, minimumBitrate: 1_500_000, maximumBitrate: 6_000_000)]
        var policy = try QualityController(profiles: profiles, attemptID: attempt,
            applied: .init(profileID: "large", videoBitrate: 1_500_000), at: 0)
        let result = try policy.evaluate(window(received: 100), at: 5)
        XCTAssertEqual(result.recommendation?.settings, .init(profileID: "small", videoBitrate: 1_200_000))
    }

    func testExpiredRecommendationsAndFailedLateAcknowledgmentPreserveAppliedTruth() throws {
        for actual in [QualityController.Settings(profileID: "medium", videoBitrate: 1_600_000), nil] {
            var policy = try controller()
            let proposal = try XCTUnwrap(policy.evaluate(window(received: 100), at: 5).recommendation)
            XCTAssertThrowsError(try policy.acknowledge(proposal, applied: actual, at: 100))
            XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
            XCTAssertEqual(policy.appliedRevision, 0)
        }
        var current = try controller()
        let proposal = try XCTUnwrap(current.evaluate(window(received: 100), at: 5).recommendation)
        try current.acknowledge(proposal, applied: proposal.settings, at: 7)
        XCTAssertEqual(current.applied.videoBitrate, 1_600_000, "Two-second freshness boundary is inclusive")
    }

    func testMinimumProfileInsufficiencyAndOutageRemainExplicit() throws {
        var policy = try controller(profile: "small", bitrate: 500_000)
        let insufficient = try policy.evaluate(window(capacity: 100_000), at: 5)
        XCTAssertEqual(insufficient.state, .insufficient)
        XCTAssertTrue(insufficient.reasons.contains(.minimumProfileInsufficient))
        XCTAssertNil(insufficient.recommendation)
        XCTAssertEqual(try policy.evaluate(window(5, connectivity: .disconnected), at: 10).state, .disconnected)
        XCTAssertEqual(try policy.evaluate(window(10, received: 0), at: 15).state, .stalled)
    }

    func testUnknownOrStaleEvidenceNeverEstablishesHealthOrRecovery() throws {
        let unknown = [window(capture: nil), window(encoded: nil), window(received: nil), window(capacity: nil),
                       window(queue: nil), window(loss: nil), window(connectivity: .unknown),
                       window(thermal: .unknown), window(worker: .unknown), window(receiverAt: 0)]
        for sample in unknown {
            var policy = try controller()
            XCTAssertEqual(try policy.evaluate(sample, at: 5).state, .unknown)
        }
        var policy = try controller()
        for start in stride(from: 0.0, to: 40, by: 5) {
            let result = try policy.evaluate(window(start, capacity: nil), at: start + 5)
            XCTAssertNil(result.recommendation)
        }
    }

    func testExactly30ContinuousQualifiedSecondsAndCandidateCapacityRequired() throws {
        var policy = try controller()
        for start in 0..<30 {
            let result = try policy.evaluate(window(Double(start), duration: 1, capture: 30, encoded: 30, received: 30), at: Double(start + 1))
            if start < 29 { XCTAssertNil(result.recommendation) }
            else { XCTAssertEqual(result.recommendation?.settings.videoBitrate, 2_200_000) }
        }
        var limited = try controller()
        for start in stride(from: 0.0, to: 40, by: 5) {
            // Enough for current rate, insufficient for proposed 2.2 Mbps + headroom.
            XCTAssertNil(try limited.evaluate(window(start, capacity: 2_600_000), at: start + 5).recommendation)
        }
    }

    func testRecoveryTargetsNextSupportedProfileAndNeverExceedsLadder() throws {
        var policy = try controller(profile: "small", bitrate: 1_000_000)
        var recommendation: QualityController.Recommendation?
        for start in stride(from: 0.0, to: 30, by: 5) {
            recommendation = try policy.evaluate(window(start), at: start + 5).recommendation
        }
        XCTAssertEqual(recommendation?.settings, .init(profileID: "medium", videoBitrate: 1_500_000))
        var highest = try controller(profile: "large", bitrate: 6_000_000)
        for start in stride(from: 0.0, to: 35, by: 5) {
            XCTAssertNil(try highest.evaluate(window(start), at: start + 5).recommendation)
        }
    }

    func testOutageUnknownPressureAndGapsResetRecoveryHistory() throws {
        for interruption in [window(25, connectivity: .disconnected), window(25, received: nil), window(25, thermal: .elevated)] {
            var policy = try controller()
            for start in stride(from: 0.0, to: 25, by: 5) { _ = try policy.evaluate(window(start), at: start + 5) }
            _ = try policy.evaluate(interruption, at: 30)
            for start in stride(from: 30.0, to: 55, by: 5) {
                XCTAssertNil(try policy.evaluate(window(start), at: start + 5).recommendation)
            }
            XCTAssertNotNil(try policy.evaluate(window(55), at: 60).recommendation)
        }
        var gap = try controller()
        for start in stride(from: 0.0, to: 25, by: 5) { _ = try gap.evaluate(window(start), at: start + 5) }
        let result = try gap.evaluate(window(26), at: 31)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.reasons.contains(.telemetryGap))
    }

    func testAppliedAcknowledgmentIsSeparateAndOldRevisionCannotAccumulate() throws {
        var policy = try controller()
        let recommendation = try XCTUnwrap(policy.evaluate(window(received: 100), at: 5).recommendation)
        XCTAssertEqual(policy.appliedRevision, 0)
        try policy.acknowledge(recommendation, applied: recommendation.settings, at: 5)
        XCTAssertEqual(policy.applied.videoBitrate, 1_600_000)
        XCTAssertEqual(policy.appliedRevision, 1)
        XCTAssertThrowsError(try policy.evaluate(window(5), at: 10))
        XCTAssertNil(try policy.evaluate(window(5, sequence: 7, revision: 1), at: 10).recommendation)
        XCTAssertThrowsError(try policy.acknowledge(recommendation, applied: recommendation.settings, at: 10))
    }

    func testFailedApplicationDoesNotChangeActualSettings() throws {
        var policy = try controller()
        let recommendation = try XCTUnwrap(policy.evaluate(window(received: 100), at: 5).recommendation)
        try policy.acknowledge(recommendation, applied: nil, at: 5)
        XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
        XCTAssertEqual(policy.appliedRevision, 0)
    }

    func testSupersededIncreaseCannotBeAcknowledgedAfterNewUnhealthyOrUnknownWindow() throws {
        for bad in [window(30, received: 100), window(30, received: nil), window(30, connectivity: .disconnected)] {
            var policy = try controller()
            var proposal: QualityController.Recommendation?
            for start in stride(from: 0.0, to: 30, by: 5) { proposal = try policy.evaluate(window(start), at: start + 5).recommendation }
            _ = try policy.evaluate(bad, at: 35)
            let stale = try XCTUnwrap(proposal)
            XCTAssertThrowsError(try policy.acknowledge(stale, applied: stale.settings, at: 35))
            XCTAssertEqual(policy.applied.videoBitrate, 2_000_000)
        }
    }

    func testRejectsIncompleteOverlappingDuplicateStaleAndCrossAttemptWindows() throws {
        let invalid = [window(duration: 0), window(duration: 6), window(capture: -1), window(queue: 1.1),
                       window(capacity: .nan), window(receiverAt: 7), window(loss: .init(expectedFrames: 1, lostFrames: 2))]
        for sample in invalid { var policy = try controller(); XCTAssertThrowsError(try policy.evaluate(sample, at: 6)) }
        var policy = try controller()
        _ = try policy.evaluate(window(), at: 5)
        for sample in [window(), window(4), window(5, sequence: 1), window(5, attemptID: UUID())] {
            XCTAssertThrowsError(try policy.evaluate(sample, at: 10))
        }
        XCTAssertThrowsError(try policy.evaluate(window(5), at: 9), "Incomplete window")
        XCTAssertThrowsError(try policy.evaluate(window(5), at: 20), "Stale complete window")
        XCTAssertThrowsError(try policy.evaluate(window(5), at: 4), "Caller time reversal")
    }

    func testRejectedInputsStillAdvanceTheMonotonicWatermark() throws {
        var staleWindow = try controller()
        _ = try staleWindow.evaluate(window(), at: 5)
        XCTAssertThrowsError(try staleWindow.evaluate(window(5), at: 100))
        XCTAssertThrowsError(try staleWindow.evaluate(window(5), at: 10)) { error in
            XCTAssertEqual(error as? QualityController.ValidationError, .invalidTime)
        }

        var expiredAdvice = try controller()
        let advice = try XCTUnwrap(expiredAdvice.evaluate(window(received: 100), at: 5).recommendation)
        XCTAssertThrowsError(try expiredAdvice.acknowledge(advice, applied: advice.settings, at: 100))
        XCTAssertThrowsError(try expiredAdvice.evaluate(window(5), at: 10)) { error in
            XCTAssertEqual(error as? QualityController.ValidationError, .invalidTime)
        }
        XCTAssertEqual(expiredAdvice.applied.videoBitrate, 2_000_000)

        var wrongIdentity = try controller()
        XCTAssertThrowsError(try wrongIdentity.acknowledge(advice, applied: nil, at: 100))
        XCTAssertThrowsError(try wrongIdentity.evaluate(window(), at: 5)) { error in
            XCTAssertEqual(error as? QualityController.ValidationError, .invalidTime)
        }
    }

    func testInvalidClockValuesCannotPoisonTheWatermark() throws {
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1] {
            var policy = try controller()
            XCTAssertThrowsError(try policy.evaluate(window(), at: invalid))
            let advice = try XCTUnwrap(policy.evaluate(window(received: 100), at: 5).recommendation)
            XCTAssertThrowsError(try policy.acknowledge(advice, applied: advice.settings, at: invalid))
            try policy.acknowledge(advice, applied: nil, at: 5)
            XCTAssertEqual(try policy.evaluate(window(5), at: 10).state, .healthy)
        }
    }

    func testExtremeSupportedBitrateRecoveryClampsBeforeIntegerConversion() throws {
        let profile = QualityController.Profile(id: "extreme", width: 1920, height: 1080,
            minimumBitrate: 1_500_000_000, maximumBitrate: Int(Int32.max))
        var policy = try QualityController(profiles: [profile], attemptID: attempt,
            applied: .init(profileID: profile.id, videoBitrate: 2_000_000_000), at: 0)
        var advice: QualityController.Recommendation?
        for start in stride(from: 0.0, to: 30, by: 5) {
            advice = try policy.evaluate(window(start, capacity: 4_000_000_000), at: start + 5).recommendation
        }
        XCTAssertEqual(advice?.settings.videoBitrate, Int(Int32.max))
        // The unbounded 10% proposal is 2.2 billion, beyond watchOS arm64_32 Int.
        // This same regression can run on that architecture without a conversion trap.
    }

    func testAcknowledgmentRejectsCrossAttemptAndReversedTime() throws {
        var first = try controller()
        let proposal = try XCTUnwrap(first.evaluate(window(received: 100), at: 5).recommendation)
        XCTAssertThrowsError(try first.acknowledge(proposal, applied: proposal.settings, at: 4))
        var other = try QualityController(profiles: ladder, attemptID: UUID(), applied: first.applied, at: 0)
        XCTAssertThrowsError(try other.acknowledge(proposal, applied: proposal.settings, at: 5))
        XCTAssertEqual(first.applied.videoBitrate, 2_000_000)
    }
}

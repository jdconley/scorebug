import Foundation
import ScorebugCore
import XCTest

final class StreamingTimingProfileTests: XCTestCase {
    private typealias Q = QualityController
    private let attempt = UUID()
    private let baseline = Q.Settings(profileID: "small", videoBitrate: 500_000)
    private func controller(_ timing: StreamingTimingProfile) throws -> Q {
        try Q(profiles: [.init(id: "small", width: 640, height: 360, minimumBitrate: 500_000, maximumBitrate: 1_000_000)],
              attemptID: attempt, applied: baseline, at: 0, recoveryStrategy: .measuredCandidateTrials,
              behavior: .progressive, timingProfile: timing)
    }
    private func health(observed: Double) -> Q.Window {
        .init(attemptID: attempt, sequence: 1, appliedRevision: 0, start: 0, end: 4,
              capturedFreshFrames: 120, encodedFreshFrames: 120, receiver: .init(freshFrames: 120, observedAt: observed),
              sourceLoss: .init(expectedFrames: 120, lostFrames: 0), meanQueueOccupancy: 0.1,
              usableVideoCapacity: nil, connectivity: .connected, thermalPressure: .nominal,
              workerPressure: .nominal, transportPressure: .nominal)
    }
    func testSharedHostNativeContractTable() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "streaming-timing-contracts", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(rows.count, StreamingTimingProfile.allCases.count)
        for row in rows {
            let timing = try XCTUnwrap(StreamingTimingProfile(rawValue: try XCTUnwrap(row["profileId"] as? String)))
            XCTAssertEqual(row["decoderBudgetMs"] as? Int, timing.decoderBudgetMs)
            XCTAssertEqual(row["maximumCaptureWindowEvaluationAgeMs"] as? Int, timing.maximumCaptureWindowEvaluationAgeMs)
            if timing != .strict1500 { XCTAssertEqual(row as NSDictionary, timing.evidence as NSDictionary?) }
            else { XCTAssertNil(timing.evidence) }
        }
    }
    func testMediaAgeBoundariesDoNotExtendReportAgeOrRefreshByReading() throws {
        for profile in StreamingTimingProfile.allCases {
            let maximum = profile.maximumCaptureWindowEvaluationAge
            var policy = try controller(profile)
            let now = 4 + maximum
            _ = try policy.evaluate(health(observed: now), at: now)
            XCTAssertEqual(policy.candidateMeasurementReadiness(at: now)?.validUntil, now)
            XCTAssertNil(policy.candidateMeasurementReadiness(at: now + 0.000001))
            var expired = try controller(profile)
            XCTAssertThrowsError(try expired.evaluate(health(observed: now + 0.000001), at: now + 0.000001))
            var staleReport = try controller(profile)
            XCTAssertNil(try staleReport.evaluate(health(observed: now - 2.000001), at: now).recommendation)
            XCTAssertNil(staleReport.candidateMeasurementReadiness(at: now))
        }
    }
    func testScheduleBudgetPlusQuarterSecondFitsMediaAgeButDoesNotRelaxFailureAuthority() throws {
        for profile in StreamingTimingProfile.allCases {
            let now = 1 + profile.decoderBudget + 0.25
            XCTAssertLessThan(now - 1, profile.maximumCaptureWindowEvaluationAge)
            func failure(observed: Double, revision: UInt64 = 0) -> Q.DeliveryFailure {
                .init(attemptID: attempt, appliedRevision: revision, sequence: 1, start: 0, end: 1,
                      expectedFrames: 30, onTimeFrames: 23, lateFrames: 0, missingFrames: 7, observedAtLowerBound: observed)
            }
            var policy = try controller(profile)
            XCTAssertNoThrow(try policy.evaluateDeliveryFailure(failure(observed: now), at: now))
            var stale = try controller(profile)
            XCTAssertThrowsError(try stale.evaluateDeliveryFailure(failure(observed: now - 0.250001), at: now))
            var wrong = try controller(profile)
            XCTAssertThrowsError(try wrong.evaluateDeliveryFailure(failure(observed: now, revision: 1), at: now))
        }
    }
    func testExperimentalMediaAgeNeverExtendsCandidateResultOrProbeExpiry() throws {
        for timing in [StreamingTimingProfile.broadcastReliability2000, .broadcastReliability3000] {
            for now in [6.000001, 6.1] {
                var policy = try controller(timing)
                _ = try policy.evaluate(health(observed: now), at: now)
                let candidate = Q.CandidateAdmission(id: UUID(), attemptID: attempt, appliedRevision: 0,
                    baseline: baseline, settings: .init(profileID: "small", videoBitrate: 550_000),
                    measuredStart: 3, measuredEnd: 4, evaluatedAt: 4.5, validUntil: 6,
                    candidateTransportBitsPerSecond: 1_000_000, deliveredPaddingBitsPerSecond: 1_250_000)
                XCTAssertThrowsError(try policy.evaluateCandidate(candidate, at: now)) {
                    XCTAssertEqual($0 as? Q.ValidationError, .staleWindow)
                }
            }
        }
    }
    func testExperimentalCaptureAllowanceDoesNotExtendLocalPressureAge() throws {
        for timing in StreamingTimingProfile.allCases {
            var policy = try controller(timing)
            let pressure = Q.Window(attemptID: attempt, sequence: 1, appliedRevision: 0, start: 0, end: 1,
                capturedFreshFrames: nil, encodedFreshFrames: nil, receiver: nil, sourceLoss: nil,
                meanQueueOccupancy: 0.8, usableVideoCapacity: nil, connectivity: .unknown,
                thermalPressure: .nominal, workerPressure: .unknown, transportPressure: .nominal)
            XCTAssertThrowsError(try policy.evaluateLocalPressure(pressure, at: 3.000001))
        }
    }
    func testFreshReportAllowsOlderMediaOnlyOnExperimentalProfilesAndRevocationWins() throws {
        for profile in StreamingTimingProfile.allCases {
            var policy = try controller(profile)
            if profile == .strict1500 {
                XCTAssertThrowsError(try policy.evaluate(health(observed: 6.1), at: 6.1))
            } else {
                _ = try policy.evaluate(health(observed: 6.1), at: 6.1)
                XCTAssertNotNil(policy.candidateMeasurementReadiness(at: 6.1))
                policy.invalidateTelemetry()
                XCTAssertNil(policy.candidateMeasurementReadiness(at: 6.1))
            }
        }
        XCTAssertEqual(Q.maximumApplicationDuration, 2)
        XCTAssertEqual(Q.maximumCandidateMeasurementDuration, 7)
        XCTAssertEqual(Q.maximumTrialDuration, 22.5)
    }
}

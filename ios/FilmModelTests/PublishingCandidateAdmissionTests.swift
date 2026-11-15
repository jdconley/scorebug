import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest
@testable import SRTHaishinKit

final class PublishingCandidateAdmissionTests: XCTestCase {
    private let anchor = ContinuousClock.now
    enum Fault: CaseIterable {
        case staleCost, futureCost, wrongAttempt, wrongMatch, wrongGeneration, wrongRate, wrongProbe
        case wrongStage, wrongReceipt, wrongRevision, invalidClock, reversedClock, lateBinding, earlyCompletion
        case revokedAuthority, revokedProbe, expiredLease, oldReceiver, noOverlap, beforeCompletion, exactCompletion
    }
    struct Fixture {
        var measurement: PublishingCandidateAdmission.Measurement
        var applied: PublishingQualityTelemetry.Applied
        var binding: PublishingProbeObservation
        var boundAt: Double
        var completedAt: Double
        var probe: PublishingProbeObservation
        var pair: WorkerReceiverProbeIntervalPair
        var authority: PublishingCandidateAuthority
        var clock: PublishingCandidateAdmission.Clock
        var currentReceipt: PublishingBitRateChange
        func admit(production: Bool = false, observeValidation: ((String) -> Void)? = nil, candidateIsCurrent: @escaping @Sendable () -> Bool = { true }) -> PublishingCandidateAdmission? {
            let receipt = currentReceipt
            let admit = production ? PublishingCandidateAdmission.productionSRT : PublishingCandidateAdmission.laboratoryIPv4
            return admit(measurement, applied, binding, boundAt, completedAt, probe, pair, authority, clock, { receipt }, candidateIsCurrent, observeValidation)
        }
    }
    func testValidationDiagnosticIdentifiesRejectedGroupWithoutChangingAdmission() throws {
        for (fault, expected) in [(Fault.staleCost, "measurement"), (.wrongMatch, "scope-receipt"),
            (.revokedAuthority, "receiver-authority"), (.expiredLease, "probe"), (.noOverlap, "receiver-time-bounds")] {
            var gate: String?
            XCTAssertNil(try fixture(fault).admit(production: true, observeValidation: { gate = $0 }))
            XCTAssertEqual(gate, expected)
        }
        var gate: String?
        XCTAssertNotNil(try fixture().admit(production: true, observeValidation: { gate = $0 }))
        XCTAssertEqual(gate, "admitted")
    }
    private func fixture(_ fault: Fault? = nil, campaign: UInt32? = nil) throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/receiver-probe-status-v1.json")
        let template = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
        let attempt = try XCTUnwrap(UUID(uuidString: template.status.publication!.publishingAttemptId))
        let probeID = try XCTUnwrap(UUID(uuidString: template.status.receiverProbe!.snapshot.id))
        var tracker = WorkerReceiverProbeTracker()
        let endpoint = fault == .oldReceiver ? 113.0 : fault == .beforeCompletion ? 114.0 : 115.0
        for (time, messages) in [(endpoint - 2, 100), (endpoint - 1, 1150), (endpoint, 2250)] {
            var response = template
            var p = response.status.receiverProbe!.snapshot
            p.publishingGeneration = "7"; p.convention = "mpegts-null-probe-v2"; p.stage = 3; p.bitRate = 12_000_000
            p.deliveredMessages = String(messages); p.deliveredPayloadBytes = String(messages * 1316)
            p.totalDeliveredPayloadBytes = p.deliveredPayloadBytes; p.nextSequence = p.deliveredMessages
            if let campaign { p.convention = "mpegts-null-probe-v3"; p.campaign = String(campaign); p.campaignDeliveredPayloadBytes = p.deliveredPayloadBytes }
            p.pendingPackets = 0; p.observedAtNanoseconds = String(Int64(time * 1e9))
            p.firstDeliveredAtNanoseconds = String(Int64((endpoint - 4.5) * 1e9)); p.lastDeliveredAtNanoseconds = String(Int64((time - 0.01) * 1e9))
            response.status.receiverProbe = .init(snapshot: p, ageUpperBoundMs: 10)
            let evidence = try XCTUnwrap(WorkerReceiverProbeFreshness(response: response,
                expected: .init(gameId: "match", generation: 2, workerId: "mac", publishingAttemptId: attempt.uuidString.lowercased(),
                    probeId: probeID.uuidString.lowercased(), publishingGeneration: 7, bitRate: 12_000_000, stage: 3, campaign: campaign),
                receivedAt: anchor + .seconds(time), requestDuration: .milliseconds(10)))
            tracker.observe(evidence, acceptedPayloadBytes: UInt64(messages * 1316), senderActive: true, at: anchor + .seconds(time))
        }
        let pair = try XCTUnwrap(tracker.latestPair)
        let authority = PublishingCandidateAuthority(pair.newer.end)
        if fault == .revokedAuthority { authority.revoke() }
        let config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 350_000))
        let receipt = try XCTUnwrap(PublishingBitRateChange(publishingGeneration: 7, configuration: config, acceptedAt: 100, lastSubmittedSourcePTS: .zero))
        let other = try XCTUnwrap(PublishingBitRateChange(publishingGeneration: 7,
            configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: config.encoderSessionID, bitRate: 350_000)!, acceptedAt: 100.1, lastSubmittedSourcePTS: .zero))
        let applied = PublishingQualityTelemetry.Applied(attemptID: attempt, revision: 0,
            settings: .init(profileID: "240p30", videoBitrate: 350_000), receipt: receipt, acknowledgedAt: 100)
        let exactCompletion = 115.1 + PublishingCandidateAdmission.Clock.seconds((anchor + .seconds(115.1)).duration(to: pair.newer.endBounds.lowerBound))
        let measurement = PublishingCandidateAdmission.Measurement(id: UUID(),
            scope: .init(recordingID: "recording", matchID: fault == .wrongMatch ? "other" : "match", broadcastGeneration: 2,
                publishingAttemptID: fault == .wrongAttempt ? UUID() : attempt, appliedProfileRevision: 1),
            profile: .low360, publishingGeneration: fault == .wrongGeneration ? 8 : 7,
            startedAt: 110, endedAt: fault == .staleCost ? 112 : fault == .futureCost ? 116 : fault == .exactCompletion ? exactCompletion : 114.06,
            firstInputAt: 110, lastInputAt: fault == .noOverlap ? 112.5 : 114,
            sourceDuration: 4, submissionDuration: 4, transportBytes: 376000, transportMessageCount: 400)
        let binding = PublishingProbeObservation(id: probeID, publishingGeneration: 7, bitRate: 12_000_000,
            startedAt: 109, leaseDeadline: 109.9, acceptedPayloadBytes: 131600, lastAcceptedAt: 109.59,
            reason: nil, stage: 3, campaign: campaign, permitsCurrentOwner: { _, _, _, _ in true })
        let probe = PublishingProbeObservation(id: fault == .wrongProbe ? UUID() : probeID, publishingGeneration: 7,
            bitRate: fault == .wrongRate ? 2_000_000 : 12_000_000, startedAt: 109,
            leaseDeadline: fault == .expiredLease ? 115 : 115.3, acceptedPayloadBytes: 6_000 * 1316,
            lastAcceptedAt: 115.09, reason: nil, stage: fault == .wrongStage ? 2 : 3, campaign: campaign,
            permitsCurrentOwner: { _, _, _, _ in fault != .revokedProbe })
        var f = Fixture(measurement: measurement, applied: applied, binding: binding,
            boundAt: fault == .lateBinding ? 111 : 109.6,
            completedAt: fault == .earlyCompletion ? 113 : fault == .exactCompletion ? exactCompletion + 0.01 : 114.07,
            probe: probe, pair: pair, authority: authority,
            clock: .init(before: fault == .invalidClock ? .nan : fault == .reversedClock ? 116 : 115.1,
                instant: anchor + .seconds(115.1), after: 115.1), currentReceipt: fault == .wrongReceipt ? other : receipt)
        // A changed policy revision has no effect until rechecking an existing admission.
        if fault == .wrongRevision { f.applied.revision = 1 }
        return f
    }
    func testProductionCostsCompleteTransportMessagesWithoutExportingLaboratoryWitness() throws {
        for (bytes, messages, duration) in [(188 * 400, 400, 4.0), (1316 * 400, 400, 4.0), (376000, 400, 3.5), (376000, 400, 4.5)] {
            var f = try fixture()
            let m = f.measurement
            f.measurement = .init(id: m.id, scope: m.scope, profile: m.profile, publishingGeneration: m.publishingGeneration,
                startedAt: m.startedAt, endedAt: m.endedAt, firstInputAt: m.firstInputAt, lastInputAt: m.lastInputAt,
                sourceDuration: m.sourceDuration, submissionDuration: duration, transportBytes: bytes, transportMessageCount: messages)
            let production = try XCTUnwrap(f.admit(production: true)), laboratory = try XCTUnwrap(f.admit())
            XCTAssertEqual(production.value.candidateTransportBitsPerSecond, Double(bytes + 64 * messages) * 8 / min(4, duration), accuracy: 1e-6)
            XCTAssertEqual(laboratory.value.candidateTransportBitsPerSecond, Double(bytes + 44 * messages) * 8 / min(4, duration), accuracy: 1e-6)
            XCTAssertEqual(production.value.deliveredPaddingBitsPerSecond,
                min(f.pair.older.payloadBitsPerSecondLowerBound, f.pair.newer.payloadBitsPerSecondLowerBound))
            XCTAssertThrowsError(try production.auditData(), "Production cannot export the legacy IPv4 laboratory witness")
            XCTAssertNoThrow(try laboratory.auditData())
        }
    }
    func testBothConventionsRejectInvalidCompleteTransportAccounting() throws {
        for (bytes, messages) in [(0, 1), (189, 1), (188, 0), (188, 2), (1504, 1), (188, 250001), (Int.max, Int.max)] {
            var f = try fixture()
            let m = f.measurement
            f.measurement = .init(id: m.id, scope: m.scope, profile: m.profile, publishingGeneration: m.publishingGeneration,
                startedAt: m.startedAt, endedAt: m.endedAt, firstInputAt: m.firstInputAt, lastInputAt: m.lastInputAt,
                sourceDuration: m.sourceDuration, submissionDuration: m.submissionDuration, transportBytes: bytes, transportMessageCount: messages)
            XCTAssertNil(f.admit())
            XCTAssertNil(f.admit(production: true))
        }
    }

    func testProductionSharesInvalidEvidenceAndRevocationGuards() throws {
        for fault in Fault.allCases where fault != .wrongRevision {
            XCTAssertNil(try fixture(fault).admit(production: true), "\(fault)")
        }
        let f = try fixture(), token = CandidateAdmissionTestToken()
        let admission = try XCTUnwrap(f.admit(production: true, candidateIsCurrent: { token.isCurrent }))
        token.revoke()
        XCTAssertNil(f.admit(production: true, candidateIsCurrent: { token.isCurrent }))
        XCTAssertFalse(admission.permits(applied: f.applied, at: 115.1, instant: anchor + .seconds(115.1)))
    }

    func testCandidateBindingMustRespectHalfSecondProbeWarmup() throws {
        var f = try fixture()
        f.binding.lastAcceptedAt = 109.49
        f.binding.leaseDeadline = 109.7
        f.boundAt = 109.5
        XCTAssertNotNil(f.admit(), "The exact warmup boundary remains admissible")
        f.boundAt = 109.499
        XCTAssertTrue(f.binding.isActive(at: f.boundAt))
        XCTAssertNil(f.admit(), "An active probe alone cannot admit a prematurely bound measurement")
    }

    func testRecoveryPolicyCannotChangeAcrossCandidateBindingAndAuditRetainsEvidence() throws {
        var f = try fixture()
        func recovery(_ value: PublishingProbeObservation, at: Double) -> PublishingProbeObservation {
            var value = value
            value.policy = .recoveryBudget
            value.recoveryObservation = .init(checkedAt: at, sampledAt: at, elapsedMilliseconds: Int64(at * 1000),
                sentBytes: 20_000_000, retransmittedBytes: 1000, droppedPackets: 0,
                rttMilliseconds: 65, senderBufferMilliseconds: 67, senderDeliveryDelayMilliseconds: 400)
            return value
        }
        f.binding = recovery(f.binding, at: 109.59)
        XCTAssertTrue(f.binding.isActive(at: f.boundAt))
        XCTAssertNil(f.admit(), "Recovery binding cannot borrow a legacy current owner")
        f = try fixture(); f.probe = recovery(f.probe, at: 115.08)
        XCTAssertTrue(f.probe.isActive(at: f.clock.after))
        XCTAssertNil(f.admit(), "Legacy binding cannot borrow a recovery owner")
        f.binding = recovery(f.binding, at: 109.59)
        let admission = try XCTUnwrap(f.admit())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: admission.auditData()) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        XCTAssertEqual(object["convention"] as? String, "measured-candidate-ipv4-recovery-v1")
        for field in ["binding", "probe"] {
            let probe = try XCTUnwrap(object[field] as? [String: Any])
            XCTAssertEqual(probe["policy"] as? String, "recovery-budget-v1")
            XCTAssertEqual((probe["recoveryObservation"] as? [String: Any])?["senderDeliveryDelayMilliseconds"] as? Int, 400)
        }
        let legacy = try XCTUnwrap(try fixture().admit())
        let old = try XCTUnwrap(try JSONSerialization.jsonObject(with: legacy.auditData()) as? [String: Any])
        XCTAssertEqual(old["formatVersion"] as? Int, 1)
        XCTAssertNil((old["probe"] as? [String: Any])?["policy"])
    }
    func testCampaignAdmissionRequiresExactBindingCurrentAndReceiverIdentity() throws {
        for ordinal: UInt32? in [nil, 1, UInt32.max] {
            let valid = try fixture(campaign: ordinal)
            XCTAssertNotNil(valid.admit())
            for other: UInt32? in [nil, 1, 2, UInt32.max] where other != ordinal {
                var changedBinding = valid; changedBinding.binding.campaign = other
                XCTAssertNil(changedBinding.admit(), "changed binding campaign")
                var changedCurrent = valid; changedCurrent.probe.campaign = other
                XCTAssertNil(changedCurrent.admit(), "changed current campaign")
                var changedBoth = valid
                changedBoth.binding.campaign = other; changedBoth.probe.campaign = other
                XCTAssertNil(changedBoth.admit(), "campaign differs from receiver")
            }
        }
    }
    func testCampaignAuditRetainsFullWidthIdentityAndLegacyOmitsIt() throws {
        for ordinal: UInt32? in [nil, UInt32.max] {
            let admission = try XCTUnwrap(try fixture(campaign: ordinal).admit())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: admission.auditData()) as? [String: Any])
            for field in ["binding", "probe"] {
                let probe = try XCTUnwrap(object[field] as? [String: Any])
                XCTAssertEqual(probe["campaign"] as? String, ordinal.map(String.init))
                if ordinal == nil { XCTAssertNil(probe["campaign"]) }
            }
            let intervals = try XCTUnwrap(object["intervals"] as? [[String: Any]])
            for interval in intervals {
                let end = try XCTUnwrap(interval["end"] as? [String: Any])
                let expected = try XCTUnwrap(end["expected"] as? [String: Any])
                XCTAssertEqual(expected["campaign"] as? String, ordinal.map(String.init))
                if ordinal == nil { XCTAssertNil(expected["campaign"]) }
            }
        }
    }
    func testCurrentPairProducesActualAccountedCostAndShortLease() throws {
        let f = try fixture(), admission = try XCTUnwrap(f.admit())
        XCTAssertEqual(admission.value.candidateTransportBitsPerSecond, 787200, accuracy: 1e-6)
        XCTAssertEqual(admission.value.deliveredPaddingBitsPerSecond, 11_054_400, accuracy: 1e-6)
        XCTAssertEqual(admission.value.validUntil, 115.3, accuracy: 1e-6)
        XCTAssertTrue(admission.permits(applied: f.applied, at: 115.1, instant: anchor + .seconds(115.1)))
    }
    func testInvalidIdentityCoverageAndFreshnessNeverAuthorizes() throws {
        for fault in Fault.allCases where fault != .wrongRevision {
            XCTAssertNil(try fixture(fault).admit(), "\(fault)")
        }
    }
    func testRevocationLeaseExpiryAndChangedRevisionRejectPreviouslyAdmittedEvidence() throws {
        let f = try fixture(), admission = try XCTUnwrap(f.admit())
        var changed = f.applied; changed.revision += 1
        XCTAssertFalse(admission.permits(applied: changed, at: 115.1, instant: anchor + .seconds(115.1)))
        XCTAssertFalse(admission.permits(applied: f.applied, at: 115.31, instant: anchor + .seconds(115.31)))
        f.authority.revoke()
        XCTAssertFalse(admission.permits(applied: f.applied, at: 115.1, instant: anchor + .seconds(115.1)))
    }
    func testCandidateRevocationInvalidatesBothNewAndPreviouslyAdmittedEvidence() throws {
        let f = try fixture(), token = CandidateAdmissionTestToken()
        let admission = try XCTUnwrap(f.admit(candidateIsCurrent: { token.isCurrent }))
        token.revoke()
        XCTAssertNil(f.admit(candidateIsCurrent: { token.isCurrent }))
        XCTAssertFalse(admission.permits(applied: f.applied, at: 115.1, instant: anchor + .seconds(115.1)))
    }
    func testAuditFreezesTheExactAdmissionPairAndNativeBinding() throws {
        let f = try fixture(), admission = try XCTUnwrap(f.admit())
        let data = try admission.auditData()
        XCTAssertLessThan(data.count, 32 * 1024)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["convention"] as? String, "measured-candidate-ipv4-v1")
        let measurement = try XCTUnwrap(object["measurement"] as? [String: Any])
        XCTAssertEqual(measurement["id"] as? String, f.measurement.id.uuidString.lowercased())
        XCTAssertEqual(measurement["transportBytes"] as? Int, f.measurement.transportBytes)
        XCTAssertEqual(measurement["transportMessageCount"] as? Int, f.measurement.transportMessageCount)
        XCTAssertEqual(measurement["submissionDuration"] as? Double, 4)
        let baseline = try XCTUnwrap(object["applied"] as? [String: Any])
        XCTAssertEqual(baseline["revision"] as? String, "0")
        let receipt = try XCTUnwrap(baseline["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["configurationID"] as? String, f.applied.receipt.configuration.id.uuidString.lowercased())
        let intervals = try XCTUnwrap(object["intervals"] as? [[String: Any]])
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0]["deliveredPayloadBytesLowerBound"] as? String, String(f.pair.older.deliveredPayloadBytesLowerBound))
        let end = try XCTUnwrap(intervals[1]["end"] as? [String: Any])
        let snapshot = try XCTUnwrap(end["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["observedAtNanoseconds"] as? String, f.pair.newer.end.snapshot.observedAtNanoseconds)
        let probe = try XCTUnwrap(object["probe"] as? [String: Any])
        XCTAssertEqual(probe["leaseDeadline"] as? Double, f.probe.leaseDeadline)
        XCTAssertEqual(object["boundAt"] as? Double, f.boundAt)
        XCTAssertEqual(object["completedAt"] as? Double, f.completedAt)
        // Later owner retirement cannot rewrite what was observed at admission.
        f.authority.revoke()
        XCTAssertEqual(try admission.auditData(), data)
    }
}

private final class CandidateAdmissionTestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isCurrent: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
}

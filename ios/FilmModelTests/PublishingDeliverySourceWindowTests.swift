import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming
import XCTest

final class PublishingDeliverySourceWindowTests: XCTestCase {
    private var bitRate = 350_000
    func testFailureAdapterKeepsStrictLossBoundaryAndRejectsUncertainty() throws {
        XCTAssertNil(try classify(missing: [40,41,42], late: []).failureSignal(sequence: 1))
        let value = try classify(missing: [40,41,42,43], late: [])
        let failure = try XCTUnwrap(value.failureSignal(sequence: 2))
        XCTAssertEqual(failure.expectedFrames, 60); XCTAssertEqual(failure.missingFrames, 4)
        XCTAssertEqual(failure.onTimeFrames, 56); XCTAssertEqual(failure.appliedRevision, 7)
        XCTAssertEqual(failure.observedAtLowerBound, 4.5); XCTAssertEqual(failure.sequence, 2)
        XCTAssertNil(try classify(missing: [], late: [], latency: 0.55, ageMs: 100, deadline: 0.5).failureSignal(sequence: 3))
    }
    private func deliveryOwner(_ native: DeadlineNative, behavior: QualityController.Behavior = .progressive, timingProfile: StreamingTimingProfile = .strict1500) throws -> PublishingQualitySession {
        try .init(operations: .init(setBitRate: { rate, _ in try native.write(rate) }, stop: { native.stop() },
            isPublishing: { native.isPublishing() }, videoStartup: { native.startup }),
            profiles: [.init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 700_000)],
            attemptID: session, initial: .init(profileID: "240p30", videoBitrate: bitRate),
            behavior: behavior, timingProfile: timingProfile, uptime: { native.now })
    }
    @MainActor func testDriverDeadlineClassificationAppliesMinimumAndExportsExactEvidence() async throws {
        bitRate = 700_000
        let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
        try await owner.bootstrap()
        var input: PublishingDeliveryMonitor.Input?
        _ = try classify(missing: Set(30..<60), late: [], revision: 0, profileID: "240p30",
            submittedBoundary: .zero, withAuthority: true, captureInput: { input = $0 }, deliveryInstant: .now)
        let current = try XCTUnwrap(input)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
            uptime: { native.now }, deliveryAudit: try .init(latencyBudget: 1.5, maximumSampleAge: 0.25),
            enableDeliveryFailures: true, export: { exported = $0 })
        driver.deliveryInputProvider = { current }
        native.setNow(0.5)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        native.setNow(4.75)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        XCTAssertEqual(native.calls, 2)
        let state = await owner.snapshot
        XCTAssertEqual(state.applied?.videoBitrate, 350_000)
        XCTAssertNil(state.lastWindow)
        XCTAssertEqual(state.lastDeliveryFailure?.onTimeFrames, 30)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        XCTAssertEqual(native.calls, 2, "Repeated evidence must not dispatch another reset")
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(json["deadlineFailuresEnabled"] as? Bool, true)
        XCTAssertEqual(json["decoderStallEnabled"] as? Bool, false)
        let row = try XCTUnwrap(events.first { $0["kind"] as? String == "deliveryFailure" })
        let evidence = try XCTUnwrap(row["deliveryFailure"] as? [String: Any])
        XCTAssertEqual(evidence["classifiedAt"] as? Double, 4.75)
        XCTAssertEqual(evidence["deliveryReceiptID"] as? String, current.delivery.receiptID.uuidString.lowercased())
        XCTAssertEqual(evidence["scopeID"] as? String, current.delivery.snapshot.scopeID)
        XCTAssertEqual(evidence["sequence"] as? String, "1")
        XCTAssertEqual(evidence["revision"] as? String, "0")
        XCTAssertEqual(evidence["start"] as? Double, 1)
        XCTAssertEqual(evidence["end"] as? Double, 3)
        XCTAssertEqual(evidence["missingFrames"] as? Int, 30)
        XCTAssertNotNil(evidence["context"])
        XCTAssertNil(row["window"])
        XCTAssertEqual((row["action"] as? [String: Any])?["bitRate"] as? Int, 350_000)
    }
    @MainActor func testDriverDeadlineChangesProfileAndAcknowledgesOneMinimumReset() async throws {
        bitRate = 1_500_000
        let native = DeadlineProfileNative(configuration: configuration)
        let owner = try PublishingQualitySession(operations: native.operations, profiles: [
            .init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000),
            .init(id: "540p30", width: 960, height: 540, minimumBitrate: 1_500_000, maximumBitrate: 1_500_000)
        ], attemptID: session, initial: .init(profileID: "540p30", videoBitrate: bitRate),
            behavior: .progressive, uptime: { native.now })
        try await owner.bootstrap()
        var input: PublishingDeliveryMonitor.Input?
        _ = try classify(missing: Set(60..<90), late: [], revision: 0, profileID: "540p30",
            submittedBoundary: .zero, withAuthority: true, captureInput: { input = $0 }, deliveryInstant: .now)
        let current = try XCTUnwrap(input)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
            uptime: { native.now }, deliveryAudit: try .init(latencyBudget: 1.5, maximumSampleAge: 0.25),
            enableDeliveryFailures: true, export: { exported = $0 })
        driver.deliveryInputProvider = { current }
        native.setNow(1.5)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        native.setNow(4.75)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        let state = await owner.snapshot
        XCTAssertEqual(native.calls, ["rate:1500000", "profile:240p30", "rate:350000"])
        XCTAssertFalse(state.isClosed)
        XCTAssertEqual(state.applied?.profileID, "240p30")
        XCTAssertEqual(state.applied?.videoBitrate, 350_000)
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.profileReceipt?.encoderSessionID, native.newEncoder)
        XCTAssertEqual(state.receipt?.configuration.encoderSessionID, native.newEncoder)
        XCTAssertEqual(state.lastDeliveryFailure?.appliedRevision, 0)
        XCTAssertEqual(state.lastDeliveryFailure?.missingFrames, 30)
        XCTAssertNil(state.lastWindow)
        // The old source/configuration cannot cause another transition after acknowledgment.
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        XCTAssertEqual(native.calls.count, 3)
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let failure = try XCTUnwrap(events.first { $0["kind"] as? String == "deliveryFailure" })
        let applied = try XCTUnwrap(events.first { $0["kind"] as? String == "applied" })
        XCTAssertEqual(events.filter { $0["kind"] as? String == "applied" }.count, 1)
        XCTAssertEqual(failure["profileID"] as? String, "540p30")
        XCTAssertEqual(failure["revision"] as? String, "0")
        XCTAssertEqual((failure["action"] as? [String: Any])?["kind"] as? String, "reset")
        XCTAssertEqual(applied["profileID"] as? String, "240p30")
        XCTAssertEqual(applied["revision"] as? String, "1")
        XCTAssertEqual((applied["application"] as? [String: Any])?["windowSequence"] as? String,
            (failure["deliveryFailure"] as? [String: Any])?["sequence"] as? String)
        XCTAssertNotNil(applied["profileReceipt"])
        XCTAssertNil(failure["window"])
    }
    @MainActor func testDriverDeadlineDefaultRetiredAndStaleEvidenceCannotWrite() async throws {
        for fault in ["disabled", "retired", "stale"] {
            bitRate = 700_000
            let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
            try await owner.bootstrap()
            var input: PublishingDeliveryMonitor.Input?
            _ = try classify(missing: Set(30..<60), late: [], revision: 0, profileID: "240p30",
                submittedBoundary: .zero, withAuthority: true, captureInput: { input = $0 },
                deliveryInstant: .now - .seconds(fault == "stale" ? 1 : 0))
            let current = try XCTUnwrap(input)
            let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1.5, maximumSampleAge: 0.25)
            let driver: PublishingQualityDriver
            if fault == "disabled" {
                driver = .init(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { native.now }, deliveryAudit: audit)
            } else {
                driver = .init(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { native.now },
                    deliveryAudit: audit, enableDeliveryFailures: true)
            }
            driver.deliveryInputProvider = { current }
            native.setNow(0.5)
            await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
            if fault == "retired" { current.authority?.revoke() }
            native.setNow(4.75)
            await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
            XCTAssertEqual(native.calls, 1, fault)
            let state = await owner.snapshot
            XCTAssertNil(state.lastDeliveryFailure, fault)
            await driver.stop()
        }
    }
    @MainActor func testDriverSurvivesOwnerAdmissionRejectionAfterSuccessfulClassification() async throws {
        bitRate = 700_000
        let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
        try await owner.bootstrap()
        var input: PublishingDeliveryMonitor.Input?
        _ = try classify(missing: Set(60..<90), late: [], revision: 0, profileID: "240p30",
            submittedBoundary: .zero, withAuthority: true, captureInput: { input = $0 }, deliveryInstant: .now)
        let current = try XCTUnwrap(input)
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1.5, maximumSampleAge: 0.25)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
            uptime: { native.now }, deliveryAudit: audit, enableDeliveryFailures: true, export: { exported = $0 })
        driver.deliveryInputProvider = { current }
        native.setNow(1.5)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        native.rejectNextAdmission()
        native.setNow(4.75)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        XCTAssertFalse(driver.isClosed)
        XCTAssertEqual(native.calls, 1)
        XCTAssertEqual(native.stops, 0)
        let state = await owner.snapshot
        XCTAssertFalse(state.isClosed)
        XCTAssertNil(state.lastDeliveryFailure)
        let auditJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        let rows = try XCTUnwrap(auditJSON["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows[0]["result"] as? [String: Any])?["missingFrames"] as? Int, 30,
            "The driver must catch actor admission failure after classification succeeds")
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["kind"] as? String == "rejected" && ($0["reason"] as? String)?.hasPrefix("delivery-") == true })
        XCTAssertFalse(events.contains { $0["kind"] as? String == "failed" || $0["kind"] as? String == "deliveryFailure" })
    }
    @MainActor func testDriverClosesPublishingOwnerWhenDeadlineResetWriteFails() async throws {
        bitRate = 700_000
        let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
        try await owner.bootstrap()
        var input: PublishingDeliveryMonitor.Input?
        _ = try classify(missing: Set(60..<90), late: [], revision: 0, profileID: "240p30",
            submittedBoundary: .zero, withAuthority: true, captureInput: { input = $0 }, deliveryInstant: .now)
        let current = try XCTUnwrap(input)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
            uptime: { native.now }, deliveryAudit: try .init(latencyBudget: 1.5, maximumSampleAge: 0.25),
            enableDeliveryFailures: true, export: { exported = $0 })
        driver.deliveryInputProvider = { current }
        native.setNow(1.5)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        native.failNextWrite()
        native.setNow(4.75)
        await driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics)?.value
        XCTAssertTrue(driver.isClosed)
        XCTAssertEqual(native.calls, 2)
        XCTAssertEqual(native.stops, 1)
        let state = await owner.snapshot
        XCTAssertTrue(state.isClosed)
        XCTAssertEqual(state.revision, 0, "A failed native write cannot acknowledge the minimum")
        XCTAssertEqual(state.lastDeliveryFailure?.missingFrames, 30)
        XCTAssertNil(driver.tick(encoderReady: true, source: nil, diagnostics: current.diagnostics))
        await driver.stop()
        XCTAssertEqual(native.stops, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["kind"] as? String == "deliveryFailure" })
        XCTAssertTrue(events.contains { $0["kind"] as? String == "failed" && $0["reason"] as? String == "native-change-failed" })
        XCTAssertFalse(events.contains { $0["kind"] as? String == "applied" })
    }
    func testNativeOwnerConsumesFailureOnceAndAppliesMinimum() async throws {
        bitRate = 700_000
        let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
        try await owner.bootstrap(); native.setNow(4.5)
        let observation = try classify(missing: [40,41,42,43], late: [], revision: 0, profileID: "240p30", submittedBoundary: .zero, withAuthority: true)
        let authority = try XCTUnwrap(observation.authority)
        let decision = try await owner.evaluateDeliveryFailure(observation, authority: authority, instant: instant)
        let reset = try XCTUnwrap(decision?.recommendation)
        XCTAssertEqual(reset.kind, .reset); XCTAssertEqual(reset.settings.videoBitrate, 350_000)
        let duplicate = try await owner.evaluateDeliveryFailure(observation, authority: authority, instant: instant)
        XCTAssertNil(duplicate)
        // Retiring later telemetry must not erase an already justified reset.
        authority.revoke()
        try await owner.apply(reset)
        let state = await owner.snapshot
        XCTAssertEqual(state.applied?.videoBitrate, 350_000); XCTAssertEqual(state.revision, 1)
        XCTAssertNil(state.lastWindow); XCTAssertNotNil(state.lastDeliveryFailure)
        XCTAssertEqual(native.calls, 2)
        await owner.stop()
    }
    func testExperimentalDeliveryMediaAgeDoesNotRenewAuthorityOrRevision() async throws {
        for timing in [StreamingTimingProfile.broadcastReliability2000, .broadcastReliability3000] {
            for fault in ["none", "expiredMedia", "expiredReport", "revoked", "revision"] {
                bitRate = 700_000
                let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native, timingProfile: timing)
                try await owner.bootstrap()
                let evaluatedAt = 3 + timing.maximumCaptureWindowEvaluationAge
                native.setNow(evaluatedAt + (fault == "expiredMedia" ? 0.000001 : 0))
                let observation = try classify(missing: [40,41,42,43], late: [], evaluationTime: evaluatedAt,
                    revision: fault == "revision" ? 1 : 0, profileID: "240p30", submittedBoundary: .zero, withAuthority: true)
                let authority = try XCTUnwrap(observation.authority)
                if fault == "revoked" { authority.revoke() }
                do {
                    let decision = try await owner.evaluateDeliveryFailure(observation, authority: authority,
                        instant: instant + (fault == "expiredReport" ? .milliseconds(251) : .zero))
                    XCTAssertEqual(fault, "none")
                    XCTAssertEqual(decision?.recommendation?.kind, .reset)
                } catch { XCTAssertNotEqual(fault, "none", "Fresh reports remain consumable at the exact experimental media boundary: \(error)") }
                await owner.stop()
            }
        }
    }

    func testNativeOwnerRejectsRetiredStaleAndWrongRevisionBeforeLatching() async throws {
        for fault in ["retired", "stale", "revision", "configuration"] {
            bitRate = 700_000
            let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
            try await owner.bootstrap(); native.setNow(fault == "stale" ? 4.751 : 4.5)
            if fault == "configuration" { bitRate = 600_000 }
            let observation = try classify(missing: [40,41,42,43], late: [], revision: fault == "revision" ? 1 : 0,
                profileID: "240p30", submittedBoundary: .zero, withAuthority: true)
            let authority = try XCTUnwrap(observation.authority)
            if fault == "retired" { authority.revoke() }
            do { _ = try await owner.evaluateDeliveryFailure(observation, authority: authority, instant: instant); XCTFail(fault) } catch {}
            XCTAssertEqual(native.calls, 1)
            let advice = try await owner.checkTrialDeadline(); XCTAssertNil(advice)
            await owner.stop()
        }
    }
    func testReplacementAuthorityCannotReauthorizeAnOlderClassification() async throws {
        bitRate = 700_000
        let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
        try await owner.bootstrap(); native.setNow(4.5)
        let observation = try classify(missing: [40,41,42,43], late: [], revision: 0, profileID: "240p30", submittedBoundary: .zero, withAuthority: true)
        let retired = try XCTUnwrap(observation.authority)
        retired.revoke()
        let replacement = PublishingDeliveryAuthority(delivery: observation.delivery)
        do {
            _ = try await owner.evaluateDeliveryFailure(observation, authority: replacement, instant: instant)
            XCTFail("A new authority must not authorize a classification created before it")
        } catch {}
        let advice = try await owner.checkTrialDeadline(); XCTAssertNil(advice)
        await owner.stop()
    }
    func testQueuedFailureExpiresBeforeNextHealthPoll() async throws {
        bitRate = 700_000
        let native = DeadlineNative(configuration: configuration), owner = try deliveryOwner(native)
        try await owner.bootstrap(); native.setNow(4.53)
        let observation = try classify(missing: [40,41,42,43], late: [], revision: 0, profileID: "240p30",
            submittedBoundary: .zero, withAuthority: true, expiresAt: "2040-01-01T00:00:00.020Z")
        let authority = try XCTUnwrap(observation.authority)
        XCTAssertTrue(authority.permits(observation.delivery), "No health poll has revoked the context yet")
        do {
            _ = try await owner.evaluateDeliveryFailure(observation, authority: authority, instant: instant + .milliseconds(30))
            XCTFail("Status expiry must reject even when sample age is below 250ms")
        } catch {}
        let advice = try await owner.checkTrialDeadline(); XCTAssertNil(advice)
        XCTAssertEqual(native.calls, 1)
        await owner.stop()
    }
    func testDeliveryAuthorityRetiresEvidencePermanently() throws {
        let delivery = try classify().delivery
        let authority = PublishingDeliveryAuthority(delivery: delivery)
        XCTAssertTrue(authority.permits(delivery))
        XCTAssertFalse(authority.permits(try classify(workerEpoch: "66666666-6666-4666-8666-666666666666").delivery))
        XCTAssertFalse(authority.permits(try classify(deliveryScope: "77777777-7777-4777-8777-777777777777").delivery))
        authority.revoke()
        XCTAssertFalse(authority.permits(delivery))
        authority.revoke()
        XCTAssertFalse(authority.permits(delivery))
        XCTAssertTrue(PublishingDeliveryAuthority(delivery: delivery).permits(delivery))
    }
    private var auditRecordingID = "recording"
    private let session = UUID()
    private var configuration: VideoEncodingConfiguration {
        .init(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, encoderSessionID: session, bitRate: bitRate)!
    }
    private var scope: VideoFrameObservationScope {
        .init(recordingID: auditRecordingID, matchID: "game", broadcastGeneration: 1,
              publishingAttemptID: session, appliedProfileRevision: 1)
    }
    private func history(capacity: Int = 256, captureRange: ClosedRange<Int> = 0...120,
                         missing: Set<Int> = [], encodedThrough: Int = 120,
                         badConfiguration: Int? = nil, noMetadata: Int? = nil,
                         offset: Int64 = 0, equalCaptureTimes: Bool = false, captureOffsets: [Int: Double] = [:],
                         extraEncoded: Bool = false, unmatchedTail: Bool = false, closed: Bool = false) throws -> VideoSourceHistorySnapshot {
        var history = try VideoSourceHistory(scope: scope, capacity: capacity)
        for i in captureRange {
            let time = (equalCaptureTimes && i == 31 ? 1 : Double(i) / 30) + (captureOffsets[i] ?? 0)
            let pts = CMTime(value: Int64(i) * 3000 + offset, timescale: 90_000)
            XCTAssertTrue(history.observe(.captureVideo, sourcePTS: pts, at: time))
            if !missing.contains(i), i <= encodedThrough {
                let config = badConfiguration == i ? VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 500_000)! : configuration
                let metadata = noMetadata == i ? nil : VideoEncodingObservation(encoderSessionID: session,
                    configuration: config, submittedAt: time, completedAt: time)
                XCTAssertTrue(history.observe(.encodedVideo, sourcePTS: pts, at: time, encoding: metadata))
                if extraEncoded && i == 45 {
                    XCTAssertTrue(history.observe(.encodedVideo, sourcePTS: CMTime(value: pts.value + 1, timescale: pts.timescale),
                        at: time, encoding: metadata))
                }
            }
        }
        if unmatchedTail {
            XCTAssertTrue(history.observe(.encodedVideo, sourcePTS: CMTime(value: 181, timescale: 60), at: 4,
                encoding: VideoEncodingObservation(encoderSessionID: session, configuration: configuration,
                    submittedAt: 4, completedAt: 4)))
        }
        if closed { history.close() }
        return history.snapshot
    }
    private func match(_ history: VideoSourceHistorySnapshot, start: Double = 1, end: Double = 3,
                       relayOrigin: Int64 = 10_919, anchor: Int64 = 358_081,
                       accepted: Double = 0, acknowledged: Double = 0,
                       submittedBoundary: CMTime? = nil, generation: UInt64 = 1,
                       origin: CMTime = .zero) -> PublishingDeliverySourceWindow? {
        .match(history: history, clock: PublishingTransportClock(sourceOrigin: origin, publishingGeneration: 1)!,
            receipt: PublishingBitRateChange(publishingGeneration: generation, configuration: configuration,
                acceptedAt: accepted, lastSubmittedSourcePTS: submittedBoundary)!,
            acknowledgedAt: acknowledged, windowStart: start, windowEnd: end,
            relayOriginPTS: relayOrigin, anchorDecodedPTS: anchor)
    }

    func testCompleteWindowIncludesUnencodedCapturesAndExcludesRightBoundary() throws {
        let value = try XCTUnwrap(match(history(missing: [40, 60, 89])))
        XCTAssertEqual(value.frames.count, 60)
        XCTAssertEqual(value.encodedFrames, 57)
        XCTAssertEqual(value.frames.first?.decodedPTS, 88_081)
        XCTAssertEqual(value.frames.last?.decodedPTS, 265_081)
        XCTAssertEqual(value.frames.first?.capturedAt, 1)
        XCTAssertEqual(value.configuration, configuration)
        XCTAssertEqual(value.scope, scope)
        XCTAssertEqual(value.publishingGeneration, 1)
        XCTAssertEqual(try XCTUnwrap(match(history(), end: 2)).frames.count, 30)
    }
    func testCaptureBracketsCannotBeInferredFromTruncatedHistory() throws {
        XCTAssertNil(try match(history(captureRange: 30...120)))
        XCTAssertNil(try match(history(captureRange: 0...89), anchor: 265_081))
        XCTAssertNil(try match(history(capacity: 90)))
        // Retirement outside the needed interval does not invalidate coverage.
        XCTAssertNotNil(try match(history(capacity: 92)))
    }
    func testEncoderBracketsMustCoverPendingCompletionsAndRetiredMetadata() throws {
        XCTAssertNil(try match(history(encodedThrough: 89), anchor: 265_081))
        XCTAssertNil(try match(history(missing: Set(0..<30))))
        XCTAssertNotNil(try match(history(missing: [89]), anchor: 358_081))
    }
    func testUnmatchedEncoderTailCannotProveCompletionCoverage() throws {
        XCTAssertNil(try match(history(encodedThrough: 88, unmatchedTail: true), anchor: 262_081),
            "An encoded-only right bracket cannot classify pending capture 89 as missing")
    }
    func testEveryEncodedSourceRequiresCaptureMembershipAndVerifiedConfiguration() throws {
        XCTAssertNil(try match(history(extraEncoded: true)))
        XCTAssertNil(try match(history(badConfiguration: 40)))
        XCTAssertNil(try match(history(noMetadata: 40)))
        XCTAssertNotNil(try match(history(badConfiguration: 10)))
    }
    func testReceiptAndAcknowledgmentMustPrecedeTheEntireWindow() throws {
        XCTAssertNil(try match(history(), accepted: 0.5, acknowledged: 0.4))
        XCTAssertNil(try match(history(), acknowledged: 1.01))
        XCTAssertNil(try match(history(), submittedBoundary: CMTime(value: 30, timescale: 30)))
        XCTAssertNotNil(try match(history(), submittedBoundary: CMTime(value: 29, timescale: 30)))
        XCTAssertNil(try match(history(), generation: 2))
    }
    func testUnknownAnchorAndUnsafeOrAmbiguousWindowsRemainUnknown() throws {
        XCTAssertNil(try match(history(), anchor: 358_082))
        XCTAssertNil(try match(history(), anchor: Int64.max))
        XCTAssertNil(try match(history(), relayOrigin: -1))
        XCTAssertNil(try match(history(), start: .nan))
        XCTAssertNil(try match(history(), end: 2.5))
        XCTAssertNil(try match(history(closed: true)))
        XCTAssertNil(try match(history(equalCaptureTimes: true)))
        XCTAssertNil(try match(history(), origin: CMTime(value: 2, timescale: 1)))
    }
    func testDecodedAnchorSelectsTheCorrectUnwrappedEpoch() throws {
        let wrap = PublishingTransportClock.wireModulus
        let value = try XCTUnwrap(match(history(offset: wrap), anchor: 358_081))
        XCTAssertEqual(value.frames.first?.decodedPTS, 88_081)
        let nextEpoch = try XCTUnwrap(match(history(), anchor: 358_081 + wrap))
        XCTAssertEqual(nextEpoch.frames.first?.decodedPTS, 88_081 + wrap)
        let negative = try XCTUnwrap(match(history(), anchor: 358_081 - wrap))
        XCTAssertEqual(negative.frames.first?.decodedPTS, 88_081 - wrap)
    }
    func testProjectionUsesExactFractionalOriginRounding() throws {
        // Native transport mapping floors the rational subtraction, then adds 9000.
        let value = try XCTUnwrap(match(history(), anchor: 358_071,
            origin: CMTime(value: 1, timescale: 9_999)))
        XCTAssertEqual(value.frames.first?.decodedPTS, 88_071)
    }
    private let instant = ContinuousClock.now
    private func classify(missing: Set<Int> = [40], late: Set<Int> = [50],
                          latency: Double = 0.5, ageMs: Double = 0, evaluationTime: Double = 4.5,
                          deadline: Double = 1, fault: Int = -1, decodedThrough: Int = 90,
                          workerEpoch: String = "22222222-2222-2222-2222-222222222222",
                          deliveryScope: String = "55555555-5555-5555-5555-555555555555",
                          revision: UInt64 = 7, profileID: String = "minimum", submittedBoundary: CMTime? = nil,
                          withAuthority: Bool = false,
                          expiresAt: String = "2040-01-01T00:00:05Z",
                          audit: PublishingDeliveryMonitor.Audit? = nil,
                          captureInput: ((PublishingDeliveryMonitor.Input) -> Void)? = nil,
                          captureResponse: ((WorkerMediaStatusResponse) -> Void)? = nil,
                          requestTiming: DeliveryRequestTiming? = nil, localDelay: Double = 0,
                          deliveryInstant: ContinuousClock.Instant? = nil) throws -> PublishingDeliveryObservation {
        let instant = deliveryInstant ?? self.instant
        let h = try history(missing: missing)
        let clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1)!
        let receipt = PublishingBitRateChange(publishingGeneration: 1, configuration: configuration,
            acceptedAt: 0, lastSubmittedSourcePTS: submittedBoundary)!
        var applied = PublishingQualityTelemetry.Applied(attemptID: session, revision: revision,
            settings: .init(profileID: profileID, videoBitrate: configuration.bitRate), receipt: receipt, acknowledgedAt: 0)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 0, maxItems: 4, maxBytes: 100)
        var diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: clock, receipt: receipt,
            ingress: ingress.poll(at: evaluationTime), transport: PublishingTransportStatisticsTracker().snapshot,
            thermal: PublishingThermalTracker().snapshot)
        // Explicit synthetic clock/publication binding; no physical latency claim.
        var rows: [(pts: Int64, at: Double)] = []
        for i in 0...decodedThrough where !missing.contains(i) {
            let pts = Int64(i) * 3000 - 1919
            let delay = late.contains(i) ? 1.2 : latency
            rows.append((pts: pts, at: Double(i) / 30 + delay))
        }
        if fault == 8 { rows.append((40 * 3000 - 1919, 2)) }
        rows.sort { $0.at < $1.at }
        let wire: [String: Any] = ["formatVersion": 1, "scopeID": deliveryScope,
            "sampledAtMs": evaluationTime * 1000, "coverageAtMs": 0, "afterOrdinal": 0, "lastOrdinal": rows.count,
            "arrivals": rows.map { [$0.pts as Any, $0.at * 1000] }, "invalidReason": NSNull(), "ended": false]
        let packet = try JSONDecoder().decode(DecoderDeliveryPacket.self,
            from: JSONSerialization.data(withJSONObject: wire))
        var observation = WorkerObservation(gameId: "game", generation: 1, state: .producingOutput,
            reason: nil, attempt: 1, frame: 91, outTimeUs: 3_000_000, scoreRevision: 1,
            decodedVideo: .init(completed: nil, invalidReason: nil, ended: false, clock: "mpegts-pts-90k-v1"))
        observation.decoderDelivery = packet
        let publication = WorkerPublication(readerId: "33333333-3333-3333-3333-333333333333",
            publisherId: "44444444-4444-4444-4444-444444444444", publishingAttemptId: session.uuidString.lowercased(),
            clock: .init(convention: "mpegts-ingress-origin-90k-v1", originPTS: "10919"))
        var response = WorkerMediaStatusResponse(status: .init(gameId: "game", generation: 1,
            workerId: "worker", state: .producingOutput, observation: observation,
            observedAt: "2040-01-01T00:00:00Z", expiresAt: expiresAt,
            workerEpoch: workerEpoch, publication: publication),
            serverTime: "2040-01-01T00:00:00Z")
        response.status.decoderDeliveryAgeUpperBoundMs = ageMs
        captureResponse?(response)
        var tracker = WorkerDecoderDeliveryTracker()
        let delivery = try XCTUnwrap(tracker.observe(response: response, expectedPublishingAttemptID: session,
            receivedAt: instant, requestDuration: .zero, requestTiming: requestTiming))
        let authority = withAuthority ? PublishingDeliveryAuthority(delivery: delivery) : nil
        switch fault {
        case 0: diagnostics.isPublishing = false
        case 1: diagnostics.receipt = nil
        case 2: applied.attemptID = UUID()
        case 3: diagnostics.clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 2)
        case 4: applied.settings = .init(profileID: "minimum", videoBitrate: 700_000)
        case 5: diagnostics.ingress = nil
        default: break
        }
        let input = PublishingDeliveryMonitor.Input(history: h,
                clock: .init(scope: scope, transportClock: clock, isClosed: false),
                diagnostics: diagnostics, delivery: delivery, authority: authority)
        captureInput?(input)
        if let audit {
            audit.record(input: input, applied: applied, at: 0.5, instant: instant)
            audit.record(input: input, applied: applied, at: evaluationTime, instant: instant)
            audit.record(input: input, applied: applied, at: evaluationTime, instant: instant)
            audit.record(input: input, applied: applied, at: evaluationTime, instant: instant)
        }
        return try PublishingDeliveryObservation.classify(history: h,
            clock: .init(scope: scope, transportClock: clock, isClosed: fault == 6),
            applied: applied, diagnostics: diagnostics, delivery: delivery,
            windowStart: 1, windowEnd: 3, at: fault == 9 ? 3.9 : evaluationTime + localDelay,
            instant: fault == 7 ? instant + .seconds(6) : instant + .seconds(localDelay),
            maximumSampleAge: 0.25, latencyBudget: deadline, authority: authority)
    }
    func testAuthenticatedAdapterClassifiesLocalLossAndLateFramesSeparately() throws {
        let value = try classify()
        XCTAssertEqual(value.source.frames.count, 60)
        XCTAssertEqual(value.source.frames.filter { !$0.wasEncoded }.count, 1)
        XCTAssertEqual(value.result.missingFrames, 1)
        XCTAssertEqual(value.result.lateFrames, 1)
        XCTAssertEqual(value.result.onTimeFrames, 58)
        XCTAssertEqual(value.result.onTimeFPS, 29)
        XCTAssertEqual(value.appliedRevision, 7)
    }
    func testReceiptAnchorPreservesArrivalProofAcrossLocalDelayButNotExpiry() throws {
        let timing = try XCTUnwrap(DeliveryRequestTiming(startedAt: 4.48, receivedAt: 4.5))
        let anchored = try classify(missing: [], late: [], latency: 0.9, requestTiming: timing, localDelay: 0.2)
        XCTAssertEqual(anchored.result.onTimeFrames, 60)
        XCTAssertEqual(anchored.result.uncertainFrames, 0)
        let legacy = try classify(missing: [], late: [], latency: 0.9, localDelay: 0.2)
        XCTAssertEqual(legacy.result.uncertainFrames, 60)
        XCTAssertThrowsError(try classify(requestTiming: timing, localDelay: 0.3))
    }
    func testAnchoredAuditsExportExactReceiptBoundsAndRequireTimingMode() throws {
        let timing = try XCTUnwrap(DeliveryRequestTiming(startedAt: 4.48, receivedAt: 4.5))
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25, usesRequestTiming: true)
        var response: WorkerMediaStatusResponse?
        let observation = try classify(audit: audit, captureResponse: { response = $0 }, requestTiming: timing)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        XCTAssertEqual(object["deliveryTiming"] as? String, "request-uptime-v1")
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.last?["sampleTimeBounds"] as? [String: Double], ["lower": 4.48, "upper": 4.5])
        var reports = WorkerCadenceReportAudit(usesRequestTiming: true)
        reports.record(response: try XCTUnwrap(response), expectedAttempt: session, helper: nil,
            delivery: observation.delivery, receivedAt: instant, requestDuration: .zero,
            receivedUptime: 4.5, instant: instant, evaluatedUptime: 4.5,
            timing: .init(controlStartedUptime: 4.47, statusRequestStartedUptime: 4.48,
                responseReceivedUptime: 4.5, probeReadStartedUptime: 4.5, probeReadFinishedUptime: 4.5, auditEvaluatedUptime: 4.5))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: reports.data()) as? [String: Any])
        XCTAssertEqual(exported["deliveryTiming"] as? String, "request-uptime-v1")
        XCTAssertEqual((exported["rows"] as? [[String: Any]])?.first?["deliverySampleTimeBounds"] as? [String: Double], ["lower": 4.48, "upper": 4.5])
        let missing = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25, usesRequestTiming: true)
        _ = try classify(audit: missing)
        let rejected = try XCTUnwrap(JSONSerialization.jsonObject(with: missing.data()) as? [String: Any])
        XCTAssertTrue((rejected["rows"] as? [[String: Any]])?.allSatisfy { $0["result"] is NSNull } == true)
    }
    func testUncertainArrivalNeverBecomesAHealthyDeadlineWindow() throws {
        let value = try classify(missing: [], late: [], latency: 0.55, ageMs: 100, deadline: 0.5)
        XCTAssertEqual(value.result.uncertainFrames, 60)
        XCTAssertNil(value.result.onTimeFPS)
        XCTAssertNil(value.result.failureFraction)
    }
    func testAdapterRejectsChangedOwnershipExpiredProofAndImpossibleLocalArrival() throws {
        for fault in 0...9 { XCTAssertThrowsError(try classify(fault: fault), "fault \(fault)") }
        XCTAssertThrowsError(try classify(ageMs: 251))
    }

    func testDeadlineAuditExportsActualClassifierResultsOncePerWindow() throws {
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25)
        _ = try classify(audit: audit)
        audit.close()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        XCTAssertEqual(json["closed"] as? Bool, true)
        XCTAssertEqual(json["overflow"] as? Bool, false)
        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        let twoSeconds = try XCTUnwrap(rows.first { ($0["end"] as? Double) == 3 && ($0["start"] as? Double) == 1 })
        let result = try XCTUnwrap(twoSeconds["result"] as? [String: Any])
        XCTAssertEqual(result["missingFrames"] as? Int, 1)
        XCTAssertEqual(result["lateFrames"] as? Int, 1)
        XCTAssertEqual(result["onTimeFrames"] as? Int, 58)
        let history = try XCTUnwrap(twoSeconds["history"] as? [String: Any])
        XCTAssertEqual(history["trimmedCaptureFrames"] as? Int, 29)
        XCTAssertEqual(history["omittedCaptureFrames"] as? String, "0")
        XCTAssertNotNil(twoSeconds["timeline"])
        XCTAssertEqual(twoSeconds["sampleAgeSeconds"] as? Double, 0)
        XCTAssertEqual(twoSeconds["reason"] as? String, nil)
        if let output = ProcessInfo.processInfo.environment["SCOREBUG_TEST_DEADLINE_EXPORT"], !output.isEmpty {
            try audit.data().write(to: URL(fileURLWithPath: output))
        }
    }

    private var repeatedAuditEnvironment: [String: String] { [
        "SCOREBUG_TEST_MEASURED_TRIAL": "1", "SCOREBUG_TEST_CANDIDATE_HEADROOM": "1",
        "SCOREBUG_TEST_CANDIDATE_PROFILE": "360p30", "SCOREBUG_TEST_BANDWIDTH_PROBE": "repeated",
        "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
        "SCOREBUG_TEST_DIRECT_RTMP_RECORDER": "1", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
        "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "180", "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": "1500"
    ] }
    private func auditFixture() throws -> (PublishingDeliveryMonitor.Input, PublishingQualityTelemetry.Applied) {
        var input: PublishingDeliveryMonitor.Input?
        let healthy = try classify(missing: [], late: [], captureInput: { input = $0 })
        XCTAssertEqual(healthy.result.onTimeFrames, 60)
        let value = try XCTUnwrap(input)
        return (value, .init(attemptID: session, revision: 7,
            settings: .init(profileID: "minimum", videoBitrate: configuration.bitRate),
            receipt: try XCTUnwrap(value.diagnostics.receipt), acknowledgedAt: 0))
    }
    private func auditObject(_ audit: PublishingDeliveryMonitor.Audit) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
    }
    func testAuditUnavailableCallbackCoversMissingFailedClosedAndMixedBatches() throws {
        let (_, applied) = try auditFixture()
        var captured: PublishingDeliveryMonitor.Input?
        _ = try classify(missing: [], late: [], decodedThrough: 60, captureInput: { captured = $0 })
        let input = try XCTUnwrap(captured)
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25)
        var unavailable = false
        audit.record(input: nil, applied: applied, at: 0, instant: instant, onUnavailable: { unavailable = true })
        XCTAssertTrue(unavailable)
        audit.record(input: input, applied: applied, at: 0.5, instant: instant)
        unavailable = false
        audit.record(input: input, applied: applied, at: 1, instant: instant, onUnavailable: { unavailable = true })
        XCTAssertFalse(unavailable, "No completed row is normal while waiting for its deadline")
        // The next batch can classify a one-second window but its two-second
        // source window lacks matching history after replacing the input history.
        let short = PublishingDeliveryMonitor.Input(history: try history(captureRange: 29...61),
            clock: input.clock, diagnostics: input.diagnostics, delivery: input.delivery)
        let mixed = audit.record(input: short, applied: applied, at: 4.5, instant: instant, onUnavailable: { unavailable = true })
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed.first?.result.onTimeFrames, 30)
        let rows = try XCTUnwrap(try auditObject(audit)["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows.last?["reason"] as? String)
        XCTAssertTrue(unavailable, "Any unclassified row must invalidate the entire scheduling batch")
        audit.close(); unavailable = false
        audit.record(input: input, applied: applied, at: 5, instant: instant, onUnavailable: { unavailable = true })
        XCTAssertTrue(unavailable)
    }

    func testLosslessTimestampBoundaryReassignmentDoesNotInvalidateRecovery() throws {
        for (offsets, expected) in [([30: -0.001], [29, 59]), ([60: -0.001, 90: -0.001], [31, 61])] {
            let (original, applied) = try auditFixture()
            let input = PublishingDeliveryMonitor.Input(history: try history(captureOffsets: offsets),
                clock: original.clock, diagnostics: original.diagnostics, delivery: original.delivery)
            let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25)
            audit.record(input: input, applied: applied, at: 0.5, instant: instant)
            var unavailable = false
            let rows = audit.record(input: input, applied: applied, at: 4.5, instant: instant,
                onUnavailable: { unavailable = true })
            XCTAssertEqual(rows.map { $0.result.expectedFrames }, expected)
            XCTAssertEqual(rows.map { $0.result.onTimeFrames }, expected)
            XCTAssertTrue(rows.allSatisfy { $0.result.lateFrames == 0 && $0.result.missingFrames == 0 && $0.result.uncertainFrames == 0 })
            XCTAssertFalse(unavailable, "Continuous 30fps source PTS can cross host-clock bucket boundaries")
        }
    }

    func testAuditClassifiedUncertaintyInvalidatesEntireMixedBatchBeforeReturning() throws {
        var captured: PublishingDeliveryMonitor.Input?
        _ = try classify(missing: [], late: Set(60..<90), ageMs: 250, captureInput: { captured = $0 })
        let input = try XCTUnwrap(captured), (_, applied) = try auditFixture()
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25)
        audit.record(input: input, applied: applied, at: 0.5, instant: instant)
        var unavailable = false
        let rows = audit.record(input: input, applied: applied, at: 4.5, instant: instant, onUnavailable: { unavailable = true })
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.result.uncertainFrames, 0)
        XCTAssertEqual(rows.first?.result.onTimeFrames, 30)
        XCTAssertGreaterThan(try XCTUnwrap(rows.last?.result.uncertainFrames), 0)
        XCTAssertTrue(unavailable, "Typed negative must be known before the driver submits any positive row")
    }

    func testCapacityDeadlineAuditRetains512RowsAndRejectsTheNextScheduledRow() throws {
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: nativeCapacityTestEnvironment())
        let (fixture, applied) = try auditFixture()
        // A shorter valid source history keeps 512 rows below the independent
        // byte limit, so this test reaches the row boundary specifically.
        let input = PublishingDeliveryMonitor.Input(history: try history(captureRange: 0...90),
            clock: fixture.clock, diagnostics: fixture.diagnostics, delivery: fixture.delivery)
        audit.record(input: input, applied: applied, at: 0.5, instant: instant)
        for step in 1...341 {
            audit.record(input: input, applied: applied, at: Double(step) + 2.25, instant: instant)
        }
        let before = try auditObject(audit)
        let prefix = try XCTUnwrap(before["rows"] as? [[String: Any]])
        XCTAssertEqual(prefix.count, 511)
        XCTAssertEqual(before["formatVersion"] as? Int, 2)
        XCTAssertEqual(before["mode"] as? String, "capacity")
        XCTAssertEqual(before["maximumRows"] as? Int, 512)
        XCTAssertEqual(before["maximumBytes"] as? Int, 33_554_432)
        XCTAssertEqual(before["overflow"] as? Bool, false)
        audit.record(input: input, applied: applied, at: 344.25, instant: instant)
        let full = try auditObject(audit)
        let retained = try XCTUnwrap(full["rows"] as? [[String: Any]])
        XCTAssertEqual(retained.count, 512)
        XCTAssertEqual(full["overflow"] as? Bool, true)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: Array(retained.prefix(511)), options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: prefix, options: [.sortedKeys]))
        let terminal = try audit.data()
        var unavailable = false
        XCTAssertTrue(audit.record(input: input, applied: applied, at: 345.25, instant: instant,
            onUnavailable: { unavailable = true }).isEmpty)
        XCTAssertTrue(unavailable)
        XCTAssertEqual(try audit.data(), terminal)
        audit.close()
        XCTAssertEqual(try auditObject(audit)["closed"] as? Bool, true)
    }
    func testRepeatedDeadlineAuditRetains512RowsAndRejectsTheNextScheduledRow() throws {
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: repeatedAuditEnvironment)
        let (fixture, applied) = try auditFixture()
        // A shorter valid source history keeps 512 rows below the independent
        // byte limit, so this test reaches the row boundary specifically.
        let input = PublishingDeliveryMonitor.Input(history: try history(captureRange: 0...90),
            clock: fixture.clock, diagnostics: fixture.diagnostics, delivery: fixture.delivery)
        audit.record(input: input, applied: applied, at: 0.5, instant: instant)
        for step in 1...341 {
            audit.record(input: input, applied: applied, at: Double(step) + 2.25, instant: instant)
        }
        let before = try auditObject(audit)
        let prefix = try XCTUnwrap(before["rows"] as? [[String: Any]])
        XCTAssertEqual(prefix.count, 511)
        XCTAssertEqual(before["formatVersion"] as? Int, 2)
        XCTAssertEqual(before["mode"] as? String, "repeated")
        XCTAssertEqual(before["maximumRows"] as? Int, 512)
        XCTAssertEqual(before["maximumBytes"] as? Int, 33_554_432)
        XCTAssertEqual(before["overflow"] as? Bool, false)
        audit.record(input: input, applied: applied, at: 344.25, instant: instant)
        let full = try auditObject(audit)
        let retained = try XCTUnwrap(full["rows"] as? [[String: Any]])
        XCTAssertEqual(retained.count, 512)
        XCTAssertEqual(full["overflow"] as? Bool, true)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: Array(retained.prefix(511)), options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: prefix, options: [.sortedKeys]))
        let terminal = try audit.data()
        var unavailable = false
        XCTAssertTrue(audit.record(input: input, applied: applied, at: 345.25, instant: instant,
            onUnavailable: { unavailable = true }).isEmpty)
        XCTAssertTrue(unavailable)
        XCTAssertEqual(try audit.data(), terminal)
        audit.close()
        XCTAssertEqual(try auditObject(audit)["closed"] as? Bool, true)
    }
    func testDeadlineAuditLegacyCapacityAndEnvelopeRemainUnchanged() throws {
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25)
        let (input, applied) = try auditFixture()
        audit.record(input: input, applied: applied, at: 0.5, instant: instant)
        for step in 1...171 {
            audit.record(input: input, applied: applied, at: Double(step) + 2.25, instant: instant)
        }
        let full = try auditObject(audit)
        XCTAssertEqual((full["rows"] as? [Any])?.count, 256)
        XCTAssertEqual(full["formatVersion"] as? Int, 1)
        XCTAssertEqual(full["overflow"] as? Bool, false)
        XCTAssertNil(full["mode"]); XCTAssertNil(full["maximumRows"]); XCTAssertNil(full["maximumBytes"])
        XCTAssertTrue(audit.record(input: input, applied: applied, at: 174.25, instant: instant).isEmpty)
        XCTAssertEqual(try auditObject(audit)["overflow"] as? Bool, true)
        let terminal = try audit.data()
        audit.record(input: nil, applied: applied, at: 175.25, instant: instant)
        XCTAssertEqual(try audit.data(), terminal)
    }
    func testRepeatedDeadlineAuditRequiresEveryValidatedFixturePrerequisite() throws {
        var rejected: [[String: String]] = [[:]]
        for key in repeatedAuditEnvironment.keys {
            var environment = repeatedAuditEnvironment; environment.removeValue(forKey: key)
            rejected.append(environment)
        }
        for (key, values) in ["SCOREBUG_TEST_BANDWIDTH_PROBE": ["staged", "renew", "Repeated"],
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": ["90", "179", "181", "0180"],
            "SCOREBUG_TEST_CANDIDATE_PROFILE": ["540p30", "1080p30"],
            "SCOREBUG_TEST_MEASURED_TRIAL": ["true", "01"],
            "SCOREBUG_TEST_CADENCE_REPORTS": ["1"], "SCOREBUG_TEST_NATIVE_QUALITY": ["1"]] {
            for value in values {
                var environment = repeatedAuditEnvironment; environment[key] = value
                rejected.append(environment)
            }
        }
        for environment in rejected {
            let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
                environment: environment)
            let object = try auditObject(audit)
            XCTAssertEqual(object["formatVersion"] as? Int, 1, "\(environment)")
            XCTAssertNil(object["mode"]); XCTAssertNil(object["maximumRows"]); XCTAssertNil(object["maximumBytes"])
        }
    }
    func testRepeatedAndLegacyDeadlineAuditsKeep256PhaseLimit() throws {
        let (input, initial) = try auditFixture()
        for environment in [[:], repeatedAuditEnvironment, nativeCapacityTestEnvironment()] {
            let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
                environment: environment)
            var applied = initial
            for revision in 0..<256 {
                applied.revision = UInt64(revision)
                audit.record(input: input, applied: applied, at: 0.5, instant: instant)
            }
            XCTAssertEqual(try auditObject(audit)["overflow"] as? Bool, false)
            applied.revision = 256
            XCTAssertTrue(audit.record(input: input, applied: applied, at: 0.5, instant: instant).isEmpty)
            XCTAssertEqual(try auditObject(audit)["overflow"] as? Bool, true)
            XCTAssertEqual((try auditObject(audit)["rows"] as? [Any])?.count, 0)
            let terminal = try audit.data()
            audit.record(input: input, applied: initial, at: 4.5, instant: instant)
            XCTAssertEqual(try audit.data(), terminal)
        }
    }
    func testCapacityDeadlineAuditByteOverflowRetainsPrefixAndCannotResumeWithSmallerRows() throws {
        auditRecordingID = String(repeating: "x", count: 128 * 1024)
        let (large, applied) = try auditFixture()
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: nativeCapacityTestEnvironment())
        audit.record(input: large, applied: applied, at: 0.5, instant: instant)
        for step in 1...100 {
            audit.record(input: large, applied: applied, at: Double(step) + 2.25, instant: instant)
        }
        let terminal = try audit.data(), object = try auditObject(audit)
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(object["overflow"] as? Bool, true)
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertLessThan(rows.count, 150)
        XCTAssertLessThanOrEqual(terminal.count, 33_554_432)
        XCTAssertEqual(rows.first?["start"] as? Double, 1)
        XCTAssertEqual(rows.first?["end"] as? Double, 2)
        let serializedRows = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).count }
        XCTAssertLessThanOrEqual(serializedRows.reduce(0, +) + rows.count + 4096, 33_554_432)
        XCTAssertGreaterThan(serializedRows.reduce(0, +) + rows.count + 4096 + (serializedRows.last ?? 0), 33_554_432)
        auditRecordingID = "recording"
        let (small, _) = try auditFixture()
        var unavailable = false
        XCTAssertTrue(audit.record(input: small, applied: applied, at: 103.25, instant: instant,
            onUnavailable: { unavailable = true }).isEmpty)
        XCTAssertTrue(unavailable)
        XCTAssertEqual(try audit.data(), terminal)
    }
    func testRepeatedDeadlineAuditByteOverflowRetainsPrefixAndCannotResumeWithSmallerRows() throws {
        auditRecordingID = String(repeating: "x", count: 128 * 1024)
        let (large, applied) = try auditFixture()
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: repeatedAuditEnvironment)
        audit.record(input: large, applied: applied, at: 0.5, instant: instant)
        for step in 1...100 {
            audit.record(input: large, applied: applied, at: Double(step) + 2.25, instant: instant)
        }
        let terminal = try audit.data(), object = try auditObject(audit)
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(object["overflow"] as? Bool, true)
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertLessThan(rows.count, 150)
        XCTAssertLessThanOrEqual(terminal.count, 33_554_432)
        XCTAssertEqual(rows.first?["start"] as? Double, 1)
        XCTAssertEqual(rows.first?["end"] as? Double, 2)
        let serializedRows = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).count }
        XCTAssertLessThanOrEqual(serializedRows.reduce(0, +) + rows.count + 4096, 33_554_432)
        XCTAssertGreaterThan(serializedRows.reduce(0, +) + rows.count + 4096 + (serializedRows.last ?? 0), 33_554_432)
        auditRecordingID = "recording"
        let (small, _) = try auditFixture()
        var unavailable = false
        XCTAssertTrue(audit.record(input: small, applied: applied, at: 103.25, instant: instant,
            onUnavailable: { unavailable = true }).isEmpty)
        XCTAssertTrue(unavailable)
        XCTAssertEqual(try audit.data(), terminal)
    }
    func testCapacityDeadlineAuditSerializationFailureIsInvalidAndTerminal() throws {
        let (input, validApplied) = try auditFixture()
        var invalidApplied = validApplied
        invalidApplied.acknowledgedAt = .infinity
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: nativeCapacityTestEnvironment())
        audit.record(input: input, applied: invalidApplied, at: 0.5, instant: instant)
        XCTAssertTrue(audit.record(input: input, applied: invalidApplied, at: 4.5, instant: instant).isEmpty)
        let object = try auditObject(audit)
        XCTAssertEqual(object["invalid"] as? Bool, true)
        XCTAssertEqual((object["rows"] as? [Any])?.count, 0)
        let terminal = try audit.data()
        audit.record(input: input, applied: validApplied, at: 5.5, instant: instant)
        audit.record(input: input, applied: validApplied, at: 8.5, instant: instant)
        XCTAssertEqual(try audit.data(), terminal, "Serialization failure cannot leave a resumable gap")
    }
    func testRepeatedDeadlineAuditSerializationFailureIsInvalidAndTerminal() throws {
        let (input, validApplied) = try auditFixture()
        var invalidApplied = validApplied
        invalidApplied.acknowledgedAt = .infinity
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: repeatedAuditEnvironment)
        audit.record(input: input, applied: invalidApplied, at: 0.5, instant: instant)
        XCTAssertTrue(audit.record(input: input, applied: invalidApplied, at: 4.5, instant: instant).isEmpty)
        let object = try auditObject(audit)
        XCTAssertEqual(object["invalid"] as? Bool, true)
        XCTAssertEqual((object["rows"] as? [Any])?.count, 0)
        let terminal = try audit.data()
        audit.record(input: input, applied: validApplied, at: 5.5, instant: instant)
        audit.record(input: input, applied: validApplied, at: 8.5, instant: instant)
        XCTAssertEqual(try audit.data(), terminal, "Serialization failure cannot leave a resumable gap")
    }

    func testRepeatedDeadlineAuditNeverReturnsHealthyObservationForUnretainedOversizedRow() throws {
        auditRecordingID = String(repeating: "x", count: 12 * 1024 * 1024)
        let (input, applied) = try auditFixture()
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25,
            environment: repeatedAuditEnvironment)
        audit.record(input: input, applied: applied, at: 0.5, instant: instant)
        XCTAssertTrue(audit.record(input: input, applied: applied, at: 4.5, instant: instant).isEmpty,
            "Healthy classification cannot escape when its serialized row was not retained")
        let object = try auditObject(audit)
        XCTAssertEqual(object["overflow"] as? Bool, true)
        XCTAssertEqual((object["rows"] as? [Any])?.count, 0)
        XCTAssertLessThan(try audit.data().count, 4096)
    }

    func testDeadlineAuditRetainsTheOlderDecoderAnchorDuringSilence() throws {
        let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: 1, maximumSampleAge: 0.25)
        _ = try classify(missing: [], late: [], decodedThrough: 20, audit: audit)
        audit.close()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        for row in rows {
            let history = try XCTUnwrap(row["history"] as? [String: Any])
            for stage in ["capture", "encoded"] {
                let frames = try XCTUnwrap(history[stage] as? [[String: Any]])
                XCTAssertTrue(frames.contains { ($0["sourcePTS"] as? [String: Any])?["value"] as? String == "60000" },
                    "Export must retain the actual older decoded anchor in \(stage)")
            }
        }
    }

}

private final class DeadlineNative: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: VideoEncodingConfiguration
    private var time = 0.0, count = 0, stopCount = 0
    private var rejectAdmission = false, rejectWrite = false
    private enum WriteFailure: Error { case injected }
    init(configuration: VideoEncodingConfiguration) { initial = configuration }
    var now: Double { lock.withLock { time } }
    var calls: Int { lock.withLock { count } }
    var stops: Int { lock.withLock { stopCount } }
    func stop() { lock.withLock { stopCount += 1 } }
    func rejectNextAdmission() { lock.withLock { rejectAdmission = true } }
    func failNextWrite() { lock.withLock { rejectWrite = true } }
    func isPublishing() -> Bool { lock.withLock {
        defer { rejectAdmission = false }
        return !rejectAdmission
    } }
    var startup: PublishingVideoStartup? { .init(profile: .low240, width: 426, height: 240,
        publishingGeneration: 1, encoderSessionID: initial.encoderSessionID, firstSourcePTS: .zero,
        submittedAt: 0, completedAt: 0, observedAt: 0) }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func write(_ rate: Int) throws -> PublishingBitRateChange { try lock.withLock {
        count += 1
        if rejectWrite { rejectWrite = false; throw WriteFailure.injected }
        let config = rate == initial.bitRate ? initial : VideoEncodingConfiguration(id: UUID(), encoderSessionID: initial.encoderSessionID, bitRate: rate)!
        return PublishingBitRateChange(publishingGeneration: 1, configuration: config, acceptedAt: time, lastSubmittedSourcePTS: .zero)!
    } }
}

/// Injected profile receipts test driver/owner ordering, not physical encoder behavior.
private final class DeadlineProfileNative: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: VideoEncodingConfiguration
    let newEncoder = UUID()
    private var switched = false, time = 0.0
    private var history: [String] = []
    init(configuration: VideoEncodingConfiguration) { initial = configuration }
    var now: Double { lock.withLock { time } }
    var calls: [String] { lock.withLock { history } }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    var operations: PublishingQualitySession.Operations {
        .init(setBitRate: { rate, _ in self.write(rate) }, stop: {}, videoStartup: {
            .init(profile: .sd540, width: 960, height: 540, publishingGeneration: 1,
                encoderSessionID: self.initial.encoderSessionID, firstSourcePTS: .zero,
                submittedAt: 0, completedAt: 0, observedAt: 0)
        }, setProfile: { profile, _ in self.change(profile) })
    }
    private func write(_ rate: Int) -> PublishingBitRateChange { lock.withLock {
        history.append("rate:\(rate)")
        let config = switched ? VideoEncodingConfiguration(id: UUID(), encoderSessionID: newEncoder, bitRate: rate)! : initial
        return .init(publishingGeneration: 1, configuration: config, acceptedAt: time,
            lastSubmittedSourcePTS: switched ? .init(value: 143, timescale: 30) : .zero)!
    } }
    private func change(_ profile: PublishingVideoProfile) -> PublishingVideoProfileChange { lock.withLock {
        history.append("profile:\(profile.rawValue)"); switched = true
        return .init(profile: profile, publishingGeneration: 1, previousEncoderSessionID: initial.encoderSessionID,
            encoderSessionID: newEncoder, lastOldSourcePTS: .init(value: 142, timescale: 30),
            firstNewSourcePTS: .init(value: 143, timescale: 30), width: profile.width, height: profile.height,
            rawVideoFramesDropped: 0, acknowledgedAt: time)!
    } }
}

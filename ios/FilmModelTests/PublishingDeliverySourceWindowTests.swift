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
    private func deliveryOwner(_ native: DeadlineNative, behavior: QualityController.Behavior = .progressive) throws -> PublishingQualitySession {
        try .init(operations: .init(setBitRate: { rate, _ in try native.write(rate) }, stop: { native.stop() },
            isPublishing: { native.isPublishing() }, videoStartup: { native.startup }),
            profiles: [.init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 700_000)],
            attemptID: session, initial: .init(profileID: "240p30", videoBitrate: bitRate),
            behavior: behavior, uptime: { native.now })
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
    private let session = UUID()
    private var configuration: VideoEncodingConfiguration {
        .init(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, encoderSessionID: session, bitRate: bitRate)!
    }
    private var scope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "game", broadcastGeneration: 1,
              publishingAttemptID: session, appliedProfileRevision: 1)
    }
    private func history(capacity: Int = 256, captureRange: ClosedRange<Int> = 0...120,
                         missing: Set<Int> = [], encodedThrough: Int = 120,
                         badConfiguration: Int? = nil, noMetadata: Int? = nil,
                         offset: Int64 = 0, equalCaptureTimes: Bool = false,
                         extraEncoded: Bool = false, unmatchedTail: Bool = false, closed: Bool = false) throws -> VideoSourceHistorySnapshot {
        var history = try VideoSourceHistory(scope: scope, capacity: capacity)
        for i in captureRange {
            let time = equalCaptureTimes && i == 31 ? 1 : Double(i) / 30
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
                          latency: Double = 0.5, ageMs: Double = 0,
                          deadline: Double = 1, fault: Int = -1, decodedThrough: Int = 90,
                          workerEpoch: String = "22222222-2222-2222-2222-222222222222",
                          deliveryScope: String = "55555555-5555-5555-5555-555555555555",
                          revision: UInt64 = 7, profileID: String = "minimum", submittedBoundary: CMTime? = nil,
                          withAuthority: Bool = false,
                          expiresAt: String = "2040-01-01T00:00:05Z",
                          audit: PublishingDeliveryMonitor.Audit? = nil,
                          captureInput: ((PublishingDeliveryMonitor.Input) -> Void)? = nil,
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
            ingress: ingress.poll(at: 4.5), transport: PublishingTransportStatisticsTracker().snapshot,
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
            "sampledAtMs": 4500, "coverageAtMs": 0, "afterOrdinal": 0, "lastOrdinal": rows.count,
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
        var tracker = WorkerDecoderDeliveryTracker()
        let delivery = try XCTUnwrap(tracker.observe(response: response, expectedPublishingAttemptID: session,
            receivedAt: instant, requestDuration: .zero))
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
            audit.record(input: input, applied: applied, at: 4.5, instant: instant)
            audit.record(input: input, applied: applied, at: 4.5, instant: instant)
            audit.record(input: input, applied: applied, at: 4.5, instant: instant)
        }
        return try PublishingDeliveryObservation.classify(history: h,
            clock: .init(scope: scope, transportClock: clock, isClosed: fault == 6),
            applied: applied, diagnostics: diagnostics, delivery: delivery,
            windowStart: 1, windowEnd: 3, at: fault == 9 ? 3.9 : 4.5,
            instant: fault == 7 ? instant + .seconds(6) : instant,
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

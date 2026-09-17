import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming
import XCTest

final class PublishingDecoderStallTests: XCTestCase {
    private let attempt = UUID(uuidString: "30000000-0000-0000-0000-00000000000c")!
    private let instant = ContinuousClock.now
    private func cadence(stalled: Bool = true, pts: Int64 = 180000, age: Int = 50,
                         scope: String = "11111111-1111-4111-8111-111111111111",
                         generation: Int = 2, receivedAt: ContinuousClock.Instant? = nil, workerEpoch: String = "d6c217a3-27c5-44ea-a55e-3b951c67981f") throws -> WorkerDecoderCadenceFreshness {
        let json = """
        {"status":{"gameId":"match","generation":\(generation),"workerId":"mac","workerEpoch":"\(workerEpoch)","state":"producing_output",
        "observation":{"gameId":"match","generation":\(generation),"state":"producing_output","reason":null,"attempt":1,"frame":12,"outTimeUs":400000,"scoreRevision":1,
        "decodedVideo":{"clock":"mpegts-pts-90k-v1","completed":null,"invalidReason":null,"ended":false},
        "decoderCadence":{"formatVersion":1,"scopeID":"\(scope)","oneSecond":null,"twoSeconds":null,"progress":{"lastFreshPTS":\(pts),"ageMs":\(stalled ? 1000 : 50),"stalled":\(stalled)},"invalidReason":null,"ended":false}},
        "observedAt":"2040-01-01T00:00:00Z","expiresAt":"2040-01-01T00:00:05Z",
        "publication":{"readerId":"10000000-0000-0000-0000-00000000000a","publisherId":"20000000-0000-0000-0000-00000000000b","publishingAttemptId":"\(attempt.uuidString.lowercased())","clock":{"convention":"mpegts-ingress-origin-90k-v1","originPTS":"90000"}},"decoderCadenceAgeUpperBoundMs":\(age)},"serverTime":"2040-01-01T00:00:01Z"}
        """
        return try XCTUnwrap(WorkerDecoderCadenceFreshness(response: JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(json.utf8)),
            expectedPublishingAttemptID: attempt, receivedAt: receivedAt ?? instant, requestDuration: .zero))
    }
    private func diagnostics(_ native: StallNative) throws -> PublishingQualityTelemetry.Diagnostics {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match", broadcastGeneration: 2,
            publishingAttemptID: attempt, appliedProfileRevision: 1)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        return .init(isPublishing: true, clock: PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7),
            receipt: native.receipt, ingress: ingress.poll(at: native.now),
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
    }
    private func applied(_ native: StallNative) -> PublishingQualityTelemetry.Applied {
        .init(attemptID: attempt, revision: 0, settings: .init(profileID: "240p30", videoBitrate: 600000),
            receipt: native.receipt, acknowledgedAt: 100)
    }
    private func owner(_ native: StallNative, behavior: QualityController.Behavior = .progressive) throws -> PublishingQualitySession {
        try .init(operations: .init(setBitRate: { rate, _ in native.write(rate) }, stop: {}, videoStartup: { native.startup }),
            profiles: [.init(id: "240p30", width: 426, height: 240, targetFPS: 30, minimumBitrate: 350000, maximumBitrate: 700000)],
            attemptID: attempt, initial: .init(profileID: "240p30", videoBitrate: 600000), behavior: behavior, uptime: { native.now })
    }
    func testAdapterAcceptsExactFreshnessBoundaryWithoutCreatingFrameCounts() throws {
        let n = StallNative(); n.setNow(101.25)
        let signal = try XCTUnwrap(PublishingQualityTelemetry.decoderStall(cadence: cadence(age: 250), applied: applied(n),
            diagnostics: diagnostics(n), sequence: 7, at: n.now, instant: instant))
        XCTAssertEqual(signal.observedAtLowerBound, 101); XCTAssertEqual(signal.sequence, 7)
    }
    func testAdapterRejectsStaleOwnershipAndConfigurationAndIgnoresPreAckStall() throws {
        let n = StallNative(); n.setNow(101.25)
        for kind in ["age", "generation", "receipt", "clock", "closed", "configuration", "time"] {
            var a = applied(n), d = try diagnostics(n)
            if kind == "receipt" { d.receipt = nil }
            if kind == "clock" { d.clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 8) }
            if kind == "closed" { d.isPublishing = false }
            if kind == "configuration" { a.settings = .init(profileID: "240p30", videoBitrate: 350000) }
            XCTAssertThrowsError(try PublishingQualityTelemetry.decoderStall(
                cadence: cadence(age: kind == "age" ? 251 : 50, generation: kind == "generation" ? 3 : 2),
                applied: a, diagnostics: d, sequence: 1, at: kind == "time" ? .nan : n.now, instant: instant), kind)
        }
        XCTAssertNil(try PublishingQualityTelemetry.decoderStall(cadence: cadence(age: 250), applied: applied(n),
            diagnostics: diagnostics(n), sequence: 1, at: 101.249, instant: instant))
        XCTAssertNil(try PublishingQualityTelemetry.decoderStall(cadence: cadence(stalled: false), applied: applied(n),
            diagnostics: diagnostics(n), sequence: 1, at: n.now, instant: instant))
        XCTAssertThrowsError(try PublishingQualityTelemetry.decoderStall(cadence: cadence(), applied: applied(n),
            diagnostics: diagnostics(n), sequence: 1, at: n.now, instant: instant + .milliseconds(201)))
    }
    func testSessionStallResetsOnceAndKeepsSourceWindowAbsent() async throws {
        let n = StallNative(), o = try owner(n); try await o.bootstrap(); n.setNow(101.25)
        let decision = try await o.evaluateDecoderStall(cadence: cadence(), diagnostics: diagnostics(n), instant: instant)
        XCTAssertEqual(decision?.state, .stalled)
        let state = await o.snapshot; XCTAssertNil(state.lastWindow); XCTAssertEqual(state.revision, 0)
        try await o.apply(XCTUnwrap(decision?.recommendation))
        let reset = await o.snapshot; XCTAssertEqual(reset.revision, 1); XCTAssertEqual(reset.applied?.videoBitrate, 350000)
        n.setNow(103)
        let duplicate = try await o.evaluateDecoderStall(cadence: cadence(), diagnostics: diagnostics(n), instant: instant)
        XCTAssertNil(duplicate); XCTAssertEqual(n.calls, 2)
        await o.stop()
    }
    func testRegressedProgressRejectsAndChangedScopeCanObserveNewStall() async throws {
        let n = StallNative(), o = try owner(n); try await o.bootstrap(); n.setNow(102)
        let noStall = try await o.evaluateDecoderStall(cadence: cadence(stalled: false, pts: 200000), diagnostics: diagnostics(n), instant: instant)
        XCTAssertNil(noStall)
        do {
            _ = try await o.evaluateDecoderStall(cadence: cadence(), diagnostics: diagnostics(n), instant: instant)
            XCTFail("Old stalled PTS must not supersede newer decoder progress")
        } catch { XCTAssertEqual(error as? QualityController.ValidationError, .outOfOrder) }
        let changed = try await o.evaluateDecoderStall(cadence: cadence(scope: "22222222-2222-4222-8222-222222222222"), diagnostics: diagnostics(n), instant: instant)
        XCTAssertEqual(changed?.recommendation?.kind, .reset)
        await o.stop()
    }
    func testChangedDecoderScopeRevokesTrialWithoutClaimingAStall() async throws {
        let n = StallNative(), o = try owner(n); try await o.bootstrap()
        var advice: QualityController.Recommendation?
        for i in 100..<104 {
            n.setNow(Double(i + 1))
            _ = try await o.evaluateDecoderStall(cadence: cadence(stalled: false, pts: Int64(i) * 3000), diagnostics: diagnostics(n), instant: instant)
            advice = try await o.evaluate(.init(attemptID: attempt, sequence: UInt64(i), appliedRevision: 0,
                start: Double(i), end: Double(i + 1), capturedFreshFrames: 30, encodedFreshFrames: 30,
                receiver: .init(freshFrames: 30, observedAt: Double(i + 1)), sourceLoss: .init(expectedFrames: 30, lostFrames: 0),
                meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)).recommendation
        }
        XCTAssertEqual(advice?.kind, .trial); try await o.apply(XCTUnwrap(advice))
        n.setNow(105.25)
        let changed = try await o.evaluateDecoderStall(cadence: cadence(stalled: false,
            workerEpoch: "55555555-5555-4555-8555-555555555555"), diagnostics: diagnostics(n), instant: instant)
        XCTAssertNil(changed)
        let reset = try await o.checkTrialDeadline(); XCTAssertEqual(reset?.kind, .reset)
        let state = await o.snapshot; XCTAssertNil(state.lastDecoderStall)
        await o.stop()
    }
    func testConsumedReceiptCanAgeWithoutRevokingIndependentRecoveryButNewStaleReportCannot() async throws {
        let n = StallNative(), o = try owner(n); try await o.bootstrap()
        let cached = try cadence(stalled: false)
        var advice: QualityController.Recommendation?
        for i in 100..<104 {
            n.setNow(Double(i + 1))
            do {
                _ = try await o.evaluateDecoderStall(cadence: cached, diagnostics: diagnostics(n),
                    instant: instant + .seconds(i - 100))
            } catch { XCTFail("Re-reading consumed evidence must not create a new rejected sample: \(error)") }
            advice = try await o.evaluate(.init(attemptID: attempt, sequence: UInt64(i), appliedRevision: 0,
                start: Double(i), end: Double(i + 1), capturedFreshFrames: 30, encodedFreshFrames: 30,
                receiver: .init(freshFrames: 30, observedAt: Double(i + 1)), sourceLoss: .init(expectedFrames: 30, lostFrames: 0),
                meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)).recommendation
        }
        XCTAssertEqual(advice?.kind, .trial)
        do {
            _ = try await o.evaluateDecoderStall(cadence: cadence(stalled: false, age: 251), diagnostics: diagnostics(n), instant: instant)
            XCTFail("New stale response must still invalidate recovery")
        } catch { XCTAssertEqual(error as? PublishingQualityTelemetry.Failure, .freshness) }
        if let advice {
            do { try await o.apply(advice); XCTFail("Stale response must revoke pending increase") } catch {}
        }
        await o.stop()
    }
    func testConsumedReceiptStillChecksCurrentNativeOwnership() async throws {
        let n = StallNative(), o = try owner(n); try await o.bootstrap(); n.setNow(102)
        let cached = try cadence(stalled: false)
        _ = try await o.evaluateDecoderStall(cadence: cached, diagnostics: diagnostics(n), instant: instant)
        var wrong = try diagnostics(n); wrong.receipt = nil
        do {
            _ = try await o.evaluateDecoderStall(cadence: cached, diagnostics: wrong, instant: instant + .seconds(1))
            XCTFail("Consumption identity must not bypass native ownership")
        } catch { XCTAssertEqual(error as? PublishingQualityTelemetry.Failure, .ownership) }
        await o.stop()
    }
    func testLegacyIgnoresStallAndStaleReportCannotInventReset() async throws {
        for legacy in [false, true] {
            let n = StallNative(), o = try owner(n, behavior: legacy ? .legacy : .progressive)
            try await o.bootstrap(); n.setNow(102)
            do {
                let result = try await o.evaluateDecoderStall(cadence: cadence(age: legacy ? 50 : 251), diagnostics: diagnostics(n), instant: instant)
                XCTAssertTrue(legacy); XCTAssertNil(result)
            } catch { XCTAssertFalse(legacy) }
            let pending = try await o.checkTrialDeadline(); XCTAssertNil(pending)
            XCTAssertEqual(n.calls, 1); await o.stop()
        }
    }
    @MainActor func testDriverUsesCurrentCadenceAfterOwnerAwaitInsteadOfTickCapture() async throws {
        for latestStalled in [false, true] {
            let native = StallNative(), owner = try owner(native)
            try await owner.bootstrap(); native.setNow(102)
            var exported: Data?, reads = 0
            let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
                uptime: { native.now }, export: { exported = $0 })
            let current = try cadence(stalled: latestStalled, receivedAt: .now)
            let currentDiagnostics = try diagnostics(native)
            driver.cadenceInputProvider = { reads += 1; return .init(cadence: current, diagnostics: currentDiagnostics) }
            let captured = try cadence(stalled: false, age: latestStalled ? 50 : 251, receivedAt: .now)
            await driver.tick(encoderReady: true, source: nil, cadence: captured, diagnostics: currentDiagnostics)?.value
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(native.calls, latestStalled ? 2 : 1)
            await driver.stop()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertFalse(events.contains { $0["reason"] as? String == "cadence-freshness" })
        }
    }

    func testUnavailableCadenceRechecksReappearingReceiptAndPreservesProgress() async throws {
        let native = StallNative(), owner = try owner(native)
        try await owner.bootstrap(); native.setNow(102)
        let cached = try cadence(stalled: false, pts: 200000)
        _ = try await owner.evaluateDecoderStall(cadence: cached, diagnostics: diagnostics(native), instant: instant)
        try await owner.noteUnavailableCadence(diagnostics: diagnostics(native))
        do {
            _ = try await owner.evaluateDecoderStall(cadence: cached, diagnostics: diagnostics(native), instant: instant + .seconds(1))
            XCTFail("Missing cadence cannot preserve a freshness bypass")
        } catch { XCTAssertEqual(error as? PublishingQualityTelemetry.Failure, .freshness) }
        do {
            _ = try await owner.evaluateDecoderStall(cadence: cadence(stalled: false), diagnostics: diagnostics(native), instant: instant)
            XCTFail("A gap cannot reset the progress watermark")
        } catch { XCTAssertEqual(error as? QualityController.ValidationError, .outOfOrder) }
        await owner.stop()
    }

    func testUnavailableCadencePreservesAlreadyPendingReset() async throws {
        let native = StallNative(), owner = try owner(native)
        try await owner.bootstrap(); native.setNow(102)
        let decision = try await owner.evaluateDecoderStall(cadence: cadence(), diagnostics: diagnostics(native), instant: instant)
        let reset = try XCTUnwrap(decision?.recommendation)
        try await owner.noteUnavailableCadence(diagnostics: diagnostics(native))
        try await owner.apply(reset)
        XCTAssertEqual(native.calls, 2)
        await owner.stop()
    }

    @MainActor func testCurrentStaleCadenceStillRejectsAndProviderClearsOnCancel() async throws {
        let native = StallNative(), owner = try owner(native)
        try await owner.bootstrap(); native.setNow(102)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
            uptime: { native.now }, export: { exported = $0 })
        let old = try cadence(stalled: false, age: 251, receivedAt: .now)
        let d = try diagnostics(native)
        driver.cadenceInputProvider = { .init(cadence: old, diagnostics: d) }
        await driver.tick(encoderReady: true, source: nil, diagnostics: d)?.value
        driver.cancel(); XCTAssertNil(driver.cadenceInputProvider)
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["reason"] as? String == "cadence-freshness" })
        XCTAssertEqual(native.calls, 1)
    }

    @MainActor func testDeadlineFixtureIgnoresCompetingFreshDecoderStall() async throws {
        let n = StallNative(), o = try owner(n)
        let driver = PublishingQualityDriver(owner: o, workerLimits: nil, transportLimits: nil,
            uptime: { n.now }, enableDeliveryFailures: true)
        try await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics(n))?.value
        n.setNow(102)
        try await driver.tick(encoderReady: true, source: nil, cadence: cadence(receivedAt: .now), diagnostics: diagnostics(n))?.value
        let state = await o.snapshot
        XCTAssertEqual(n.calls, 1)
        XCTAssertEqual(state.applied?.videoBitrate, 600000)
        XCTAssertNil(state.lastDecoderStall)
        XCTAssertNil(state.lastDeliveryFailure)
        await driver.stop()
    }
    @MainActor func testDriverRecordsSeparateStallAndAppliesMinimum() async throws {
        let n = StallNative(), o = try owner(n); var exported: Data?
        let driver = PublishingQualityDriver(owner: o, workerLimits: nil, transportLimits: nil, uptime: { n.now }, export: { exported = $0 })
        try await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics(n))?.value
        n.setNow(102)
        try await driver.tick(encoderReady: true, source: nil, cadence: cadence(receivedAt: .now), diagnostics: diagnostics(n))?.value
        let state = await o.snapshot; XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.applied?.videoBitrate, 350000)
        n.setNow(104)
        try await driver.tick(encoderReady: true, source: nil, cadence: cadence(receivedAt: .now), diagnostics: diagnostics(n))?.value
        XCTAssertEqual(n.calls, 2, "A repeated stalled PTS must not dispatch another reset")
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first { $0["kind"] as? String == "decoderStall" })
        XCTAssertNil(event["window"]); XCTAssertNotNil(event["decoderStall"])
        XCTAssertEqual(events.filter { $0["kind"] as? String == "decoderStall" }.count, 1)
    }
}

private final class StallNative: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 100.0, count = 0
    private let encoder = UUID()
    private var current: PublishingBitRateChange?
    init() { current = PublishingBitRateChange(publishingGeneration: 7,
        configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: encoder, bitRate: 600000)!,
        acceptedAt: 100, lastSubmittedSourcePTS: .zero)! }
    var now: Double { lock.withLock { time } }
    var calls: Int { lock.withLock { count } }
    var receipt: PublishingBitRateChange { lock.withLock { current! } }
    var startup: PublishingVideoStartup? { .init(profile: .low240, width: 426, height: 240, publishingGeneration: 7,
        encoderSessionID: encoder, firstSourcePTS: .zero, submittedAt: 99, completedAt: 99.1, observedAt: 99.1) }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func write(_ rate: Int) -> PublishingBitRateChange { lock.withLock {
        count += 1
        current = PublishingBitRateChange(publishingGeneration: 7,
            configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: encoder, bitRate: rate)!,
            acceptedAt: time, lastSubmittedSourcePTS: .zero)!
        return current!
    } }
}

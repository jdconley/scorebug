import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

@MainActor final class PublishingQualityDriverTests: XCTestCase {
    func testQualityExportVersionsTheSelectedRecoveryPressurePolicy() async throws {
        for policy in [PublishingQualityTelemetry.TransportLimits.Policy.legacyThreshold, .senderDelay, .recoveryBudget] {
            let f = try await CandidateQualityFixture.make()
            var final: Data?
            let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil,
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500,
                    maximumRetransmittedFraction: 0.01, policy: policy),
                uptime: { f.native.now }, enableDeliveryFailures: true, enableMeasuredSourceEvaluation: true,
                export: { final = $0 })
            await driver.stop()
            let quality = try checkpointObject(XCTUnwrap(final))
            XCTAssertEqual(quality["formatVersion"] as? Int, policy == .recoveryBudget ? 6 : 4)
            XCTAssertEqual(quality["transportPolicy"] as? String, policy == .recoveryBudget ? "recovery-budget-v1" : nil)
            if policy == .recoveryBudget {
                let dictionary = try XCTUnwrap(quality["evidenceDictionary"] as? [String: Any])
                XCTAssertEqual(dictionary["formatVersion"] as? Int, 1)
            } else { XCTAssertNil(quality["evidenceDictionary"]) }
            XCTAssertEqual(quality["measuredSourceEvaluationEnabled"] as? Bool, true)
            XCTAssertEqual(quality["overflow"] as? Bool, false)
        }
    }

    func testRecoveryExportPoolsActualEvaluatedDiagnosticHistories() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500,
                maximumRetransmittedFraction: 0.01, policy: .recoveryBudget),
            uptime: { f.native.now }, enableDeliveryFailures: true, enableMeasuredSourceEvaluation: true,
            export: { exported = $0 })
        await driver.tick(encoderReady: true, source: f.source, diagnostics: diagnostics)?.value
        await driver.stop()
        let data = try XCTUnwrap(exported), quality = try checkpointObject(data)
        let rows = try XCTUnwrap(quality["events"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["kind"] as? String == "evaluated" })
        let evidence = try XCTUnwrap(row["evidence"] as? [String: Any])
        let transport = try XCTUnwrap(evidence["transport"] as? [String: Any])
        let dictionary = try XCTUnwrap(quality["evidenceDictionary"] as? [String: Any])
        XCTAssertNil(transport["samples"])
        XCTAssertEqual(transport["sampleCount"] as? Int, diagnostics.transport.samples.count)
        XCTAssertNotNil(transport["sampleRanges"] as? [[Int]])
        XCTAssertEqual(try json(XCTUnwrap(dictionary["transport"])),
                       try json(XCTUnwrap(PublishingQualityDriver.transportEvidence(diagnostics.transport)["samples"])))
        XCTAssertEqual(quality["overflow"] as? Bool, false)
        XCTAssertLessThan(data.count, 8 * 1024 * 1024)
    }

    func testRejectedSourceDiagnosticsPreserveTickSelectionAndOriginalSourceKey() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let source = try XCTUnwrap(f.source)
        let d = try XCTUnwrap(f.sourceDiagnostics)
        f.native.setNow(source.interval.captureBoundaryEndTime + 2.01)
        var exported: Data?, clockReads = 0
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            uptime: { clockReads += 1; return 200 + Double(clockReads) / 1000 }, export: { exported = $0 })
        await driver.tick(encoderReady: true, source: source, diagnostics: d)?.value
        await driver.stop()
        let quality = try checkpointObject(XCTUnwrap(exported))
        let events = try XCTUnwrap(quality["events"] as? [[String: Any]])
        let rejected = try XCTUnwrap(events.first { $0["kind"] as? String == "rejected" && $0["reason"] as? String == "time" })
        let trace = try XCTUnwrap(rejected["evaluationDiagnostic"] as? [String: Any])
        XCTAssertEqual(trace["selectedAt"] as? Double, 200.001, "Source selection is the original tick capture, before actor awaits")
        XCTAssertLessThan(try XCTUnwrap(trace["selectedAt"] as? Double), try XCTUnwrap(trace["dispatchedAt"] as? Double))
        XCTAssertLessThan(try XCTUnwrap(trace["dispatchedAt"] as? Double), try XCTUnwrap(trace["caughtAt"] as? Double))
        XCTAssertLessThan(try XCTUnwrap(trace["caughtAt"] as? Double), try XCTUnwrap(rejected["at"] as? Double))
        let session = try XCTUnwrap(trace["session"] as? [String: Any])
        XCTAssertEqual(session["kind"] as? String, "source")
        XCTAssertEqual(session["evaluatedAt"] as? Double, f.native.now)
        XCTAssertEqual(try XCTUnwrap(session["sourceAgeSeconds"] as? Double), 2.01, accuracy: 0.000001)
        let key = try XCTUnwrap(session["sourceKey"] as? [String: Any])
        XCTAssertEqual(key["workerEpoch"] as? String, source.workerEpoch)
        XCTAssertEqual(key["workerAttempt"] as? Int, source.workerAttempt)
        XCTAssertEqual(key["readerID"] as? String, source.publication.readerId)
        XCTAssertEqual(key["sequence"] as? String, String(source.sequence))
        XCTAssertTrue(session["cadenceReceiptID"] is NSNull)
        XCTAssertEqual((rejected["source"] as? [String: Any])?["sequence"] as? String, String(source.sequence))
    }

    func testRepeatedLiveCheckpointPreservesOriginalPrefixSourceAndIdentity() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        var live: [Data] = [], final: Data?
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            uptime: { f.native.now }, enableDeliveryFailures: true, enableMeasuredSourceEvaluation: true,
            liveExport: { live.append($0) }, export: { final = $0 })
        driver.candidateInputProvider = { _ in f.admission }
        await driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics))?.value
        await driver.stop()
        let quality = try checkpointObject(XCTUnwrap(final)), original = try XCTUnwrap(quality["events"] as? [[String: Any]])
        XCTAssertFalse(live.isEmpty)
        var previousCount = 0
        for data in live {
            let checkpoint = try checkpointObject(data), prefix = try XCTUnwrap(checkpoint["quality"] as? [String: Any])
            let rows = try XCTUnwrap(prefix["events"] as? [[String: Any]])
            XCTAssertEqual(checkpoint["formatVersion"] as? Int, 1)
            XCTAssertEqual(checkpoint["mode"] as? String, "repeated")
            XCTAssertEqual(checkpoint["publishingAttemptID"] as? String, f.attempt.uuidString.lowercased())
            XCTAssertEqual(checkpoint["eventCount"] as? Int, rows.count)
            XCTAssertGreaterThanOrEqual(rows.count, previousCount)
            XCTAssertEqual(try json(rows), try json(Array(original.prefix(rows.count))))
            var completed = prefix; completed["events"] = original
            XCTAssertEqual(try json(completed), try json(quality))
            previousCount = rows.count
        }
        let terminal = try checkpointObject(XCTUnwrap(live.last))
        XCTAssertEqual(terminal["closed"] as? Bool, true)
        XCTAssertEqual(terminal["eventCount"] as? Int, original.count)
        XCTAssertEqual(original.last?["kind"] as? String, "stopped")
        let source = try XCTUnwrap(original.first { $0["kind"] as? String == "evaluated" }?["source"] as? [String: Any])
        XCTAssertEqual(source["sequence"] as? String, String(try XCTUnwrap(f.source).sequence))
        XCTAssertEqual(source["attemptID"] as? String, f.attempt.uuidString)
        let appliedIndex = try XCTUnwrap(original.firstIndex { $0["kind"] as? String == "applied" })
        let candidateIndex = try XCTUnwrap(original.firstIndex { $0["kind"] as? String == "candidate" })
        XCTAssertLessThan(appliedIndex, candidateIndex)
        let candidate = try XCTUnwrap(original[candidateIndex]["candidate"] as? [String: Any])
        XCTAssertEqual(candidate["id"] as? String, f.admission.value.id.uuidString)
        XCTAssertEqual(original[appliedIndex]["revision"] as? String, "1")
    }

    func testRepeatedLiveDrainDoesNotDelayAdmissionAndStopJoinsTerminalAfterBlockedWriter() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true), gate = LiveCheckpointGate()
        var writes: [Data] = [], final: Data?, tickFinished = false, stopped = false
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            uptime: { f.native.now }, liveExport: { data in
                if writes.isEmpty { await gate.wait() }
                writes.append(data)
            }, export: { final = $0 })
        driver.candidateInputProvider = { _ in f.admission }
        let work = driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics))
        let observe = Task { await work?.value; tickFinished = true }
        await checkpointWait { gate.started && tickFinished }
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"], "Live I/O must not run inside the short admission lease")
        driver.cancel()
        let stop = Task { await driver.stop(); stopped = true }
        await checkpointWait { f.native.stops == 1 }
        XCTAssertFalse(stopped, "stop must join the blocked live writer")
        XCTAssertNil(final)
        gate.release()
        await observe.value; await stop.value
        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(writes.count, 2)
        XCTAssertLessThanOrEqual(writes.count, 3, "Pending applied/candidate prefixes must coalesce while the first writer waits")
        // If stop has already enqueued its terminal prefix only two writes are
        // needed; if the writer wins that actor turn, the pending active prefix
        // may finish first. Either order must end with exactly one closed write.
        XCTAssertEqual(try writes.filter { try checkpointObject($0)["closed"] as? Bool == true }.count, 1)
        let first = try checkpointObject(XCTUnwrap(writes.first)), terminal = try checkpointObject(XCTUnwrap(writes.last))
        XCTAssertEqual(first["closed"] as? Bool, false)
        XCTAssertEqual(terminal["closed"] as? Bool, true)
        XCTAssertLessThan(try XCTUnwrap(first["eventCount"] as? Int), try XCTUnwrap(terminal["eventCount"] as? Int))
        XCTAssertEqual(try json(XCTUnwrap(terminal["quality"])), try json(checkpointObject(XCTUnwrap(final))))
        let writesAtStop = writes.count
        XCTAssertNil(driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics)))
        await driver.stop()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(writes.count, writesAtStop, "No active checkpoint may be written after the joined terminal checkpoint")
    }

    func testRepeatedLiveOverflowKeepsBoundedOriginalPrefixAndClosesWithoutTruncation() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        let expired = try XCTUnwrap(decision.recommendation)
        f.native.setNow(expired.validUntil + 0.1)
        var live: Data?, final: Data?, largestCount = 0
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now }, liveExport: { data in
                live = data
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let count = object["eventCount"] as? Int {
                    largestCount = max(largestCount, count)
                }
            }, export: { final = $0 })
        for _ in 0..<520 { try await driver.apply(expired) }
        await driver.stop()
        let terminal = try checkpointObject(XCTUnwrap(live)), quality = try checkpointObject(XCTUnwrap(final))
        XCTAssertEqual(largestCount, 512)
        XCTAssertEqual(terminal["eventCount"] as? Int, 512)
        XCTAssertEqual(terminal["closed"] as? Bool, true)
        XCTAssertEqual(quality["overflow"] as? Bool, true)
        XCTAssertEqual((quality["events"] as? [[String: Any]])?.count, 512)
        XCTAssertEqual(try json(XCTUnwrap(terminal["quality"])), try json(quality))
    }

    func testLiveCheckpointFixtureSelectionRequiresValidatedRepeatedMeasuredRoute() throws {
        let valid = [
            "SCOREBUG_TEST_MEASURED_TRIAL": "1", "SCOREBUG_TEST_CANDIDATE_HEADROOM": "1",
            "SCOREBUG_TEST_CANDIDATE_PROFILE": "360p30", "SCOREBUG_TEST_BANDWIDTH_PROBE": "repeated",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_DIRECT_RTMP_RECORDER": "1", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "180", "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": "1500"
        ]
        XCTAssertTrue(try PublishingQualityDriver.repeatedLiveExportRequested(environment: valid))
        XCTAssertFalse(try PublishingQualityDriver.repeatedLiveExportRequested(environment: [:]))
        for mode in ["staged", "renew", "expire", ""] {
            var legacy = valid; legacy["SCOREBUG_TEST_BANDWIDTH_PROBE"] = mode
            XCTAssertFalse(try PublishingQualityDriver.repeatedLiveExportRequested(environment: legacy))
        }
        for key in ["SCOREBUG_TEST_MEASURED_TRIAL", "SCOREBUG_TEST_CANDIDATE_HEADROOM", "SCOREBUG_TEST_VIDEO_OBSERVATIONS"] {
            var malformed = valid; malformed.removeValue(forKey: key)
            XCTAssertThrowsError(try PublishingQualityDriver.repeatedLiveExportRequested(environment: malformed))
        }
    }

    func testFailedLivePrefixRemainsNonterminalUntilJoinedStoppedSnapshot() async throws {
        let attempt = UUID()
        let owner = try PublishingQualitySession(operations: .init(setBitRate: { _, _ in
            throw NSError(domain: "LiveCheckpointFixture", code: 1)
        }, stop: {}), profiles: [.init(id: "hd", width: 1920, height: 1080,
            minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
            attemptID: attempt, initial: .init(profileID: "hd", videoBitrate: 6_000_000), uptime: { 100 })
        var live: [Data] = [], final: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil,
            uptime: { 100 }, liveExport: { live.append($0) }, export: { final = $0 })
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: nil, receipt: nil, ingress: nil,
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        await checkpointWait { !live.isEmpty }
        XCTAssertTrue(driver.isClosed)
        let failed = try checkpointObject(XCTUnwrap(live.last))
        let failedQuality = try XCTUnwrap(failed["quality"] as? [String: Any])
        let failedRows = try XCTUnwrap(failedQuality["events"] as? [[String: Any]])
        XCTAssertEqual(failed["closed"] as? Bool, false, "Session closure does not finalize the original audit prefix")
        XCTAssertEqual(failed["publishingAttemptID"] as? String, attempt.uuidString.lowercased())
        XCTAssertEqual(failedRows.last?["kind"] as? String, "failed")
        XCTAssertEqual(failedRows.last?["closed"] as? Bool, true)
        XCTAssertNil(final)
        await driver.stop()
        let terminal = try checkpointObject(XCTUnwrap(live.last)), quality = try checkpointObject(XCTUnwrap(final))
        let rows = try XCTUnwrap(quality["events"] as? [[String: Any]])
        XCTAssertEqual(terminal["closed"] as? Bool, true)
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["failed", "stopped"])
        XCTAssertEqual(try json(failedRows), try json(Array(rows.prefix(failedRows.count))))
        XCTAssertEqual(try json(XCTUnwrap(terminal["quality"])), try json(quality))
        XCTAssertEqual(terminal["eventCount"] as? Int, rows.count)
        let count = live.count
        await driver.stop()
        XCTAssertEqual(live.count, count)
    }

    func testDefaultDriverRetainsLegacyFinalQualityEnvelope() async throws {
        let f = try await CandidateQualityFixture.make()
        var exported: [Data] = []
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now }, export: { exported.append($0) })
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertTrue(exported.isEmpty)
        await driver.stop()
        XCTAssertEqual(exported.count, 1)
        let quality = try checkpointObject(XCTUnwrap(exported.first))
        XCTAssertEqual(quality["formatVersion"] as? Int, 4)
        XCTAssertEqual(Set(quality.keys), Set(["formatVersion", "overflow", "deadlineFailuresEnabled", "decoderStallEnabled", "measuredSourceEvaluationEnabled", "events"]))
        XCTAssertEqual(quality["overflow"] as? Bool, false)
    }

    private func checkpointObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func checkpointWait(_ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(condition())
    }

    func testMeasurementContextForwardsCurrentOwnerWithoutApplyingQuality() async throws {
        let f = try await CandidateQualityFixture.make()
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil)
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let context = await driver.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertEqual(context?.readiness.attemptID, f.attempt)
        XCTAssertEqual(context?.applied.receipt.configuration, f.native.receipt?.configuration)
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        var invalid = diagnostics; invalid.isPublishing = false
        let absent = await driver.candidateMeasurementContext(diagnostics: invalid)
        XCTAssertNil(absent)
        driver.cancel()
        let closed = await driver.candidateMeasurementContext(diagnostics: diagnostics)
        XCTAssertNil(closed)
        await driver.stop()
    }

    func testCancelledMeasurementQueryDoesNotReturnReadiness() async throws {
        let f = try await CandidateQualityFixture.make()
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil)
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let query = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await driver.candidateMeasurementContext(diagnostics: diagnostics)
        }
        let context = await query.value
        XCTAssertNil(context)
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        await driver.stop()
    }

    func testCandidateWaitsForFreshOverlappingSourceWithoutConsumingIdentity() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true, priorHealthEnd: 110)
        var data: Data?, calls = 0
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            uptime: { f.native.now }, export: { data = $0 })
        driver.candidateInputProvider = { _ in calls += 1; return f.admission }
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        await driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics))?.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["kind"] as? String == "candidate" }.count, 1)
    }

    func testSourceArrivingDuringProviderAwaitIsReadAtCandidateExecution() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now })
        driver.candidateInputProvider = { state in
            XCTAssertNil(state.lastWindow)
            _ = try? await f.owner.evaluate(source: try! XCTUnwrap(f.source), diagnostics: try! XCTUnwrap(f.sourceDiagnostics),
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            return f.admission
        }
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
        await driver.stop()
    }

    func testSourceInvalidatedDuringProviderAwaitCannotConsumeCandidate() async throws {
        let f = try await CandidateQualityFixture.make()
        var data: Data?
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now }, export: { data = $0 })
        driver.candidateInputProvider = { _ in
            var invalid = try! f.diagnostics(); invalid.isPublishing = false
            _ = try? await f.owner.evaluateLocalPressure(diagnostics: invalid, transportLimits: nil)
            return f.admission
        }
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertFalse(events.contains { $0["kind"] as? String == "candidate" || ($0["reason"] as? String)?.hasPrefix("candidate-") == true })
    }

    func testUnavailableCadenceProviderBlocksSourceAndCandidatePositivePaths() async throws {
        for ownerLost in [false, true] {
            let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
            let driver = PublishingQualityDriver(owner: f.owner,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                uptime: { f.native.now })
            let diagnostics = try f.diagnostics()
            driver.cadenceInputProvider = { ownerLost ? nil : .init(cadence: nil, diagnostics: diagnostics) }
            var calls = 0
            driver.candidateInputProvider = { _ in calls += 1; return f.admission }
            await driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics))?.value
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(f.native.calls, ["rate:350000"])
            let state = await f.owner.snapshot
            XCTAssertNil(state.lastWindow)
            await driver.stop()
        }
    }

    func testMissingCurrentCadenceResetsOwnedTrialImmediately() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        f.native.setNow(116)
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now })
        let current = try f.diagnostics()
        driver.cadenceInputProvider = { .init(cadence: nil, diagnostics: current) }
        await driver.tick(encoderReady: true, source: nil, diagnostics: current)?.value
        let state = await f.owner.snapshot
        XCTAssertEqual(state.revision, 2)
        XCTAssertEqual(state.applied?.profileID, "240p30")
        await driver.stop()
    }

    func testMissingCadenceWithInvalidReceiptInvalidatesProbationImmediately() async throws {
        let f = try await CandidateQualityFixture.make()
        let decision = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        f.native.setNow(116)
        var invalid = try f.diagnostics(); invalid.receipt = nil
        do { try await f.owner.noteUnavailableCadence(diagnostics: invalid); XCTFail("Invalid receipt") }
        catch { XCTAssertEqual(error as? PublishingQualityTelemetry.Failure, .ownership) }
        let reset = try await f.owner.checkTrialDeadline()
        XCTAssertEqual(reset?.kind, .reset)
        await f.owner.stop()
    }

    func testMeasuredDeliveryModeRetainsSourceHealthBeforeCandidateAdmission() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            uptime: { f.native.now }, enableDeliveryFailures: true, enableMeasuredSourceEvaluation: true)
        driver.candidateInputProvider = { state in
            XCTAssertNotNil(state.lastWindow)
            return f.admission
        }
        await driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics))?.value
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
        await driver.stop()
    }

    func testNewHealthySourceAndCandidateApplyInSameTick() async throws {
        let f = try await CandidateQualityFixture.make(deferHealthEvaluation: true)
        let driver = PublishingQualityDriver(owner: f.owner,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            uptime: { f.native.now })
        var calls = 0
        driver.candidateInputProvider = { state in
            calls += 1
            XCTAssertNotNil(state.lastWindow)
            return f.admission
        }
        await driver.tick(encoderReady: true, source: f.source, diagnostics: try XCTUnwrap(f.sourceDiagnostics))?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
        XCTAssertFalse(driver.isClosed)
        await driver.stop()
    }
    func testCandidateProviderReadsCurrentSnapshotAppliesBeforeAuditAndConsumesIdentityOnce() async throws {
        let f = try await CandidateQualityFixture.make()
        var exported: Data?, calls = 0
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now }, export: { exported = $0 })
        driver.candidateInputProvider = { state in
            calls += 1
            XCTAssertEqual(state.revision, calls == 1 ? 0 : 1)
            return f.admission
        }
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
        XCTAssertFalse(driver.isClosed)
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(f.native.calls.count, 3)
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let candidateIndex = try XCTUnwrap(events.firstIndex { $0["kind"] as? String == "candidate" })
        let appliedIndex = try XCTUnwrap(events.firstIndex { $0["kind"] as? String == "applied" })
        XCTAssertLessThan(appliedIndex, candidateIndex, "The short probe lease must reach native admission before audit awaits")
        XCTAssertEqual(events.filter { $0["kind"] as? String == "candidate" }.count, 1)
        let evidence = try XCTUnwrap(events[candidateIndex]["candidate"] as? [String: Any])
        XCTAssertEqual(evidence["id"] as? String, f.admission.value.id.uuidString)
        XCTAssertEqual(evidence["appliedRevision"] as? String, "0")
        XCTAssertEqual(evidence["evaluatedAt"] as? Double, f.admission.value.evaluatedAt)
        XCTAssertEqual(evidence["validUntil"] as? Double, f.admission.value.validUntil)
        XCTAssertEqual(events[appliedIndex]["revision"] as? String, "1")
        let action = try XCTUnwrap(events[appliedIndex]["action"] as? [String: Any])
        let application = try XCTUnwrap(events[appliedIndex]["application"] as? [String: Any])
        XCTAssertEqual(action["candidateID"] as? String, f.admission.value.id.uuidString)
        XCTAssertEqual(application["candidateID"] as? String, f.admission.value.id.uuidString)
        XCTAssertEqual(evidence["candidateTransportBitsPerSecond"] as? Double, f.admission.value.candidateTransportBitsPerSecond)
        XCTAssertEqual(evidence["deliveredPaddingBitsPerSecond"] as? Double, f.admission.value.deliveredPaddingBitsPerSecond)
    }
    func testCandidateProviderRunsWithNoCandidateAndIsClearedOnCancel() async throws {
        let f = try await CandidateQualityFixture.make()
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil, uptime: { f.native.now })
        var first = 0, second = 0
        driver.candidateInputProvider = { _ in first += 1; return nil }
        let pending = driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())
        driver.candidateInputProvider = { _ in second += 1; return nil }
        await pending?.value
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(f.native.calls.count, 1)
        driver.cancel()
        XCTAssertNil(driver.candidateInputProvider)
        await driver.stop()
    }
    func testCandidateProviderCannotOvertakeLocalPressure() async throws {
        let f = try await CandidateQualityFixture.make()
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil, uptime: { f.native.now })
        var calls = 0
        driver.candidateInputProvider = { _ in calls += 1; return f.admission }
        f.native.setNow(115.4)
        var diagnostics = try f.diagnostics(), thermal = PublishingThermalTracker()
        thermal.observe(.init(state: .serious, sampledAt: 115))
        thermal.observe(.init(state: .serious, sampledAt: 115.2))
        thermal.observe(.init(state: .serious, sampledAt: 115.4))
        diagnostics.thermal = thermal.snapshot
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(f.native.calls.count, 1)
        XCTAssertFalse(driver.isClosed)
        await driver.stop()
    }
    func testRevokedCandidateFromAsyncProviderDoesNotStopOrWrite() async throws {
        let f = try await CandidateQualityFixture.make()
        var exported: Data?
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now }, export: { exported = $0 })
        driver.candidateInputProvider = { _ in
            await Task.yield()
            f.admission.authority.revoke()
            return f.admission
        }
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        await driver.tick(encoderReady: true, source: nil, diagnostics: try f.diagnostics())?.value
        XCTAssertEqual(f.native.calls.count, 1)
        XCTAssertEqual(f.native.stops, 0)
        XCTAssertFalse(driver.isClosed)
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["kind"] as? String == "rejected" && $0["reason"] as? String == "candidate-staleAdvice" }.count, 1)
    }
    func testTransportEvidencePreservesBandwidthEstimateOnActualCollectionWithoutInventingCapacity() throws {
        var history = PublishingTransportStatisticsTracker()
        for (time, bandwidth) in [(10.0, 0.0), (10.25, 3.875), (10.5, 128.0)] {
            history.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(time * 1000),
                sentBytes: UInt64(time * 1000), retransmittedBytes: 0, droppedPackets: 0,
                rttMilliseconds: 1, estimatedBandwidthMbps: bandwidth, senderBufferedBytes: 1,
                senderBufferMilliseconds: 1, availableSenderBytes: 1000))
        }
        let evidence = PublishingQualityDriver.transportEvidence(history.snapshot)
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.compactMap { $0["estimatedBandwidthMbps"] as? Double }, [0, 3.875, 128])
        XCTAssertEqual(samples.compactMap { $0["sampledAt"] as? Double }, [10, 10.25, 10.5])
        XCTAssertTrue(samples.allSatisfy { $0["usableVideoCapacity"] == nil })
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: evidence))
    }

    func testTransportEvidenceKeepsNegotiatedDelayOnItsActualSampleAndPreservesUnknown() throws {
        var history = PublishingTransportStatisticsTracker()
        for (time, delay) in [(10.0, nil as Int32?), (10.25, 120), (10.5, 0)] {
            history.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(time * 1000),
                sentBytes: UInt64(time * 1000), retransmittedBytes: 0, droppedPackets: 0,
                rttMilliseconds: 1, estimatedBandwidthMbps: 100, senderBufferedBytes: 1,
                senderBufferMilliseconds: 1, availableSenderBytes: 1000, senderDeliveryDelayMilliseconds: delay))
        }
        let evidence = PublishingQualityDriver.transportEvidence(history.snapshot)
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples[0]["senderDeliveryDelayMilliseconds"] is NSNull)
        XCTAssertEqual(samples[1]["senderDeliveryDelayMilliseconds"] as? Int32, 120)
        XCTAssertEqual(samples[1]["sampledAt"] as? Double, 10.25)
        XCTAssertEqual(samples[2]["senderDeliveryDelayMilliseconds"] as? Int32, 0)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: evidence))
    }

    func testTransportEvidenceExportsActualPacingAndPreservesUnknown() throws {
        var history = PublishingTransportStatisticsTracker()
        for (time, maximum, period) in [(10.0, nil as Double?, nil as Double?), (10.25, 7.5, 1403.7)] {
            history.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(time * 1000),
                sentBytes: UInt64(time * 1000), retransmittedBytes: 0, droppedPackets: 0,
                rttMilliseconds: 1, estimatedBandwidthMbps: 100, senderBufferedBytes: 1,
                senderBufferMilliseconds: 1, availableSenderBytes: 1000,
                senderMaximumBandwidthMbps: maximum, packetSendPeriodMicroseconds: period))
        }
        let evidence = PublishingQualityDriver.transportEvidence(history.snapshot)
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        XCTAssertTrue(samples[0]["senderMaximumBandwidthMbps"] is NSNull)
        XCTAssertTrue(samples[0]["packetSendPeriodMicroseconds"] is NSNull)
        XCTAssertEqual(samples[1]["senderMaximumBandwidthMbps"] as? Double, 7.5)
        XCTAssertEqual(samples[1]["packetSendPeriodMicroseconds"] as? Double, 1403.7)
        XCTAssertEqual(samples[1]["sampledAt"] as? Double, 10.25)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: evidence))
    }

    func testDeadlineProviderIsReadAtExecutionAndClearedOnCancel() async throws {
        let native = DriverNative(); native.release()
        let (driver, diagnostics) = try make(native)
        var first = 0, second = 0
        driver.deliveryInputProvider = { first += 1; return nil }
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        let work = driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)
        driver.deliveryInputProvider = { second += 1; return nil }
        await work?.value
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
        let pending = driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)
        driver.cancel()
        await pending?.value
        XCTAssertNil(driver.deliveryInputProvider)
        XCTAssertEqual(second, 1)
        await driver.stop()
    }

    private func make(_ native: DriverNative) throws -> (PublishingQualityDriver, PublishingQualityTelemetry.Diagnostics) {
        let owner = try PublishingQualitySession(operations: native.operations,
            profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
            attemptID: UUID(), initial: .init(profileID: "hd", videoBitrate: 6_000_000), uptime: { 100 })
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: nil, receipt: nil, ingress: nil,
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
        return (.init(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { 100 }), diagnostics)
    }
    func testExpiredAdviceSkipsWriteAndLaterAdviceStillApplies() async throws {
        let native = DriverNative(), attempt = UUID()
        native.release()
        let owner = try PublishingQualitySession(operations: native.operations,
            profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
            attemptID: attempt, initial: .init(profileID: "hd", videoBitrate: 6_000_000), uptime: { native.now })
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { native.now },
                                             export: { exported = $0 })
        try await owner.bootstrap()
        func advice(_ start: Double) async throws -> QualityController.Recommendation {
            native.setNow(start + 5)
            let result = try await owner.evaluate(.init(attemptID: attempt, sequence: UInt64(start), appliedRevision: 0,
                start: start, end: start + 5, capturedFreshFrames: 150, encodedFreshFrames: 150,
                receiver: .init(freshFrames: 100, observedAt: start + 5), sourceLoss: .init(expectedFrames: 150, lostFrames: 50),
                meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal))
            return try XCTUnwrap(result.recommendation)
        }
        let expired = try await advice(100)
        native.setNow(expired.validUntil + 0.1)
        try await driver.apply(expired)
        XCTAssertFalse(driver.isClosed); XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 0)
        let fresh = try await advice(105)
        try await driver.apply(fresh)
        XCTAssertEqual(native.calls, 2)
        let snapshot = await owner.snapshot
        XCTAssertFalse(snapshot.isClosed); XCTAssertEqual(snapshot.revision, 1)
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 4)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let applied = try XCTUnwrap(events.first { $0["kind"] as? String == "applied" })
        let application = try XCTUnwrap(applied["application"] as? [String: Any])
        XCTAssertEqual(application["admittedAt"] as? Double, 110)
        XCTAssertEqual(application["completionDeadline"] as? Double, 112)
        XCTAssertEqual(application["attemptID"] as? String, attempt.uuidString)
        XCTAssertEqual(application["fromRevision"] as? String, "0")
        XCTAssertEqual(application["windowSequence"] as? String, "105")
        XCTAssertEqual(application["id"] as? String, snapshot.application?.id.uuidString)
    }
    func testPendingFirstFrameDoesNotWriteOrCloseUntilBoundedWaitExpires() async throws {
        for arrivesAtDeadline in [false, true] {
        let native = DriverNative()
        native.release()
        var operations = native.operations
        operations.videoStartup = {
            guard arrivesAtDeadline, native.now >= 102 else { return nil }
            return .init(profile: .low240, width: 426, height: 240, publishingGeneration: 7,
                encoderSessionID: UUID(), firstSourcePTS: .zero, submittedAt: 100, completedAt: 101, observedAt: 101.9)
        }
        let owner = try PublishingQualitySession(operations: operations,
            profiles: [.init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000)],
            attemptID: UUID(), initial: .init(profileID: "240p30", videoBitrate: 350_000), behavior: .progressive,
            uptime: { native.now })
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { native.now })
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: nil, receipt: nil, ingress: nil,
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        XCTAssertFalse(driver.isClosed); XCTAssertEqual(native.calls, 0)
        native.setNow(101.999)
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        XCTAssertFalse(driver.isClosed); XCTAssertEqual(native.calls, 0)
        native.setNow(102)
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        XCTAssertTrue(driver.isClosed); XCTAssertEqual(native.calls, 0); XCTAssertEqual(native.stops, 1)
        await driver.stop()
        }
    }
    func testWaitsForEncoderAndCoalescesHealthTicksIntoOneBootstrap() async throws {
        let native = DriverNative(), (driver, diagnostics) = try make(native)
        driver.tick(encoderReady: false, source: nil, diagnostics: diagnostics)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(native.calls, 0)
        for _ in 0..<100 { driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics) }
        let end = ContinuousClock.now + .seconds(2)
        while native.calls == 0, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(native.calls, 1)
        native.release()
        while driver.bootstrapCount == 0, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(driver.bootstrapCount, 1)
        await driver.stop()
    }
    func testStopJoinsSuspendedWriteAndPreventsLateBootstrapOrFutureTicks() async throws {
        let native = DriverNative(), (driver, diagnostics) = try make(native)
        driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)
        let end = ContinuousClock.now + .seconds(2)
        while native.calls == 0, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(native.calls, 1)
        await driver.stop()
        XCTAssertTrue(driver.isClosed); XCTAssertEqual(driver.bootstrapCount, 0)
        driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)
        await driver.stop()
        XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 1)
    }
}
private final class DriverNative: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, stopCount = 0
    private var clock = 100.0
    var now: Double { lock.withLock { clock } }
    func setNow(_ value: Double) { lock.withLock { clock = value } }
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var calls: Int { lock.withLock { count } }
    var stops: Int { lock.withLock { stopCount } }
    var operations: PublishingQualitySession.Operations {
        .init(setBitRate: { rate, _ in
            self.lock.withLock { self.count += 1 }
            await withCheckedContinuation { c in
                let ready = self.lock.withLock { if self.released { return true }; self.continuation = c; return false }
                if ready { c.resume() }
            }
            return PublishingBitRateChange(publishingGeneration: 1,
                configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!,
                acceptedAt: self.now, lastSubmittedSourcePTS: nil)!
        }, stop: { self.lock.withLock { self.stopCount += 1 }; self.release() })
    }
    func release() {
        let c = lock.withLock { released = true; let c = continuation; continuation = nil; return c }
        c?.resume()
    }
}

@MainActor private final class LiveCheckpointGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { value in
            if released { value.resume() } else { continuation = value }
        }
    }
    func release() {
        released = true
        let value = continuation; continuation = nil; value?.resume()
    }
}

import CoreMedia
import ScorebugCore
import Foundation
import ScorebugMedia
@testable import ScorebugStreaming
@testable import SRTHaishinKit
import libsrt
@testable import HaishinKit
import XCTest

final class NativeOwnedCandidatePublisherTests: XCTestCase {
    @MainActor func testContinuousMeasurementsRetryBeyondLaboratoryLimitWithFreshHealth() async throws {
        try await exerciseRetryLimit(continuous: true)
    }
    @MainActor func testLaboratoryMeasurementsKeepSixteenAttemptLimitAndCompleteAudit() async throws {
        try await exerciseRetryLimit(continuous: false)
    }
    @MainActor private func exerciseRetryLimit(continuous: Bool) async throws {
        let f = try await CandidateQualityFixture.make()
        var diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = continuous
            ? NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
                campaignOwner: PublishingCandidateCampaignOwner(),
                stagePlan: try NativeCandidateStagePlan(bitRates: [500_000, 2_000_000], holds: [0.8, 0.5]))
            : NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
                campaignOwner: PublishingCandidateCampaignOwner())
        try await wrapper.start()
        try await f.owner.installOwnedMeasurementPublisher(wrapper)
        var sequence: Int64 = 3
        for attempt in 1...18 {
            await fixture.failNextAllocation()
            let started = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
            XCTAssertEqual(started, continuous || attempt <= 16, "Attempt \(attempt)")
            await f.owner.joinOwnedMeasurement()
            let premature = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
            XCTAssertFalse(premature, "Settlement still requires a new healthy hold")
            var start = f.native.now + 1
            // The policy caps failure backoff at 60 seconds; every retry earns it anew.
            for _ in 0..<12 {
                f.native.setNow(start + 5.1)
                let fresh = try await f.freshSource(start: start, sequence: sequence)
                _ = try await f.owner.evaluate(source: fresh.0, diagnostics: fresh.1,
                    workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                    transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
                diagnostics = fresh.1; sequence += 1; start += 5
            }
        }
        let allocated = await fixture.counts.allocations
        XCTAssertEqual(allocated, continuous ? 18 : 16)
        let retained = await fixture.retainedOperationCount
        XCTAssertLessThanOrEqual(retained, 1, "Settled attempts must release their exact operation owners")
        if continuous { XCTAssertNil(wrapper.audit, "Continuous ownership must not allocate an event history") }
        else {
            let rows = try auditRows(wrapper)
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "registered" }.count, 16)
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "settledFailure" }.count, 16)
            XCTAssertEqual(wrapper.stagePlan, .laboratory)
        }
        await f.owner.stop(); await wrapper.stop()
    }

    func testStagePlanRejectsInvalidRatesCountsAndHolds() throws {
        for rates in [[], [0], [-1], [12_000_001], [500_000, 0], [500_000, 12_000_001], Array(repeating: 500_000, count: 33)] {
            XCTAssertThrowsError(try NativeCandidateStagePlan(bitRates: rates, holds: Array(repeating: 0.8, count: rates.count)))
        }
        for holds in [[], [0.8], [-1, 0.5], [0.8, 0], [0.8, 0.499], [Double.nan, 0.5], [Double.infinity, 0.5], [59.5, 0.5]] {
            XCTAssertThrowsError(try NativeCandidateStagePlan(bitRates: [500_000, 2_000_000], holds: holds))
        }
        let plan = try NativeCandidateStagePlan(bitRates: [800_000, 3_000_000], holds: [0.8, 0.5])
        XCTAssertNoThrow(try NativeCandidateStagePlan(bitRates: [12_000_000], holds: [0.5]))
        XCTAssertEqual(plan.finalStage, 2)
        XCTAssertEqual(plan.bitRates, [800_000, 3_000_000])
        XCTAssertEqual(NativeCandidateStagePlan.laboratory.bitRates, [500_000, 2_000_000, 12_000_000])
        XCTAssertEqual(NativeCandidateStagePlan.laboratory.holds, [0.8, 0.8, 0.5])
    }

    @MainActor func testContinuousRetryWaitsForHeldCleanupThenEarnsFreshHealth() async throws {
        let f = try await CandidateQualityFixture.make()
        var diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        await fixture.hold(.retire)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner(),
            stagePlan: try NativeCandidateStagePlan(bitRates: [500_000, 1_000_000, 2_000_000], holds: [0.8, 0.8, 0.5]))
        try await wrapper.start(); try await f.owner.installOwnedMeasurementPublisher(wrapper)
        let started = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertTrue(started)
        await fixture.waitForEntry()
        try await f.owner.noteUnavailableCadence(diagnostics: diagnostics)
        var start = f.native.now + 1
        for sequence in 3...16 {
            f.native.setNow(start + 5.1)
            let fresh = try await f.freshSource(start: start, sequence: Int64(sequence))
            _ = try await f.owner.evaluate(source: fresh.0, diagnostics: fresh.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
            diagnostics = fresh.1; start += 5
            let retried = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
            XCTAssertFalse(retried, "Healthy telemetry cannot release the still-unjoined native owner")
        }
        let heldCounts = await fixture.counts
        XCTAssertEqual(heldCounts.allocations, 1)
        await fixture.release(); await f.owner.joinOwnedMeasurement()
        let premature = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertFalse(premature, "Pre-join health cannot satisfy post-settlement retry backoff")
        start = f.native.now + 1
        for sequence in 17...18 {
            f.native.setNow(start + 5.1)
            let fresh = try await f.freshSource(start: start, sequence: Int64(sequence))
            _ = try await f.owner.evaluate(source: fresh.0, diagnostics: fresh.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
            diagnostics = fresh.1; start += 5
        }
        await fixture.failNextAllocation()
        let retried = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertTrue(retried)
        await f.owner.joinOwnedMeasurement()
        let finalCounts = await fixture.counts
        XCTAssertEqual(finalCounts.allocations, 2)
        await f.owner.stop(); await wrapper.stop()
    }

    func testOwnedFixtureRequiresCompleteDedicatedCapacityRoute() throws {
        var environment = ["SCOREBUG_TEST_OWNED_MEASUREMENT": "1", "SCOREBUG_TEST_CAPACITY_RECOVERY": "1",
            "SCOREBUG_TEST_UPLINK_PROFILE": "capacity750k-retry", "SCOREBUG_TEST_UPLINK_PROXY_PORT": "1234",
            "SCOREBUG_TEST_PROBE_POLICY": "recovery-budget-v1", "SCOREBUG_TEST_FILE_CAPTURE": "1",
            "SCOREBUG_TEST_MEASURED_TRIAL": "1", "SCOREBUG_TEST_CANDIDATE_HEADROOM": "1",
            "SCOREBUG_TEST_CANDIDATE_PROFILE": "360p30", "SCOREBUG_TEST_BANDWIDTH_PROBE": "staged",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_DIRECT_RTMP_RECORDER": "1",
            "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "270",
            "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": "1500"]
        XCTAssertTrue(try NativeOwnedCandidatePublisher.requested(environment: environment))
        XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: environment))
        environment.removeValue(forKey: "SCOREBUG_TEST_OWNED_MEASUREMENT")
        XCTAssertFalse(VideoObservationFixture.capacityFileUplink(environment: environment))
        environment["SCOREBUG_TEST_OWNED_MEASUREMENT"] = "1"
        environment["SCOREBUG_TEST_UPLINK_PROFILE"] = "capacity750k"
        XCTAssertThrowsError(try NativeOwnedCandidatePublisher.requested(environment: environment))
    }

    func testTimingProfilesRequireCompleteOwnedRouteAndPreserveAuditContract() throws {
        let base = ["SCOREBUG_TEST_OWNED_MEASUREMENT": "1", "SCOREBUG_TEST_CAPACITY_RECOVERY": "1",
            "SCOREBUG_TEST_UPLINK_PROFILE": "capacity750k-retry", "SCOREBUG_TEST_UPLINK_PROXY_PORT": "1234",
            "SCOREBUG_TEST_PROBE_POLICY": "recovery-budget-v1", "SCOREBUG_TEST_FILE_CAPTURE": "1",
            "SCOREBUG_TEST_MEASURED_TRIAL": "1", "SCOREBUG_TEST_CANDIDATE_HEADROOM": "1",
            "SCOREBUG_TEST_CANDIDATE_PROFILE": "360p30", "SCOREBUG_TEST_BANDWIDTH_PROBE": "staged",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_DIRECT_RTMP_RECORDER": "1",
            "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "270",
            "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": "1500"]
        for timing in StreamingTimingProfile.allCases {
            var environment = base
            environment["SCOREBUG_TEST_TIMING_PROFILE"] = timing.rawValue
            environment["SCOREBUG_TEST_CAPACITY_EVIDENCE"] = "token-budget-v1"
            environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] = String(timing.decoderBudgetMs)
            XCTAssertEqual(try VideoObservationFixture.timingProfile(environment: environment), timing)
            XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: environment))
            XCTAssertEqual(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: environment), timing.decoderBudget)
            XCTAssertTrue(try NativeOwnedCandidatePublisher.requested(environment: environment))
            let audit = try PublishingDeliveryMonitor.Audit(latencyBudget: timing.decoderBudget,
                maximumSampleAge: 0.25, usesRequestTiming: true, environment: environment, timingProfile: timing)
            audit.close()
            let delivery = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.data()) as? [String: Any])
            var cadenceAudit = WorkerCadenceReportAudit(usesRequestTiming: true, environment: environment)
            cadenceAudit.close()
            let cadence = try XCTUnwrap(JSONSerialization.jsonObject(with: cadenceAudit.data()) as? [String: Any])
            for value in [delivery, cadence] {
                XCTAssertEqual(value["formatVersion"] as? Int, 2)
                XCTAssertEqual(value["mode"] as? String, "capacity")
                XCTAssertEqual(value["timingContract"] as? NSDictionary, timing.evidence as NSDictionary?)
            }
            for key in base.keys {
                var invalid = environment; invalid.removeValue(forKey: key)
                XCTAssertThrowsError(try VideoObservationFixture.timingProfile(environment: invalid), key)
            }
            for value in ["", "unknown", "2000", " broadcast-reliability2000-v1"] {
                var invalid = environment; invalid["SCOREBUG_TEST_TIMING_PROFILE"] = value
                XCTAssertThrowsError(try VideoObservationFixture.timingProfile(environment: invalid))
            }
            for value in ["2", "2000.0", "02000", " 2000", "1000"] {
                var invalid = environment; invalid["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] = value
                XCTAssertThrowsError(try VideoObservationFixture.timingProfile(environment: invalid))
            }
        }
        XCTAssertEqual(try VideoObservationFixture.timingProfile(environment: base), .strict1500)
    }

    func testActualOwnedSRTCandidateTransfersThroughGuardedWrapperAndAcknowledgesOnce() async throws {
        try await exerciseOwnedApplication(.accepted)
    }
    func testOwnedTransferredSafeProfileRejectionJoinsAndSettlesWithoutStopping() async throws {
        try await exerciseOwnedApplication(.profileRejected)
    }
    func testOwnedTransferredRateRejectionAfterProfileEffectStopsWithoutAcknowledgment() async throws {
        try await exerciseOwnedApplication(.rateRejected)
    }
    func testOwnedNativeContextExpiryBeforeTransferSkipsWithoutStopping() async throws {
        try await exerciseOwnedApplication(.contextRejected)
    }
    func testDriverHandlesFreshDownwardTickWhileRejectedMeasurementCleanupIsHeld() async throws {
        try await exerciseOwnedApplication(.heldProfileRejection)
    }
    func testDriverStopJoinsRejectedMeasurementBeforeClosingAudit() async throws {
        try await exerciseOwnedApplication(.heldRejectionStop)
    }
    func testFourSecondCandidateUsesActualFiveSecondSourceCadenceWithReportLag() async throws {
        try await exerciseOwnedApplication(.sourceCadence)
    }
    func testContinuousTwoStagePlanBindsItsFinalStageAndKeepsItImmutable() async throws {
        try await exerciseOwnedApplication(.continuousPlan)
    }
    private enum ApplicationOutcome { case continuousPlan, sourceCadence, accepted, profileRejected, rateRejected, contextRejected, heldProfileRejection, heldRejectionStop }
    @MainActor private func exerciseOwnedApplication(_ outcome: ApplicationOutcome) async throws {
        let router = OwnedMutationRouter()
        let heldRejection = outcome == .heldProfileRejection || outcome == .heldRejectionStop
        let baseline: PublishingVideoProfile = heldRejection ? .low360 : .low240
        let f = try await CandidateQualityFixture.make(initialProfile: baseline, guarded: router.guarded)
        let start = ProcessInfo.processInfo.systemUptime
        f.native.useActualInstant()
        f.native.setNow(start)
        let fresh = try await f.freshSource(start: start - (outcome == .sourceCadence ? 6.8 : 5), sequence: 3)
        _ = try await f.owner.evaluate(source: fresh.0, diagnostics: fresh.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        var nativeOperations = await fixture.operations()
        nativeOperations.validateVideoMutationExpectation = { _ in }
        nativeOperations.setProfileExpecting = { profile, _ in
            if outcome == .profileRejected || (heldRejection && profile != .low240) { throw PublishingVideoMutationAdmissionError.stale }
            return try await f.native.operations.setProfile!(profile, f.native.now + 2)
        }
        nativeOperations.setBitRateExpecting = { rate, _ in
            if outcome == .rateRejected { throw PublishingVideoMutationAdmissionError.stale }
            return try await f.native.operations.setBitRate(rate, f.native.now + 2)
        }
        let lower = SRTMediaPublisher(operations: nativeOperations)
        let campaign = PublishingCandidateCampaignOwner(factory: { scope, profile, generation in
            let result = OwnedCandidateResult(scope: scope, profile: profile, generation: generation)
            return .init(id: result.id, start: { result.start() }, offer: { _ in true }, observeAudio: { _ in },
                cancel: { result.cancel($0) }, result: { await result.result() })
        })
        let wrapper = outcome == .continuousPlan
            ? NativeOwnedCandidatePublisher(publisher: lower, scope: fresh.1.ingress!.scope, campaignOwner: campaign,
                stagePlan: try NativeCandidateStagePlan(bitRates: [800_000, 3_000_000], holds: [0.8, 0.5]))
            : NativeOwnedCandidatePublisher(publisher: lower, scope: fresh.1.ingress!.scope, campaignOwner: campaign)
        router.install(wrapper)
        try await wrapper.start(); await fixture.enableSending()
        try await f.owner.installOwnedMeasurementPublisher(wrapper, diagnostics: {
            // Immutable configuration diagnostics re-read by the Session at application.
            fresh.1
        })
        XCTAssertTrue(wrapper.installReaders(candidate: { await f.owner.ownedCandidateSnapshot() },
            probe: { await f.owner.ownedProbeObservation() }, pressure: {
                let now = ProcessInfo.processInfo.systemUptime
                return .init(observedAt: now, sampledAt: now, thermal: 0, dropped: 0, rejected: 0, publishing: true)
            }))
        if outcome == .sourceCadence {
            let driver = PublishingQualityDriver(owner: f.owner,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                uptime: { f.native.now })
            driver.candidateInputProvider = { [self] _ in
                guard let value = await wrapper.candidateSnapshot() else { return nil }
                return try? ownedAdmission(value, f: f)
            }
            var nextSourceReport = 5.0, sequence: Int64 = 4
            var diagnostics = fresh.1
            while ProcessInfo.processInfo.systemUptime - start < 12 {
                f.native.setNow(ProcessInfo.processInfo.systemUptime)
                var source: WorkerSourceIntervalObservation?
                if f.native.now - start >= nextSourceReport {
                    let next = try await f.freshSource(start: start + nextSourceReport - 6.8, sequence: sequence)
                    source = next.0; diagnostics = next.1
                    nextSourceReport += 5; sequence += 1
                }
                await driver.tick(encoderReady: true, source: source, diagnostics: diagnostics)?.value
                if (await f.owner.snapshot).revision == 1 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let state = await f.owner.snapshot
            XCTAssertEqual(state.revision, 1, "A real four-second candidate must meet the next observed source window without widening freshness")
            XCTAssertEqual(state.applied?.profileID, "360p30")
            await f.owner.joinOwnedMeasurement()
            let rows = try auditRows(wrapper)
            let measurement = try XCTUnwrap(rows.first { $0["kind"] as? String == "candidateJoined" }?["measurement"] as? [String: Any])
            XCTAssertEqual(measurement["acceptedInputCount"] as? Int, 121)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(measurement["endedAt"] as? Double) - XCTUnwrap(measurement["startedAt"] as? Double), 4)
            let terminal = try XCTUnwrap(rows.last { $0["kind"] as? String == "retired" }?["snapshot"] as? [String: Any])
            XCTAssertLessThanOrEqual(try XCTUnwrap(Int(try XCTUnwrap(terminal["totalAcceptedPayloadBytes"] as? String))), 16 * 1024 * 1024)
            XCTAssertFalse(driver.isClosed)
            await driver.stop(); await wrapper.stop()
            return
        }
        _ = try await f.owner.startOwnedMeasurement(diagnostics: fresh.1)
        let deadline = ContinuousClock.now + .seconds(11.5)
        var witness: NativeCandidatePublisher.CandidateSnapshot?
        var suppliedNextSource = false
        while witness == nil, ContinuousClock.now < deadline {
            f.native.setNow(ProcessInfo.processInfo.systemUptime)
            if !suppliedNextSource, f.native.now >= start + 5.15 {
                let next = try await f.freshSource(start: start, sequence: 4)
                _ = try await f.owner.evaluate(source: next.0, diagnostics: next.1,
                    workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                    transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
                suppliedNextSource = true
            }
            witness = await wrapper.candidateSnapshot()
            if witness == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let completedWitness = try XCTUnwrap(witness, "Actual registered stages must produce the joined candidate")
        if outcome == .continuousPlan {
            XCTAssertEqual(completedWitness.probe.stage, 2)
            XCTAssertEqual(completedWitness.probe.bitRate, 3_000_000)
            XCTAssertEqual(completedWitness.binding.id, completedWitness.probe.id)
            XCTAssertTrue(completedWitness.permitsCurrentCandidate(completedWitness.cost.id))
            try await Task.sleep(for: .milliseconds(150))
            let reread = await wrapper.candidateSnapshot()
            XCTAssertEqual(reread?.binding.id, completedWitness.binding.id)
            XCTAssertEqual(reread?.probe.id, completedWitness.probe.id)
            XCTAssertEqual(reread?.boundAt, completedWitness.boundAt)
            let counts = await fixture.counts
            XCTAssertEqual(counts.allocations, 2)
            XCTAssertNil(wrapper.audit)
            await f.owner.stop(); await wrapper.stop()
            return
        }
        while ProcessInfo.processInfo.systemUptime < max(start + 10.15, completedWitness.cost.endedAt + 0.1) { try await Task.sleep(for: .milliseconds(10)) }
        f.native.setNow(ProcessInfo.processInfo.systemUptime)
        let covered = try await f.freshSource(start: start + 5, sequence: 5)
        _ = try await f.owner.evaluate(source: covered.0, diagnostics: covered.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
        let finalValue = await wrapper.candidateSnapshot()
        let final = try XCTUnwrap(finalValue)
        let admission = try XCTUnwrap(ownedAdmission(final, f: f, baseline: baseline))
        if heldRejection {
            await fixture.hold(.retire)
            let driver = PublishingQualityDriver(owner: f.owner,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                uptime: { f.native.now })
            driver.candidateInputProvider = { _ in admission }
            let applying = driver.tick(encoderReady: true, source: nil, diagnostics: covered.1)
            await fixture.waitForEntry()
            var applyingFinished = false
            let completion = Task { await applying?.value; applyingFinished = true }
            let completionDeadline = ContinuousClock.now + .seconds(1)
            while !applyingFinished, ContinuousClock.now < completionDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(applyingFinished, "No-effect rejection must release Driver tick before measurement cleanup")
            XCTAssertEqual(try auditRows(wrapper).filter { $0["kind"] as? String == "applicationTransferred" }.count, 1)
            if outcome == .heldRejectionStop {
                let stopping = Task { await driver.stop() }
                while !(await f.owner.snapshot).isClosed { await Task.yield() }
                let before = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(wrapper.audit).data()) as? [String: Any])
                XCTAssertEqual(before["isClosed"] as? Bool, false)
                await fixture.release(); await stopping.value; await completion.value
                let after = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(wrapper.audit).data()) as? [String: Any])
                XCTAssertEqual(after["isClosed"] as? Bool, true)
                let rows = try auditRows(wrapper)
                XCTAssertEqual(rows.filter { $0["kind"] as? String == "cleanupJoined" }.count, 1)
                XCTAssertFalse(rows.contains { $0["kind"] as? String == "settledApplicationRejection" })
                await wrapper.stop()
                return
            }
            f.native.setNow(start + 15.2)
            let unhealthy = try await f.freshSource(start: start + 10.1, sequence: 6, unhealthy: true)
            let downward = driver.tick(encoderReady: true, source: unhealthy.0, diagnostics: unhealthy.1)
            let deadline = ContinuousClock.now + .seconds(1)
            while (await f.owner.snapshot).revision == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let beforeJoin = await f.owner.snapshot
            XCTAssertEqual(beforeJoin.revision, 1, "Fresh downward Driver work must finish before old measurement cleanup")
            XCTAssertEqual(beforeJoin.applied?.profileID, "240p30")
            XCTAssertFalse(driver.isClosed)
            let beforeRows = try auditRows(wrapper)
            XCTAssertFalse(beforeRows.contains { $0["kind"] as? String == "cleanupJoined" })
            await fixture.release(); await applying?.value; await completion.value; await downward?.value
            await f.owner.joinOwnedMeasurement()
            let rows = try auditRows(wrapper)
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "retiredObsolete" }.count, 1)
            XCTAssertFalse(rows.contains { $0["kind"] as? String == "settledApplicationRejection" })
            XCTAssertEqual(f.native.calls, ["rate:600000", "profile:240p30", "rate:350000"])
            await driver.stop(); await wrapper.stop()
            return
        }
        let decision = try await f.owner.evaluateCandidate(admission, instant: admissionClockInstant)
        let advice = try XCTUnwrap(decision.recommendation)
        if outcome == .contextRejected { await fixture.invalidateContext() }
        do {
            try await f.owner.apply(advice)
            XCTAssertEqual(outcome, .accepted)
        } catch {
            XCTAssertNotEqual(outcome, .accepted)
            if outcome == .contextRejected { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
            else { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .stale) }
        }
        await f.owner.joinOwnedMeasurement()
        let state = await f.owner.snapshot, rows = try auditRows(wrapper)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "applicationTransferred" }.count, outcome == .contextRejected ? 0 : 1)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "settledFailure" }.count, outcome == .contextRejected ? 1 : 0)
        switch outcome {
        case .accepted:
            XCTAssertEqual(state.revision, 1); XCTAssertEqual(state.applied?.profileID, "360p30")
            XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30", "rate:600000"])
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "acknowledged" }.count, 1)
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "settledAcknowledged" }.count, 1)
        case .profileRejected:
            XCTAssertFalse(state.isClosed); XCTAssertFalse(state.isBusy); XCTAssertEqual(state.revision, 0)
            XCTAssertEqual(f.native.calls, ["rate:350000"])
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "settledApplicationRejection" }.count, 1)
            XCTAssertFalse(rows.contains { $0["kind"] as? String == "acknowledged" })
        case .contextRejected:
            XCTAssertFalse(state.isClosed); XCTAssertFalse(state.isBusy); XCTAssertEqual(state.revision, 0)
            XCTAssertEqual(f.native.calls, ["rate:350000"])
        case .continuousPlan, .sourceCadence, .heldProfileRejection, .heldRejectionStop: XCTFail("Handled above")
        case .rateRejected:
            XCTAssertTrue(state.isClosed); XCTAssertEqual(state.revision, 0)
            XCTAssertEqual(f.native.calls, ["rate:350000", "profile:360p30"])
            XCTAssertFalse(rows.contains { $0["kind"] as? String == "acknowledged" })
            XCTAssertFalse(rows.contains { $0["kind"] as? String == "settledApplicationRejection" })
        }
        await f.owner.stop(); await wrapper.stop()
    }
    private var admissionClockInstant = ContinuousClock.now
    private func ownedAdmission(_ value: NativeCandidatePublisher.CandidateSnapshot, f: CandidateQualityFixture, baseline: PublishingVideoProfile = .low240) throws -> PublishingCandidateAdmission? {
        let templateURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/receiver-probe-status-v1.json")
        let template = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: templateURL))
        let clock = PublishingCandidateAdmission.Clock.sample(), instant = clock.instant, now = clock.after
        f.native.setNow(now)
        admissionClockInstant = instant
        var tracker = WorkerReceiverProbeTracker()
        for (offset, messages) in [(-2.0, 100), (-1.0, 500), (0.0, 1000)] {
            var response = template, sample = template.status.receiverProbe!.snapshot
            sample.id = value.probe.id.uuidString.lowercased(); sample.publishingGeneration = "7"
            sample.convention = "mpegts-null-probe-v3"; sample.stage = 3; sample.bitRate = 12_000_000
            sample.campaign = String(value.probe.campaign!); sample.deliveredMessages = String(messages)
            sample.deliveredPayloadBytes = String(messages * 1316); sample.totalDeliveredPayloadBytes = sample.deliveredPayloadBytes
            sample.campaignDeliveredPayloadBytes = sample.deliveredPayloadBytes; sample.nextSequence = sample.deliveredMessages
            sample.pendingPackets = 0; sample.observedAtNanoseconds = String(Int64((115 + offset) * 1e9))
            sample.firstDeliveredAtNanoseconds = String(Int64(111 * 1e9)); sample.lastDeliveredAtNanoseconds = String(Int64((115 + offset - 0.01) * 1e9))
            response.status.receiverProbe = .init(snapshot: sample, ageUpperBoundMs: 10)
            let evidence = try XCTUnwrap(WorkerReceiverProbeFreshness(response: response,
                expected: .init(gameId: "match", generation: 2, workerId: "mac", publishingAttemptId: f.attempt.uuidString.lowercased(),
                    probeId: sample.id, publishingGeneration: 7, bitRate: 12_000_000, stage: 3, campaign: value.probe.campaign),
                receivedAt: instant + .seconds(offset), requestDuration: .milliseconds(10)))
            tracker.observe(evidence, acceptedPayloadBytes: value.probe.acceptedPayloadBytes, senderActive: true, at: instant + .seconds(offset))
        }
        let pair = try XCTUnwrap(tracker.latestPair), receipt = try XCTUnwrap(f.native.receipt)
        let applied = PublishingQualityTelemetry.Applied(attemptID: f.attempt, revision: 0,
            settings: .init(profileID: baseline.rawValue, videoBitrate: baseline.bitRate), receipt: receipt, acknowledgedAt: 100)
        return .laboratoryIPv4(measurement: .init(value.cost), applied: applied, binding: value.binding,
            boundAt: value.boundAt, completedAt: value.completedAt, probe: value.probe, pair: pair,
            authority: .init(pair.newer.end), clock: clock,
            currentReceipt: { f.native.receipt }, candidateIsCurrent: { value.permitsCurrentCandidate(value.cost.id) })
    }

    @MainActor func testActualOwnedSRTStagesJoinAndRetryOnSameRevisionAfterFreshHealth() async throws {
        let f = try await CandidateQualityFixture.make()
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner())
        try await wrapper.start()
        try await f.owner.installOwnedMeasurementPublisher(wrapper)
        let driver = PublishingQualityDriver(owner: f.owner, workerLimits: nil, transportLimits: nil,
            uptime: { f.native.now })
        await driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)?.value
        XCTAssertFalse(driver.isClosed)
        await advanceSourceAfterStageTwo(f, start: 115, sequence: 3)
        await f.owner.joinOwnedMeasurement()
        var rows = try auditRows(wrapper)
        let first = rows.filter { $0["kind"] as? String == "allocated" }.compactMap { $0["snapshot"] as? [String: Any] }
        XCTAssertEqual(first.compactMap { $0["stage"] as? Int }, [1, 2, 3])
        XCTAssertEqual(Set(first.compactMap { $0["id"] as? String }).count, 3)
        XCTAssertEqual(first.compactMap { $0["campaign"] as? String }, ["1", "1", "1"])
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "settledFailure" }.count, 1)
        let settled = try XCTUnwrap(rows.first { $0["kind"] as? String == "settledFailure" })
        let diagnostic = try XCTUnwrap(settled["policyDiagnostic"] as? [String: Any])
        XCTAssertEqual(diagnostic["consecutiveFailures"] as? Int, 1)
        XCTAssertEqual(diagnostic["requiredHealthyDuration"] as? Double, 10)
        let premature = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertFalse(premature)
        var latest = diagnostics
        for (start, sequence) in [(121.0, Int64(4)), (126.0, Int64(5))] {
            f.native.setNow(start + 5.1)
            let pair = try await f.freshSource(start: start, sequence: sequence)
            _ = try await f.owner.evaluate(source: pair.0, diagnostics: pair.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            latest = pair.1
        }
        await fixture.setDefect("captureOnce")
        let failedCapture = try await f.owner.startOwnedMeasurement(diagnostics: latest)
        XCTAssertTrue(failedCapture)
        await f.owner.joinOwnedMeasurement()
        for (start, sequence) in [(132.0, Int64(6)), (137.0, Int64(7)), (142.0, Int64(8)), (147.0, Int64(9))] {
            f.native.setNow(start + 5.1)
            let pair = try await f.freshSource(start: start, sequence: sequence)
            _ = try await f.owner.evaluate(source: pair.0, diagnostics: pair.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            latest = pair.1
        }
        await driver.tick(encoderReady: true, source: nil, diagnostics: latest)?.value
        XCTAssertFalse(driver.isClosed)
        await advanceSourceAfterStageTwo(f, start: 152, sequence: 10)
        await f.owner.joinOwnedMeasurement()
        rows = try auditRows(wrapper)
        let second = rows.filter { $0["kind"] as? String == "allocated" }.compactMap { $0["snapshot"] as? [String: Any] }.dropFirst(3)
        XCTAssertEqual(second.compactMap { $0["stage"] as? Int }, [1, 2, 3])
        XCTAssertEqual(second.compactMap { $0["campaign"] as? String }, ["2", "2", "2"])
        let state = await f.owner.snapshot
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        await driver.stop(); await wrapper.stop()
    }
    private func advanceSourceAfterStageTwo(_ f: CandidateQualityFixture, start: Double, sequence: Int64) async {
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while await f.owner.ownedProbeObservation()?.stage != 2, ContinuousClock.now < deadline { await Task.yield() }
            f.native.setNow(start + 5.1)
            let next = try await f.freshSource(start: start, sequence: sequence)
            _ = try await f.owner.evaluate(source: next.0, diagnostics: next.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01), instant: f.native.instant)
        } catch { XCTFail("Fresh source fixture: \(error)") }
    }
    func testSourceWaitCancellationAndTimeoutJoinStageTwoWithoutStartingCandidate() async throws {
        for cancel in [true, false] {
            let f = try await CandidateQualityFixture.make(), diagnostics = try XCTUnwrap(f.sourceDiagnostics)
            let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
            let lower = SRTMediaPublisher(operations: await fixture.operations())
            let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
                campaignOwner: PublishingCandidateCampaignOwner())
            try await wrapper.start(); await fixture.enableSending()
            try await f.owner.installOwnedMeasurementPublisher(wrapper)
            _ = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
            let waitDeadline = ContinuousClock.now + .seconds(3)
            while !(try auditRows(wrapper).contains { $0["kind"] as? String == "sourceWaitStarted" }), ContinuousClock.now < waitDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(try auditRows(wrapper).contains { $0["kind"] as? String == "sourceWaitStarted" })
            if cancel { await f.owner.stop() }
            else { await f.owner.joinOwnedMeasurement() }
            let rows = try auditRows(wrapper)
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "allocated" }.compactMap { ($0["snapshot"] as? [String: Any])?["stage"] as? Int }, [1, 2])
            XCTAssertFalse(rows.contains { $0["kind"] as? String == "candidateStarted" || $0["kind"] as? String == "sourceReady" })
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "sourceWaitTimedOut" }.count, cancel ? 0 : 1)
            XCTAssertEqual(rows.filter { $0["kind"] as? String == "cleanupJoined" }.count, 1)
            let terminal = try XCTUnwrap(rows.last { $0["kind"] as? String == "retired" }?["snapshot"] as? [String: Any])
            XCTAssertLessThanOrEqual(try XCTUnwrap(Int(try XCTUnwrap(terminal["totalAcceptedPayloadBytes"] as? String))), 16 * 1024 * 1024)
            XCTAssertLessThan(try XCTUnwrap(rows.last?["at"] as? Double) - XCTUnwrap(rows.first?["at"] as? Double), 9)
            await f.owner.stop(); await wrapper.stop()
        }
    }
    func testStaleDownwardAdviceCannotRevokeCurrentOwnedMeasurement() async throws {
        let f = try await CandidateQualityFixture.make()
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner())
        try await wrapper.start(); try await f.owner.installOwnedMeasurementPublisher(wrapper)
        let started = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        XCTAssertTrue(started)
        let deadline = ContinuousClock.now + .seconds(1)
        while await f.owner.ownedProbeObservation() == nil, ContinuousClock.now < deadline { await Task.yield() }
        let foreign = try await CandidateQualityFixture.make(initialProfile: .low360, unhealthySource: true)
        do { try await f.owner.apply(try XCTUnwrap(foreign.sourceAdvice)); XCTFail("Foreign advice") }
        catch { XCTAssertEqual(error as? PublishingQualitySession.Failure, .staleAdvice) }
        let after = await f.owner.ownedProbeObservation()
        XCTAssertNotNil(after, "Rejected downward advice cannot withdraw a current measurement")
        await f.owner.stop(); await wrapper.stop(); await foreign.owner.stop()
    }
    private func auditRows(_ wrapper: NativeOwnedCandidatePublisher) throws -> [[String: Any]] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(wrapper.audit).data()) as? [String: Any])
        return try XCTUnwrap(object["events"] as? [[String: Any]])
    }

    func testStoppedOwnedPublicationReleasesSessionAndReaderClosures() async throws {
        let released = try await makeStoppedOwnedPublication()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(released.owner)
        XCTAssertNil(released.publisher)
    }
    private func makeStoppedOwnedPublication() async throws -> WeakOwnedPublication {
        let f = try await CandidateQualityFixture.make()
        let gate = OwnedProbeCaptureGate()
        let wrapper = NativeOwnedCandidatePublisher(publisher: gate, scope: f.sourceDiagnostics!.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner(), probes: gate.probes)
        try await f.owner.installOwnedMeasurementPublisher(wrapper)
        let owner = f.owner
        XCTAssertTrue(wrapper.installReaders(candidate: { await owner.ownedCandidateSnapshot() },
            probe: { await owner.ownedProbeObservation() }, pressure: { nil }))
        let result = WeakOwnedPublication(owner: owner, publisher: wrapper)
        await owner.stop(); await wrapper.stop()
        return result
    }

    func testCancellationRetainsLateNativeAllocationUntilExactRetirement() async throws {
        let f = try await CandidateQualityFixture.make(), diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        await fixture.hold(.allocation)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner())
        try await wrapper.start(); try await f.owner.installOwnedMeasurementPublisher(wrapper)
        _ = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        await fixture.waitForEntry()
        let stopping = Task { await f.owner.stop() }
        for _ in 0..<20 { await Task.yield() }
        let before = await f.owner.snapshot
        XCTAssertTrue(before.isClosed)
        XCTAssertFalse(before.isBusy)
        await fixture.release()
        await stopping.value
        let counts = await fixture.counts
        XCTAssertEqual(counts.allocations, 1)
        XCTAssertEqual(counts.retirements, 1)
        let rows = try auditRows(wrapper)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "cleanupJoined" }.count, 1)
        await wrapper.stop()
    }
    func testCancellationExportsRenewalThatAdvancedBeforeItsHeldReturn() async throws {
        let f = try await CandidateQualityFixture.make(), diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        await fixture.hold(.renewReturn)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner())
        try await wrapper.start(); try await f.owner.installOwnedMeasurementPublisher(wrapper)
        _ = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        await fixture.waitForEntry()
        let stopping = Task { await f.owner.stop() }
        for _ in 0..<20 { await Task.yield() }
        await fixture.release(); await stopping.value
        let rows = try auditRows(wrapper)
        let requested = try XCTUnwrap(rows.first { $0["kind"] as? String == "renewalRequested" })
        let prior = try XCTUnwrap(requested["snapshot"] as? [String: Any])
        let terminal = try XCTUnwrap(rows.last { $0["kind"] as? String == "retired" }?["snapshot"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(terminal["leaseDeadline"] as? Double), try XCTUnwrap(prior["leaseDeadline"] as? Double))
        XCTAssertEqual(rows.filter { ["renewed", "renewalRejected"].contains($0["kind"] as? String ?? "") }.count, 1)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "cleanupJoined" }.count, 1)
        await wrapper.stop()
    }
    func testDownwardApplicationRemainsAvailableWhileExactProbeRetirementIsHeld() async throws {
        let f = try await CandidateQualityFixture.make(initialProfile: .low360)
        let diagnostics = try XCTUnwrap(f.sourceDiagnostics)
        let fixture = OwnedAppRouteFixture(selected: f.native.receipt!)
        await fixture.hold(.retire)
        let lower = SRTMediaPublisher(operations: await fixture.operations())
        let wrapper = NativeOwnedCandidatePublisher(publisher: lower, scope: diagnostics.ingress!.scope,
            campaignOwner: PublishingCandidateCampaignOwner())
        try await wrapper.start(); try await f.owner.installOwnedMeasurementPublisher(wrapper)
        _ = try await f.owner.startOwnedMeasurement(diagnostics: diagnostics)
        await fixture.waitForEntry()
        f.native.setNow(116.1)
        let bad = QualityController.Window(attemptID: f.attempt, sequence: 2, appliedRevision: 0,
            start: 115.1, end: 116.1, capturedFreshFrames: 30, encodedFreshFrames: 30,
            receiver: .init(freshFrames: 30, observedAt: 116.1), sourceLoss: .init(expectedFrames: 30, lostFrames: 0),
            meanQueueOccupancy: 1, usableVideoCapacity: nil, connectivity: .connected,
            thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)
        let decision = try await f.owner.evaluate(bad)
        let advice = try XCTUnwrap(decision.recommendation)
        try await f.owner.apply(advice)
        let beforeJoin = await f.owner.snapshot
        XCTAssertEqual(beforeJoin.revision, 1)
        XCTAssertEqual(beforeJoin.applied?.profileID, "240p30")
        await fixture.release()
        await f.owner.joinOwnedMeasurement()
        let rows = try auditRows(wrapper)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "retiredObsolete" }.count, 1)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "settledFailure" }.count, 0)
        await f.owner.stop(); await wrapper.stop()
    }
    func testGuardedStaleSelectorUsesGuardedPublisherAndPreservesCandidateOwner() async throws {
        let native = OwnedWrapperNative()
        let wrapper = NativeOwnedCandidatePublisher(publisher: native, scope: native.scope,
            campaignOwner: PublishingCandidateCampaignOwner())
        let probe = OwnedWrapperAttempt()
        try await probe.attempt.start()
        wrapper.installCandidate(probe.attempt)
        do {
            _ = try await wrapper.setVideoBitRate(600_000, expecting: .verified(native.receipt))
            XCTFail("Stale selector must reject")
        } catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, .stale) }
        XCTAssertEqual(native.guardedCalls, 1)
        XCTAssertEqual(native.legacyCalls, 0)
        XCTAssertEqual(probe.cancellations, 0)
        await wrapper.stop()
        XCTAssertGreaterThan(probe.cancellations, 0)
    }
}

private final class OwnedWrapperAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var cancellations: Int { lock.withLock { count } }
    lazy var attempt = NativeCandidateAttempt(operations: .init(begin: { _ in UUID() }, offer: { _,_ in true },
        cancel: { [self] _,_ in lock.withLock { count += 1 } }, result: { _ in nil }, retire: { _,_ in }))
}
private final class OwnedWrapperNative: MediaPublisher, @unchecked Sendable {
    let scope = VideoFrameObservationScope(recordingID: "record", matchID: "match", broadcastGeneration: 1,
        publishingAttemptID: UUID(), appliedProfileRevision: 1)
    let receipt = PublishingBitRateChange(publishingGeneration: 7,
        configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 350_000)!, acceptedAt: 1, lastSubmittedSourcePTS: .zero)!
    private let lock = NSLock()
    private var guarded = 0, legacy = 0
    var guardedCalls: Int { lock.withLock { guarded } }
    var legacyCalls: Int { lock.withLock { legacy } }
    func start() async throws {}
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { get async { true } }
    func stop() async {}
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange {
        lock.withLock { legacy += 1 }; return receipt
    }
    func setVideoBitRate(_ rate: Int, expecting: PublishingVideoMutationExpectation) async throws -> PublishingBitRateChange {
        lock.withLock { guarded += 1 }; throw PublishingVideoMutationAdmissionError.stale
    }
}

final class OwnedProbeCaptureGate: MediaPublisher, @unchecked Sendable {
    private let gate = AsyncStream<Void>.makeStream()
    private let entered = AsyncStream<Void>.makeStream()
    var probes: NativeOwnedCandidatePublisher.Probes {
        .init(capture: { [self] _ in
            entered.continuation.finish()
            for await _ in gate.stream {}
            throw PublishingBandwidthProbeError.obsolete
        }, validate: { _ in }, begin: { _,_,_ in throw PublishingBandwidthProbeError.disabled },
        replace: { _,_,_ in throw PublishingBandwidthProbeError.disabled },
        restart: { _,_,_ in throw PublishingBandwidthProbeError.disabled })
    }
    func waitUntilEntered() async { for await _ in entered.stream {} }
    func release() { gate.continuation.finish() }
    func start() async throws {}
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { get async { true } }
    func stop() async { release() }
}

private actor OwnedAppRouteFixture {
    init(selected: PublishingBitRateChange) { self.selected = selected }
    enum Gate { case allocation, renew, renewReturn, cancel, context, retire }
    let issuer = UUID()
    private var epoch = UUID(), stopped = false, valid = true
    var selected = PublishingBitRateChange(publishingGeneration: 7,
        configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 900_000)!,
        acceptedAt: 1, lastSubmittedSourcePTS: .zero)!
    private var sender: Task<Void, Never>?
    func enableSending() {
        sender = Task {
            while !stopped, !Task.isCancelled {
                let at = ProcessInfo.processInfo.systemUptime
                var mon = CBytePerfMon(); mon.msRTT = 2; mon.msSndTsbPdDelay = 200
                _ = try? probe?.offer(statistics: .init(mon: mon, sampledAt: at), now: { at }, send: { _ in true })
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
    private var slot: PublishingBandwidthProbeOperation?, foreign: PublishingBandwidthProbeOperation?
    private var weakOperations: [WeakOwnedOperation] = []
    var retainedOperationCount: Int { weakOperations.filter { $0.value != nil }.count }
    private var probe: SRTBandwidthProbe?
    private var failAllocation = false, rejectFactory = false, invalidateAllocation = false
    private var defect = "", revision = 0
    private var gate: Gate?, entered = false, wait: CheckedContinuation<Void, Never>?
    var counts = (allocations: 0, retirements: 0, cancellations: 0)
    func setDefect(_ value: String) { defect = value }
    func invalidateContext() { valid = false }
    func failNextAllocation() { failAllocation = true }
    func rejectNextFactory() { rejectFactory = true }
    func invalidateAfterAllocation() { invalidateAllocation = true }
    func hold(_ value: Gate) { gate = value; entered = false }
    func release() { gate = nil; wait?.resume(); wait = nil }
    func waitForEntry() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    private func pause(_ value: Gate) async {
        guard gate == value else { return }; entered = true
        await withCheckedContinuation { wait = $0 }
    }
    func cancelCount() -> Int { counts.cancellations }
    func retirementCount() -> Int { counts.retirements }
    func capture(_ receipt: PublishingBitRateChange) throws -> PublishingBandwidthProbeContext {
        if defect == "captureOnce" { defect = ""; throw PublishingBandwidthProbeError.obsolete }
        let context = PublishingBandwidthProbeContext(issuer: issuer, epoch: epoch, selected: selected)
        guard valid, !stopped, context.matches(receipt) else { throw PublishingBandwidthProbeError.obsolete }
        return context
    }
    func validate(_ context: PublishingBandwidthProbeContext) async throws {
        await pause(.context)
        guard valid, !stopped, context.issuer == issuer, context.epoch == epoch, context.matches(selected) else {
            throw PublishingBandwidthProbeError.obsolete
        }
    }
    func write(_ bitRate: Int) async -> PublishingBitRateChange {
        epoch = UUID(); valid = true
        await slot?.cancel()
        selected = PublishingBitRateChange(publishingGeneration: 7,
            configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: bitRate)!,
            acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: .zero)!
        return selected
    }
    func make(_ context: PublishingBandwidthProbeContext, request: PublishingOwnedProbeRequest,
              predecessor: PublishingBandwidthProbeRetirement?) throws -> PublishingBandwidthProbeOperation {
        do {
            guard !Task.isCancelled, !stopped, context.issuer == issuer, context.epoch == epoch else { throw PublishingBandwidthProbeError.obsolete }
            if rejectFactory { rejectFactory = false; throw PublishingBandwidthProbeError.obsolete }
            try validateOwnedReservation(current: slot, issuer: issuer, context: context, receipt: predecessor, request: request)
            try predecessor?.consume()
        } catch {
            throw PublishingOwnedFactoryRejection(context: context, predecessor: predecessor, request: request, reason: publishingProbeError(error))
        }
        if defect == "genericFactory" { throw CancellationError() }
        let actualContext = defect == "foreignContext"
            ? PublishingBandwidthProbeContext(issuer: UUID(), epoch: context.epoch, selected: context.selected) : context
        let actualRequest = defect == "wrongRate" ? PublishingOwnedProbeRequest(kind: request.kind, bitRate: request.bitRate + 1, policy: request.policy) : request
        let operation = PublishingBandwidthProbeOperation(issuer: actualContext.issuer, context: actualContext, request: actualRequest,
            predecessor: predecessor, backend: .native(.init(validate: { id in
                try await self.validateOperation(context, id: id)
            }, allocate: { request, prior in try await self.allocate(request, prior: prior) },
                renew: { try await self.renew($0, generation: $1) },
                cancel: { await self.cancel($0, generation: $1) },
                retire: { try await self.retire($0, generation: $1) })))
        slot = operation
        weakOperations.append(WeakOwnedOperation(operation))
        if defect == "foreignContext" || defect == "wrongRate" { foreign = operation }
        if defect == "cancelBeforeStart" { defect = ""; operation.revoke() }
        operation.start()
        return operation
    }
    func validateOperation(_ context: PublishingBandwidthProbeContext, id: UUID) async throws {
        guard slot?.id == id else { throw PublishingBandwidthProbeError.obsolete }
        try await validate(context)
        guard slot?.id == id else { throw PublishingBandwidthProbeError.obsolete }
    }
    func allocate(_ request: PublishingOwnedProbeRequest, prior: PublishingBandwidthProbeSnapshot?) async throws -> PublishingBandwidthProbeSnapshot {
        counts.allocations += 1
        let capturedRevision = revision
        await pause(.allocation)
        if failAllocation { failAllocation = false; throw PublishingBandwidthProbeError.failed }
        guard capturedRevision == revision else { throw PublishingBandwidthProbeError.obsolete }
        let at = ProcessInfo.processInfo.systemUptime
        let replacing = request.kind == .replace
        var mon = CBytePerfMon(); mon.msRTT = 2; mon.msSndTsbPdDelay = 200
        let next = try SRTBandwidthProbe(bitRate: request.bitRate, generation: 7,
            statistics: .init(mon: mon, sampledAt: at), at: at,
            stage: replacing ? prior!.stage! + 1 : 1,
            campaign: replacing ? prior!.campaign : (prior.map { $0.campaign! + 1 } ?? 1),
            campaignStartedAt: replacing ? prior!.campaignStartedAt : at,
            previouslyAcceptedPayloadBytes: replacing ? prior!.totalAcceptedPayloadBytes! : 0, policy: request.policy)
        probe = next
        if invalidateAllocation { invalidateAllocation = false; valid = false }
        var value = PublishingBandwidthProbeSnapshot(next.snapshot(now: { at }))
        if defect == "inflatedCarry" { value.totalAcceptedPayloadBytes = (value.totalAcceptedPayloadBytes ?? 0) + 1316 }
        return value
    }
    func sendPacket() async throws {
        try await Task.sleep(for: .milliseconds(25))
        let at = ProcessInfo.processInfo.systemUptime
        var mon = CBytePerfMon(); mon.msRTT = 2; mon.msSndTsbPdDelay = 200
        let probe = try XCTUnwrap(probe)
        XCTAssertTrue(try probe.offer(statistics: .init(mon: mon, sampledAt: at), now: { at }, send: { _ in true }))
    }
    func renew(_ id: UUID, generation: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        await pause(.renew)
        let probe = try XCTUnwrap(probe)
        _ = probe.renew(now: { ProcessInfo.processInfo.systemUptime })
        let value = PublishingBandwidthProbeSnapshot(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }))
        await pause(.renewReturn)
        if defect != "foreignRenewal" { return value }
        return .init(id: UUID(), publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: value.acceptedPayloadBytes,
            lastAcceptedAt: value.lastAcceptedAt, reason: value.reason, stage: value.stage, campaign: value.campaign,
            authority: value.authority, campaignStartedAt: value.campaignStartedAt, totalAcceptedPayloadBytes: value.totalAcceptedPayloadBytes)
    }
    func cancel(_ id: UUID, generation: UInt64) async {
        await pause(.cancel)
        guard probe?.id == id, probe?.generation == generation else { return }
        counts.cancellations += 1; revision += 1; probe?.cancel(.cancelled)
    }
    func retire(_ id: UUID, generation: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        counts.retirements += 1
        await pause(.retire)
        guard let probe, probe.id == id, probe.generation == generation else { throw PublishingBandwidthProbeError.obsolete }
        if defect == "failedJoin" { throw PublishingBandwidthProbeError.failed }
        probe.cancel(.cancelled)
        let value = PublishingBandwidthProbeSnapshot(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }))
        if defect != "rollback" { return value }
        return .init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: 0,
            lastAcceptedAt: nil, reason: value.reason, stage: value.stage, campaign: value.campaign,
            authority: value.authority, campaignStartedAt: value.campaignStartedAt, totalAcceptedPayloadBytes: 0)
    }
    func stop() {
        stopped = true; sender?.cancel(); slot?.revoke(); probe?.cancel(.closed); release()
    }
    func disposeForeign() async { if let foreign { _ = try? await foreign.retire() } }
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: {}, start: {}, append: { _ in }, isPublishing: { true }, stop: { await self.stop() },
            setBitRate: { await self.write($0) }, metrics: { nil },
            captureProbeContext: { try await self.capture($0) }, validateProbeContext: { try await self.validate($0) },
            beginOwnedProbe: { try await self.make($0, request: .init(kind: .begin, bitRate: $1, policy: $2), predecessor: nil) },
            replaceOwnedProbe: { try await self.make($1, request: .init(kind: .replace, bitRate: $2, policy: $0.policy), predecessor: $0) },
            restartOwnedProbe: { try await self.make($1, request: .init(kind: .restart, bitRate: $2, policy: $0.policy), predecessor: $0) })
    }
}

private final class WeakOwnedPublication {
    weak var owner: PublishingQualitySession?
    weak var publisher: NativeOwnedCandidatePublisher?
    init(owner: PublishingQualitySession, publisher: NativeOwnedCandidatePublisher) { self.owner = owner; self.publisher = publisher }
}

private final class OwnedMutationRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NativeOwnedCandidatePublisher?
    func install(_ value: NativeOwnedCandidatePublisher) { lock.withLock { self.value = value } }
    var guarded: PublishingQualitySession.GuardedMutations {
        .init(setBitRate: { [self] rate, expected, _ in
            guard let publisher = lock.withLock({ value }) else { throw PublishingVideoMutationAdmissionError.unavailable }
            return try await publisher.setVideoBitRate(rate, expecting: expected)
        }, setProfile: { [self] profile, expected, _ in
            guard let publisher = lock.withLock({ value }) else { throw PublishingVideoMutationAdmissionError.unavailable }
            return try await publisher.setVideoProfile(profile, expecting: expected)
        })
    }
}
private final class OwnedCandidateResult: @unchecked Sendable {
    let id = UUID()
    private let scope: VideoFrameObservationScope, generation: UInt64
    private let profile: PublishingVideoProfile
    private let lock = NSLock()
    private var startedAt = 0.0, reason: PublishingCandidateMeasurement.Reason = .completed
    init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile, generation: UInt64) { self.scope = scope; self.generation = generation; self.profile = profile }
    func start() { lock.withLock { startedAt = ProcessInfo.processInfo.systemUptime } }
    func cancel(_ value: PublishingCandidateMeasurement.Reason) { lock.withLock { reason = value } }
    func result() async -> PublishingCandidateMeasurement.Result {
        let start = lock.withLock { startedAt }
        var collectedAt: [Double] = []
        for index in 0...120 {
            let remaining = start + Double(index) / 30 - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            collectedAt.append(ProcessInfo.processInfo.systemUptime)
        }
        let reason = lock.withLock { self.reason }
        return ownedCandidateResult(id: id, scope: scope, start: start, end: ProcessInfo.processInfo.systemUptime,
            generation: generation, profile: profile, collectedAt: collectedAt, reason: reason)
    }
}
private func ownedCandidateResult(id: UUID, scope: VideoFrameObservationScope, start: Double, end: Double,
                           generation: UInt64 = 7, profile: PublishingVideoProfile = .low360, collectedAt: [Double], reason: PublishingCandidateMeasurement.Reason = .completed) -> PublishingCandidateMeasurement.Result {
    let session = UUID()
    let frames: [VideoCandidateEncoder.Frame] = (0...120).map { index in
        let pts = CMTime(value: Int64(index), timescale: 30)
        let at = collectedAt[index]
        return .init(sourcePTS: pts, outputPTS: pts, encoderSessionID: session,
            admittedAt: at, rawByteCount: 16384, submittedAt: at, completedAt: at, dequeuedAt: at,
            byteCount: 1000, width: Int32(profile.width), height: Int32(profile.height), isSync: index == 0)
    }
    let audio: [PublishingCandidateTransport.AudioReceipt] = (0..<188).map { index in
        .init(sourcePTS: CMTime(value: Int64(index * 1024), timescale: 48000), publishingGeneration: generation,
            wasEncoded: true, valid: true, observedAt: start, consumedAt: start, byteCount: 100,
            sampleRate: 48000, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2)
    }
    let following = PublishingCandidateTransport.AudioReceipt(sourcePTS: CMTime(value: 188 * 1024, timescale: 48000),
        publishingGeneration: generation, wasEncoded: true, valid: true, observedAt: start, consumedAt: end,
        byteCount: 100, sampleRate: 48000, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2)
    let inputs: [CandidateTransportMeasurement.Input] = frames.map {
        .init(media: .video, sourcePTS: $0.sourcePTS, decodePTS: $0.sourcePTS,
            byteCount: $0.byteCount, isSync: $0.isSync, parameterSetBytes: $0.isSync ? 24 : 0)
    } + audio.map { .init(media: .audio, sourcePTS: $0.sourcePTS, decodePTS: .invalid,
        byteCount: $0.byteCount, isSync: true, parameterSetBytes: 0) }
    let mux = CandidateTransportMeasurement.Result(inputs: inputs, outcome: .completed, failure: nil,
        videoInputCount: 121, audioInputCount: 188, videoInputBytes: 121000, audioInputBytes: 18800,
        firstVideoPTS: .zero, lastVideoPTS: CMTime(value: 4, timescale: 1),
        firstAudioPTS: audio.first!.sourcePTS, lastAudioPTS: audio.last!.sourcePTS,
        transportBytes: 376000, transportMessageCount: 400)
    let transport = PublishingCandidateTransport.Result(scope: scope, profile: profile, id: id,
        outcome: .completed, failure: nil, publishingGeneration: generation, startedAt: start,
        closedAt: end, endedAt: end, rawInputCount: 121, firstRawPTS: .zero,
        lastRawPTS: CMTime(value: 4, timescale: 1), audio: audio, followingAudio: following, openingAudioFailure: nil,
        maximumPendingCount: 2, maximumPendingBytes: 200, mux: mux)
    let native = VideoCandidateEncoder.Result(id: id, settings: profile.settings,
        outcome: .completed, failure: nil, nativeFailure: nil, encoderSessionID: session,
        acceptedInputCount: 121, outputCount: 121, frames: frames)
    let encoding = PublishingCandidateEncoder.Result(scope: scope, profile: profile, encoding: native, transport: transport)
    return .init(id: id, scope: scope, profile: profile, reason: reason,
        startedAt: start, endedAt: end, acceptedInputCount: 121,
        firstInputPTS: .zero, lastInputPTS: CMTime(value: 4, timescale: 1), encoding: encoding)
}

private final class WeakOwnedOperation {
    weak var value: PublishingBandwidthProbeOperation?
    init(_ value: PublishingBandwidthProbeOperation) { self.value = value }
}

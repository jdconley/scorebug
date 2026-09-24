import AVFoundation
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

@MainActor final class CaptureStreamingModelTests: XCTestCase {
    func testReceiverEvidenceWriterIncludesRepeatedModeAndRetainsLegacySelection() {
        for mode in ["renew", "expire", "staged", "repeated"] {
            XCTAssertNotNil(ReceiverProbeFixtureHistory.writer(environment: ["SCOREBUG_TEST_BANDWIDTH_PROBE": mode]), mode)
        }
        XCTAssertNil(ReceiverProbeFixtureHistory.writer(environment: [:]))
        for mode in ["", "repeat", "1", "unknown"] {
            XCTAssertNil(ReceiverProbeFixtureHistory.writer(environment: ["SCOREBUG_TEST_BANDWIDTH_PROBE": mode]), mode)
        }
    }

    func testOnlyExplicitMeasuredFactoryInstallsCandidateProviderAndStopClearsIt() async throws {
        for enabled in [false, true] {
            let server = CaptureTestServer()
            var driver: PublishingQualityDriver?
            let model = makeModel(server: server, qualityFactory: { session, attempt in
                let owner = try PublishingQualitySession(session: session,
                    profiles: [.init(id: "240p30", width: 426, height: 240, minimumBitrate: 350_000, maximumBitrate: 350_000)],
                    attemptID: attempt, initial: .init(profileID: "240p30", videoBitrate: 350_000))
                let value = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil)
                driver = value; return value
            })
            if enabled { model.measuredCandidateFactory = { _ in { nil } } }
            await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
            XCTAssertEqual(driver?.candidateInputProvider != nil, enabled)
            let cadenceProvider = driver?.cadenceInputProvider
            XCTAssertNotNil(cadenceProvider?())
            XCTAssertNil(cadenceProvider?()?.cadence)
            model.captureChanged(captureContext())
            XCTAssertNil(cadenceProvider?(), "A replacement tap cannot inherit cadence ownership")
            await model.stopStreaming()
            XCTAssertNil(driver?.candidateInputProvider)
            XCTAssertNil(driver?.cadenceInputProvider)
            XCTAssertNil(cadenceProvider?())
        }
    }

    func testMeasuredProviderRechecksAuthorityAfterSuspendedCandidateRead() async throws {
        for replacement in [false, true] {
            var session: PublishingSession?
            let (model, server, _, response) = try await receiverProbeModel { value, _ in session = value; return nil }
            let receipt = try await XCTUnwrap(session).setVideoBitRate(350_000)
            await server.setStatusOverride(response); await model.pollControl()
            let receiver = try XCTUnwrap(model.workerReceiverProbeFreshness)
            let authority = try XCTUnwrap(model.candidateAuthority)
            let state = candidateState(model, receipt: receipt), gate = FilmTestGate()
            let read = Task { await model.measuredCandidateInput(state) { await gate.enter(); return nil } }
            await gate.waitUntilEntered()
            if replacement { model.captureChanged(captureContext()) }
            else {
                var changed = response
                changed.status.publication?.readerId = UUID().uuidString.lowercased()
                await server.setStatusOverride(changed); await model.pollControl()
            }
            XCTAssertFalse(authority.permits(receiver))
            await gate.release()
            let result = await read.value
            XCTAssertNil(result)
            await model.stopStreaming()
        }
    }

    func testMeasuredProviderUsesNewerPairAfterAwaitAndReturnedAdmissionRevokesOnStop() async throws {
        try await checkMeasuredProvider(revision: 0)
    }
    func testMeasuredProviderBindsLaterRevisionAndV3CampaignWithoutReusingInitialRevision() async throws {
        try await checkMeasuredProvider(revision: 2)
    }
    func testMeasuredProviderRetainsTwoActualIntervalsAfterDelayedFirstStatus() async throws {
        try await checkMeasuredProvider(revision: 2, additionalFirstStatusDelay: .milliseconds(250))
    }
    private func checkMeasuredProvider(revision: UInt64, additionalFirstStatusDelay: Duration = .zero) async throws {
        var session: PublishingSession?
        let (model, server, publisher, initial) = try await receiverProbeModel { value, _ in session = value; return nil }
        let live = try XCTUnwrap(session)
        let receipt = try await live.setVideoBitRate(350_000)
        let start = ProcessInfo.processInfo.systemUptime + 0.02
        let original = await publisher.probeValue()
        var probe = try XCTUnwrap(original)
        probe.stage = 3; probe.bitRate = 12_000_000
        if revision > 0 { probe.campaign = 2 }
        probe.startedAt = start - 1; probe.leaseDeadline = start + 0.25
        probe.acceptedPayloadBytes = 1316; probe.lastAcceptedAt = start - 0.01
        let binding = probe
        await publisher.setRenewProbeLeaseOnRead(true)
        var response = initial
        response.status.receiverProbe?.snapshot.convention = revision == 0 ? "mpegts-null-probe-v2" : "mpegts-null-probe-v3"
        if revision > 0 { response.status.receiverProbe?.snapshot.campaign = "2" }
        response.status.receiverProbe?.snapshot.stage = 3
        response.status.receiverProbe?.snapshot.bitRate = 12_000_000
        response.status.receiverProbe?.ageUpperBoundMs = 1
        response.status.receiverProbe?.snapshot.firstDeliveredAtNanoseconds = "1000000"
        var previousObservedNanoseconds: Int64?
        func report(at offset: Double, messages: Int, delayBeforeStatus: Bool = false) async throws {
            // Status is sampled after the recovery delay. Schedule from that
            // actual observation so scheduler lateness cannot collapse the next
            // required one-second receiver interval.
            let earliest = previousObservedNanoseconds.map { start + Double($0) / 1e9 + 1.1 } ?? start
            let target = max(start + offset, earliest)
            try await Task.sleep(for: .seconds(max(0, target - ProcessInfo.processInfo.systemUptime)))
            let deliveredAt = ProcessInfo.processInfo.systemUptime
            let ns = Int64((deliveredAt - start) * 1e9)
            response.status.receiverProbe?.snapshot.observedAtNanoseconds = String(ns)
            response.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = String(ns)
            response.status.receiverProbe?.snapshot.deliveredMessages = String(messages)
            response.status.receiverProbe?.snapshot.nextSequence = String(messages)
            response.status.receiverProbe?.snapshot.deliveredPayloadBytes = String(messages * 1316)
            response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = String(messages * 1316)
            if revision > 0 { response.status.receiverProbe?.snapshot.campaignDeliveredPayloadBytes = String(messages * 1316) }
            probe.leaseDeadline = deliveredAt + 0.3
            probe.acceptedPayloadBytes = UInt64(messages * 1316)
            probe.lastAcceptedAt = deliveredAt
            await publisher.setProbe(probe)
            // The packet event stays fixed across recovery; only sampling occurs at /status.
            let template = response
            await server.setStatusResponseFactory { sampledAt in
                var sampled = template
                sampled.status.receiverProbe?.snapshot.observedAtNanoseconds = String(Int64((sampledAt - start) * 1e9))
                return sampled
            }
            if delayBeforeStatus {
                let delay = FilmTestGate(); await server.setSnapshotGate(delay)
                let poll = Task { await model.pollControl() }
                await delay.waitUntilEntered()
                try await Task.sleep(for: .milliseconds(400) + additionalFirstStatusDelay)
                await delay.release(); await poll.value
            } else { await model.pollControl() }
            let sampledProbe = await publisher.probeValue()
            probe = try XCTUnwrap(sampledProbe)
            XCTAssertEqual(probe.lastAcceptedAt, deliveredAt)
            XCTAssertEqual(probe.acceptedPayloadBytes, UInt64(messages * 1316))
            let receiver = try XCTUnwrap(model.workerReceiverProbeFreshness)
            let observed = try XCTUnwrap(Int64(receiver.snapshot.observedAtNanoseconds))
            if let previousObservedNanoseconds {
                XCTAssertGreaterThanOrEqual(observed - previousObservedNanoseconds, 1_000_000_000)
                XCTAssertNotNil(model.workerReceiverProbeInterval)
            }
            previousObservedNanoseconds = observed
            if delayBeforeStatus {
                XCTAssertGreaterThan(observed - ns, 350_000_000)
                XCTAssertEqual(receiver.snapshot.lastDeliveredAtNanoseconds, String(ns))
                XCTAssertGreaterThan(try XCTUnwrap(receiver.lastDeliveryAgeUpperBound()), .milliseconds(350))
                XCTAssertGreaterThan(probe.leaseDeadline, deliveredAt + 0.4)
            }
        }
        try await report(at: 1.65, messages: 100, delayBeforeStatus: true)
        try await report(at: 3.15, messages: 1150)
        let state = candidateState(model, receipt: receipt, revision: revision)
        let measurement = PublishingCandidateAdmission.Measurement(id: UUID(), scope: try XCTUnwrap(model.videoObservation?.scope),
            profile: .low360, publishingGeneration: 1, startedAt: start, endedAt: start + 4.02,
            firstInputAt: start, lastInputAt: start + 4, sourceDuration: 4, submissionDuration: 4,
            transportBytes: 376_000, transportMessageCount: 400)
        let staleProbe = probe, gate = FilmTestGate()
        let pending = Task {
            await model.measuredCandidateInput(state) {
                await gate.enter()
                return .init(measurement: measurement, binding: binding, probe: staleProbe,
                    boundAt: start - 0.01, completedAt: start + 4.03, permitsCurrentCandidate: { $0 == measurement.id })
            }
        }
        guard await gate.waitUntilEntered(timeout: .seconds(1)) else {
            await gate.release(); _ = await pending.value
            XCTFail("Current revision never reached the candidate reader")
            await model.stopStreaming(); return
        }
        try await report(at: 4.35, messages: 2250)
        await gate.release()
        let result = await pending.value
        let admission = try XCTUnwrap(result)
        XCTAssertEqual(admission.value.appliedRevision, revision)
        XCTAssertEqual(admission.applied.revision, revision)
        XCTAssertEqual(admission.probe.campaign, revision == 0 ? nil : 2)
        XCTAssertEqual(admission.receiver.snapshot.deliveredMessages, "2250")
        XCTAssertTrue(admission.permits(applied: admission.applied, at: ProcessInfo.processInfo.systemUptime, instant: .now))
        model.captureChanged(nil)
        XCTAssertFalse(admission.permits(applied: admission.applied, at: ProcessInfo.processInfo.systemUptime, instant: .now))
        await model.stopStreaming()
    }

    func testMeasuredProviderRefreshesNativeLeaseWithoutRenewingRemoteEvidence() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let probeValue = await publisher.probeValue()
        var probe = try XCTUnwrap(probeValue)
        probe.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.15
        await publisher.setProbe(probe)
        await server.setStatusOverride(response); await model.pollControl()
        let receiver = try XCTUnwrap(model.workerReceiverProbeFreshness)
        let authority = try XCTUnwrap(model.candidateAuthority)
        probe.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.3
        await publisher.setProbe(probe)
        let input = await model.measuredCandidateInput(candidateState(model)) { XCTFail("No bootstrap receipt"); return nil }
        XCTAssertNil(input)
        XCTAssertEqual(model.workerReceiverProbeFreshness?.receivedAt, receiver.receivedAt)
        XCTAssertTrue(authority.permits(receiver))
        model.pollLocalHealth(at: .now + .milliseconds(200))
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        model.pollLocalHealth(at: .now + .seconds(2))
        XCTAssertNil(model.workerReceiverProbeFreshness)
        XCTAssertFalse(authority.permits(receiver))
        await model.stopStreaming()
    }

    func testLatePollNativeReadCannotRollBackProviderLease() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let probeValue = await publisher.probeValue()
        var probe = try XCTUnwrap(probeValue)
        probe.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.15
        await publisher.setProbe(probe)
        await server.setStatusOverride(response); await model.pollControl()
        let gate = FilmTestGate(); await publisher.setProbeGate(gate)
        let poll = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        await publisher.setProbeGate(nil)
        probe.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.3
        probe.acceptedPayloadBytes += 1316
        await publisher.setProbe(probe)
        _ = await model.measuredCandidateInput(candidateState(model)) { nil }
        await gate.release(); await poll.value
        model.pollLocalHealth(at: .now + .milliseconds(200))
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        await model.stopStreaming()
    }

    func testMeasuredProviderRechecksTapAfterSuspendedNativeRead() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        await server.setStatusOverride(response); await model.pollControl()
        let receiver = try XCTUnwrap(model.workerReceiverProbeFreshness)
        let authority = try XCTUnwrap(model.candidateAuthority)
        let state = candidateState(model)
        let gate = FilmTestGate(); await publisher.setProbeGate(gate)
        let read = Task { await model.measuredCandidateInput(state) { XCTFail("Replaced owner"); return nil } }
        await gate.waitUntilEntered()
        model.captureChanged(captureContext())
        XCTAssertFalse(authority.permits(receiver))
        await gate.release()
        let result = await read.value
        XCTAssertNil(result); XCTAssertNil(model.workerReceiverProbeFreshness)
        await model.stopStreaming()
    }

    func testReceiverPublicationChangeAndStopRevokeReturnedAuthority() async throws {
        let (model, server, _, initial) = try await receiverProbeModel()
        await server.setStatusOverride(initial); await model.pollControl()
        let receiver = try XCTUnwrap(model.workerReceiverProbeFreshness)
        let authority = try XCTUnwrap(model.candidateAuthority)
        var changed = initial
        changed.status.publication?.readerId = UUID().uuidString.lowercased()
        await server.setStatusOverride(changed); await model.pollControl()
        XCTAssertFalse(authority.permits(receiver))
        if let latest = model.workerReceiverProbeFreshness, let latestAuthority = model.candidateAuthority {
            model.captureChanged(nil)
            XCTAssertFalse(latestAuthority.permits(latest))
        }
        await model.stopStreaming()
    }

    private func candidateState(_ model: CaptureStreamingModel, receipt: PublishingBitRateChange? = nil, revision: UInt64 = 0) -> PublishingQualitySession.Snapshot {
        .init(attemptID: model.videoObservation!.scope.publishingAttemptID,
            applied: receipt == nil ? nil : .init(profileID: "240p30", videoBitrate: 350_000),
            revision: receipt == nil ? nil : revision, receipt: receipt, profileReceipt: nil, application: nil,
            acknowledgedAt: receipt?.acceptedAt, lastWindow: nil, lastDecoderStall: nil, lastDeliveryFailure: nil,
            evaluatedAt: nil, isClosed: false, isBusy: false)
    }

    func testReplacementTapSynchronouslyWithdrawsReceiverEvidence() async throws {
        let (model, server, _, response) = try await receiverProbeModel()
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        model.captureChanged(captureContext())
        XCTAssertNil(model.workerReceiverProbeFreshness)
        XCTAssertNil(model.workerReceiverProbeInterval)
        await model.stopStreaming()
    }

    func testProbeObservationRateCeilingDependsOnStageAndRequiresCurrentOwner() {
        var sample = PublishingProbeObservation(id: UUID(), publishingGeneration: 1, bitRate: 2_000_000,
            startedAt: 10, leaseDeadline: 10.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, permitsCurrentOwner: { _, _, _ in true })
        XCTAssertTrue(sample.isActive(at: 10.1))
        sample.bitRate = 2_000_001
        XCTAssertFalse(sample.isActive(at: 10.1))
        sample.stage = 1
        XCTAssertTrue(sample.isActive(at: 10.1))
        sample.bitRate = 12_000_000
        XCTAssertTrue(sample.isActive(at: 10.1))
        sample.bitRate = 12_000_001
        XCTAssertFalse(sample.isActive(at: 10.1))
        sample.bitRate = 12_000_000
        sample.stage = 33
        XCTAssertFalse(sample.isActive(at: 10.1))
        sample.stage = 1
        sample.permitsCurrentOwner = { _, _, _ in false }
        XCTAssertFalse(sample.isActive(at: 10.1))
        sample.permitsCurrentOwner = { _, _, _ in true }
        XCTAssertFalse(sample.isActive(at: 10.3))
        sample.reason = "cancelled"
        XCTAssertFalse(sample.isActive(at: 10.1))
    }

    func testReceiverProbeFixturePollsWithinNativeLeaseWithoutWeakeningDefaultCadence() async throws {
        let (model, _, _, _) = try await receiverProbeModel()
        model.cadenceReportFixtureWriter = nil
        model.receiverProbeFixtureWriter = nil
        XCTAssertEqual(model.controlPollInterval, .seconds(2))
        model.receiverProbeFixtureWriter = { _ in }
        // A 300-ms observed native lease must be refreshed before local health
        // expires it; otherwise a one-second receiver interval never forms.
        XCTAssertLessThan(model.controlPollInterval, .milliseconds(300))
        XCTAssertGreaterThanOrEqual(model.controlPollInterval, .milliseconds(100))
        model.receiverProbeFixtureWriter = nil
        XCTAssertEqual(model.controlPollInterval, .seconds(2))
        await model.stopStreaming()
    }
    func testObservedLeaseGapCannotBeBridgedByAStillRenewedNativeOwner() async throws {
        let (model, server, publisher, initial) = try await receiverProbeModel()
        let value = await publisher.probeValue()
        var sample = try XCTUnwrap(value)
        sample.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.3
        await publisher.setProbe(sample)
        var response = initial; response.status.receiverProbe?.ageUpperBoundMs = 100
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        let firstReceived = ContinuousClock.now
        // Native renewal continues, but the app has not observed that new lease.
        sample.leaseDeadline += 10; sample.acceptedPayloadBytes = 5264
        await publisher.setProbe(sample)
        try await Task.sleep(for: .milliseconds(350))
        model.pollLocalHealth()
        XCTAssertNil(model.workerReceiverProbeFreshness)
        try await Task.sleep(for: .milliseconds(700))
        let elapsed = firstReceived.duration(to: .now).components
        let observed = 1_000_000_000 + elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000
        response.status.receiverProbe?.snapshot.observedAtNanoseconds = String(observed)
        response.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = String(observed - 10_000_000)
        response.status.receiverProbe?.snapshot.deliveredMessages = "4"
        response.status.receiverProbe?.snapshot.deliveredPayloadBytes = "5264"
        response.status.receiverProbe?.snapshot.nextSequence = "4"
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        XCTAssertNil(model.workerReceiverProbeInterval, "A new baseline is required after unavailable ownership evidence")
        XCTAssertEqual(model.localState, .publishing)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await model.stopStreaming()
    }
    func testLocalHealthWithdrawsRevokedProbeBeforeItsLeaseExpires() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let ownership = CaptureProbeOwnership()
        let value = await publisher.probeValue()
        var sample = try XCTUnwrap(value)
        sample.permitsCurrentOwner = { _, _, _ in ownership.permits }
        await publisher.setProbe(sample)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        ownership.revoke()
        model.pollLocalHealth()
        XCTAssertNil(model.workerReceiverProbeFreshness)
        XCTAssertNil(model.workerReceiverProbeInterval)
        XCTAssertEqual(model.localState, .publishing)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await model.stopStreaming()
    }
    func testLegacySnapshotWithoutNativeOwnershipIsNotEvidence() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let value = await publisher.probeValue()
        var sample = try XCTUnwrap(value)
        sample.permitsCurrentOwner = nil
        await publisher.setProbe(sample)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNil(model.workerReceiverProbeFreshness)
        XCTAssertEqual(model.localState, .publishing)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await model.stopStreaming()
    }
    func testStagedReceiverEvidenceRequiresExactLocalStageAndOwnership() async throws {
        for mode in ["matched", "missingAuthority", "wrongStage", "legacyOwner"] {
            let (model, server, publisher, initial) = try await receiverProbeModel()
            let value = await publisher.probeValue()
            var sample = try XCTUnwrap(value)
            sample.stage = mode == "legacyOwner" ? nil : 3
            sample.permitsCurrentOwner = nil
            if mode != "missingAuthority" { sample.permitsCurrentOwner = { _, _, _ in true } }
            await publisher.setProbe(sample)
            var response = initial
            response.status.receiverProbe?.snapshot.convention = "mpegts-null-probe-v2"
            response.status.receiverProbe?.snapshot.stage = mode == "wrongStage" ? 4 : 3
            response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = "5264"
            await server.setStatusOverride(response); await model.pollControl()
            XCTAssertEqual(model.workerReceiverProbeFreshness != nil, mode == "matched", mode)
            XCTAssertEqual(model.localState, .publishing)
            XCTAssertEqual(model.activeRecordingID, "recording-1")
            await model.stopStreaming()
        }
    }

    func testRevokedSnapshotCannotSurviveSuspendedNativeRead() async throws {
        for stage: Int? in [nil, 3] {
            let (model, server, publisher, initial) = try await receiverProbeModel()
            let ownership = CaptureProbeOwnership()
            let value = await publisher.probeValue()
            var sample = try XCTUnwrap(value)
            sample.stage = stage
            sample.permitsCurrentOwner = { _, _, _ in ownership.permits }
            await publisher.setProbe(sample)
            var response = initial
            if let stage {
                response.status.receiverProbe?.snapshot.convention = "mpegts-null-probe-v2"
                response.status.receiverProbe?.snapshot.stage = stage
                response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = "5264"
            }
            await server.setStatusOverride(response); await model.pollControl()
            XCTAssertNotNil(model.workerReceiverProbeFreshness)
            let gate = FilmTestGate(); await publisher.setProbeGate(gate)
            let polling = Task { await model.pollControl() }
            await gate.waitUntilEntered()
            ownership.revoke()
            await publisher.setProbe(nil)
            await gate.release(); await polling.value
            XCTAssertNil(model.workerReceiverProbeFreshness)
            XCTAssertNil(model.workerReceiverProbeInterval)
            XCTAssertEqual(model.localState, .publishing)
            XCTAssertEqual(model.activeRecordingID, "recording-1")
            await model.stopStreaming()
        }
    }

    func testProbeEvidenceExpiresAtObservedNativeLeaseWithoutStoppingRecording() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let nativeValue = await publisher.probeValue()
        var sample = try XCTUnwrap(nativeValue)
        sample.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.3
        await publisher.setProbe(sample)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        model.pollLocalHealth(at: ContinuousClock.now + .milliseconds(500))
        XCTAssertNil(model.workerReceiverProbeFreshness); XCTAssertNil(model.workerReceiverProbeInterval)
        XCTAssertEqual(model.localState, .publishing); XCTAssertEqual(model.activeRecordingID, "recording-1")
        await model.stopStreaming()
    }

    func testWrongStatusScopeCannotWashSameNativeProbeQuarantine() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let nativeValue = await publisher.probeValue()
        let accepted = try XCTUnwrap(nativeValue)
        var impossible = accepted; impossible.acceptedPayloadBytes = 0; impossible.lastAcceptedAt = nil
        await publisher.setProbe(impossible)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNil(model.workerReceiverProbeFreshness)
        var wrong = response; wrong.status.gameId = "other"
        await server.setStatusOverride(wrong); await model.pollControl()
        await publisher.setProbe(accepted)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNil(model.workerReceiverProbeFreshness)
        await model.stopStreaming()
    }

    func testReceiverProbeMatchesActualPublisherAndExpiresIndependentlyOfRecording() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerReceiverProbeFreshness)
        XCTAssertEqual(model.workerReceiverProbeFreshness?.expected.publishingGeneration, 1)
        XCTAssertNil(model.workerReceiverProbeInterval)
        model.pollLocalHealth(at: ContinuousClock.now + .seconds(2))
        XCTAssertNil(model.workerReceiverProbeFreshness)
        XCTAssertEqual(model.localState, .publishing); XCTAssertEqual(model.activeRecordingID, "recording-1")
        await publisher.setProbe(nil); await model.pollControl()
        XCTAssertNil(model.workerReceiverProbeFreshness)
        await model.stopStreaming()
    }

    func testWrongReceiverProbeIdentityNativeGenerationOrTerminatedLeaseCannotMatch() async throws {
        for fault in ["id", "nativeGeneration", "ended", "lease", "accepted", "stale"] {
            let (model, server, publisher, initial) = try await receiverProbeModel()
            var response = initial
            if fault == "id" { response.status.receiverProbe?.snapshot.id = UUID().uuidString.lowercased() }
            if fault == "stale" { response.status.receiverProbe?.ageUpperBoundMs = 1501 }
            if fault == "nativeGeneration" { await publisher.setTransportClock(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 2)); await publisher.waitForTransportClockReads(2) }
            if var sample = await publisher.probe {
                if fault == "ended" { sample.reason = "cancelled" }
                if fault == "lease" { sample.leaseDeadline = sample.startedAt }
                if fault == "accepted" { sample.acceptedPayloadBytes = 0; sample.lastAcceptedAt = nil }
                await publisher.setProbe(sample)
            }
            await server.setStatusOverride(response); await model.pollControl()
            XCTAssertNil(model.workerReceiverProbeFreshness, fault)
            XCTAssertNil(model.workerReceiverProbeInterval, fault)
            XCTAssertEqual(model.localState, .publishing)
            await model.stopStreaming()
        }
    }

    func testLateNativeProbeReadCannotResurrectDetachedCaptureEvidence() async throws {
        let (model, server, publisher, response) = try await receiverProbeModel()
        let gate = FilmTestGate(); await publisher.setProbeGate(gate)
        await server.setStatusOverride(response)
        let polling = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release(); await polling.value
        XCTAssertNil(model.workerReceiverProbeFreshness); XCTAssertNil(model.workerReceiverProbeInterval)
        await model.stopStreaming()
    }

    func testReceiverIntervalFixtureSerializesActualTrackerAndDeduplicates() async throws {
        try await checkReceiverIntervalSerialization(stage: nil)
        try await checkReceiverIntervalSerialization(stage: 3)
    }
    func testReceiverIntervalFixturePreservesCampaignAndRejectsCrossedNativeOwnership() async throws {
        try await checkReceiverIntervalSerialization(stage: 3, campaign: 2)
    }
    private func checkReceiverIntervalSerialization(stage: Int?, campaign: UInt32? = nil) async throws {
        let (model, _, publisher, initial) = try await receiverProbeModel()
        let nativeValue = await publisher.probeValue()
        var native = try XCTUnwrap(nativeValue); native.stage = stage; native.campaign = campaign
        let scope = try XCTUnwrap(model.videoObservation?.scope)
        let expected = WorkerReceiverProbeExpectation(gameId: "game-1", generation: 1, workerId: "worker-1",
            publishingAttemptId: scope.publishingAttemptID.uuidString.lowercased(), probeId: native.id.uuidString.lowercased(),
            publishingGeneration: 1, bitRate: 1_000_000, stage: stage, campaign: campaign)
        var tracker = WorkerReceiverProbeTracker(), history = ReceiverProbeFixtureHistory()
        let anchor = ContinuousClock.now
        var end: WorkerReceiverProbeInterval?
        for n in [1, 2] {
            var response = initial
            response.status.receiverProbe?.snapshot.observedAtNanoseconds = String(n * 1_000_000_000)
            response.status.receiverProbe?.snapshot.lastDeliveredAtNanoseconds = String(n * 1_000_000_000 - 10_000_000)
            response.status.receiverProbe?.snapshot.deliveredMessages = String(n * 2)
            response.status.receiverProbe?.snapshot.deliveredPayloadBytes = String(n * 2632)
            response.status.receiverProbe?.snapshot.nextSequence = String(n * 2)
            if let stage {
                response.status.receiverProbe?.snapshot.convention = campaign == nil ? "mpegts-null-probe-v2" : "mpegts-null-probe-v3"
                response.status.receiverProbe?.snapshot.stage = stage
                response.status.receiverProbe?.snapshot.totalDeliveredPayloadBytes = String((n + 1) * 2632)
                if let campaign {
                    response.status.receiverProbe?.snapshot.campaign = String(campaign)
                    response.status.receiverProbe?.snapshot.campaignDeliveredPayloadBytes = String(n * 2632)
                }
            }
            let evidence = try XCTUnwrap(WorkerReceiverProbeFreshness(response: response, expected: expected,
                receivedAt: anchor + .seconds(n), requestDuration: .zero))
            end = tracker.observe(evidence, acceptedPayloadBytes: UInt64(n * 2632), senderActive: true, at: anchor + .seconds(n))
        }
        let interval = try XCTUnwrap(end)
        var accepted = native; accepted.acceptedPayloadBytes = 5264
        let timing = PublishingProbeReadTiming(requestStartedAt: 1.98, responseReceivedAt: 2,
            nativeReadStartedAt: 2, nativeReadFinishedAt: 2, evaluatedAt: 2)
        history.record(interval, accepted: accepted, at: anchor + .seconds(2), timing: timing, quarantined: false)
        history.record(interval, accepted: accepted, at: anchor + .seconds(2.1), timing: timing, quarantined: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: history.data(scope: scope)) as? [String: Any])
        XCTAssertEqual(json["isClosed"] as? Bool, true)
        XCTAssertEqual(json["invalid"] as? Bool, false)
        let rows = try XCTUnwrap(json["intervals"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["nativeProbeStage"] as? Int, stage)
        XCTAssertEqual(rows.first?["nativeProbeCampaign"] as? String, campaign.map(String.init))
        XCTAssertEqual((rows.first?["start"] as? [String: Any])?["campaign"] as? String, campaign.map(String.init))
        XCTAssertEqual((rows.first?["end"] as? [String: Any])?["campaign"] as? String, campaign.map(String.init))
        if campaign != nil {
            for fault in ["campaign", "missingCampaign", "id", "stage", "generation", "rate"] {
                var wrong = accepted, damaged = history
                switch fault {
                case "campaign": wrong.campaign = 3
                case "missingCampaign": wrong.campaign = nil
                case "id": wrong.id = UUID()
                case "stage": wrong.stage = 2
                case "generation": wrong.publishingGeneration = 2
                default: wrong.bitRate = 2_000_000
                }
                damaged.record(interval, accepted: wrong, at: anchor + .seconds(2.1), timing: timing, quarantined: false)
                let result = try XCTUnwrap(JSONSerialization.jsonObject(with: damaged.data(scope: scope)) as? [String: Any])
                XCTAssertEqual(result["invalid"] as? Bool, true, fault)
            }
        }
        XCTAssertEqual((rows.first?["end"] as? [String: Any])?["stage"] as? Int, stage)
        XCTAssertEqual((rows.first?["end"] as? [String: Any])?["totalDeliveredPayloadBytes"] as? String, stage == nil ? nil : "7896")
        XCTAssertEqual(rows.first?["serverAgeUpperBoundMs"] as? Double, 10)
        XCTAssertEqual(rows.first?["requestDurationMs"] as? Double, 0)
        XCTAssertEqual(rows.first?["residenceDurationMs"] as? Double, 0)
        XCTAssertEqual(rows.first?["nativeReadFinishedAt"] as? Double, 2)
        XCTAssertEqual(rows.first?["deliveredMessages"] as? String, "2")
        XCTAssertEqual(rows.first?["deliveredPayloadBytesLowerBound"] as? String, "2632")
        history.record(nil, accepted: accepted, at: anchor + .seconds(2.1), timing: timing, quarantined: true)
        let failed = try XCTUnwrap(JSONSerialization.jsonObject(with: history.data(scope: scope)) as? [String: Any])
        XCTAssertEqual(failed["invalid"] as? Bool, true)
        await model.stopStreaming()
    }

    private func receiverProbeModel(qualityFactory: @escaping @MainActor (PublishingSession, UUID) throws -> PublishingQualityDriver? = { _, _ in nil }) async throws -> (CaptureStreamingModel, CaptureTestServer, CaptureTestPublisher, WorkerMediaStatusResponse) {
        let server = CaptureTestServer(), publisher = CaptureTestPublisher()
        await publisher.setTransportClock(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        let model = makeModel(server: server, publisher: publisher, qualityFactory: qualityFactory)
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await publisher.waitForTransportClockReads(1)
        let scope = try XCTUnwrap(model.videoObservation?.scope)
        let now = ProcessInfo.processInfo.systemUptime
        let id = UUID()
        await publisher.setProbe(.init(id: id, publishingGeneration: 1, bitRate: 1_000_000,
            startedAt: now - 1, leaseDeadline: now + 10, acceptedPayloadBytes: 2632,
            lastAcceptedAt: now - 0.01, reason: nil, permitsCurrentOwner: { _, _, _ in true }))
        var response = workerAgeResponse()
        response.status.workerEpoch = "22222222-2222-2222-2222-222222222222"
        response.status.publication = .init(readerId: "33333333-3333-3333-3333-333333333333",
            publisherId: "44444444-4444-4444-4444-444444444444",
            publishingAttemptId: scope.publishingAttemptID.uuidString.lowercased(),
            clock: .init(convention: "mpegts-ingress-origin-90k-v1", originPTS: "0"))
        response.status.receiverProbe = .init(snapshot: .init(convention: "mpegts-null-probe-v1",
            id: id.uuidString.lowercased(), publishingGeneration: "1", bitRate: 1_000_000,
            deliveredMessages: "2", deliveredPayloadBytes: "2632", nextSequence: "2", pendingPackets: 0,
            observedAtNanoseconds: "1000000000", firstDeliveredAtNanoseconds: "100000000", lastDeliveredAtNanoseconds: "990000000"), ageUpperBoundMs: 10)
        return (model, server, publisher, response)
    }

    func testQualityDriverJoinsPublishingStopWhileRecordingContextSurvives() async throws {
        let server = CaptureTestServer()
        var driver: PublishingQualityDriver?
        var exported: Data?
        let model = makeModel(server: server, qualityFactory: { session, attempt in
            let owner = try PublishingQualitySession(session: session,
                profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
                attemptID: attempt, initial: .init(profileID: "hd", videoBitrate: 6_000_000))
            let created = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil, export: { exported = $0 })
            driver = created; return created
        })
        XCTAssertEqual(model.controlPollInterval, .seconds(2))
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        XCTAssertEqual(model.controlPollInterval, .milliseconds(100))
        XCTAssertNotNil(driver); XCTAssertEqual(driver?.isClosed, false)
        model.pollLocalHealth()
        await model.stopStreaming()
        XCTAssertEqual(driver?.isClosed, true); XCTAssertNotNil(exported)
        XCTAssertEqual(model.controlPollInterval, .seconds(2))
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        XCTAssertEqual((json["events"] as? [[String: Any]])?.last?["kind"] as? String, "stopped")
    }

    func testNativeSourceIntervalFollowsPublishingAndClearsOnCaptureReplacement() async throws {
        let (model, server, owner) = try await sourceIntervalModel()
        let result = try XCTUnwrap(model.workerSourceInterval)
        XCTAssertEqual(result.sequence, 2)
        XCTAssertEqual(result.interval.encodedFrames, 150)
        XCTAssertEqual(result.interval.encodedNotDecodedFrames, 0)
        XCTAssertEqual(result.interval.scope, owner.snapshot.scope)
        XCTAssertEqual(model.localState, .publishing)
        // A reused recording ID with another capture tap cannot inherit evidence.
        model.captureChanged(captureContext())
        XCTAssertNil(model.workerSourceInterval)
        await model.pollControl()
        XCTAssertNil(model.workerSourceInterval)
        let requests = await server.requestCount
        XCTAssertGreaterThan(requests, 0)
        await model.stopStreaming()
    }

    func testNativeSourceIntervalExpiresWithoutStoppingRecordingAndStopClearsIt() async throws {
        let (model, _, _) = try await sourceIntervalModel()
        XCTAssertNotNil(model.workerSourceInterval)
        model.pollLocalHealth(at: ContinuousClock.now + .seconds(6))
        XCTAssertNil(model.workerSourceInterval)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertEqual(model.localState, .publishing)
        await model.stopStreaming()
        XCTAssertNil(model.workerSourceInterval)
    }

    func testSourceIntervalExportPreservesMeasuredCountsAndRejectsOtherAttemptClock() async throws {
        let (model, _, owner) = try await sourceIntervalModel()
        let interval = try XCTUnwrap(model.workerSourceInterval)
        var accumulator = try VideoFrameObservationAccumulator(scope: owner.snapshot.scope, monotonicAnchor: 0)
        let closed = accumulator.close(at: 1)
        let clock = PublishingClockObservation(scope: closed.scope, transportClock: interval.nativeClock, isClosed: true)
        let data = try VideoObservationFixture.data(for: closed, captureDetachedAt: 0.9,
            publishingClockObservation: clock, sourceIntervals: [interval])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proofs = try XCTUnwrap(json["sourceIntervals"] as? [[String: Any]])
        XCTAssertEqual(proofs.count, 1)
        XCTAssertEqual(proofs[0]["encodedFrames"] as? Int, 150)
        XCTAssertEqual(proofs[0]["sequence"] as? String, "2")
        XCTAssertEqual(proofs[0]["previousDecodedPTS"] as? String, "445081")
        let differentClock = PublishingClockObservation(scope: closed.scope,
            transportClock: PublishingTransportClock(sourceOrigin: CMTime(value: 1, timescale: 30), publishingGeneration: 1)!, isClosed: true)
        XCTAssertThrowsError(try VideoObservationFixture.data(for: closed, captureDetachedAt: 0.9,
            publishingClockObservation: differentClock, sourceIntervals: [interval]))
        await model.stopStreaming()
    }

    func testBothStreamAndCaptureStopExportSourceIntervalsBeforeClearing() async throws {
        for stopCapture in [false, true] {
            let (model, _, _) = try await sourceIntervalModel()
            XCTAssertEqual(model.workerSourceIntervalHistory.count, 1)
            var exported: [WorkerSourceIntervalObservation] = []
            model.videoObservationFixtureWriter = { snapshot, _, _, _, _, intervals in
                XCTAssertTrue(snapshot.isClosed)
                exported = intervals
            }
            if stopCapture { model.captureChanged(nil) }
            await model.stopStreaming()
            XCTAssertEqual(exported.count, 1)
            XCTAssertEqual(exported.first?.interval.encodedFrames, 150)
            XCTAssertTrue(model.workerSourceIntervalHistory.isEmpty)
            XCTAssertNil(model.workerSourceInterval)
        }
    }

    private func sourceIntervalModel() async throws -> (CaptureStreamingModel, CaptureTestServer, VideoFrameObservationOwner) {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        await publisher.setTransportClock(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        var owner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisher: publisher, observationFactory: { scope in
            let result = try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 2048)
            owner = result
            return result
        })
        model.workerReportAgeProofsEnabled = true
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let observed = try XCTUnwrap(owner)
        for i in 0..<450 {
            let pts = CMTime(value: Int64(i), timescale: 30)
            observed.observe(.captureVideo, sourcePTS: pts)
            observed.observe(.encodedVideo, sourcePTS: pts)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            model.pollLocalHealth()
            if model.publishingClockObservation != nil { break }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTAssertNotNil(model.publishingClockObservation)
        for sequence: Int64 in [1, 2] {
            var response = workerAgeResponse()
            response.status.workerEpoch = "22222222-2222-2222-2222-222222222222"
            response.status.publication = .init(readerId: "33333333-3333-3333-3333-333333333333",
                publisherId: "44444444-4444-4444-4444-444444444444",
                publishingAttemptId: observed.snapshot.scope.publishingAttemptID.uuidString.lowercased(),
                clock: .init(convention: "mpegts-ingress-origin-90k-v1", originPTS: "10919"))
            response.status.observation?.decodedVideo?.clock = "mpegts-pts-90k-v1"
            response.status.observation?.decodedVideo?.completed = .init(sequence: sequence, durationMs: 5000, ageMs: 250,
                firstPTS: (sequence - 1) * 450_000 - 1919, lastPTS: sequence * 450_000 - 4919,
                freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true)
            await server.setStatusOverride(response)
            await model.pollControl()
        }
        return (model, server, observed)
    }

    func testStartActionDuringBackgroundPollIsNotLost() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await server.setStatusGate(gate)
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        XCTAssertTrue(model.canStart, "Background polling must not disable the start control")
        model.requestStartStreaming()
        XCTAssertEqual(model.localState, .starting)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.canChangeSetup)
        model.requestStartStreaming() // Duplicate tap cannot create another attempt.
        let startsWhilePolling = await publisher.startCount
        XCTAssertEqual(startsWhilePolling, 0)
        await gate.release()
        await polling.value
        await waitForPublishing(model)
        XCTAssertEqual(model.localState, .publishing, "A start action must survive overlap with a background poll")
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await model.stopStreaming()
    }

    private func waitForPublishing(_ model: CaptureStreamingModel) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.localState == .starting, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.localState, .publishing)
    }

    func testStartRequestReservesImmediatelyBeforeTaskScheduling() async throws {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        model.requestStartStreaming()
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.localState, .starting)
        XCTAssertFalse(model.canStart)
        model.requestStartStreaming()
        await model.pollControl()
        await waitForPublishing(model)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await model.stopStreaming()
    }

    func testImmediateStopCancelsReservedStartBeforeItsTaskRuns() async throws {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        model.requestStartStreaming()
        await model.stopStreaming()
        let starts = await publisher.startCount
        let operations = await server.operations
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(model.localState, .idle)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertFalse(model.busy)
    }

    func testStorageFailureAfterQueuedStartPreventsPublisherAndAutomaticRetry() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await server.setStatusGate(gate)
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        model.requestStartStreaming()
        storage.fails = true
        await gate.release()
        await polling.value
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.localState, .failed)
        XCTAssertTrue(model.needsStorageRetry)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        storage.fails = false
        await model.pollControl()
        let starts = await publisher.startCount
        let operations = await server.operations
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(model.canStart)
        await model.stopStreaming()
    }

    func testUnresolvedCommandDiscoveredByPollEndsQueuedStart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let saved = captureSetup()
        let pending = CaptureMemoryPending()
        pending.value = PendingBroadcastCommand(endpointScope: saved.endpointScope,
            command: BroadcastCommand(commandId: UUID().uuidString, gameId: "game-1", expectedGeneration: 0,
                issuedAt: ISO8601DateFormatter().string(from: Date()), operation: .start(selection:
                    .init(workerId: "worker-1", outputId: "output-1", captureDeviceId: "capture-1", recordingId: "older-recording"))),
            captureDeviceId: "capture-1")
        let model = CaptureStreamingModel(storage: CaptureMemoryStorage(saved), pendingStore: pending,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
            publisherFactory: { _, _ in publisher })
        await model.restore()
        model.captureChanged(captureContext())
        await server.setSnapshotGate(gate)
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        XCTAssertTrue(model.canStart)
        model.requestStartStreaming()
        await gate.release()
        await polling.value
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNotNil(model.commandState?.pending)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.canStart)
        let starts = await publisher.startCount
        let operations = await server.operations
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await model.stopStreaming()
    }

    func testStopCancelsQueuedStartBeforePollCompletes() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await server.setStatusGate(gate)
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        model.requestStartStreaming()
        XCTAssertEqual(model.localState, .starting)
        await model.stopStreaming()
        XCTAssertEqual(model.localState, .idle)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await gate.release()
        await polling.value
        let starts = await publisher.startCount
        let operations = await server.operations
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(model.localState, .idle)
    }

    func testRecordingChangeCancelsQueuedStartIncludingReusedIdentifier() async throws {
        for replacementID in [nil, "recording-2", "recording-1"] as [String?] {
            let server = CaptureTestServer()
            let gate = FilmTestGate()
            let publisher = CaptureTestPublisher()
            let model = makeModel(server: server, publisher: publisher)
            await model.restore()
            model.captureChanged(captureContext())
            await server.setStatusGate(gate)
            let polling = Task { await model.pollControl() }
            let entered = await gate.waitUntilEntered(timeout: .seconds(3))
            XCTAssertTrue(entered)
            model.requestStartStreaming()
            model.captureChanged(replacementID.map {
                CurrentCapture(id: $0, startedAt: "2026-09-15T00:00:00Z", tap: PublishingTap())
            })
            XCTAssertEqual(model.localState, .idle)
            await gate.release()
            await polling.value
            let starts = await publisher.startCount
            let operations = await server.operations
            XCTAssertEqual(starts, 0)
            XCTAssertTrue(operations.isEmpty)
            XCTAssertEqual(model.localState, .idle)
            XCTAssertEqual(model.activeRecordingID, replacementID)
            await model.stopStreaming()
        }
    }

    func testFailedPollEndsQueuedStartWithVisibleFailureAndRequiresNewTap() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await server.setStatusGate(gate)
        await server.setStatusFailure(true)
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        model.requestStartStreaming()
        await gate.release()
        await polling.value
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await server.setStatusFailure(false)
        await model.pollControl()
        let startsBeforeRetry = await publisher.startCount
        XCTAssertEqual(startsBeforeRetry, 0)
        model.requestStartStreaming()
        await waitForPublishing(model)
        await model.stopStreaming()
    }

    func testQueuedStartPreservesUnresolvedCommandWithoutStartingPublisher() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await server.setSnapshotGate(gate)
        await server.setFailBeforeCommand()
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        model.requestStartStreaming()
        await gate.release()
        await polling.value
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNotNil(model.commandState?.pending)
        XCTAssertFalse(model.canStart)
        model.requestStartStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        await model.stopStreaming()
    }

    func testStopThenFreshQueuedStartIgnoresObsoletePollFailure() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await server.setStatusGate(gate)
        await server.setStatusFailure(true)
        let polling = Task { await model.pollControl() }
        let entered = await gate.waitUntilEntered(timeout: .seconds(3))
        XCTAssertTrue(entered)
        model.requestStartStreaming()
        await model.stopStreaming()
        model.requestStartStreaming()
        XCTAssertEqual(model.localState, .starting)
        await gate.release()
        await polling.value
        await waitForPublishing(model)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await server.setStatusFailure(false)
        await model.stopStreaming()
    }

    func testOfflineRecordDoesNotCallAPI() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, saved: nil)
        let context = captureContext()
        model.captureChanged(context)
        await model.pollControl()
        model.captureChanged(nil)
        await model.pollControl()
        let count = await server.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.localState, .idle)
    }

    func testStreamingStartAndStopLeaveLocalCaptureActive() async throws {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        let context = captureContext()
        model.captureChanged(context)
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)
        let isPublishing = await publisher.isPublishing
        XCTAssertTrue(isPublishing)
        await model.stopStreaming()
        let stopped = await publisher.isPublishing
        XCTAssertFalse(stopped)
        XCTAssertEqual(model.activeRecordingID, context.id)
        XCTAssertEqual(model.localState, .idle)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testEachStartBindsGrantAndPublisherURLToDiagnosticAttempt() async throws {
        let server = CaptureTestServer()
        var destinations: [URL] = []
        let model = makeModel(server: server, publisherFactory: { url, _ in
            destinations.append(url)
            return CaptureTestPublisher()
        })
        await model.restore()
        model.captureChanged(captureContext())
        var attempts: [UUID] = []
        for _ in 0..<2 {
            await model.startStreaming()
            XCTAssertEqual(model.localState, .publishing)
            let attempt = try XCTUnwrap(model.videoObservation?.scope.publishingAttemptID)
            attempts.append(attempt)
            let requests = await server.publishAttempts
            XCTAssertEqual(requests.last!, attempt.uuidString.lowercased())
            let streamID = URLComponents(url: try XCTUnwrap(destinations.last), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "streamid" }?.value
            XCTAssertEqual(streamID, testPublishStreamID(attempt.uuidString.lowercased()))
            await model.stopStreaming()
            XCTAssertEqual(model.activeRecordingID, "recording-1")
        }
        XCTAssertNotEqual(attempts[0], attempts[1])
        XCTAssertEqual(destinations.count, 2)
    }

    func testInvalidAttemptGrantNeverStartsPublisherAndLocalRecordingCompletes() async throws {
        for failure in ["missing", "stale", "proof", "network"] {
            let server = CaptureTestServer()
            await server.setPublishFailure(failure)
            let publisher = CaptureTestPublisher()
            var factoryCalls = 0
            let model = makeModel(server: server, publisherFactory: { _, _ in
                factoryCalls += 1
                return publisher
            })
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = FilmTestSource()
            let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
            film.onCaptureChanged = { model.captureChanged($0) }
            await model.restore()
            await film.start()
            await model.startStreaming()
            XCTAssertEqual(model.localState, .failed, failure)
            XCTAssertEqual(factoryCalls, 0, failure)
            let starts = await publisher.startCount
            XCTAssertEqual(starts, 0, failure)
            XCTAssertEqual(film.state, .recording, failure)
            XCTAssertNotNil(model.activeRecordingID, failure)
            await film.stop()
            XCTAssertEqual(film.recordings.first?.status, .completed, failure)
            await model.stopStreaming()
        }
    }

    func testStopDuringPublishAccessCannotStartLatePublisher() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        await server.setPublishGate(gate)
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        await model.pollControl()
        let stopped = await publisher.isPublishing
        XCTAssertFalse(stopped)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertNil(model.activeRecordingID)
    }

    func testNetworkFailureDoesNotClearLocalRecording() async throws {
        let server = CaptureTestServer()
        await server.setOffline(true)
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNotNil(model.message)
    }

    func testRelaunchReplacesLiveReportWithHigherSequenceInterruptedReport() async throws {
        let server = CaptureTestServer()
        let saved = captureSetup()
        let storage = CaptureMemoryStorage(saved)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let before = try XCTUnwrap(storage.value?.reports.first)
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        XCTAssertNil(relaunched.activeRecordingID)
        let terminal = try XCTUnwrap(storage.value?.reports.first)
        XCTAssertEqual(terminal.report.status, .interrupted)
        XCTAssertGreaterThan(terminal.report.sequence, before.report.sequence)
        XCTAssertEqual(terminal.report.startedAt, before.report.startedAt)
        await relaunched.pollControl()
        let lastStatus = await server.reports.last?.status
        XCTAssertEqual(lastStatus, .interrupted)
        await model.stopStreaming()
    }

    func testStorageFailureCanRetryRestoreWithoutDiscardingSetup() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        storage.fails = true
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        XCTAssertTrue(model.needsStorageRetry)
        storage.fails = false
        await model.pollControl()
        XCTAssertEqual(model.connectedGameID, "game-1")
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testCadenceAuditClosesOnlyAtJoinedPublisherTeardown() async throws {
        let server = CaptureTestServer()
        let streaming = makeModel(server: server)
        var exported: Data?
        streaming.cadenceReportFixtureWriter = { exported = $0 }
        XCTAssertEqual(streaming.controlPollInterval, .milliseconds(100))
        await streaming.restore(); streaming.captureChanged(captureContext()); await streaming.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await streaming.pollControl()
        XCTAssertNil(exported)
        await streaming.stopStreaming()
        let audit = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        XCTAssertEqual(audit["closed"] as? Bool, true)
        let rows = try XCTUnwrap(audit["rows"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty); XCTAssertTrue(rows.last?["sampleAgeSeconds"] is NSNull)
    }

    func testCadenceTimingSeparatesDelayedRecoveryFromStatusAndNativeRead() async throws {
        let server = CaptureTestServer(), model = makeModel(server: server)
        var exported: Data?
        model.cadenceReportFixtureWriter = { exported = $0 }
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        let gate = FilmTestGate()
        await server.setSnapshotGate(gate)
        let poll = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(60))
        await gate.release(); await poll.value
        await model.stopStreaming()
        let audit = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        XCTAssertEqual(audit["invalid"] as? Bool, false)
        let rows = try XCTUnwrap(audit["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.last)
        let timing = try XCTUnwrap(row["timing"] as? [String: Double])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(timing["maintenanceSeconds"]), 0.06)
        XCTAssertEqual(timing["responseReceivedUptime"], row["receivedUptime"] as? Double)
        XCTAssertEqual(timing["auditEvaluatedUptime"], row["evaluatedUptime"] as? Double)
        let residence = try XCTUnwrap(timing["responseProcessingSeconds"]) + XCTUnwrap(timing["nativeProbeSeconds"]) + XCTUnwrap(timing["postProbeProcessingSeconds"])
        XCTAssertEqual(residence, try XCTUnwrap(row["residenceSeconds"] as? Double), accuracy: 0.001)
    }

    func testCadenceDoesNotRequireSourceHistoryAndClearsOnMismatchExpiryAndStop() async throws {
        let server = CaptureTestServer()
        var owner: VideoFrameObservationOwner?
        let model = makeModel(server: server, observationFactory: { scope in
            let value = try VideoFrameObservationOwner(scope: scope)
            owner = value; return value
        })
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        let observed = try XCTUnwrap(owner)
        XCTAssertNil(observed.sourceHistorySnapshot)
        var response = workerAgeResponse()
        response.status.workerEpoch = "22222222-2222-2222-2222-222222222222"
        response.status.publication = .init(readerId: "33333333-3333-3333-3333-333333333333",
            publisherId: "44444444-4444-4444-4444-444444444444",
            publishingAttemptId: observed.snapshot.scope.publishingAttemptID.uuidString.lowercased(),
            clock: .init(convention: "mpegts-ingress-origin-90k-v1", originPTS: "10919"))
        response.status.observation?.decodedVideo?.clock = "mpegts-pts-90k-v1"
        response.status.decoderCadenceAgeUpperBoundMs = 50
        response.status.observation?.decoderCadence = try JSONDecoder().decode(DecoderCadenceSnapshot.self, from: Data("""
            {"formatVersion":1,"scopeID":"11111111-1111-4111-8111-111111111111","oneSecond":null,"twoSeconds":null,
            "progress":{"lastFreshPTS":180000,"ageMs":1000,"stalled":true},"invalidReason":null,"ended":false}
            """.utf8))
        for fault in ["publication", "scope", "legacy", "expiry"] {
            await server.setStatusOverride(response); await model.pollControl()
            XCTAssertNotNil(model.workerDecoderCadenceFreshness)
            if fault == "expiry" { model.pollLocalHealth(at: .now + .seconds(6)) }
            else {
                var changed = response
                if fault == "publication" { changed.status.publication?.publishingAttemptId = UUID().uuidString.lowercased() }
                if fault == "scope" { changed.status.generation = 2 }
                if fault == "legacy" { changed.status.observation?.decoderCadence = nil }
                await server.setStatusOverride(changed); await model.pollControl()
            }
            XCTAssertNil(model.workerDecoderCadenceFreshness, fault)
            XCTAssertEqual(model.localState, .publishing)
        }
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerDecoderCadenceFreshness)
        await model.stopStreaming(); XCTAssertNil(model.workerDecoderCadenceFreshness)
    }

    func testWorkerDecodedVideoAgeStoredAndExpiresWithoutAnotherRequest() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        let evidence = try XCTUnwrap(model.workerDecodedVideoFreshness)
        XCTAssertEqual(evidence.gameId, "game-1")
        XCTAssertEqual(evidence.generation, 1)
        XCTAssertEqual(evidence.workerId, "worker-1")
        XCTAssertEqual(evidence.attempt, 2)
        XCTAssertEqual(evidence.completed.sequence, 7)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(evidence.ageUpperBound()), .milliseconds(550))
        XCTAssertEqual(model.workerState, .producingOutput)
        let requestsBefore = await server.requestCount
        model.pollLocalHealth(at: ContinuousClock.now + .seconds(5))
        XCTAssertNil(model.workerDecodedVideoFreshness)
        XCTAssertEqual(model.workerState, .stale)
        XCTAssertEqual(model.localState, .publishing)
        let requestsAfter = await server.requestCount
        XCTAssertEqual(requestsAfter, requestsBefore)
        await model.stopStreaming()
    }

    func testLegacyWorkerReplyClearsPreviouslyStoredAgeWithoutChangingProcessHealth() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        XCTAssertNotNil(model.workerDecodedVideoFreshness)
        await server.setStatusOverride(workerAgeResponse(bound: nil))
        await model.pollControl()
        XCTAssertNil(model.workerDecodedVideoFreshness)
        XCTAssertEqual(model.workerState, .producingOutput)
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        XCTAssertNotNil(model.workerDecodedVideoFreshness)
        await model.stopStreaming()
        XCTAssertNil(model.workerDecodedVideoFreshness)
    }

    func testWorkerScopeMismatchClearsPreviouslyStoredAge() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        for field in ["game", "generation", "worker"] {
            await server.setStatusOverride(workerAgeResponse())
            await model.pollControl()
            XCTAssertNotNil(model.workerDecodedVideoFreshness)
            var mismatch = workerAgeResponse()
            switch field {
            case "game": mismatch.status.gameId = "other"
            case "generation": mismatch.status.generation = 2
            default: mismatch.status.workerId = "other"
            }
            await server.setStatusOverride(mismatch)
            await model.pollControl()
            XCTAssertNil(model.workerDecodedVideoFreshness)
            XCTAssertEqual(model.workerState, .unknown)
        }
        await model.stopStreaming()
    }

    func testLateWorkerFailureAfterStopIsIgnoredAndRestartWaitsForControlCompletion() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        var publishers: [CaptureTestPublisher] = []
        let model = makeModel(server: server, publisherFactory: { _, _ in
            let publisher = CaptureTestPublisher(); publishers.append(publisher); return publisher
        })
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusGate(gate)
        await server.setStatusFailure(true)
        let polling = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        await model.stopStreaming()
        let messageAfterStop = model.message
        await model.startStreaming()
        XCTAssertEqual(publishers.count, 1, "A pending control request blocks replacement startup")
        XCTAssertEqual(model.localState, .idle)
        await gate.release()
        await polling.value
        XCTAssertEqual(model.localState, .idle)
        XCTAssertEqual(model.message, messageAfterStop, "An obsolete worker failure must not overwrite current status")
        XCTAssertEqual(model.workerState, .unknown)
        await server.setStatusFailure(false)
        await server.setStatusGate(nil)
        await model.startStreaming()
        XCTAssertEqual(publishers.count, 2)
        XCTAssertEqual(model.localState, .publishing)
        await model.pollControl()
        XCTAssertEqual(model.localState, .publishing)
        let replacementPublishing = await publishers.last?.isPublishing
        XCTAssertEqual(replacementPublishing, true)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start"], "Obsolete failure must not trigger a stop of the replacement")
        await model.stopStreaming()
    }

    func testWorkerReplyAfterLocalStopCannotReappearAsCurrent() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        XCTAssertNotNil(model.workerDecodedVideoFreshness)
        await server.setStatusGate(gate)
        let polling = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        XCTAssertNil(model.workerDecodedVideoFreshness)
        await gate.release()
        await polling.value
        XCTAssertEqual(model.workerState, .unknown)
        XCTAssertNil(model.workerDecodedVideoFreshness)
    }

    func testWorkerObservationExpiresIndependentlyOfControlRequests() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await model.pollControl()
        XCTAssertEqual(model.workerState, .stale)
        await model.stopStreaming()
    }

    func testLostStartReplyRecoversReceiptAndStopsOnlyOwnedRecording() async throws {
        let server = CaptureTestServer()
        await server.setDropReply()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertNotNil(model.commandState?.pending)
        model.captureChanged(nil)
        await model.pollControl()
        XCTAssertNil(model.commandState?.pending)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testStopNeverStopsAnotherCaptureSelection() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.selectAnotherCapture()
        await model.stopStreaming()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start"])
    }

    func testStopDuringPublisherStartupIsTerminal() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        let active = await publisher.isPublishing
        XCTAssertFalse(active)
        XCTAssertEqual(model.localState, .idle)
    }

    func testStopDuringCaptureJoinPreventsAnyBroadcastOrPublisherStart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        await server.setJoinGate(gate)
        var saved = captureSetup(); saved.credential = nil
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, saved: saved, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        let operations = await server.operations
        let starts = await publisher.startCount
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(model.activeRecordingID)
    }

    func testBroadcastStorageFailureIsVisibleAndDoesNotPOST() async throws {
        let server = CaptureTestServer()
        let pending = CaptureMemoryPending()
        let model = CaptureStreamingModel(storage: CaptureMemoryStorage(captureSetup()), pendingStore: pending,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
            publisherFactory: { _, _ in CaptureTestPublisher() })
        await model.restore()
        pending.fails = true
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertTrue(model.needsStorageRetry)
        XCTAssertFalse(model.canChangeSetup)
        let operations = await server.operations
        XCTAssertTrue(operations.isEmpty)
        pending.fails = false
        await model.pollControl()
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testSetupPersistsDeviceIdentityBeforeFailedJoin() async throws {
        let server = CaptureTestServer()
        await server.setOffline(true)
        let storage = CaptureMemoryStorage(nil)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.installationToken = "token"
        await model.connect()
        let first = try XCTUnwrap(storage.value?.deviceId)
        XCTAssertNotNil(UUID(uuidString: first))
        let next = makeModel(server: server, storage: storage)
        await next.restore()
        await next.connect()
        XCTAssertEqual(storage.value?.deviceId, first)
    }

    func testStopStreamingDoesNotReplayAnUncommittedStartWhileArchiveContinues() async throws {
        let server = CaptureTestServer()
        await server.setFailBeforeCommand()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertNotNil(model.commandState?.pending)
        await model.stopStreaming()
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        let operations = await server.operations
        XCTAssertTrue(operations.isEmpty)
        XCTAssertNotNil(model.commandState?.pending)
    }

    func testSecondRelaunchRetainsStopOwnershipAfterTerminalReportAcknowledgment() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        model.captureChanged(nil)
        await server.setFailMedia(true)
        await model.stopStreaming()
        XCTAssertTrue(storage.value?.reports.isEmpty == true, "Terminal report was acknowledged before media lookup failed")
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        await server.setFailMedia(false)
        await relaunched.pollControl()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testSetupSaveFailureCannotBeBypassedByRetryingSameFields() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(nil)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.installationToken = "test-token"
        storage.fails = true
        await model.connect()
        await model.connect()
        let requestsBeforeSave = await server.requestCount
        XCTAssertEqual(requestsBeforeSave, 0, "No join may use an identity that has not been saved")
        storage.fails = false
        await model.connect()
        XCTAssertEqual(model.connectedGameID, "game-1")
    }

    func testBlockedPublisherStopPreventsOverlappingRestart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await gate.release()
        await stopping.value
        XCTAssertTrue(model.canStart)
    }

    func testIndependentPollDefersOwnedStopUntilPublisherFinishCompletes() async throws {
        let trace = CaptureStopOrderTrace()
        let server = CaptureTestServer(stopOrderTrace: trace)
        let finishGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: finishGate, stopOrderTrace: trace)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)

        let stopping = Task { await model.stopStreaming() }
        let finishEntered = await finishGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(finishEntered, "Publisher finish must be pending before the independent poll")
        if finishEntered {
            await model.pollControl()
            let operations = await server.operations
            let desired = await server.broadcast.desired
            XCTAssertEqual(operations, ["start"], "Control stop must wait for publisher finish: \(trace.events)")
            XCTAssertEqual(desired, .running)
            XCTAssertEqual(trace.events, ["publisher.finish.entered"])
        }
        await finishGate.release()
        await stopping.value
        let operations = await server.operations
        let desired = await server.broadcast.desired
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertEqual(desired, .stopped)
        XCTAssertEqual(trace.events, ["publisher.finish.entered", "publisher.finish.completed", "server.stop"])
        XCTAssertEqual(model.activeRecordingID, "recording-1")
    }

    func testInFlightRecoveryDefersOwnedStopUntilPublisherFinishCompletes() async throws {
        let trace = CaptureStopOrderTrace()
        let server = CaptureTestServer(stopOrderTrace: trace)
        let recoveryGate = FilmTestGate(), finishGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: finishGate, stopOrderTrace: trace)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)

        await server.setSnapshotGate(recoveryGate)
        let polling = Task { await model.pollControl() }
        let recoveryEntered = await recoveryGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(recoveryEntered, "The poll must already be suspended in snapshot recovery")
        let stopping = Task { await model.stopStreaming() }
        let finishEntered = await finishGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(finishEntered, "Publisher finish must be pending before recovery resumes")
        await recoveryGate.release()
        await polling.value
        if recoveryEntered && finishEntered {
            let operations = await server.operations
            let desired = await server.broadcast.desired
            XCTAssertEqual(operations, ["start"], "Resumed recovery must wait for publisher finish: \(trace.events)")
            XCTAssertEqual(desired, .running)
            XCTAssertEqual(trace.events, ["publisher.finish.entered"])
        }
        await finishGate.release()
        await stopping.value
        let operations = await server.operations
        let desired = await server.broadcast.desired
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertEqual(desired, .stopped)
        XCTAssertEqual(trace.events, ["publisher.finish.entered", "publisher.finish.completed", "server.stop"])
        XCTAssertEqual(model.activeRecordingID, "recording-1")
    }

    func testCaptureEndDefersTerminalControlUntilPublisherFinishCompletes() async throws {
        let trace = CaptureStopOrderTrace()
        let server = CaptureTestServer(stopOrderTrace: trace)
        let finishGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: finishGate, stopOrderTrace: trace)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)

        model.captureChanged(nil)
        let finishEntered = await finishGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(finishEntered)
        if finishEntered {
            await model.pollControl()
            let operations = await server.operations
            let desired = await server.broadcast.desired
            let statuses = await server.reports.map(\.status)
            XCTAssertEqual(operations, ["start"], "Capture end must wait for publisher finish: \(trace.events)")
            XCTAssertEqual(desired, .running)
            XCTAssertEqual(statuses, [.recording], "The capture terminal report should remain queued while finish is pending")
        }
        await finishGate.release()
        await model.stopStreaming()
        await model.pollControl()
        let operations = await server.operations
        let statuses = await server.reports.map(\.status)
        XCTAssertEqual(operations, ["start", "stop"], "Later polls must not duplicate the owned stop")
        XCTAssertEqual(statuses, [.recording, .stopped])
        XCTAssertEqual(trace.events, ["publisher.finish.entered", "publisher.finish.completed", "server.stop"])
        XCTAssertNil(model.activeRecordingID)
    }

    func testCaptureFailureReportsInterruptedAfterArchiveOutcome() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let streaming = makeModel(server: server, storage: storage)
        await streaming.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { streaming.captureChanged($0, terminalStatus: nil) }
        film.onCaptureFinished = { streaming.captureFinished($0, interrupted: $1) }
        await film.start()
        source.interrupt()
        await film.pollHealth()
        XCTAssertNil(film.currentCapture)
        XCTAssertEqual(storage.value?.reports.last?.report.status, .interrupted)
        XCTAssertEqual(storage.value?.reports.last?.report.sequence, 2)
    }

    func testRejectedStopKeepsOwnershipAcrossRelaunch() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        model.captureChanged(nil)
        await server.setRejectStop()
        await model.stopStreaming()
        XCTAssertEqual(storage.value?.stopRecordingIDs, ["recording-1"])
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        await relaunched.pollControl()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertTrue(storage.value?.stopRecordingIDs?.isEmpty == true)
    }

    func testHealthFailureTeardownBlocksRestartUntilOldPublisherStops() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await publisher.failHealth()
        await gate.waitUntilEntered()
        model.pollLocalHealth()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await gate.release()
        await model.stopStreaming()
        XCTAssertTrue(model.canStart)
    }

    func testPublishingClockUnavailableAndEarlyStopRemainOptional() async throws {
        let startupGate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: startupGate)
        await publisher.setTransportClock(testTransportClock())
        let model = makeModel(server: CaptureTestServer(), publisher: publisher)
        await model.restore(); model.captureChanged(captureContext())
        XCTAssertNil(model.publishingClockObservation)
        let starting = Task { await model.startStreaming() }
        await startupGate.waitUntilEntered()
        model.pollLocalHealth()
        XCTAssertNil(model.publishingClockObservation)
        model.captureChanged(nil)
        await startupGate.release(); await starting.value; await model.stopStreaming()
        XCTAssertNil(model.publishingClockObservation)
        XCTAssertEqual(model.videoObservation?.isClosed, true)

        let unavailable = makeModel(server: CaptureTestServer())
        await unavailable.restore(); unavailable.captureChanged(captureContext()); await unavailable.startStreaming()
        unavailable.pollLocalHealth()
        XCTAssertNil(unavailable.publishingClockObservation)
        XCTAssertEqual(unavailable.localState, .publishing)
        await unavailable.stopStreaming()
        XCTAssertNil(unavailable.publishingClockObservation)
    }

    func testPublishingClockBindsExactScopeClosesAtDetachAndExportsAfterDrain() async throws {
        let stopGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: stopGate)
        let descriptor = testTransportClock()
        await publisher.setTransportClock(descriptor)
        let model = makeModel(server: CaptureTestServer(), publisher: publisher)
        model.workerReportAgeProofsEnabled = true
        var exported: PublishingClockObservation?
        model.videoObservationFixtureWriter = { snapshot, _, _, _, clock, _ in
            XCTAssertEqual(clock?.scope, snapshot.scope)
            XCTAssertEqual(clock?.isClosed, true)
            XCTAssertTrue(snapshot.isClosed)
            exported = clock
        }
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await waitForClock(model)
        let live = try XCTUnwrap(model.publishingClockObservation)
        XCTAssertEqual(live.scope, model.videoObservation?.scope)
        XCTAssertEqual(live.transportClock, descriptor)
        XCTAssertFalse(live.isClosed)
        let stopping = Task { await model.stopStreaming() }
        await stopGate.waitUntilEntered()
        XCTAssertEqual(model.publishingClockObservation?.scope, live.scope)
        XCTAssertEqual(model.publishingClockObservation?.transportClock, descriptor)
        XCTAssertEqual(model.publishingClockObservation?.isClosed, true)
        XCTAssertEqual(model.videoObservation?.isClosed, false)
        await publisher.setTransportClock(testTransportClock(generation: 2))
        await stopGate.release(); await stopping.value
        XCTAssertEqual(exported, model.publishingClockObservation)
        XCTAssertEqual(exported?.transportClock, descriptor)
        model.pollLocalHealth()
        XCTAssertEqual(model.publishingClockObservation, exported)
    }

    func testPublishingClockReplacementClearsHistoryAndCannotBorrowOldDescriptor() async throws {
        let first = CaptureTestPublisher(), second = CaptureTestPublisher()
        await first.setTransportClock(testTransportClock())
        var count = 0
        let model = makeModel(server: CaptureTestServer(), publisherFactory: { _, _ in
            count += 1; return count == 1 ? first : second
        })
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await waitForClock(model)
        let previous = try XCTUnwrap(model.publishingClockObservation)
        await model.stopStreaming()
        await model.startStreaming()
        model.pollLocalHealth()
        XCTAssertNil(model.publishingClockObservation)
        XCTAssertNotEqual(model.videoObservation?.scope.publishingAttemptID, previous.scope.publishingAttemptID)
        await first.setTransportClock(testTransportClock(generation: 3))
        await second.setTransportClock(testTransportClock(generation: 2))
        await waitForClock(model)
        XCTAssertEqual(model.publishingClockObservation?.scope, model.videoObservation?.scope)
        XCTAssertEqual(model.publishingClockObservation?.transportClock.publishingGeneration, 2)
        XCTAssertEqual(model.publishingClockObservation?.isClosed, false)
        await model.stopStreaming()
    }

    func testPublishingClockContradictionClearsDiagnosticWithoutStoppingPublication() async throws {
        let publisher = CaptureTestPublisher()
        await publisher.setTransportClock(testTransportClock())
        let model = makeModel(server: CaptureTestServer(), publisher: publisher)
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await waitForClock(model)
        XCTAssertNotNil(model.publishingClockObservation)
        await publisher.setTransportClock(testTransportClock(generation: 2))
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            await Task.yield(); model.pollLocalHealth()
        } while model.publishingClockObservation != nil && ContinuousClock.now < deadline
        XCTAssertNil(model.publishingClockObservation)
        XCTAssertEqual(model.localState, .publishing)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertFalse(model.needsStorageRetry)
        await model.stopStreaming()
        XCTAssertNil(model.publishingClockObservation)
    }

    private func waitForClock(_ model: CaptureStreamingModel) async {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            await Task.yield(); model.pollLocalHealth()
        } while model.publishingClockObservation == nil && ContinuousClock.now < deadline
    }

    private func testTransportClock(generation: UInt64 = .max) -> PublishingTransportClock {
        PublishingTransportClock(sourceOrigin: CMTime(value: 9_007_199_254_740_993, timescale: 60), publishingGeneration: generation)!
    }

    func testCaptureCallbacksAreObservedDuringPublisherStartupBeforeReadiness() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: gate)
        var owners: [VideoFrameObservationOwner] = []
        let model = makeModel(server: server, publisherFactory: { _, owner in
            owners.append(try XCTUnwrap(owner)); return publisher
        })
        await model.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { model.captureChanged($0) }
        await film.start()
        let context = try XCTUnwrap(film.currentCapture)
        source.send(try streamingVideo(0)) // Before publish access: outside the measured interval.
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        let owner = try XCTUnwrap(owners.first)
        source.send(try streamingVideo(1))
        source.send(try streamingVideo(2))
        model.pollLocalHealth()
        let snapshot = try XCTUnwrap(model.videoObservation)
        XCTAssertEqual(snapshot.scope.recordingID, context.id)
        XCTAssertEqual(snapshot.scope.matchID, "game-1")
        XCTAssertEqual(snapshot.scope.broadcastGeneration, 1)
        XCTAssertEqual(snapshot.scope.appliedProfileRevision, 1)
        XCTAssertEqual(snapshot.scope, owner.snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.scope, snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.monotonicAnchor, snapshot.monotonicAnchor)
        XCTAssertEqual(model.ingressObservation?.phase, .startup)
        XCTAssertTrue(model.ingressObservation?.totalDispositions.isEmpty == true)
        XCTAssertEqual(snapshot.current.captureVideo.callbackCount, 2)
        XCTAssertEqual(snapshot.current.encodedVideo.callbackCount, 0)
        XCTAssertEqual(snapshot.current.captureVideo.firstSourcePTS, CMTime(value: 1, timescale: 30))
        XCTAssertFalse(snapshot.isClosed)
        XCTAssertEqual(model.localState, .starting)
        let appends = await publisher.appendCount
        XCTAssertEqual(appends, 0)
        XCTAssertEqual(model.sentSamples, 0)
        await gate.release()
        await starting.value
        XCTAssertEqual(model.localState, .publishing)
        source.send(try streamingVideo(3))
        await publisher.waitForAppends(1)
        model.pollLocalHealth()
        XCTAssertEqual(model.videoObservation?.current.captureVideo.callbackCount, 3)
        XCTAssertEqual(model.ingressObservation?.phase, .admitting)
        XCTAssertEqual(model.ingressObservation?.totalDispositions[.admitted]?[.video]?.count, 1)
        XCTAssertEqual(model.ingressObservation?.totalDispositions[.dequeued]?[.video]?.count, 1)
        XCTAssertEqual(model.ingressObservation?.totalDispositions[.admitted]?[.video]?.firstSourcePTS, CMTime(value: 3, timescale: 30))
        await model.stopStreaming()
        XCTAssertEqual(model.ingressObservation?.isClosed, true)
        XCTAssertEqual(film.state, .recording)
        await film.stop()
        XCTAssertEqual(film.recordings.first?.status, .completed)
    }

    func testCaptureStopDuringStartupDetachesImmediatelyAndClosesOnlyAfterJoinedStop() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let startupGate = FilmTestGate(), stopGate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: startupGate, stopGate: stopGate)
        var capturedOwner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisherFactory: { _, owner in capturedOwner = owner; return publisher })
        await model.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { model.captureChanged($0) }
        await film.start()
        let starting = Task { await model.startStreaming() }
        await startupGate.waitUntilEntered()
        let owner = try XCTUnwrap(capturedOwner)
        source.send(try streamingVideo(1))
        // The same synchronous callback FilmModel uses must detach before archive shutdown.
        model.captureChanged(nil)
        source.send(try streamingVideo(2))
        XCTAssertEqual(owner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertFalse(owner.snapshot.isClosed)
        await stopGate.waitUntilEntered()
        owner.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30))
        await startupGate.release()
        XCTAssertFalse(owner.snapshot.isClosed)
        await stopGate.release()
        await starting.value
        await model.stopStreaming() // Joins the teardown even after the action completed.
        XCTAssertEqual(model.localState, .idle)
        XCTAssertNil(model.activeRecordingID)
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        XCTAssertEqual(model.videoObservation?.current.captureVideo.callbackCount, 1)
        XCTAssertEqual(model.videoObservation?.current.encodedVideo.callbackCount, 1)
        let ready = await publisher.isPublishing
        XCTAssertFalse(ready)
        XCTAssertFalse(owner.observe(.encodedVideo, sourcePTS: CMTime(value: 2, timescale: 30)))
        await film.stop()
        XCTAssertEqual(film.recordings.first?.status, .completed)
    }

    func testGatedEncoderStopKeepsOldOwnerOpenAndRestartUsesFreshScope() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let first = CaptureTestPublisher(stopGate: gate), second = CaptureTestPublisher()
        var owners: [VideoFrameObservationOwner] = []
        let model = makeModel(server: server, publisherFactory: { _, owner in
            owners.append(try XCTUnwrap(owner)); return owners.count == 1 ? first : second
        })
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let old = try XCTUnwrap(owners.first)
        XCTAssertEqual(model.ingressObservation?.scope, old.snapshot.scope)
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        let closedIngress = model.ingressObservation
        XCTAssertEqual(closedIngress?.isClosed, true, "Ingress closes before the encoder drains")
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        XCTAssertEqual(owners.count, 1)
        XCTAssertFalse(old.snapshot.isClosed)
        XCTAssertTrue(old.observe(.encodedVideo, sourcePTS: .zero))
        await gate.release()
        await stopping.value
        let final = try XCTUnwrap(model.videoObservation)
        XCTAssertTrue(final.isClosed)
        XCTAssertEqual(model.ingressObservation?.current.monotonicEnd, closedIngress?.current.monotonicEnd)
        XCTAssertEqual(final.scope, old.snapshot.scope)
        XCTAssertEqual(final.current.encodedVideo.callbackCount, 1)
        XCTAssertFalse(old.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30)))
        XCTAssertTrue(model.canStart)
        await model.startStreaming()
        XCTAssertEqual(owners.count, 2)
        let fresh = owners[1]
        XCTAssertFalse(fresh === old)
        XCTAssertNotEqual(fresh.snapshot.scope.publishingAttemptID, final.scope.publishingAttemptID)
        XCTAssertGreaterThan(fresh.snapshot.scope.broadcastGeneration, final.scope.broadcastGeneration)
        XCTAssertEqual(model.videoObservation?.current.encodedVideo.callbackCount, 0)
        XCTAssertFalse(old.observe(.encodedVideo, sourcePTS: CMTime(value: 2, timescale: 30)))
        old.close()
        model.pollLocalHealth()
        XCTAssertEqual(model.videoObservation?.scope, fresh.snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.scope, fresh.snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.isClosed, false)
        XCTAssertTrue(model.ingressObservation?.totalDispositions.isEmpty == true)
        XCTAssertEqual(model.videoObservation?.current.encodedVideo.callbackCount, 0)
        XCTAssertEqual(model.videoObservation?.isClosed, false)
        await model.stopStreaming()
        XCTAssertTrue(fresh.snapshot.isClosed)
    }

    func testClosedCaptureTapRejectsStartupAndStillClosesCreatedOwner() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink)
        await film.start()
        let closedContext = try XCTUnwrap(film.currentCapture)
        await film.stop()
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        var owner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisherFactory: { _, observations in owner = observations; return publisher })
        await model.restore()
        model.captureChanged(closedContext)
        await model.startStreaming()
        await model.stopStreaming()
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        XCTAssertEqual(owner?.snapshot.isClosed, true)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 0)
        let stopped = await publisher.terminated
        XCTAssertTrue(stopped)
    }

    func testThrowingPublisherFactoryClosesOrphanedOwner() async throws {
        let server = CaptureTestServer()
        var owner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisherFactory: { _, observations in
            owner = observations; throw URLError(.cannotConnectToHost)
        })
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertFalse(model.needsStorageRetry)
        XCTAssertEqual(owner?.snapshot.isClosed, true)
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        XCTAssertEqual(model.videoObservation?.scope, owner?.snapshot.scope)
        await model.stopStreaming()
    }

    func testUnavailableObservationDoesNotFailPublisherArchiveOrStorage() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        await publisher.setTransportClock(testTransportClock())
        var receivedNil = false
        let model = makeModel(server: server, publisherFactory: { _, owner in
            receivedNil = owner == nil; return publisher
        }, observationFactory: { _ in throw VideoFrameObservationError.invalidConfiguration })
        await model.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { model.captureChanged($0) }
        await film.start()
        await model.startStreaming()
        XCTAssertTrue(receivedNil)
        XCTAssertEqual(model.localState, .publishing)
        // A second read proves the first available descriptor returned to the
        // session cache, even though this attempt has no observation owner.
        await publisher.waitForTransportClockReads(2)
        source.send(try streamingVideo(1))
        await publisher.waitForAppends(1)
        model.pollLocalHealth()
        XCTAssertNil(model.videoObservation)
        XCTAssertFalse(model.needsStorageRetry)
        XCTAssertNil(model.ingressObservation)
        XCTAssertNil(model.publishingClockObservation)
        XCTAssertEqual(model.localState, .publishing)
        await model.stopStreaming()
        XCTAssertNil(model.publishingClockObservation)
        XCTAssertNil(model.videoObservation)
        XCTAssertEqual(film.state, .recording)
        await film.stop()
        XCTAssertEqual(film.recordings.first?.status, .completed)
    }

    func testAttemptFailureBeforePublishAccessClearsPreviousDiagnostics() async throws {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        await publisher.setTransportClock(testTransportClock())
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await waitForClock(model)
        XCTAssertNotNil(model.publishingClockObservation)
        await model.stopStreaming()
        XCTAssertEqual(model.publishingClockObservation?.isClosed, true)
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        await server.setOffline(true)
        await model.startStreaming()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNil(model.videoObservation)
        XCTAssertNil(model.ingressObservation)
        XCTAssertNil(model.publishingClockObservation)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testPollRecordsActualHelperReturnAndClearsProofOnLatestUnusableOrExpiry() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        model.workerReportAgeProofsEnabled = true
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        let scope = try XCTUnwrap(model.videoObservation?.scope)
        for invalid in ["nil", "invalid", "expired"] {
            await server.setStatusOverride(workerAgeResponse())
            await model.pollControl()
            let proof = try XCTUnwrap(model.workerReportAgeProofHistory.proofs.first)
            XCTAssertEqual(proof.recordingID, "recording-1")
            XCTAssertEqual(proof.publishingAttemptID, scope.publishingAttemptID.uuidString)
            XCTAssertEqual(proof.gameId, "game-1")
            XCTAssertEqual(proof.generation, 1)
            XCTAssertEqual(proof.workerId, "worker-1")
            XCTAssertEqual(proof.attempt, 2)
            XCTAssertEqual(proof.completed.sequence, 7)
            XCTAssertEqual(proof.decodedVideoAgeUpperBoundMs, 550)
            XCTAssertNotEqual(proof.requestDuration.attoseconds, "0")
            if invalid == "expired" { model.pollLocalHealth(at: ContinuousClock.now + .seconds(5)) }
            else {
                var latest = workerAgeResponse(bound: invalid == "nil" ? nil : 550)
                if invalid == "invalid" { latest.status.observation?.decodedVideo?.invalidReason = .numeric }
                await server.setStatusOverride(latest); await model.pollControl()
            }
            XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        }
        await model.stopStreaming()
    }

    func testProofRecordingRequiresFlagAndActiveAttemptAndClearsAcrossStopRestartAndRemoteMismatch() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, publisherFactory: { _, _ in CaptureTestPublisher() })
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        model.workerReportAgeProofsEnabled = true
        await model.pollControl()
        let old = try XCTUnwrap(model.workerReportAgeProofHistory.proofs.first)
        var next = workerAgeResponse(); next.status.observation?.decodedVideo?.completed?.sequence = 8
        await server.setStatusOverride(next); await model.pollControl()
        XCTAssertEqual(model.workerReportAgeProofHistory.proofs.map { $0.completed.sequence }, [7, 8])
        var mismatch = workerAgeResponse(); mismatch.status.workerId = "other"
        await server.setStatusOverride(mismatch); await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        XCTAssertEqual(model.workerReportAgeProofHistory.proofs.count, 1)
        await model.stopStreaming()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.startStreaming()
        var new = workerAgeResponse(); new.status.generation = 3; new.status.observation?.generation = 3
        await server.setStatusOverride(new); await model.pollControl()
        let restarted = try XCTUnwrap(model.workerReportAgeProofHistory.proofs.first)
        XCTAssertNotEqual(old.publishingAttemptID, restarted.publishingAttemptID)
        XCTAssertEqual(restarted.generation, 3)
        model.captureChanged(nil)
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.stopStreaming()
    }

    func testRecordingScopeChangeImmediatelyClearsProofAndCannotPollOldPublisherIntoNewRecording() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        model.workerReportAgeProofsEnabled = true
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        XCTAssertEqual(model.workerReportAgeProofHistory.proofs.count, 1)
        model.captureChanged(CurrentCapture(id: "recording-2", startedAt: "2026-09-14T00:00:01Z", tap: PublishingTap()))
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.stopStreaming()
    }

    func testStreamAndCaptureStopExportImmutableSnapshotBeforeHistoryClear() async throws {
        for stopCapture in [false, true] {
            let server = CaptureTestServer()
            let model = makeModel(server: server)
            model.workerReportAgeProofsEnabled = true
            var exported: [WorkerReportAgeProof]?
            var closed: VideoFrameObservationSnapshot?
            model.videoObservationFixtureWriter = { snapshot, detached, proofs, ingress, clock, _ in
                XCTAssertTrue(snapshot.isClosed)
                XCTAssertGreaterThanOrEqual(detached, snapshot.monotonicAnchor)
                XCTAssertEqual(ingress?.scope, snapshot.scope)
                XCTAssertEqual(ingress?.isClosed, true)
                XCTAssertEqual(ingress?.phase, .closed)
                XCTAssertEqual(ingress?.currentItems, 0)
                XCTAssertEqual(ingress?.currentBytes, 0)
                XCTAssertGreaterThanOrEqual(ingress?.current.monotonicEnd ?? 0, detached)
                XCTAssertLessThanOrEqual(ingress?.current.monotonicEnd ?? .infinity, snapshot.current.monotonicEnd)
                exported = proofs; closed = snapshot
            }
            await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
            await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
            let beforeStop = model.workerReportAgeProofHistory.proofs
            XCTAssertEqual(beforeStop.count, 1)
            if stopCapture { model.captureChanged(nil) }
            await model.stopStreaming()
            XCTAssertEqual(exported, beforeStop)
            XCTAssertEqual(exported?.first?.publishingAttemptID, closed?.scope.publishingAttemptID.uuidString)
            XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        }
    }

    func testFixtureExportIsJoinedBeforePublishingCanRestart() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, publisherFactory: { _, _ in CaptureTestPublisher() })
        model.workerReportAgeProofsEnabled = true
        let gate = FilmTestGate()
        var exported: [WorkerReportAgeProof] = []
        model.videoObservationFixtureWriter = { snapshot, detached, proofs, ingress, clock, _ in
            XCTAssertEqual(ingress?.scope, snapshot.scope)
            XCTAssertEqual(ingress?.isClosed, true)
            XCTAssertGreaterThanOrEqual(ingress?.current.monotonicEnd ?? 0, detached)
            XCTAssertLessThanOrEqual(ingress?.current.monotonicEnd ?? .infinity, snapshot.current.monotonicEnd)
            exported = proofs
            await gate.enter()
        }
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        let beforeStop = model.workerReportAgeProofHistory.proofs
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        XCTAssertEqual(exported, beforeStop)
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        XCTAssertEqual(model.videoObservation?.scope.publishingAttemptID.uuidString, beforeStop.first?.publishingAttemptID)
        await gate.release(); await stopping.value
        XCTAssertTrue(model.canStart)
        model.videoObservationFixtureWriter = nil
        await model.startStreaming()
        XCTAssertNotEqual(model.videoObservation?.scope.publishingAttemptID.uuidString, beforeStop.first?.publishingAttemptID)
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        XCTAssertEqual(exported, beforeStop)
        await model.stopStreaming()
    }

    func testDeliveryConsumerUsesCursorAndClearsOnOmissionExpiryAndDetach() async throws {
        let server = CaptureTestServer(), publisher = CaptureTestPublisher()
        var owner: VideoFrameObservationOwner?, driver: PublishingQualityDriver?, auditData: Data?
        await publisher.setTransportClock(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        let model = makeModel(server: server, publisher: publisher, observationFactory: { scope in
            let value = try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 8); owner = value; return value
        }, qualityFactory: { session, attempt in
            let quality = try PublishingQualitySession(session: session,
                profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
                attemptID: attempt, initial: .init(profileID: "hd", videoBitrate: 6_000_000))
            let created = PublishingQualityDriver(owner: quality, workerLimits: nil, transportLimits: nil)
            driver = created; return created
        })
        model.cadenceReportFixtureWriter = { auditData = $0 }
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await publisher.waitForTransportClockReads(1)
        let observed = try XCTUnwrap(owner)
        var response = workerAgeResponse()
        response.status.workerEpoch = "22222222-2222-4222-8222-222222222222"
        response.status.publication = .init(readerId:"33333333-3333-4333-8333-333333333333",
            publisherId:"44444444-4444-4444-8444-444444444444", publishingAttemptId:observed.snapshot.scope.publishingAttemptID.uuidString.lowercased(),
            clock:.init(convention:"mpegts-ingress-origin-90k-v1",originPTS:"10919"))
        response.status.observation?.decodedVideo?.clock = "mpegts-pts-90k-v1"
        response.status.decoderDeliveryAgeUpperBoundMs = 50
        func packet(_ sampledAt: Int, delta: Bool = false) throws -> DecoderDeliveryPacket {
            try JSONDecoder().decode(DecoderDeliveryPacket.self,from:Data("""
            {"formatVersion":1,"scopeID":"11111111-1111-4111-8111-111111111111","sampledAtMs":\(sampledAt),"coverageAtMs":0,"afterOrdinal":\(delta ? 1 : 0),"lastOrdinal":1,"arrivals":\(delta ? "[]" : "[[0,1]]"),"invalidReason":null,"ended":false}
            """.utf8))
        }
        response.status.observation?.decoderDelivery = try packet(10)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertEqual(model.workerDecoderDeliveryFreshness?.snapshot.lastOrdinal,1)
        XCTAssertEqual(driver?.deliveryInputProvider?()?.delivery.receiptID, model.workerDecoderDeliveryFreshness?.receiptID)
        let firstInput = try XCTUnwrap(driver?.deliveryInputProvider?())
        let firstAuthority = try XCTUnwrap(firstInput.authority)
        XCTAssertTrue(firstAuthority.permits(firstInput.delivery))
        response.status.observation?.decoderDelivery = try packet(20,delta:true)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertEqual(model.workerDecoderDeliveryFreshness?.sampledAtMs,20)
        XCTAssertTrue(firstAuthority === driver?.deliveryInputProvider?()?.authority)
        let queries = await server.deliveryQueries
        XCTAssertTrue(queries.last?.contains("deliveryAfter=1") == true)
        response.status.observation?.decoderDelivery = nil
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNil(model.workerDecoderDeliveryFreshness); XCTAssertEqual(model.localState,.publishing)
        XCTAssertNil(driver?.deliveryInputProvider?())
        XCTAssertFalse(firstAuthority.permits(firstInput.delivery))
        response.status.observation?.decoderDelivery = try packet(30)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerDecoderDeliveryFreshness)
        let expiring = try XCTUnwrap(driver?.deliveryInputProvider?())
        model.pollLocalHealth(at:.now + .seconds(6)); XCTAssertNil(model.workerDecoderDeliveryFreshness)
        XCTAssertFalse(try XCTUnwrap(expiring.authority).permits(expiring.delivery))
        response.status.observation?.decoderDelivery = try packet(40)
        await server.setStatusOverride(response); await model.pollControl()
        XCTAssertNotNil(model.workerDecoderDeliveryFreshness)
        let receipt = try XCTUnwrap(model.workerDecoderDeliveryFreshness?.receiptID.uuidString.lowercased())
        XCTAssertEqual(driver?.deliveryInputProvider?()?.delivery.receiptID.uuidString.lowercased(), receipt)
        let stoppingInput = try XCTUnwrap(driver?.deliveryInputProvider?())
        await model.stopStreaming(); XCTAssertNil(model.workerDecoderDeliveryFreshness)
        XCTAssertFalse(try XCTUnwrap(stoppingInput.authority).permits(stoppingInput.delivery))
        XCTAssertNil(driver?.deliveryInputProvider)
        let audit = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(auditData)) as? [String: Any])
        let rows = try XCTUnwrap(audit["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { ($0["deliveryReceiptID"] as? String) == receipt })
    }

    private func workerAgeResponse(bound: Double? = 550) -> WorkerMediaStatusResponse {
        let window = DecodedVideoWindow(sequence: 7, durationMs: 5000, ageMs: 250, firstPTS: 0, lastPTS: 447000,
                                       freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true)
        let observation = WorkerObservation(gameId: "game-1", generation: 1, state: .producingOutput,
            reason: nil, attempt: 2, frame: 150, outTimeUs: 1000, scoreRevision: 1,
            decodedVideo: .init(completed: window, invalidReason: nil, ended: false))
        return WorkerMediaStatusResponse(status: .init(gameId: "game-1", generation: 1, workerId: "worker-1",
            state: .producingOutput, observation: observation, observedAt: "2040-01-01T00:00:00.000Z",
            expiresAt: "2040-01-01T00:00:05.000Z", decodedVideoAgeUpperBoundMs: bound), serverTime: "2040-01-01T00:00:00.000Z")
    }

    private func makeModel(server: CaptureTestServer, saved: SavedCaptureSetup? = captureSetup(),
                           storage: CaptureMemoryStorage? = nil,
                           publisher: CaptureTestPublisher = CaptureTestPublisher(),
                           publisherFactory: ((URL, VideoFrameObservationOwner?) throws -> any MediaPublisher)? = nil,
                           observationFactory: @escaping (VideoFrameObservationScope) throws -> VideoFrameObservationOwner = { try VideoFrameObservationOwner(scope: $0) },
                           qualityFactory: @escaping @MainActor (PublishingSession, UUID) throws -> PublishingQualityDriver? = { _, _ in nil }) -> CaptureStreamingModel {
        CaptureStreamingModel(storage: storage ?? CaptureMemoryStorage(saved), pendingStore: CaptureMemoryPending(),
                              clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
                              publisherFactory: publisherFactory ?? { _, _ in publisher }, observationFactory: observationFactory, qualityFactory: qualityFactory)
    }
}

func captureContext() -> CurrentCapture { CurrentCapture(id: "recording-1", startedAt: "2026-09-14T00:00:00Z", tap: PublishingTap()) }
func captureSetup() -> SavedCaptureSetup {
    SavedCaptureSetup(endpoint: "http://localhost:18787", installationToken: "test-token", deviceId: "capture-1", workerId: "worker-1", outputId: "output-1",
                      credential: MatchCredential(gameId: "game-1", deviceId: "capture-1", role: .capture, token: "capture-token"), reports: [])
}
final class CaptureMemoryStorage: CaptureSetupStorage {
    var value: SavedCaptureSetup?
    var fails = false
    init(_ value: SavedCaptureSetup?) { self.value = value }
    func load() throws -> SavedCaptureSetup? { if fails { throw URLError(.cannotWriteToFile) }; return value }
    func save(_ value: SavedCaptureSetup) throws { if fails { throw URLError(.cannotWriteToFile) }; self.value = value }
}
final class CaptureMemoryPending: PendingBroadcastStore, @unchecked Sendable {
    var value: PendingBroadcastCommand?
    var fails = false
    func load() throws -> PendingBroadcastCommand? { if fails { throw URLError(.cannotWriteToFile) }; return value }
    func save(_ value: PendingBroadcastCommand?) throws { if fails { throw URLError(.cannotWriteToFile) }; self.value = value }
}
/// A shared synchronous history observes ordering without adding suspension points.
final class CaptureStopOrderTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [String] = []
    var events: [String] { lock.withLock { history } }
    func record(_ event: String) { lock.withLock { history.append(event) } }
}
actor CaptureTestPublisher: MediaPublisher, PublishingProbeObserving {
    var probe: PublishingProbeObservation?
    private var probeGate: FilmTestGate?
    private var renewProbeLeaseOnRead = false
    func setRenewProbeLeaseOnRead(_ value: Bool) { renewProbeLeaseOnRead = value }
    func probeValue() -> PublishingProbeObservation? { probe }
    func setProbe(_ value: PublishingProbeObservation?) { probe = value }
    func setProbeGate(_ value: FilmTestGate?) { probeGate = value }
    func probeObservation() async -> PublishingProbeObservation? {
        if renewProbeLeaseOnRead { probe?.leaseDeadline = ProcessInfo.processInfo.systemUptime + 0.3 }
        let value = probe
        if let probeGate { await probeGate.enter() }
        return value
    }
    func setVideoBitRate(_ value: Int) async throws -> PublishingBitRateChange {
        .init(publishingGeneration: clock?.publishingGeneration ?? 1,
            configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: value)!,
            acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: nil)!
    }
    var isPublishing = false
    var startCount = 0
    var appendCount = 0
    var terminated = false
    private var clock: PublishingTransportClock?
    private var transportClockReads = 0
    func setTransportClock(_ value: PublishingTransportClock?) { clock = value }
    func transportClock() async -> PublishingTransportClock? {
        transportClockReads += 1
        return clock
    }
    func waitForTransportClockReads(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while transportClockReads < count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThanOrEqual(transportClockReads, count)
    }
    let gate: FilmTestGate?
    let stopGate: FilmTestGate?
    let stopOrderTrace: CaptureStopOrderTrace?
    init(gate: FilmTestGate? = nil, stopGate: FilmTestGate? = nil, stopOrderTrace: CaptureStopOrderTrace? = nil) {
        self.gate = gate; self.stopGate = stopGate; self.stopOrderTrace = stopOrderTrace
    }
    func start() async throws {
        startCount += 1
        if let gate { await gate.enter() }
        guard !terminated else { throw CancellationError() }
        isPublishing = true
    }
    func append(_ sample: CapturedMediaSample) async throws { appendCount += 1 }
    func waitForAppends(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while appendCount < count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(appendCount, count)
    }
    func failHealth() { isPublishing = false }
    func stop() async {
        guard !terminated else { return }
        terminated = true; isPublishing = false
        stopOrderTrace?.record("publisher.finish.entered")
        if let stopGate { await stopGate.enter() }
        stopOrderTrace?.record("publisher.finish.completed")
    }
}
actor CaptureTestServer {
    let stopOrderTrace: CaptureStopOrderTrace?
    init(stopOrderTrace: CaptureStopOrderTrace? = nil) { self.stopOrderTrace = stopOrderTrace }
    var snapshotGate: FilmTestGate?
    func setSnapshotGate(_ value: FilmTestGate) { snapshotGate = value }
    var requestCount = 0
    var operations: [String] = []
    var reports: [RecordingReport] = []
    var broadcast = MediaBroadcast(desired: .stopped, generation: 0, selection: nil)
    var receipts: [String: BroadcastOutcome] = [:]
    var offline = false
    var failMedia = false
    func setFailMedia(_ value: Bool) { failMedia = value }
    var publishAttempts: [String?] = []
    var publishFailure: String?
    func setPublishFailure(_ value: String) { publishFailure = value }
    var publishGate: FilmTestGate?
    var statusGate: FilmTestGate?
    var statusFailure = false
    var statusOverride: WorkerMediaStatusResponse?
    private var statusResponseFactory: (@Sendable (Double) -> WorkerMediaStatusResponse)?
    func setStatusResponseFactory(_ value: (@Sendable (Double) -> WorkerMediaStatusResponse)?) { statusResponseFactory = value }
    var deliveryQueries: [String] = []
    func setStatusFailure(_ value: Bool) { statusFailure = value }
    func setStatusOverride(_ value: WorkerMediaStatusResponse?) { statusOverride = value }
    var joinGate: FilmTestGate?
    func setJoinGate(_ value: FilmTestGate) { joinGate = value }
    var dropReply = false
    var failBeforeCommand = false
    var rejectStop = false
    func setRejectStop() { rejectStop = true }
    func setFailBeforeCommand() { failBeforeCommand = true }
    func setDropReply() { dropReply = true }
    func setStatusGate(_ value: FilmTestGate?) { statusGate = value }
    func selectAnotherCapture() { broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: .init(workerId: "worker-1", outputId: "output-1", captureDeviceId: "another-device", recordingId: "other-recording")) }
    func setOffline(_ value: Bool) { offline = value }
    func setPublishGate(_ value: FilmTestGate) { publishGate = value }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        if failMedia && path.hasSuffix("/media") { throw URLError(.notConnectedToInternet) }
        let time = ISO8601DateFormatter().string(from: Date())
        let data: Data
        if path.hasSuffix("/active") {
            data = try JSONEncoder().encode(ActiveMatchResponse(snapshot: matchSnapshot(), serverTime: time))
        } else if path.hasSuffix("/join") {
            if let joinGate { await joinGate.enter() }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            data = try JSONEncoder().encode(MatchSessionResponse(snapshot: matchSnapshot(), credential: .init(gameId: "game-1", deviceId: body["deviceId"]!, role: .capture, token: "capture-token"), serverTime: time))
        } else if path.hasSuffix("/recordings") {
            let report = try JSONDecoder().decode(RecordingReport.self, from: request.httpBody!)
            reports.append(report)
            data = try JSONEncoder().encode(RecordingReportResponse(recording: .init(gameId: "game-1", recordingId: report.recordingId, deviceId: "capture-1", startedAt: report.startedAt, updatedAt: time, status: report.status, sequence: report.sequence), serverTime: time))
        } else if path.hasSuffix("/commands") {
            if failBeforeCommand { failBeforeCommand = false; throw URLError(.networkConnectionLost) }
            let command = try JSONDecoder().decode(BroadcastCommand.self, from: request.httpBody!)
            if case .stop = command.operation, rejectStop {
                rejectStop = false
                let rejected = BroadcastOutcome(commandId: command.commandId, accepted: false, error: "generation_conflict", snapshot: snapshot())
                return (try JSONEncoder().encode(rejected), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            switch command.operation {
            case .start(let selection): broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: selection); operations.append("start")
            case .stop:
                stopOrderTrace?.record("server.stop")
                broadcast = .init(desired: .stopped, generation: broadcast.generation + 1, selection: nil); operations.append("stop")
            }
            let result = BroadcastOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot())
            receipts[command.commandId] = result
            if dropReply { dropReply = false; throw URLError(.networkConnectionLost) }
            data = try JSONEncoder().encode(result)
        } else if path.contains("/commands/") {
            if let receipt = receipts[request.url!.lastPathComponent] { data = try JSONEncoder().encode(receipt) }
            else { return (Data("{\"error\":\"command_not_found\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        } else if path.hasSuffix("/publish") {
            if let publishGate { await publishGate.enter() }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let requestedAttempt = body["publishingAttemptId"] as? String
            publishAttempts.append(requestedAttempt)
            if publishFailure == "network" { throw URLError(.timedOut) }
            let attempt = publishFailure == "stale" ? UUID().uuidString.lowercased() : requestedAttempt
            var response: [String: Any] = ["gameId": "game-1", "recordingId": body["recordingId"]!, "generation": broadcast.generation, "serverTime": time]
            if let attempt, publishFailure != "missing" { response["publishingAttemptId"] = attempt }
            let streamID = attempt.map(testPublishStreamID) ?? "test"
            response["publishUrl"] = "srt://localhost:19000?streamid=\(streamID)" + (publishFailure == "proof" ? "invalid" : "")
            data = try JSONSerialization.data(withJSONObject: response)
        } else if path.hasSuffix("/status") {
            deliveryQueries.append(request.url?.query ?? "")
            let failure = statusFailure
            let response = statusOverride ?? WorkerMediaStatusResponse(status: .init(gameId: "game-1", generation: broadcast.generation, workerId: "worker-1", state: .producingOutput, observation: nil, observedAt: time, expiresAt: time), serverTime: time)
            let responseFactory = statusResponseFactory
            if let statusGate { await statusGate.enter() }
            if failure { throw URLError(.networkConnectionLost) }
            // Existing gated tests retain the response captured before suspension.
            data = try JSONEncoder().encode(responseFactory?(ProcessInfo.processInfo.systemUptime) ?? response)
        } else {
            // Gate one snapshot only so submit's ownership refresh remains independent.
            if let snapshotGate { self.snapshotGate = nil; await snapshotGate.enter() }
            data = try JSONEncoder().encode(MediaSnapshotResponse(snapshot: snapshot(), serverTime: time))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func snapshot() -> MediaSnapshot { .init(gameId: "game-1", recordings: [], broadcast: broadcast) }
}

private func matchSnapshot() throws -> MatchSnapshot {
    let json = ##"{"id":"game-1","createdAt":"2026-09-14T00:00:00Z","revision":0,"teams":{"home":{"name":"Home","shortName":"HOM","color":"#112233"},"away":{"name":"Away","shortName":"AWY","color":"#445566"}},"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":0,"away":0,"set":1,"homeSets":0,"awaySets":0},"completedSets":[],"status":"active","endReason":null,"canUndo":false,"scorer":{"deviceId":"scorer-1","epoch":1},"broadcast":{"desired":"stopped","generation":0}}"##
    return try JSONDecoder().decode(MatchSnapshot.self, from: Data(json.utf8))
}

private func streamingVideo(_ frame: Int64) throws -> CapturedMediaSample {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: frame, timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
}

private func testPublishStreamID(_ attempt: String) -> String {
    "publish:scorebug-0123456789abcdef-0123456789abcdef0123456789abcdef:sbp1=\(attempt)." + String(repeating: "a", count: 64)
}

private final class CaptureProbeOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var permits: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
}

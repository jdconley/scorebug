import CoreMedia
import Foundation
import ScorebugMedia
import XCTest

final class NativeBandwidthProbeFixtureTests: XCTestCase {
    func testProbeObservationCarriesCampaignWithoutNarrowing() async throws {
        let id = UUID()
        let sample = NativeBandwidthProbeSample(id: id, publishingGeneration: 7, bitRate: 500_000,
            startedAt: 10, leaseDeadline: 10.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil,
            reason: nil, stage: 1, campaign: UInt32.max, permitsCurrentOwner: { _, _, _ in true })
        XCTAssertEqual(sample.object["campaign"] as? String, "4294967295")
        let fixture = ProbeFixtureOperations()
        var operations = await fixture.operations()
        // Snapshot closures are fixed values; retain the other fixture operations.
        operations = .init(clock: operations.clock, begin: operations.begin, renew: operations.renew,
            cancel: operations.cancel, snapshot: { sample }, export: operations.export)
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .renew,
            operations: operations, timing: .init(delay: .zero))
        let observed = await publisher.probeObservation()
        var observation = try XCTUnwrap(observed)
        XCTAssertEqual(observation.campaign, UInt32.max)
        XCTAssertTrue(observation.isActive(at: 10.1))
        observation.campaign = 0
        XCTAssertFalse(observation.isActive(at: 10.1))
        observation.campaign = 1
        observation.stage = nil
        XCTAssertFalse(observation.isActive(at: 10.1))
    }

    func testFlagsRequireExclusiveFixedProfileAndRejectMalformedValues() throws {
        let valid = ["SCOREBUG_TEST_BANDWIDTH_PROBE": "renew", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "540p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
        XCTAssertEqual(try NativeBandwidthProbePublisher.requested(environment: valid), .renew)
        XCTAssertNil(try NativeBandwidthProbePublisher.requested(environment: [:]))
        for (key, value) in [("SCOREBUG_TEST_BANDWIDTH_PROBE", "1"), ("SCOREBUG_TEST_LIVE_PROFILE", ""),
            ("SCOREBUG_TEST_VIDEO_OBSERVATIONS", ""), ("SCOREBUG_TEST_STREAM_HOLD_SECONDS", "89"),
            ("SCOREBUG_TEST_NATIVE_QUALITY", "1"), ("SCOREBUG_TEST_ADAPTIVE_PROFILES", "1"),
            ("SCOREBUG_TEST_PROFILE_TRANSITIONS", "1"), ("SCOREBUG_TEST_SOURCE_CADENCE_PACING", "1")] {
            var bad = valid; bad[key] = value
            XCTAssertThrowsError(try NativeBandwidthProbePublisher.requested(environment: bad))
        }
    }

    func testRenewedRunIsBoundedAndExportWaitsForStop() async throws {
        let fixture = ProbeFixtureOperations()
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .renew,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3))
        try await publisher.start()
        await publisher.waitForProbe()
        var counts = await fixture.counts()
        XCTAssertEqual(counts.renew, 3)
        XCTAssertEqual(counts.export, 0)
        XCTAssertEqual(counts.cancel, 1)
        await publisher.stop()
        await publisher.stop()
        counts = await fixture.counts()
        XCTAssertEqual(counts.export, 1)
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["isClosed"] as? Bool, true)
        XCTAssertEqual(object["result"] as? String, "completed")
        XCTAssertEqual(object["mode"] as? String, "renew")
        XCTAssertEqual((object["events"] as? [Any])?.count, 5)
    }

    func testExpireModeNeverRenewsAndRetainsTerminalSnapshot() async throws {
        let fixture = ProbeFixtureOperations(expire: true)
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .expire,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3))
        try await publisher.start()
        await publisher.waitForProbe()
        await publisher.stop()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.renew, 0)
        let object = try await fixture.exportedObject()
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual((events.last?["sample"] as? [String: Any])?["reason"] as? String, "leaseExpired")
    }

    func testStopJoinsPendingAdmissionBeforeExportAndNeverRenews() async throws {
        let fixture = ProbeFixtureOperations(gateBegin: true)
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .renew,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3))
        try await publisher.start()
        await fixture.waitUntilEntered()
        await publisher.stop()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.renew, 0)
        XCTAssertEqual(counts.export, 1)
        XCTAssertGreaterThanOrEqual(counts.cancel, 1)
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["result"] as? String, "cancelled")
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual((events.last?["sample"] as? [String: Any])?["reason"] as? String, "cancelled")
    }

    func testMalformedCountersAndClocksCannotBecomeValidEvidence() async throws {
        for fault in [ProbeFixtureOperations.Fault.clock, .counter] {
            let fixture = ProbeFixtureOperations(fault: fault)
            let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .renew,
                operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3))
            try await publisher.start()
            await publisher.waitForProbe()
            await publisher.stop()
            let object = try await fixture.exportedObject()
            XCTAssertEqual(object["invalid"] as? Bool, true)
            XCTAssertEqual(object["result"] as? String, "invalidEvidence")
        }
    }

    func testMaximumEventBudgetAndOversizedSchedule() async throws {
        for limit in [600, 601] {
            let fixture = ProbeFixtureOperations()
            let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .renew,
                operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: limit))
            try await publisher.start()
            await publisher.waitForProbe()
            await publisher.stop()
            let object = try await fixture.exportedObject()
            XCTAssertEqual(object["invalid"] as? Bool, limit == 601)
            XCTAssertEqual((object["events"] as? [Any])?.count, limit == 600 ? 602 : 0)
            let counts = await fixture.counts()
            XCTAssertEqual(counts.renew, limit == 600 ? 600 : 0)
        }
    }

    private func scope() -> VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
    }
}

private actor ProbeFixtureOperations: MediaPublisher {
    private var stopped = false, entered = false
    enum Fault { case clock, counter }
    private let fault: Fault?
    private let expire: Bool, gateBegin: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var sample: NativeBandwidthProbeSample?
    private var renews = 0, cancels = 0, exports: [Data] = []
    init(expire: Bool = false, gateBegin: Bool = false, fault: Fault? = nil) { self.expire = expire; self.gateBegin = gateBegin; self.fault = fault }
    func start() async throws {}
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { !stopped }
    func stop() async { stopped = true; waiter?.resume(); waiter = nil }
    func operations() -> NativeBandwidthProbePublisher.Operations {
        .init(clock: { PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7) },
            begin: { try await self.begin() }, renew: { _, _ in await self.renew() },
            cancel: { _, _ in await self.cancel() }, snapshot: { await self.snapshot() },
            export: { await self.export($0) })
    }
    func begin() async throws -> NativeBandwidthProbeSample {
        entered = true
        if gateBegin { await withCheckedContinuation { waiter = $0 } }
        let now = ProcessInfo.processInfo.systemUptime
        let sample = NativeBandwidthProbeSample(id: UUID(), publishingGeneration: 7, bitRate: 1_000_000,
            startedAt: fault == .clock ? .nan : now, leaseDeadline: now + 0.3, acceptedPayloadBytes: 1316,
            lastAcceptedAt: now, reason: nil)
        self.sample = sample
        return sample
    }
    func renew() -> NativeBandwidthProbeSample {
        renews += 1
        if fault == .counter, let prior = sample {
            sample = .init(id: prior.id, publishingGeneration: prior.publishingGeneration, bitRate: prior.bitRate,
                startedAt: prior.startedAt, leaseDeadline: prior.leaseDeadline, acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil)
        }
        return sample!
    }
    func cancel() { cancels += 1; if sample?.reason == nil { sample?.reason = "cancelled" } }
    func snapshot() -> NativeBandwidthProbeSample? {
        if expire, sample?.reason == nil { sample?.reason = "leaseExpired" }
        return sample
    }
    func export(_ data: Data) { exports.append(data) }
    func counts() -> (renew: Int, cancel: Int, export: Int) { (renews, cancels, exports.count) }
    func exportedObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exports.last)) as? [String: Any])
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
}

extension NativeBandwidthProbeFixtureTests {
    func testCombinedStageRetirementUsesAbsoluteEightSecondDeadline() async throws {
        let clock = ProbeFixtureClock()
        let fixture = StagedProbeFixtureOperations(clock: clock.read, renewed: { clock.advance(4) })
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 240,
                stagePolls: 80, now: clock.read), candidateHeadroom: true)
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.renew, 6, "each absolute eight-second stage permits two four-second renewals")
        XCTAssertEqual(counts.cancel, 3)
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["invalid"] as? Bool, false)
        XCTAssertEqual(object["result"] as? String, "completed")
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        for event in events where event["phase"] as? String == "retired" {
            let sample = try XCTUnwrap(event["sample"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(event["retirementRequestedAt"] as? Double) - XCTUnwrap(sample["startedAt"] as? Double), 8, accuracy: 0.001)
        }
    }
    func testCombinedProbeForwardsPrimaryStartup() async throws {
        let fixture = StagedProbeFixtureOperations()
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3, stagePolls: 1),
            candidateHeadroom: true)
        XCTAssertEqual(publisher.videoStartup, fixture.videoStartup)
        XCTAssertNotNil(publisher.videoStartup)
    }
    func testCombinedScheduleUsesTwelveMbpsFinalStageAndTerminalJoins() async throws {
        let fixture = StagedProbeFixtureOperations()
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3, stagePolls: 1),
            candidateHeadroom: true)
        try await publisher.start(); await publisher.waitForProbe()
        let before = await fixture.counts()
        XCTAssertEqual(before.export, 0)
        await publisher.stop(); await publisher.stop()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.cancel, 3); XCTAssertEqual(counts.export, 1)
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["invalid"] as? Bool, false)
        XCTAssertEqual(object["result"] as? String, "completed")
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let starts = events.filter { ["began", "replaced"].contains($0["phase"] as? String ?? "") }
        XCTAssertEqual(starts.compactMap { ($0["sample"] as? [String: Any])?["bitRate"] as? Int }, [500_000, 2_000_000, 12_000_000])
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: object).count, 256 * 1024)
    }
    func testStagedModeIsExplicitAndRequiresTheSameExclusiveFixtureRoute() throws {
        let valid = ["SCOREBUG_TEST_BANDWIDTH_PROBE": "staged", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "540p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
        XCTAssertEqual(try NativeBandwidthProbePublisher.requested(environment: valid), .staged)
    }

    func testStagedScheduleRetiresEachOwnerAndExportsCumulativeBytes() async throws {
        let fixture = StagedProbeFixtureOperations()
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3, stagePolls: 1))
        try await publisher.start(); await publisher.waitForProbe()
        var counts = await fixture.counts()
        XCTAssertEqual(counts.renew, 3); XCTAssertEqual(counts.replace, 2); XCTAssertEqual(counts.export, 0)
        await publisher.stop(); await publisher.stop()
        counts = await fixture.counts()
        XCTAssertEqual(counts.cancel, 3); XCTAssertEqual(counts.export, 1)
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        XCTAssertEqual(object["invalid"] as? Bool, false)
        XCTAssertEqual(object["result"] as? String, "completed")
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["phase"] as? String },
            ["began", "renewed", "retired", "replaced", "renewed", "retired", "replaced", "renewed", "retired", "final"])
        let samples = try events.map { try XCTUnwrap($0["sample"] as? [String: Any]) }
        XCTAssertEqual(samples.compactMap { $0["stage"] as? Int }, [1,1,1,2,2,2,3,3,3,3])
        XCTAssertEqual(samples.last?["totalAcceptedPayloadBytes"] as? String, "3948")
        XCTAssertEqual(samples.last?["acceptedPayloadBytes"] as? String, "1316")
        XCTAssertEqual(samples.last?["reason"] as? String, "cancelled")
        XCTAssertEqual(Set(samples.compactMap { $0["campaignStartedAt"] as? Double }).count, 1)
        for (index, event) in events.enumerated() where event["phase"] as? String == "retired" {
            let requested = try XCTUnwrap(event["retirementRequestedAt"] as? Double)
            XCTAssertGreaterThanOrEqual(requested, try XCTUnwrap(events[index - 1]["observedAt"] as? Double))
            XCTAssertLessThanOrEqual(requested, try XCTUnwrap(event["observedAt"] as? Double))
        }
    }

    func testStagedScheduleRejectsMutatedTransitionEvidence() async throws {
        for fault in StagedProbeFixtureOperations.Fault.allCases {
            let fixture = StagedProbeFixtureOperations(fault: fault)
            let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
                operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3, stagePolls: 1))
            try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
            let object = try await fixture.exportedObject()
            XCTAssertEqual(object["invalid"] as? Bool, true, "\(fault)")
            XCTAssertEqual(object["result"] as? String, "invalidEvidence", "\(fault)")
        }
    }

    func testStopDuringStagedReplacementJoinsBeforeExport() async throws {
        let fixture = StagedProbeFixtureOperations(gateReplacement: true)
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3, stagePolls: 1))
        try await publisher.start(); await fixture.waitUntilEntered()
        await publisher.stop()
        let counts = await fixture.counts()
        XCTAssertEqual(counts.replace, 1); XCTAssertEqual(counts.renew, 1); XCTAssertEqual(counts.export, 1)
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["result"] as? String, "cancelled")
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual((events.last?["sample"] as? [String: Any])?["reason"] as? String, "cancelled")
    }

    func testStagedMissingFinalSnapshotCannotExportSuccessfulEvidence() async throws {
        let fixture = StagedProbeFixtureOperations(missingFinalSnapshot: true)
        let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
            operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 3, stagePolls: 1))
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        let object = try await fixture.exportedObject()
        XCTAssertEqual(object["invalid"] as? Bool, true)
        XCTAssertEqual(object["result"] as? String, "invalidEvidence")
    }

    func testStagedMaximumScheduleAndEventBudgetAreBounded() async throws {
        for polls in [200, 201] {
            let fixture = StagedProbeFixtureOperations()
            let publisher = NativeBandwidthProbePublisher(publisher: fixture, scope: scope(), mode: .staged,
                operations: await fixture.operations(), timing: .init(delay: .zero, poll: .zero, maximumPolls: 600, stagePolls: polls))
            try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
            let object = try await fixture.exportedObject()
            XCTAssertEqual(object["invalid"] as? Bool, polls == 201)
            XCTAssertEqual((object["events"] as? [Any])?.count, polls == 200 ? 607 : 0)
        }
    }
}

private actor StagedProbeFixtureOperations: MediaPublisher {
    enum Fault: CaseIterable { case stage, campaign, cumulative, localBytes, identity, rate }
    private let fault: Fault?
    private let gateReplacement: Bool, missingFinalSnapshot: Bool
    private let clock: @Sendable () -> Double
    private let renewed: @Sendable () -> Void
    private var stopped = false, entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var sample: NativeBandwidthProbeSample?
    private var renews = 0, replacements = 0, cancels = 0, exports: [Data] = []
    init(fault: Fault? = nil, gateReplacement: Bool = false, missingFinalSnapshot: Bool = false,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, renewed: @escaping @Sendable () -> Void = {}) {
        self.clock = clock; self.renewed = renewed
        self.fault = fault; self.gateReplacement = gateReplacement; self.missingFinalSnapshot = missingFinalSnapshot
    }
    nonisolated let videoStartup = PublishingVideoStartup(profile: .low240, width: PublishingVideoProfile.low240.width,
        height: PublishingVideoProfile.low240.height, publishingGeneration: 7, encoderSessionID: UUID(),
        firstSourcePTS: .zero, submittedAt: 1, completedAt: 1, observedAt: 1)
    func start() async throws {}
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { !stopped }
    func stop() async { stopped = true; waiter?.resume(); waiter = nil }
    func operations() -> NativeBandwidthProbePublisher.Operations {
        .init(clock: { PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7) },
            begin: { throw Failure.unexpected }, renew: { _, _ in await self.renew() },
            cancel: { _, _ in await self.cancel() }, snapshot: { await self.snapshot() },
            export: { await self.export($0) }, beginStaged: { await self.begin() },
            replace: { id, generation, stage, rate in try await self.replace(id, generation, stage, rate) })
    }
    func begin() -> NativeBandwidthProbeSample {
        let now = clock()
        let value = NativeBandwidthProbeSample(id: UUID(), publishingGeneration: 7, bitRate: 500_000,
            startedAt: now, leaseDeadline: now + 0.3, acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil,
            stage: 1, permitsCurrentOwner: { _,_,_ in true }, campaignStartedAt: now, totalAcceptedPayloadBytes: 0)
        sample = value; return value
    }
    func renew() -> NativeBandwidthProbeSample {
        renews += 1; renewed()
        let prior = sample!, now = clock()
        let value = NativeBandwidthProbeSample(id: prior.id, publishingGeneration: 7, bitRate: prior.bitRate,
            startedAt: prior.startedAt, leaseDeadline: now + 0.3, acceptedPayloadBytes: prior.acceptedPayloadBytes + 1316,
            lastAcceptedAt: now, reason: prior.reason, stage: prior.stage, permitsCurrentOwner: prior.permitsCurrentOwner,
            campaignStartedAt: prior.campaignStartedAt, totalAcceptedPayloadBytes: prior.totalAcceptedPayloadBytes! + 1316)
        sample = value; return value
    }
    func snapshot() -> NativeBandwidthProbeSample? { stopped && missingFinalSnapshot ? nil : sample }
    func replace(_ id: UUID, _ generation: UInt64, _ stage: Int, _ rate: Int) async throws -> NativeBandwidthProbeSample {
        replacements += 1
        let prior = sample!
        XCTAssertEqual(prior.reason, "cancelled"); XCTAssertEqual(id, prior.id)
        XCTAssertEqual(generation, 7); XCTAssertEqual(stage, prior.stage)
        if gateReplacement { entered = true; await withCheckedContinuation { waiter = $0 } }
        let now = clock()
        let value = NativeBandwidthProbeSample(id: fault == .identity ? prior.id : UUID(), publishingGeneration: 7,
            bitRate: fault == .rate ? 123 : rate, startedAt: now, leaseDeadline: now + 0.3,
            acceptedPayloadBytes: fault == .localBytes ? 1316 : 0, lastAcceptedAt: fault == .localBytes ? now : nil,
            reason: stopped ? "cancelled" : nil, stage: fault == .stage ? stage : stage + 1,
            permitsCurrentOwner: { _,_,_ in true }, campaignStartedAt: fault == .campaign ? now : prior.campaignStartedAt,
            totalAcceptedPayloadBytes: fault == .cumulative ? 0 : prior.totalAcceptedPayloadBytes)
        sample = value; return value
    }
    func cancel() { cancels += 1; if sample?.reason == nil { sample?.reason = "cancelled" } }
    func export(_ data: Data) { exports.append(data) }
    func counts() -> (renew: Int, replace: Int, cancel: Int, export: Int) { (renews, replacements, cancels, exports.count) }
    func exportedObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exports.last)) as? [String: Any])
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    private enum Failure: Error { case unexpected }
}

private final class ProbeFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = ProcessInfo.processInfo.systemUptime
    func read() -> Double { lock.withLock { now } }
    func advance(_ interval: Double) { lock.withLock { now += interval } }
}

@MainActor
extension NativeBandwidthProbeFixtureTests {
    func testRepeatedRequiresFreshProviderAndInstallsOnlyOnce() async throws {
        let fake = RepeatedProbeOperations()
        let publisher = repeatedPublisher(fake, scope: scope())
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertEqual(fake.begins, 0)
        XCTAssertEqual(try fake.object()["formatVersion"] as? Int, 3)
        XCTAssertEqual(try fake.object()["result"] as? String, "readinessUnavailable")
        let afterStop = await publisher.setMeasurementContextProvider { nil }
        XCTAssertFalse(afterStop)
        let other = repeatedPublisher(RepeatedProbeOperations(), scope: scope())
        let installed = await other.setMeasurementContextProvider { nil }
        let replaced = await other.setMeasurementContextProvider { nil }
        XCTAssertTrue(installed); XCTAssertFalse(replaced)
        await other.stop()
    }

    func testRepeatedTwoCampaignsRequireNewRevisionAndKeepSeparateEvidence() async throws {
        let (f, first, next) = try await repeatedContexts()
        let fake = RepeatedProbeOperations()
        let reads = RepeatedProbeCounter()
        let publisher = repeatedPublisher(fake, scope: first.scope)
        _ = await publisher.setMeasurementContextProvider {
            guard fake.firstCampaignJoined else { return first }
            let count = reads.increment()
            if count == 1 { return nil }
            if count == 2 { return first }
            return next
        }
        try await publisher.start(); await publisher.waitForProbe()
        XCTAssertEqual(fake.begins, 1); XCTAssertEqual(fake.restarts, 1)
        XCTAssertGreaterThanOrEqual(reads.value, 4, "restart must reread readiness after allocation")
        XCTAssertEqual(fake.exports, 0)
        await publisher.stop()
        let object = try fake.object()
        XCTAssertEqual(object["formatVersion"] as? Int, 3)
        XCTAssertEqual(object["isClosed"] as? Bool, true)
        XCTAssertEqual(object["invalid"] as? Bool, false)
        let campaigns = try XCTUnwrap(object["campaigns"] as? [[String: Any]])
        XCTAssertEqual(campaigns.count, 2)
        let starts = try campaigns.map { campaign -> [String: Any] in
            let events = try XCTUnwrap(campaign["events"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(events.count, 607)
            XCTAssertEqual((events.last?["sample"] as? [String: Any])?["reason"] as? String, "cancelled")
            return try XCTUnwrap(events.first?["sample"] as? [String: Any])
        }
        XCTAssertEqual(starts.compactMap { $0["campaign"] as? String }, ["1", "2"])
        XCTAssertEqual(starts.compactMap { $0["stage"] as? Int }, [1, 1])
        XCTAssertEqual(starts.compactMap { $0["totalAcceptedPayloadBytes"] as? String }, ["0", "0"])
        XCTAssertNotEqual(starts[0]["id"] as? String, starts[1]["id"] as? String)
        XCTAssertLessThan(try XCTUnwrap(starts[0]["campaignStartedAt"] as? Double),
                          try XCTUnwrap(starts[1]["campaignStartedAt"] as? Double))
        XCTAssertTrue(fake.restartSawJoinedTerminal)
        await f.owner.stop()
    }

    func testRepeatedNeverRestartsFromTimerOrSameRevision() async throws {
        let f = try await CandidateQualityFixture.make()
        let context = try XCTUnwrap(awaitContext: await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics)))
        let fake = RepeatedProbeOperations()
        let publisher = repeatedPublisher(fake, scope: context.scope)
        _ = await publisher.setMeasurementContextProvider { context }
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertEqual(fake.begins, 1); XCTAssertEqual(fake.restarts, 0)
        XCTAssertEqual((try fake.object()["campaigns"] as? [Any])?.count, 1)
        await f.owner.stop()
    }

    func testRepeatedStopDuringRecoveryPreservesJoinedCampaignStatus() async throws {
        let f = try await CandidateQualityFixture.make()
        let first = try XCTUnwrap(awaitContext: await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics)))
        let fake = RepeatedProbeOperations(), waiting = RepeatedProbeCounter()
        let recoveryGate = RepeatedProbeGate(blocked: true)
        let publisher = repeatedPublisher(fake, scope: first.scope)
        _ = await publisher.setMeasurementContextProvider {
            guard fake.firstCampaignJoined else { return first }
            _ = waiting.increment()
            await recoveryGate.wait()
            return nil
        }
        try await publisher.start()
        await repeatedWait { waiting.value > 0 }
        let stop = Task { await publisher.stop() }
        await repeatedWait { fake.hasStopped }
        recoveryGate.open()
        await stop.value
        let object = try fake.object()
        XCTAssertEqual(object["result"] as? String, "cancelled")
        let campaigns = try XCTUnwrap(object["campaigns"] as? [[String: Any]])
        XCTAssertEqual(campaigns.count, 1)
        XCTAssertEqual(campaigns.first?["status"] as? String, "completed")
        XCTAssertEqual(campaigns.first?["isJoined"] as? Bool, true)
        await f.owner.stop()
    }

    func testRepeatedWaitsPastTemporarilyDifferentRecoveryTarget() async throws {
        let (f, first, next) = try await repeatedContexts()
        let higherFixture = try await CandidateQualityFixture.make(initialProfile: .low360)
        let higher = try XCTUnwrap(awaitContext: await higherFixture.owner.candidateMeasurementContext(
            diagnostics: try XCTUnwrap(higherFixture.sourceDiagnostics)))
        XCTAssertEqual(higher.scope, first.scope)
        XCTAssertEqual(higher.clock, first.clock)
        XCTAssertEqual(higher.readiness.settings.profileID, "540p30")
        let fake = RepeatedProbeOperations(), reads = RepeatedProbeCounter()
        let publisher = repeatedPublisher(fake, scope: first.scope)
        _ = await publisher.setMeasurementContextProvider {
            guard fake.firstCampaignJoined else { return first }
            return reads.increment() == 1 ? higher : next
        }
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertGreaterThanOrEqual(reads.value, 3, "ineligible targets must wait for eligible readiness then revalidate allocation")
        XCTAssertEqual(fake.restarts, 1)
        XCTAssertEqual((try fake.object()["campaigns"] as? [Any])?.count, 2)
        XCTAssertEqual(try fake.object()["invalid"] as? Bool, false)
        await f.owner.stop(); await higherFixture.owner.stop()
    }

    func testRepeatedRejectsChangedTransportClockBeforeRestart() async throws {
        let (f, first, next) = try await repeatedContexts()
        let changed = PublishingQualitySession.CandidateMeasurementContext(readiness: next.readiness,
            applied: next.applied, scope: next.scope,
            clock: try XCTUnwrap(PublishingTransportClock(sourceOrigin: CMTime(value: 1, timescale: 30), publishingGeneration: 7)))
        let fake = RepeatedProbeOperations()
        let publisher = repeatedPublisher(fake, scope: first.scope)
        _ = await publisher.setMeasurementContextProvider { fake.firstCampaignJoined ? changed : first }
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertEqual(fake.restarts, 0)
        XCTAssertTrue(fake.lastOwnerJoined)
        XCTAssertEqual(try fake.object()["invalid"] as? Bool, true)
        await f.owner.stop()
    }

    func testRepeatedProfileCancellationKeepsTerminalEvidenceThenWaitsForRecovery() async throws {
        let (f, first, next) = try await repeatedContexts()
        let fake = RepeatedProbeOperations(terminalOnStageThree: true)
        let publisher = repeatedPublisher(fake, scope: first.scope)
        _ = await publisher.setMeasurementContextProvider { fake.firstCampaignJoined ? next : first }
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertEqual(fake.restarts, 1)
        XCTAssertTrue(fake.restartSawJoinedTerminal)
        let campaigns = try XCTUnwrap(try fake.object()["campaigns"] as? [[String: Any]])
        XCTAssertEqual(campaigns.count, 2)
        XCTAssertEqual(campaigns.first?["status"] as? String, "withdrawn")
        XCTAssertEqual(try fake.object()["invalid"] as? Bool, false)
        await f.owner.stop()
    }

    func testRepeatedRestartRevalidatesContextAndJoinsRejectedAllocation() async throws {
        let (f, first, next) = try await repeatedContexts()
        let fake = RepeatedProbeOperations()
        let publisher = repeatedPublisher(fake, scope: first.scope)
        _ = await publisher.setMeasurementContextProvider {
            if fake.restarts > 0 { return nil }
            return fake.firstCampaignJoined ? next : first
        }
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertEqual(fake.restarts, 1)
        XCTAssertTrue(fake.lastOwnerJoined)
        XCTAssertEqual(fake.cancellations.last, fake.currentID)
        XCTAssertEqual(try fake.object()["invalid"] as? Bool, true)
        await f.owner.stop()
    }

    func testRepeatedStopJoinsLateBeginAndTerminalSnapshotBeforeExport() async throws {
        let f = try await CandidateQualityFixture.make()
        let context = try XCTUnwrap(awaitContext: await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics)))
        let fake = RepeatedProbeOperations(blockBegin: true, blockTerminal: true)
        let publisher = repeatedPublisher(fake, scope: context.scope)
        _ = await publisher.setMeasurementContextProvider { context }
        try await publisher.start()
        await repeatedWait { fake.begins == 1 }
        let finished = RepeatedProbeCounter()
        let stop = Task { await publisher.stop(); _ = finished.increment() }
        await repeatedWait { !fake.cancellations.isEmpty }
        XCTAssertEqual(fake.exports, 0); XCTAssertEqual(finished.value, 0)
        fake.terminalGate.open()
        await stop.value
        XCTAssertEqual(fake.exports, 1); XCTAssertTrue(fake.lastOwnerJoined)
        XCTAssertEqual(try fake.object()["result"] as? String, "cancelled")
        await f.owner.stop()
    }

    func testRepeatedRejectsCampaignMismatchAndJoinsExactOwner() async throws {
        let f = try await CandidateQualityFixture.make()
        let context = try XCTUnwrap(awaitContext: await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics)))
        let fake = RepeatedProbeOperations(mismatchCampaign: true)
        let publisher = repeatedPublisher(fake, scope: context.scope)
        _ = await publisher.setMeasurementContextProvider { context }
        try await publisher.start(); await publisher.waitForProbe(); await publisher.stop()
        XCTAssertEqual(fake.restarts, 0)
        XCTAssertTrue(fake.lastOwnerJoined)
        XCTAssertEqual(try fake.object()["invalid"] as? Bool, true)
        await f.owner.stop()
    }

    private func repeatedPublisher(_ fake: RepeatedProbeOperations, scope: VideoFrameObservationScope) -> NativeBandwidthProbePublisher {
        NativeBandwidthProbePublisher(publisher: fake, scope: scope, mode: .repeated,
            operations: fake.operations, timing: .init(delay: .zero, poll: .zero, maximumPolls: 12, stagePolls: 1,
                now: fake.now), candidateHeadroom: true)
    }
    private func repeatedContexts() async throws -> (CandidateQualityFixture, PublishingQualitySession.CandidateMeasurementContext,
                                                     PublishingQualitySession.CandidateMeasurementContext) {
        let f = try await CandidateQualityFixture.make()
        let first = try XCTUnwrap(awaitContext: await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics)))
        let decision = try await f.owner.evaluateCandidate(f.admission)
        try await f.owner.apply(XCTUnwrap(decision.recommendation))
        f.native.setNow(116)
        try await f.owner.noteUnavailableCadence(diagnostics: try f.diagnostics())
        let reset = try await f.owner.checkTrialDeadline()
        try await f.owner.apply(XCTUnwrap(reset))
        var last: PublishingQualitySession.CandidateMeasurementContext?
        for (start, sequence) in [(117.0, Int64(3)), (122.0, Int64(4))] {
            f.native.setNow(start + 5.1)
            let health = try await f.freshSource(start: start, sequence: sequence)
            _ = try await f.owner.evaluate(source: health.0, diagnostics: health.1,
                workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
                transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
                instant: f.native.instant)
            last = await f.owner.candidateMeasurementContext(diagnostics: health.1)
        }
        let next = try XCTUnwrap(last)
        XCTAssertEqual(first.scope, next.scope)
        XCTAssertGreaterThan(next.applied.revision, first.applied.revision)
        return (f, first, next)
    }
    private func repeatedWait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

private final class RepeatedProbeGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init(blocked: Bool) { (stream, continuation) = AsyncStream.makeStream(); if !blocked { continuation.finish() } }
    func open() { continuation.finish() }
    func wait() async { await Task.detached { for await _ in self.stream {} }.value }
}
private final class RepeatedProbeCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}
private final class RepeatedProbeOperations: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    let beginGate: RepeatedProbeGate, terminalGate: RepeatedProbeGate
    private let mismatchCampaign: Bool, terminalOnStageThree: Bool
    private var time = 115.1, stopped = false, beginCount = 0, restartCount = 0
    private var value: NativeBandwidthProbeSample?, cancelled: [UUID] = [], exported: [Data] = []
    private var joined = Set<UUID>(), firstJoined = false, restartJoined = false
    init(blockBegin: Bool = false, blockTerminal: Bool = false, mismatchCampaign: Bool = false, terminalOnStageThree: Bool = false) {
        beginGate = .init(blocked: blockBegin); terminalGate = .init(blocked: blockTerminal)
        self.mismatchCampaign = mismatchCampaign; self.terminalOnStageThree = terminalOnStageThree
    }
    var hasStopped: Bool { lock.withLock { stopped } }
    var begins: Int { lock.withLock { beginCount } }
    var restarts: Int { lock.withLock { restartCount } }
    var exports: Int { lock.withLock { exported.count } }
    var firstCampaignJoined: Bool { lock.withLock { firstJoined } }
    var restartSawJoinedTerminal: Bool { lock.withLock { restartJoined } }
    var cancellations: [UUID] { lock.withLock { cancelled } }
    var currentID: UUID? { lock.withLock { value?.id } }
    var lastOwnerJoined: Bool { lock.withLock { value.map { joined.contains($0.id) } ?? false } }
    func now() -> Double { lock.withLock { time } }
    func start() async throws {}
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { get async { lock.withLock { !stopped } } }
    func stop() async { lock.withLock { stopped = true }; beginGate.open() }
    var operations: NativeBandwidthProbePublisher.Operations {
        .init(clock: { PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7) },
            begin: { throw Failure.unexpected }, renew: { id, generation in self.renew(id, generation) },
            cancel: { id, generation in self.cancel(id, generation) }, snapshot: { await self.snapshot() },
            export: { data in self.lock.withLock { self.exported.append(data) } },
            replace: { id, generation, stage, rate in self.replace(id, generation, stage, rate) },
            beginRepeatable: { await self.begin() },
            restart: { id, generation, stage, rate in self.restart(id, generation, stage, rate) })
    }
    private func allocation(stage: Int, rate: Int, campaign: UInt32, origin: Double?, total: UInt64) -> NativeBandwidthProbeSample {
        time += 0.01
        return .init(id: UUID(), publishingGeneration: 7, bitRate: rate, startedAt: time, leaseDeadline: time + 0.3,
            acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil, stage: stage, campaign: campaign,
            permitsCurrentOwner: { _,_,_ in true }, campaignStartedAt: origin ?? time, totalAcceptedPayloadBytes: total)
    }
    func begin() async -> NativeBandwidthProbeSample {
        lock.withLock { beginCount += 1 }
        await beginGate.wait()
        return lock.withLock { let sample = allocation(stage: 1, rate: 500_000, campaign: 1, origin: nil, total: 0); value = sample; return sample }
    }
    func renew(_ id: UUID, _ generation: UInt64) -> NativeBandwidthProbeSample {
        lock.withLock {
            let old = value!; XCTAssertEqual(id, old.id); XCTAssertEqual(generation, 7)
            time += 0.01
            let sample = NativeBandwidthProbeSample(id: old.id, publishingGeneration: 7, bitRate: old.bitRate,
                startedAt: old.startedAt, leaseDeadline: time + 0.3, acceptedPayloadBytes: old.acceptedPayloadBytes + 1316,
                lastAcceptedAt: time, reason: terminalOnStageThree && old.stage == 3 ? "cancelled" : nil,
                stage: old.stage, campaign: mismatchCampaign ? 2 : old.campaign,
                permitsCurrentOwner: old.permitsCurrentOwner, campaignStartedAt: old.campaignStartedAt,
                totalAcceptedPayloadBytes: old.totalAcceptedPayloadBytes! + 1316)
            value = sample; return sample
        }
    }
    func cancel(_ id: UUID, _ generation: UInt64) {
        lock.withLock { XCTAssertEqual(id, value?.id); XCTAssertEqual(generation, 7); cancelled.append(id); value?.reason = "cancelled" }
    }
    func snapshot() async -> NativeBandwidthProbeSample? {
        if lock.withLock({ value?.reason != nil }) { await terminalGate.wait() }
        return lock.withLock {
            if let sample = value, sample.reason != nil {
                joined.insert(sample.id)
                if sample.campaign == 1 && sample.stage == 3 { firstJoined = true }
            }
            return value
        }
    }
    func replace(_ id: UUID, _ generation: UInt64, _ stage: Int, _ rate: Int) -> NativeBandwidthProbeSample {
        lock.withLock {
            let old = value!; XCTAssertEqual(id, old.id); XCTAssertEqual(generation, 7); XCTAssertEqual(stage, old.stage)
            XCTAssertTrue(joined.contains(id)); XCTAssertEqual(old.reason, "cancelled")
            let sample = allocation(stage: stage + 1, rate: rate, campaign: old.campaign!, origin: old.campaignStartedAt, total: old.totalAcceptedPayloadBytes!)
            value = sample; return sample
        }
    }
    func restart(_ id: UUID, _ generation: UInt64, _ stage: Int, _ rate: Int) -> NativeBandwidthProbeSample {
        lock.withLock {
            let old = value!; XCTAssertEqual(id, old.id); XCTAssertEqual(generation, 7); XCTAssertEqual(stage, old.stage)
            restartCount += 1; restartJoined = joined.contains(id) && old.reason != nil
            let sample = allocation(stage: 1, rate: rate, campaign: 2, origin: nil, total: 0)
            value = sample; return sample
        }
    }
    func object() throws -> [String: Any] {
        let data = try XCTUnwrap(lock.withLock { exported.last })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private enum Failure: Error { case unexpected }
}

private func XCTUnwrap<T>(awaitContext value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

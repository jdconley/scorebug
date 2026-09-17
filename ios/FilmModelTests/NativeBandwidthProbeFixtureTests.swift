import CoreMedia
import Foundation
import ScorebugMedia
import XCTest

final class NativeBandwidthProbeFixtureTests: XCTestCase {
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

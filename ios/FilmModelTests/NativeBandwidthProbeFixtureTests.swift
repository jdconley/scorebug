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

import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class SRTMediaPublisherTests: XCTestCase {
    func testNativeObservationOwnerCanConfigureAndStopWithoutOpeningTransport() async throws {
        let owner = try VideoFrameObservationOwner(scope: .init(recordingID: "recording", matchID: "match",
            broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1))
        let adapter = SRTPublisher(observations: owner)
        try await adapter.configure()
        await adapter.stop()
        XCTAssertEqual(owner.snapshot.current.encodedVideo.callbackCount, 0)
        XCTAssertFalse(owner.snapshot.isClosed, "The controller owns closure after joined publisher shutdown")
        owner.close()
    }

    func testMediaPublisherAcceptsOptionalOwnerWithoutOpeningTransport() async throws {
        let owner = try VideoFrameObservationOwner(scope: .init(recordingID: "recording", matchID: "match",
            broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1))
        let url = try XCTUnwrap(URL(string: "srt://localhost:19000"))
        for observation in [nil, owner] {
            let publisher = SRTMediaPublisher(url: url, observations: observation)
            let publishing = await publisher.isPublishing
            XCTAssertFalse(publishing)
            await publisher.stop()
            XCTAssertEqual(owner.snapshot.current.encodedVideo.callbackCount, 0)
            XCTAssertFalse(owner.snapshot.isClosed)
        }
        // Existing source callers need no diagnostic argument.
        let legacy = SRTMediaPublisher(url: url)
        await legacy.stop()
        owner.close()
    }

    func testMediaPublisherRetainsItsImmutableOwnerThroughTheNativeStream() async throws {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
            broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1)
        var owner: VideoFrameObservationOwner? = try VideoFrameObservationOwner(scope: scope)
        weak var retainedOwner = owner
        let publisher = SRTMediaPublisher(url: try XCTUnwrap(URL(string: "srt://localhost:19000")), observations: owner)
        owner = nil
        XCTAssertNotNil(retainedOwner, "The immutable SDK observer must strongly retain this exact attempt owner")
        await publisher.stop()
        let snapshot = try XCTUnwrap(retainedOwner?.snapshot)
        XCTAssertEqual(snapshot.scope, scope)
        XCTAssertFalse(snapshot.isClosed, "Only the controller closes after joined shutdown")
        retainedOwner?.close()
        withExtendedLifetime(publisher) {}
    }

    func testBitRateRejectsPreparedAndStoppedWithoutCallingEncoder() async throws {
        let fixture = AdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        for stopped in [false, true] {
            if stopped { await publisher.stop() }
            do { try await publisher.setBitRate(3_000_000); XCTFail("No active publisher") }
            catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .notPublishing) }
        }
        let calls = await fixture.bitRateCalls
        XCTAssertEqual(calls, 0)
    }

    func testCancelledBitRateCallNeverReachesEncoder() async throws {
        let fixture = AdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let update = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await publisher.setBitRate(3_000_000)
        }
        do { try await update.value; XCTFail("Cancelled request cannot apply settings") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .cancelled) }
        let calls = await fixture.bitRateCalls
        XCTAssertEqual(calls, 0)
        await publisher.stop()
    }

    func testOnlyOneBitRateUpdateMayOwnTheEncoderAtATime() async throws {
        let fixture = AdapterFixture(gated: .bitRate)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let first = Task { try await publisher.setBitRate(3_000_000) }
        await fixture.waitUntilEntered()
        do { try await publisher.setBitRate(4_000_000); XCTFail("Overlapping update must be rejected") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .invalidState) }
        await fixture.releaseBitRate()
        try await first.value
        let calls = await fixture.bitRateCalls
        XCTAssertEqual(calls, 1)
        try await publisher.setBitRate(5_000_000)
        await publisher.stop()
    }

    func testCancellationOrStopDuringBitRateWriteCannotReturnSuccess() async throws {
        for stop in [false, true] {
            let fixture = AdapterFixture(gated: .bitRate)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let update = Task { try await publisher.setBitRate(3_000_000) }
            await fixture.waitUntilEntered()
            if stop { await publisher.stop() } else { update.cancel(); await fixture.releaseBitRate() }
            do { try await update.value; XCTFail("Late encoder result must not acknowledge a cancelled operation") }
            catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .cancelled) }
            let alive = await publisher.isPublishing
            XCTAssertFalse(alive, "A cancelled in-flight update cannot leave changed native settings under old caller state")
            await publisher.stop()
        }
    }

    func testBitRateFailureDoesNotExposeNativeErrorDetails() async throws {
        let fixture = AdapterFixture(bitRateFails: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        do { try await publisher.setBitRate(3_000_000); XCTFail("Native error must propagate") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .bitRateUpdateFailed) }
        await publisher.stop()
    }

    func testStopDuringConfigurationCannotStartConnectionLater() async throws {
        let fixture = AdapterFixture(gated: .configure)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        let start = Task { try await publisher.start() }
        await fixture.waitUntilEntered()
        await publisher.stop()
        do { try await start.value; XCTFail("Stopped start must not succeed") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .cancelled) }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.starts, 0)
        XCTAssertEqual(counts.stops, 2)
        let publishing = await publisher.isPublishing
        XCTAssertFalse(publishing)
    }

    func testStopDuringConnectIsTerminalEvenIfConnectionCompletesLate() async throws {
        let fixture = AdapterFixture(gated: .start)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        let start = Task { try await publisher.start() }
        await fixture.waitUntilEntered()
        let stop = Task { await publisher.stop() }
        stop.cancel()
        await stop.value
        do { try await start.value; XCTFail("Stopped start must not succeed") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .cancelled) }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.stops, 2)
        let publishing = await publisher.isPublishing
        XCTAssertFalse(publishing)
        let transportAlive = await fixture.isHealthy()
        XCTAssertFalse(transportAlive, "Late reusable SDK start must be closed before stop returns")
        do { try await publisher.start(); XCTFail("One attempt only") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .invalidState) }
    }

    func testReadinessAndHealthAreObservedAndErrorsDoNotLeakUnderlyingDetails() async throws {
        for fails in [false, true] {
            let fixture = AdapterFixture(fails: fails)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            if fails {
                do { try await publisher.start(); XCTFail("Should fail") }
                catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .startFailed) }
            } else {
                try await publisher.start()
                let ready = await publisher.isPublishing
                XCTAssertTrue(ready)
                await fixture.setHealthy(false)
                let failed = await publisher.isPublishing
                XCTAssertFalse(failed)
            }
            await publisher.stop()
            await publisher.stop()
            let counts = await fixture.counts()
            XCTAssertEqual(counts.stops, 1)
        }
    }
}

private actor AdapterFixture {
    enum Gate { case configure, start, bitRate }
    private let gated: Gate?
    private let fails: Bool
    private let bitRateFails: Bool
    private(set) var bitRateCalls = 0
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var healthy = false
    private var stopped = false
    private var starts = 0
    private var stops = 0
    init(gated: Gate? = nil, fails: Bool = false, bitRateFails: Bool = false) {
        self.gated = gated; self.fails = fails; self.bitRateFails = bitRateFails
    }
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: { try await self.configure() }, start: { await self.start() },
              append: { _ in }, isPublishing: { await self.isHealthy() }, stop: { await self.stop() },
              setBitRate: { _ in try await self.setBitRate() }, metrics: { nil })
    }
    func configure() async throws {
        if fails { throw NSError(domain: "srt://private-secret", code: 1) }
        if gated == .configure { await wait() }
    }
    func start() async {
        starts += 1
        if gated == .start { await wait() }
        healthy = true // Model reusable SDK: a late start can reopen after close.
    }
    func setBitRate() async throws {
        bitRateCalls += 1
        if gated == .bitRate, bitRateCalls == 1 { await wait() }
        if bitRateFails { throw NSError(domain: "private encoder details", code: -1) }
    }
    func releaseBitRate() { continuation?.resume(); continuation = nil }
    func isHealthy() -> Bool { healthy }
    func setHealthy(_ value: Bool) { healthy = value }
    func stop() {
        stops += 1; stopped = true; healthy = false
        continuation?.resume(); continuation = nil
    }
    func counts() -> (starts: Int, stops: Int) { (starts, stops) }
    private func wait() async {
        entered = true
        if stopped { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
}

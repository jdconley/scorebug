import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class SRTProfileChangeTests: XCTestCase {
    func testForwardsValidatedProfileReceipt() async throws {
        let fixture = ProfileAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let receipt = try await publisher.setVideoProfile(.sd540)
        XCTAssertEqual(receipt.profile, .sd540)
        XCTAssertEqual(receipt.width, 960); XCTAssertEqual(receipt.height, 540)
        XCTAssertEqual(receipt.publishingGeneration, 7)
        let calls = await fixture.profileCalls
        XCTAssertEqual(calls, [.sd540])
        await publisher.stop()
    }
    func testProfileAdmissionRejectsInactiveCancelledAndConcurrentMutations() async throws {
        for gate in [ProfileAdapterFixture.Gate.profile, .bitRate] {
            let fixture = ProfileAdapterFixture(gated: gate)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            await fails(.notPublishing) { _ = try await publisher.setVideoProfile(.sd540) }
            try await publisher.start()
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await publisher.setVideoProfile(.sd540)
            }
            await fails(.cancelled) { _ = try await cancelled.value }
            let first = Task {
                if gate == .profile { _ = try await publisher.setVideoProfile(.sd540) }
                else { _ = try await publisher.setVideoBitRate(3_000_000) }
            }
            await fixture.waitForEntry()
            await fails(.invalidState) { _ = try await publisher.setVideoProfile(.hd1080) }
            await fails(.invalidState) { _ = try await publisher.setVideoBitRate(4_000_000) }
            let healthy = await publisher.isPublishing
            XCTAssertTrue(healthy, "Readiness stays responsive during a profile change")
            await fixture.release()
            try await first.value
            await publisher.stop()
            await fails(.notPublishing) { _ = try await publisher.setVideoProfile(.sd540) }
        }
    }
    func testStopAndCancellationJoinLateProfileResultAndCloseAgain() async throws {
        for cancel in [false, true] {
            let fixture = ProfileAdapterFixture(gated: .profile)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let changed = ProfileDone(), stopped = ProfileDone()
            let change = Task {
                defer { changed.set() }
                return try await publisher.setVideoProfile(.sd540)
            }
            await fixture.waitForEntry()
            if cancel { change.cancel() }
            let stop = Task { await publisher.stop(); stopped.set() }
            stop.cancel() // Shutdown itself stays shielded.
            await fixture.waitForStop()
            XCTAssertFalse(stopped.value); XCTAssertFalse(changed.value)
            await fixture.release()
            await stop.value
            await fails(.cancelled) { _ = try await change.value }
            XCTAssertTrue(stopped.value); XCTAssertTrue(changed.value)
            let counts = await fixture.stops, healthy = await fixture.isHealthy()
            XCTAssertEqual(counts, 2); XCTAssertFalse(healthy, "Late reusable native work must be closed before stop returns")
        }
    }
    func testBadProfileResultsRetireAttemptWithoutExposingNativeDetails() async throws {
        for failure in [ProfileAdapterFixture.Defect.nativeError, .wrongProfile, .unhealthy] {
            let fixture = ProfileAdapterFixture(defect: failure)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            await fails(.profileUpdateFailed) { _ = try await publisher.setVideoProfile(.sd540) }
            let healthy = await publisher.isPublishing
            XCTAssertFalse(healthy)
            await publisher.stop()
        }
    }
    func testNativeAdapterRejectsProfileBeforeStartAndAfterJoinedStop() async throws {
        let adapter = SRTPublisher()
        try await adapter.configure()
        do { _ = try await adapter.setVideoProfile(.sd540); XCTFail("Not publishing") }
        catch { XCTAssertTrue(error is SRTPublisher.PublisherError) }
        await adapter.stop()
        do { _ = try await adapter.setVideoProfile(.sd540); XCTFail("Stopped") }
        catch { XCTAssertTrue(error is SRTPublisher.PublisherError) }
    }
    func testStoppedNativeAdapterRejectsStartupBeforeDispatch() async throws {
        let adapter = SRTPublisher()
        await adapter.stop()
        // A non-SRT URL proves admission rejection happens before native URL parsing.
        do { try await adapter.start(URL(string: "https://invalid.example")!); XCTFail("Stopped startup") }
        catch { XCTAssertTrue(error is SRTPublisher.PublisherError, "Must reject before native startup, not at its URL parser") }
        do { try await adapter.configure(); XCTFail("Stopped configuration") }
        catch { XCTAssertTrue(error is SRTPublisher.PublisherError) }
        await adapter.stop()
        let healthy = await adapter.isPublishing()
        XCTAssertFalse(healthy)
    }
    private func fails(_ expected: SRTMediaPublisher.PublisherError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? SRTMediaPublisher.PublisherError, expected) }
    }

}

private actor ProfileAdapterFixture {
    enum Gate { case profile, bitRate }
    enum Defect { case nativeError, wrongProfile, unhealthy }
    private let gated: Gate?
    private let defect: Defect?
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private(set) var stops = 0
    private var healthy = false
    init(gated: Gate? = nil, defect: Defect? = nil) { self.gated = gated; self.defect = defect }
    private(set) var profileCalls: [PublishingVideoProfile] = []
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: {}, start: { await self.start() }, append: { _ in },
              isPublishing: { await self.isHealthy() }, stop: { await self.stop() },
              setBitRate: { try await self.rate($0) }, metrics: { nil },
              setProfile: { try await self.change($0) })
    }
    func start() { healthy = true }
    func stop() { healthy = false; stops += 1 }
    func isHealthy() -> Bool { healthy }
    func change(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        profileCalls.append(profile)
        if gated == .profile { await wait() }
        if defect == .nativeError { throw NSError(domain: "private encoder detail", code: -1) }
        healthy = defect != .unhealthy // Model a late native change after close.
        let resultProfile: PublishingVideoProfile = defect == .wrongProfile ? .hd1080 : profile
        return PublishingVideoProfileChange(profile: resultProfile, publishingGeneration: 7,
            previousEncoderSessionID: UUID(), encoderSessionID: UUID(),
            lastOldSourcePTS: CMTime(value: 29, timescale: 30), firstNewSourcePTS: CMTime(value: 30, timescale: 30),
            width: resultProfile.width, height: resultProfile.height, rawVideoFramesDropped: 0,
            acknowledgedAt: ProcessInfo.processInfo.systemUptime)!
    }
    func rate(_ rate: Int) async throws -> PublishingBitRateChange {
        if gated == .bitRate { await wait() }
        return .init(publishingGeneration: 7, configuration: .init(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!,
            acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: .zero)!
    }
    private func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitForEntry() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    func waitForStop() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while stops == 0 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThan(stops, 0)
    }

}

private final class ProfileDone: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

import Foundation
import XCTest
@testable import ScorebugMedia

final class PublishingProfileUpdateTests: XCTestCase {
    func testProfileChangesApplyInOrderAndAreReportedInSnapshot() async throws {
        let publisher = ProfilePublisher()
        let session = try PublishingSession(publisher: publisher, profile: .hd720)
        XCTAssertEqual(session.snapshot.profile, .hd720)
        await fails(.invalidState) { try await session.setVideoProfile(.sd540) }
        try await session.start()
        try await session.setVideoProfile(.sd540)
        try await session.setVideoProfile(.hd1080)
        XCTAssertEqual(publisher.profiles, [.sd540, .hd1080])
        XCTAssertEqual(session.snapshot.profile, .hd1080)
        await session.stop()
        XCTAssertEqual(publisher.stops, 1)
    }

    func testOnlyOneProfileChangeRunsAtATime() async throws {
        let publisher = ProfilePublisher(gated: true)
        let session = try PublishingSession(publisher: publisher)
        try await session.start()
        let first = Task { try await session.setVideoProfile(.sd540) }
        while publisher.calls == 0 { await Task.yield() }
        await fails(.profileUpdateInProgress) { try await session.setVideoProfile(.low360) }
        publisher.release()
        try await first.value
        XCTAssertEqual(session.snapshot.state, .publishing)
        await session.stop()
    }

    func testFailedProfileChangeEndsTheSession() async throws {
        let publisher = ProfilePublisher(fails: true)
        let session = try PublishingSession(publisher: publisher, profile: .hd720)
        try await session.start()
        await fails(.profileUpdateFailed) { try await session.setVideoProfile(.sd540) }
        XCTAssertEqual(session.snapshot.state, .failed)
        XCTAssertEqual(session.snapshot.failure, .profileUpdateFailed)
        XCTAssertEqual(session.snapshot.profile, .hd720)
        XCTAssertEqual(publisher.stops, 1)
    }

    func testHealthMonitorPublishesLatestTransportStatistics() async throws {
        let publisher = ProfilePublisher()
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        XCTAssertNil(session.snapshot.transportStatistics)
        try await session.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while (session.snapshot.transportStatistics?.sentPackets ?? 0) < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThanOrEqual(session.snapshot.transportStatistics?.sentPackets ?? 0, 3)
        await session.stop()
    }

    func testLadderProfilesMatchTheStreamTable() {
        XCTAssertEqual(PublishingVideoProfile.allCases.map(\.height), [1080, 720, 540, 360])
        XCTAssertEqual(PublishingVideoProfile.allCases.map(\.bitRate), [6_000_000, 3_000_000, 1_600_000, 800_000])
        XCTAssertEqual(PublishingVideoProfile.hd720.width, 1280)
    }

    private func fails(_ expected: PublishingSessionError, _ operation: () async throws -> Void,
                       file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PublishingSessionError, expected, file: file, line: line) }
    }
}

private final class ProfilePublisher: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var active = false, stopCount = 0, callCount = 0, samples: Int64 = 0
    private var applied: [PublishingVideoProfile] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    let gated: Bool, failsChange: Bool
    init(gated: Bool = false, fails: Bool = false) { self.gated = gated; failsChange = fails }
    var stops: Int { lock.withLock { stopCount } }
    var calls: Int { lock.withLock { callCount } }
    var profiles: [PublishingVideoProfile] { lock.withLock { applied } }
    var isPublishing: Bool { get async { lock.withLock { active } } }
    func start() async throws { lock.withLock { active = true } }
    func append(_ sample: CapturedMediaSample) async throws {}
    func stop() async {
        lock.withLock { stopCount += 1; active = false }
        release()
    }
    func release() {
        let pending = lock.withLock { released = true; let value = gate; gate = nil; return value }
        pending?.resume()
    }
    func transportStatistics() async -> PublishingTransportStatistics? {
        let sent = lock.withLock { samples += 1; return samples }
        return .init(sampledAt: ProcessInfo.processInfo.systemUptime, sentPackets: sent, retransmittedPackets: 0,
                     droppedPackets: 0, senderBufferMilliseconds: 40, rttMilliseconds: 20, sendRateMbps: 3)
    }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws {
        lock.withLock { callCount += 1 }
        if gated {
            await withCheckedContinuation { pending in
                let immediate = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = pending; return false
                }
                if immediate { pending.resume() }
            }
        }
        if failsChange { throw ProfileError.failed }
        lock.withLock { applied.append(profile) }
    }
    private enum ProfileError: Error { case failed }
}

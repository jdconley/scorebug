import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

@MainActor final class PublishingTransportStatisticsSessionTests: XCTestCase {
    func testSessionCachesFirstClockRetainsEqualAndUnavailableHistoryThroughStop() async throws {
        let publisher = StatisticsPublisher()
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        XCTAssertNil(session.snapshot.transportStatistics.latest)
        try await session.start()
        await eventually { publisher.reads > 0 }
        XCTAssertNil(session.snapshot.transportStatistics.latest)
        let clock = try XCTUnwrap(statisticsSample())
        publisher.setClock(clock)
        await eventually { session.snapshot.transportStatistics.latest == clock }
        let reads = publisher.reads
        await eventually { publisher.reads > reads + 1 }
        XCTAssertEqual(session.snapshot.transportStatistics.latest, clock)
        publisher.setClock(nil)
        let nilReads = publisher.reads
        await eventually { publisher.reads > nilReads + 1 }
        XCTAssertEqual(session.snapshot.transportStatistics.latest, clock)
        await session.stop()
        XCTAssertEqual(session.snapshot.transportStatistics.latest, clock)
        XCTAssertNil(session.snapshot.failure)
        XCTAssertTrue(session.snapshot.transportStatistics.isClosed)
        XCTAssertNil(session.snapshot.transportStatistics.freshSample(at: 10))
    }

    func testSessionExposesAdvancingWindowAndClosesFreshAccessOnStop() async throws {
        let publisher = StatisticsPublisher()
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        publisher.setClock(statisticsSample())
        try await session.start()
        await eventually { session.snapshot.transportStatistics.latest != nil }
        XCTAssertNil(session.snapshot.transportStatistics.window)
        publisher.setClock(.init(publishingGeneration: 1, sampledAt: 11, elapsedMilliseconds: 2000,
                                sentBytes: 11000, retransmittedBytes: 200, droppedPackets: 0,
                                rttMilliseconds: 20, estimatedBandwidthMbps: 200,
                                senderBufferedBytes: 100, senderBufferMilliseconds: 2, availableSenderBytes: 1000))
        await eventually { session.snapshot.transportStatistics.window != nil }
        let window = try XCTUnwrap(session.snapshot.transportStatistics.freshWindow(at: 11))
        XCTAssertEqual(window.sentBytes, 1000)
        XCTAssertEqual(window.retransmittedBytes, 100)
        XCTAssertEqual(window.meanBufferedBytes, 50)
        await session.stop()
        XCTAssertEqual(session.snapshot.transportStatistics.window, window)
        XCTAssertNil(session.snapshot.transportStatistics.freshWindow(at: 11))
    }

    func testStopOrCancellationUnblocksGetterAndRejectsLateEvidence() async throws {
        for cancel in [false, true] {
            let publisher = StatisticsPublisher(gated: true)
            publisher.setClock(statisticsSample())
            let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
            try await session.start()
            await eventually { publisher.entered }
            if cancel { session.cancel() }
            await session.stop()
            XCTAssertTrue(publisher.returned)
            XCTAssertEqual(publisher.stops, 1)
            XCTAssertNil(session.snapshot.transportStatistics.latest)
            XCTAssertEqual(session.snapshot.failure, cancel ? .cancelled : nil)
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }
}

private final class StatisticsPublisher: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var clock: PublishingTransportStatistics?
    private var active = false, ended = false
    private var readCount = 0, stopCount = 0
    private var didEnter = false, didReturn = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let gated: Bool
    init(gated: Bool = false) { self.gated = gated }
    var reads: Int { lock.withLock { readCount } }
    var stops: Int { lock.withLock { stopCount } }
    var entered: Bool { lock.withLock { didEnter } }
    var returned: Bool { lock.withLock { didReturn } }
    func setClock(_ value: PublishingTransportStatistics?) { lock.withLock { clock = value } }
    func start() async throws { lock.withLock { active = true } }
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { get async { lock.withLock { active } } }
    func transportStatistics() async -> PublishingTransportStatistics? {
        let captured = lock.withLock { readCount += 1; return clock }
        if gated {
            await withCheckedContinuation { pending in
                let immediate = lock.withLock {
                    didEnter = true
                    if ended { return true }
                    continuation = pending
                    return false
                }
                if immediate { pending.resume() }
            }
        }
        lock.withLock { didReturn = true }
        return captured // Deliberately late evidence after stop to test the session guard.
    }
    func stop() async {
        let pending = lock.withLock {
            active = false; ended = true; stopCount += 1
            let result = continuation; continuation = nil; return result
        }
        pending?.resume()
    }
}

private func statisticsSample() -> PublishingTransportStatistics? {
    .init(publishingGeneration: 1, sampledAt: 10, elapsedMilliseconds: 1000,
          sentBytes: 10000, retransmittedBytes: 100, droppedPackets: 0,
          rttMilliseconds: 10, estimatedBandwidthMbps: 100, senderBufferedBytes: 50,
          senderBufferMilliseconds: 1, availableSenderBytes: 1000)
}

import CoreMedia
import Foundation
import XCTest
@testable import ScorebugMedia

@MainActor final class PublishingTransportClockTests: XCTestCase {
    func testDescriptorPreservesExactRationalOriginAndGeneration() throws {
        for origin in [CMTime(value: 493, timescale: 4), CMTime(value: -1, timescale: 3),
                       CMTime(value: Int64.max, timescale: 90_000)] {
            let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: origin, publishingGeneration: UInt64.max))
            XCTAssertEqual(clock.sourceOrigin.value, origin.value)
            XCTAssertEqual(clock.sourceOrigin.timescale, origin.timescale)
            XCTAssertEqual(clock.publishingGeneration, UInt64.max)
            XCTAssertEqual(clock, PublishingTransportClock(sourceOrigin: origin, publishingGeneration: UInt64.max))
        }
        XCTAssertEqual(PublishingTransportClock.timescale, 90_000)
        XCTAssertEqual(PublishingTransportClock.presentationLead, 9_000)
        XCTAssertEqual(PublishingTransportClock.wireModulus, 8_589_934_592)
    }

    func testDescriptorRejectsInvalidOriginsAndZeroGeneration() {
        for origin in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                       CMTime(value: 1, timescale: 0), CMTime(value: 1, timescale: -1),
                       CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1)] {
            XCTAssertNil(PublishingTransportClock(sourceOrigin: origin, publishingGeneration: 1))
        }
        XCTAssertNil(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 0))
    }

    func testSessionCachesFirstClockRetainsEqualAndUnavailableHistoryThroughStop() async throws {
        let publisher = ClockPublisher()
        let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
        XCTAssertNil(session.snapshot.transportClock)
        try await session.start()
        await eventually { publisher.reads > 0 }
        XCTAssertNil(session.snapshot.transportClock)
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: CMTime(value: 493, timescale: 4), publishingGeneration: 7))
        publisher.setClock(clock)
        await eventually { session.snapshot.transportClock == clock }
        let reads = publisher.reads
        await eventually { publisher.reads > reads + 1 }
        XCTAssertEqual(session.snapshot.transportClock, clock)
        publisher.setClock(nil)
        let nilReads = publisher.reads
        await eventually { publisher.reads > nilReads + 1 }
        XCTAssertEqual(session.snapshot.transportClock, clock)
        await session.stop()
        XCTAssertEqual(session.snapshot.transportClock, clock)
        XCTAssertNil(session.snapshot.failure)
    }

    func testContradictoryOriginOrGenerationPermanentlyQuarantinesOnlyItsSession() async throws {
        let first = try XCTUnwrap(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        for conflicting in [PublishingTransportClock(sourceOrigin: CMTime(value: 1, timescale: 1), publishingGeneration: 1),
                            PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 2)] {
            let publisher = ClockPublisher()
            publisher.setClock(first)
            let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
            try await session.start()
            await eventually { session.snapshot.transportClock == first }
            publisher.setClock(conflicting)
            await eventually { session.snapshot.transportClock == nil }
            publisher.setClock(first)
            let reads = publisher.reads
            await eventually { publisher.reads > reads + 1 }
            XCTAssertNil(session.snapshot.transportClock)
            XCTAssertEqual(session.snapshot.state, .publishing)
            XCTAssertNil(session.snapshot.failure)
            await session.stop()
            XCTAssertNil(session.snapshot.transportClock)
            let replacement = ClockPublisher()
            replacement.setClock(first)
            let newSession = try PublishingSession(publisher: replacement, healthCheckInterval: .milliseconds(2))
            XCTAssertNil(newSession.snapshot.transportClock)
            try await newSession.start()
            await eventually { newSession.snapshot.transportClock == first }
            await newSession.stop()
        }
    }

    func testStopOrCancellationUnblocksGetterAndRejectsLateEvidence() async throws {
        for cancel in [false, true] {
            let publisher = ClockPublisher(gated: true)
            publisher.setClock(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
            let session = try PublishingSession(publisher: publisher, healthCheckInterval: .milliseconds(2))
            try await session.start()
            await eventually { publisher.entered }
            if cancel { session.cancel() }
            await session.stop()
            XCTAssertTrue(publisher.returned)
            XCTAssertEqual(publisher.stops, 1)
            XCTAssertNil(session.snapshot.transportClock)
            XCTAssertEqual(session.snapshot.failure, cancel ? .cancelled : nil)
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }
}

private final class ClockPublisher: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var clock: PublishingTransportClock?
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
    func setClock(_ value: PublishingTransportClock?) { lock.withLock { clock = value } }
    func start() async throws { lock.withLock { active = true } }
    func append(_ sample: CapturedMediaSample) async throws {}
    var isPublishing: Bool { get async { lock.withLock { active } } }
    func transportClock() async -> PublishingTransportClock? {
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

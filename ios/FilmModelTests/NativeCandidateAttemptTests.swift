import CoreMedia
import CoreVideo
import Foundation
import ScorebugMedia
import ScorebugStreaming
import XCTest

@MainActor
final class NativeCandidateAttemptTests: XCTestCase {
    func testCancellationBeforeStartNeverCreatesOwner() async throws {
        let fake = CandidateAttemptFake(), attempt = NativeCandidateAttempt(operations: fake.operations)
        attempt.cancel(.pressure)
        do { try await attempt.start(); XCTFail("cancelled attempt reopened") } catch {}
        XCTAssertEqual(fake.starts, 0)
        XCTAssertFalse(attempt.offer(try sample()))
        await attempt.retire()
        XCTAssertEqual(fake.retires, 0)
    }
    func testCancellationJoinsLateBeginBeforeReturning() async throws {
        for callerCancellation in [false, true] {
            let fake = CandidateAttemptFake(beginOpen: false, terminalOpen: false)
            let attempt = NativeCandidateAttempt(operations: fake.operations), finished = AttemptFlag()
            let start = Task { defer { finished.set() }; try await attempt.start() }
            await wait { fake.starts == 1 }
            if callerCancellation { start.cancel() } else { attempt.cancel(.pressure) }
            XCTAssertFalse(attempt.offer(try sample()))
            fake.beginGate.open()
            await wait { fake.retires == 1 }
            XCTAssertFalse(finished.value, "start returned before native retirement joined")
            fake.terminalGate.open()
            do { try await start.value; XCTFail("late begin installed cancelled owner") } catch {}
            await attempt.retire()
            XCTAssertEqual(fake.retires, 1)
            XCTAssertTrue(fake.cancelledIDs.allSatisfy { $0 == fake.id })
        }
    }
    func testExactOwnerRoutesOffersAndRetirementIsShared() async throws {
        let fake = CandidateAttemptFake(terminalOpen: false)
        let attempt = NativeCandidateAttempt(operations: fake.operations)
        try await attempt.start()
        XCTAssertTrue(attempt.offer(try sample()))
        XCTAssertEqual(fake.offers, 1)
        do { try await attempt.start(); XCTFail("single attempt started twice") } catch {}
        XCTAssertEqual(fake.starts, 1)
        let result = Task { await attempt.result() }
        await wait { fake.results == 1 }
        let retired = AttemptFlag()
        let first = Task { await attempt.retire(); retired.set() }
        await wait { fake.retires == 1 }
        let second = Task { await attempt.retire() }
        XCTAssertFalse(attempt.offer(try sample()))
        XCTAssertFalse(retired.value)
        fake.terminalGate.open()
        await first.value; await second.value
        _ = await result.value
        XCTAssertEqual(fake.retires, 1)
        XCTAssertEqual(fake.offers, 1)
        XCTAssertTrue(fake.cancelledIDs.allSatisfy { $0 == fake.id })
    }
    private func wait(_ predicate: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate())
    }
    private func sample() throws -> CapturedMediaSample {
        var pixel: CVPixelBuffer?, format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), noErr)
        let buffer = try XCTUnwrap(pixel)
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
    }
}
private final class AttemptFlag: @unchecked Sendable {
    private let lock = NSLock(); private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
private final class AttemptGate: Sendable {
    private let stream: AsyncStream<Void>; private let continuation: AsyncStream<Void>.Continuation
    init(open: Bool) { (stream, continuation) = AsyncStream.makeStream(); if open { continuation.finish() } }
    func open() { continuation.finish() }
    func wait() async { await Task.detached { for await _ in self.stream {} }.value }
}
private final class CandidateAttemptFake: @unchecked Sendable {
    let id = UUID(), beginGate: AttemptGate, terminalGate: AttemptGate
    private let lock = NSLock()
    private var startCount = 0, resultCount = 0, retireCount = 0, offerCount = 0
    private var cancellations: [UUID] = []
    var starts: Int { lock.withLock { startCount } }
    var results: Int { lock.withLock { resultCount } }
    var retires: Int { lock.withLock { retireCount } }
    var offers: Int { lock.withLock { offerCount } }
    var cancelledIDs: [UUID] { lock.withLock { cancellations } }
    init(beginOpen: Bool = true, terminalOpen: Bool = true) {
        beginGate = AttemptGate(open: beginOpen); terminalGate = AttemptGate(open: terminalOpen)
    }
    var operations: NativeCandidateAttempt.Operations {
        .init(begin: {
            self.lock.withLock { self.startCount += 1 }
            await self.beginGate.wait(); return self.id
        }, offer: { _, id in self.lock.withLock {
            guard id == self.id, self.cancellations.isEmpty else { return false }
            self.offerCount += 1; return true
        } }, cancel: { id, _ in self.lock.withLock { self.cancellations.append(id) } }, result: { id in
            self.lock.withLock { self.resultCount += 1 }; XCTAssertEqual(id, self.id)
            await self.terminalGate.wait(); return nil
        }, retire: { id, _ in
            self.lock.withLock { self.retireCount += 1 }; XCTAssertEqual(id, self.id)
            await self.terminalGate.wait()
        })
    }
}

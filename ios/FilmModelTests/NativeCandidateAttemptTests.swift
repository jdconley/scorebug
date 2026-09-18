import CoreMedia
import CoreVideo
import Foundation
import ScorebugCore
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
    func testCheckedStartupRejectsMissingOrInconsistentContextBeforeAllocation() async throws {
        let f = try await CandidateQualityFixture.make()
        let context = try await currentContext(f)
        var wrongAttempt = context.applied; wrongAttempt.attemptID = UUID()
        var wrongRevision = context.applied; wrongRevision.revision += 1
        var wrongSettings = context.applied
        wrongSettings.settings = .init(profileID: "360p30", videoBitrate: 600_000)
        var wrongRate = context.applied
        wrongRate.receipt = try XCTUnwrap(.init(publishingGeneration: context.applied.receipt.publishingGeneration,
            configuration: .init(id: UUID(), encoderSessionID: UUID(), bitRate: 1)!,
            acceptedAt: context.applied.receipt.acceptedAt, lastSubmittedSourcePTS: nil))
        let wrongClock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 99)!
        let invalid: [PublishingQualitySession.CandidateMeasurementContext?] = [nil,
            replacing(context, applied: wrongAttempt), replacing(context, applied: wrongRevision),
            replacing(context, applied: wrongSettings), replacing(context, applied: wrongRate),
            .init(readiness: context.readiness, applied: context.applied, scope: context.scope, clock: wrongClock)]
        for value in invalid {
            let fake = CandidateAttemptFake()
            let attempt = NativeCandidateAttempt(operations: fake.operations, scope: context.scope,
                candidate: .low360, contextProvider: { value })
            do { try await attempt.start(); XCTFail("invalid context allocated an owner") } catch {}
            XCTAssertEqual(fake.starts, 0)
            XCTAssertEqual(fake.retires, 0)
        }
        for candidate in [PublishingVideoProfile.low240, .sd540] {
            let fake = CandidateAttemptFake()
            let attempt = NativeCandidateAttempt(operations: fake.operations, scope: context.scope,
                candidate: candidate, contextProvider: { context })
            do { try await attempt.start(); XCTFail("wrong candidate allocated an owner") } catch {}
            XCTAssertEqual(fake.starts, 0)
        }
        let wrongScope = VideoFrameObservationScope(recordingID: "replacement", matchID: context.scope.matchID,
            broadcastGeneration: context.scope.broadcastGeneration, publishingAttemptID: context.scope.publishingAttemptID,
            appliedProfileRevision: context.scope.appliedProfileRevision)
        let fake = CandidateAttemptFake()
        let attempt = NativeCandidateAttempt(operations: fake.operations, scope: wrongScope,
            candidate: .low360, contextProvider: { context })
        do { try await attempt.start(); XCTFail("wrong scope allocated an owner") } catch {}
        XCTAssertEqual(fake.starts, 0)
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        await f.owner.stop()
    }
    func testCheckedStartupForwardsCurrentContextAndAcceptsFreshHealthForSameConfiguration() async throws {
        let f = try await CandidateQualityFixture.make()
        let first = try await currentContext(f)
        let fake = CandidateAttemptFake(beginOpen: false)
        let contexts = AttemptContextBox(first)
        let attempt = NativeCandidateAttempt(operations: fake.operations, scope: first.scope,
            candidate: .low360, contextProvider: { contexts.read() })
        let start = Task { try await attempt.start() }
        await wait { fake.starts == 1 }
        XCTAssertEqual(fake.beginContext?.applied.receipt.configuration, first.applied.receipt.configuration)
        XCTAssertEqual(fake.beginContext?.applied.receipt.publishingGeneration, 7)
        f.native.setNow(120.1)
        let health = try await f.freshSource(start: 115, sequence: 3)
        _ = try await f.owner.evaluate(source: health.0, diagnostics: health.1,
            workerLimits: .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000),
            transportLimits: .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01),
            instant: f.native.instant)
        let nextValue = await f.owner.candidateMeasurementContext(diagnostics: health.1)
        let next = try XCTUnwrap(nextValue)
        XCTAssertGreaterThan(next.readiness.healthSequence, first.readiness.healthSequence)
        XCTAssertGreaterThan(next.readiness.healthyThrough, first.readiness.healthyThrough)
        XCTAssertEqual(next.readiness.healthySince, first.readiness.healthySince)
        contexts.set(next); fake.beginGate.open()
        try await start.value
        XCTAssertTrue(attempt.offer(try sample()))
        XCTAssertEqual(contexts.reads, 2)
        XCTAssertEqual(f.native.calls, ["rate:350000"])
        await attempt.retire(); await f.owner.stop()
    }
    func testCheckedStartupRetiresExactAllocatedOwnerAfterContextChanges() async throws {
        let f = try await CandidateQualityFixture.make(), other = try await CandidateQualityFixture.make()
        let first = try await currentContext(f), otherContext = try await currentContext(other)
        var changedAck = first.applied; changedAck.acknowledgedAt += 1
        var changedReceipt = first.applied
        changedReceipt.receipt = try XCTUnwrap(.init(publishingGeneration: first.applied.receipt.publishingGeneration,
            configuration: first.applied.receipt.configuration, acceptedAt: first.applied.receipt.acceptedAt,
            lastSubmittedSourcePTS: .init(value: 999, timescale: 30)))
        let changedClock = PublishingTransportClock(sourceOrigin: .init(value: 1, timescale: 30), publishingGeneration: 7)!
        let replacements: [PublishingQualitySession.CandidateMeasurementContext?] = [nil, otherContext,
            replacing(first, applied: changedAck), replacing(first, applied: changedReceipt),
            .init(readiness: first.readiness, applied: first.applied, scope: first.scope, clock: changedClock)]
        for replacement in replacements {
            let fake = CandidateAttemptFake(beginOpen: false, terminalOpen: false), contexts = AttemptContextBox(first)
            let attempt = NativeCandidateAttempt(operations: fake.operations, scope: first.scope,
                candidate: .low360, contextProvider: { contexts.read() }), finished = AttemptFlag()
            let start = Task { defer { finished.set() }; try await attempt.start() }
            await wait { fake.starts == 1 }
            contexts.set(replacement); fake.beginGate.open()
            await wait { fake.retires == 1 }
            XCTAssertEqual(fake.cancelledIDs, [fake.id])
            XCTAssertFalse(finished.value, "invalid startup returned before exact owner retired")
            XCTAssertFalse(attempt.offer(try sample()))
            fake.terminalGate.open()
            do { try await start.value; XCTFail("changed context installed owner") } catch {}
            await attempt.retire()
            XCTAssertEqual(fake.retires, 1)
        }
        await f.owner.stop(); await other.owner.stop()
    }
    func testCheckedStartupCancellationDuringInitialContextReadNeverAllocates() async throws {
        let f = try await CandidateQualityFixture.make(), context = try await currentContext(f)
        let fake = CandidateAttemptFake(), entered = AttemptFlag(), gate = AttemptGate(open: false)
        let attempt = NativeCandidateAttempt(operations: fake.operations, scope: context.scope,
            candidate: .low360, contextProvider: { entered.set(); await gate.wait(); return context })
        let start = Task { try await attempt.start() }
        await wait { entered.value }
        start.cancel(); gate.open()
        do { try await start.value; XCTFail("cancelled context read allocated owner") } catch {}
        XCTAssertEqual(fake.starts, 0)
        XCTAssertEqual(fake.retires, 0)
        await f.owner.stop()
    }
    func testCheckedStartupCancellationJoinsAllocatedOwnerAndSuspendedContextRead() async throws {
        let f = try await CandidateQualityFixture.make(), context = try await currentContext(f)
        for cancelDuringRead in [false, true] {
            let fake = CandidateAttemptFake(beginOpen: cancelDuringRead, terminalOpen: false)
            let contextGate = AttemptGate(open: false), reads = AttemptCounter(), finished = AttemptFlag()
            let attempt = NativeCandidateAttempt(operations: fake.operations, scope: context.scope,
                candidate: .low360, contextProvider: {
                    if reads.increment() == 2 { await contextGate.wait() }
                    return context
                })
            let start = Task { defer { finished.set() }; try await attempt.start() }
            await wait { cancelDuringRead ? reads.value == 2 : fake.starts == 1 }
            start.cancel(); fake.beginGate.open(); contextGate.open()
            await wait { fake.retires == 1 }
            XCTAssertEqual(fake.cancelledIDs, [fake.id])
            XCTAssertFalse(finished.value)
            fake.terminalGate.open()
            do { try await start.value; XCTFail("cancelled checked startup installed owner") } catch {}
            await attempt.retire()
            XCTAssertEqual(fake.retires, 1)
        }
        await f.owner.stop()
    }
    func testContextReaderInstallsOnceReadsFreshAndClosesPermanently() async throws {
        let f = try await CandidateQualityFixture.make(), context = try await currentContext(f)
        let reader = NativeCandidateContextReader(), box = AttemptContextBox(context)
        let missing = await reader.read(); XCTAssertNil(missing)
        XCTAssertTrue(reader.install { box.read() })
        XCTAssertFalse(reader.install { nil })
        let first = await reader.read(); XCTAssertNotNil(first)
        box.set(nil)
        let second = await reader.read(); XCTAssertNil(second, "reader cached authority")
        XCTAssertEqual(box.reads, 2)
        reader.close(); reader.close()
        box.set(context)
        let closed = await reader.read(); XCTAssertNil(closed)
        XCTAssertFalse(reader.install { context })
        XCTAssertEqual(box.reads, 2)
        await f.owner.stop()
    }
    func testContextReaderCloseDiscardsSuspendedProviderResult() async throws {
        let f = try await CandidateQualityFixture.make(), context = try await currentContext(f)
        let reader = NativeCandidateContextReader(), entered = AttemptFlag(), gate = AttemptGate(open: false)
        XCTAssertTrue(reader.install { entered.set(); await gate.wait(); return context })
        let read = Task { await reader.read() }
        await wait { entered.value }
        reader.close(); gate.open()
        let value = await read.value; XCTAssertNil(value)
        await f.owner.stop()
    }
    private func currentContext(_ f: CandidateQualityFixture) async throws -> PublishingQualitySession.CandidateMeasurementContext {
        let value = await f.owner.candidateMeasurementContext(diagnostics: try XCTUnwrap(f.sourceDiagnostics))
        return try XCTUnwrap(value)
    }
    private func replacing(_ context: PublishingQualitySession.CandidateMeasurementContext,
                           applied: PublishingQualityTelemetry.Applied) -> PublishingQualitySession.CandidateMeasurementContext {
        .init(readiness: context.readiness, applied: applied, scope: context.scope, clock: context.clock)
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
    private var context: PublishingQualitySession.CandidateMeasurementContext?
    var beginContext: PublishingQualitySession.CandidateMeasurementContext? { lock.withLock { context } }
    var starts: Int { lock.withLock { startCount } }
    var results: Int { lock.withLock { resultCount } }
    var retires: Int { lock.withLock { retireCount } }
    var offers: Int { lock.withLock { offerCount } }
    var cancelledIDs: [UUID] { lock.withLock { cancellations } }
    init(beginOpen: Bool = true, terminalOpen: Bool = true) {
        beginGate = AttemptGate(open: beginOpen); terminalGate = AttemptGate(open: terminalOpen)
    }
    var operations: NativeCandidateAttempt.Operations {
        .init(begin: { context in
            self.lock.withLock { self.startCount += 1; self.context = context }
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

private final class AttemptContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: PublishingQualitySession.CandidateMeasurementContext?
    private var count = 0
    init(_ context: PublishingQualitySession.CandidateMeasurementContext?) { self.context = context }
    var reads: Int { lock.withLock { count } }
    func set(_ value: PublishingQualitySession.CandidateMeasurementContext?) { lock.withLock { context = value } }
    func read() -> PublishingQualitySession.CandidateMeasurementContext? {
        lock.withLock { count += 1; return context }
    }
}
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

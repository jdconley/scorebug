import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

@MainActor
final class PublishingCandidateMeasurementTests: XCTestCase {
    private func scope() -> VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 7,
              publishingAttemptID: UUID(), appliedProfileRevision: 11)
    }
    private func measurement(_ fake: MeasurementEncoder = .init(), clock: MeasurementClock = .init(),
                             timer: MeasurementGate = .init()) -> PublishingCandidateMeasurement {
        .init(scope: scope(), profile: .low240, operations: fake.operations,
              now: { clock.now }, deadlineWait: { await timer.wait() })
    }

    func testRawCloseHookRunsImmediatelyAndCancellationRevokesAnAlreadyFinishingOwner() async throws {
        let fake = MeasurementEncoder(), gate = MeasurementGate(), closed = MeasurementClosures()
        fake.finishGate = gate
        var operations = fake.operations
        operations.rawClosed = closed.record
        let candidate = PublishingCandidateMeasurement(scope: scope(), profile: .low240, operations: operations,
            now: { 10 }, deadlineWait: { try? await Task.sleep(for: .seconds(5)) })
        try await candidate.start()
        for index in 0...96 { XCTAssertTrue(candidate.offer(try sample(index, scale: 24))) }
        XCTAssertEqual(closed.reasons, [.completed])
        await fake.waitForFinish()
        candidate.cancel(reason: .pressure)
        XCTAssertEqual(closed.reasons.last, .pressure)
        gate.open()
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .pressure)
    }

    func testPrestartOfferDoesNotDamageStartAndCancellationIsTerminal() async throws {
        let candidate = measurement()
        XCTAssertFalse(candidate.offer(try sample(0)))
        try await candidate.start()
        candidate.cancel(reason: .pressure)
        XCTAssertFalse(candidate.offer(try sample(0)))
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .pressure)
        XCTAssertNotNil(result.startedAt)
        XCTAssertEqual(result.scope, candidate.scope)
        XCTAssertEqual(result.profile, candidate.profile)
        XCTAssertEqual(result.id, candidate.id)
        XCTAssertEqual(result.acceptedInputCount, 0)
        let repeated = await candidate.result()
        XCTAssertEqual(result.endedAt, repeated.endedAt)
    }

    func testResultBeforeStartIsIncompleteAndPrestartCancellationIsPreserved() async throws {
        let first = measurement()
        let result = await first.result()
        XCTAssertEqual(result.reason, .incomplete)
        XCTAssertNil(result.startedAt)
        do { try await first.start(); XCTFail("single use") } catch {}
        let second = measurement()
        second.cancel(reason: .publisherStopped)
        let cancelled = await second.result()
        XCTAssertEqual(cancelled.reason, .publisherStopped)
        XCTAssertNil(cancelled.startedAt)
    }

    func testFourSecondWindowClosesAt97InputsAndJoinsOneFinish() async throws {
        let fake = MeasurementEncoder(), clock = MeasurementClock()
        let candidate = measurement(fake, clock: clock)
        try await candidate.start()
        for n in 0...96 { XCTAssertTrue(candidate.offer(try sample(n, scale: 24))) }
        XCTAssertFalse(candidate.offer(try sample(97, scale: 24)))
        let result = await candidate.result()
        // The injected encoder supplies no evidence: window completion alone
        // cannot manufacture measured native output.
        XCTAssertEqual(result.reason, .encoderFailed)
        XCTAssertEqual(result.acceptedInputCount, 97)
        XCTAssertEqual(result.firstInputPTS, .zero)
        XCTAssertEqual(result.lastInputPTS, CMTime(value: 96, timescale: 24))
        XCTAssertEqual(fake.finishes, 1)
        XCTAssertEqual(fake.cancels, 0)
    }

    func testSparseWindowAnd121InputCapAreIncomplete() async throws {
        let sparse = measurement()
        try await sparse.start()
        XCTAssertTrue(sparse.offer(try sample(0)))
        XCTAssertTrue(sparse.offer(try sample(120)))
        let sparseResult = await sparse.result()
        XCTAssertEqual(sparseResult.reason, .incomplete)
        let capped = measurement()
        try await capped.start()
        for n in 0...120 { XCTAssertTrue(capped.offer(try sample(n, scale: 60))) }
        XCTAssertFalse(capped.offer(try sample(121, scale: 60)))
        let capResult = await capped.result()
        XCTAssertEqual(capResult.reason, .incomplete)
        XCTAssertEqual(capResult.acceptedInputCount, 121)
    }

    func testRejectedNativeOfferClosesImmediately() async throws {
        let fake = MeasurementEncoder(accepts: false), candidate = measurement(fake)
        try await candidate.start()
        XCTAssertFalse(candidate.offer(try sample(0)))
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .inputRejected)
        XCTAssertEqual(result.acceptedInputCount, 0)
        XCTAssertEqual(fake.cancels, 1)
    }

    func testAudioIsIgnoredAndInvalidVideoCannotAdmitEvidence() async throws {
        let candidate = measurement()
        try await candidate.start()
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4, buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer), noErr)
        let audio = try CapturedMediaSample(sampleBuffer: XCTUnwrap(buffer), kind: .audio)
        XCTAssertFalse(candidate.offer(audio))
        XCTAssertTrue(candidate.offer(try sample(0)))
        XCTAssertFalse(candidate.offer(try sample(0)))
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .inputRejected)
        XCTAssertEqual(result.acceptedInputCount, 1)
    }

    func testStartupFailureAndRepeatedStartCannotOpenAdmission() async throws {
        let fake = MeasurementEncoder()
        fake.failsStart = true
        let candidate = measurement(fake)
        do { try await candidate.start(); XCTFail("startup must throw") } catch {}
        XCTAssertFalse(candidate.offer(try sample(0)))
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .startupFailed)
        XCTAssertEqual(fake.cancels, 1)
        do { try await candidate.start(); XCTFail("single use") } catch {}
    }

    func testDeadlineTimerClosesIdleMeasurementWithoutAnotherOffer() async throws {
        let fake = MeasurementEncoder(), clock = MeasurementClock(), timer = MeasurementGate()
        let candidate = measurement(fake, clock: clock, timer: timer)
        try await candidate.start()
        clock.set(15); timer.open()
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .deadline)
        XCTAssertEqual(fake.cancels, 1)
    }

    func testLateCompletingOfferCannotBeatDelayedDeadlineTask() async throws {
        let fake = MeasurementEncoder(), clock = MeasurementClock()
        let candidate = measurement(fake, clock: clock)
        try await candidate.start()
        for n in 0..<96 { XCTAssertTrue(candidate.offer(try sample(n, scale: 24))) }
        clock.set(15)
        XCTAssertFalse(candidate.offer(try sample(96, scale: 24)))
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .deadline)
        XCTAssertEqual(result.acceptedInputCount, 96)
    }

    func testDeadlineCrossedInsideSynchronousOfferStillRejectsWindow() async throws {
        let fake = MeasurementEncoder(), clock = MeasurementClock()
        fake.onOffer = { clock.set(15) }
        let candidate = measurement(fake, clock: clock)
        try await candidate.start()
        XCTAssertTrue(candidate.offer(try sample(0)))
        XCTAssertFalse(candidate.offer(try sample(1)))
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .deadline)
        XCTAssertEqual(result.acceptedInputCount, 1)
    }

    func testOversizedSourceSpanAndBackwardClockFailClosed() async throws {
        let spanCandidate = measurement()
        try await spanCandidate.start()
        XCTAssertTrue(spanCandidate.offer(try sample(0)))
        XCTAssertFalse(spanCandidate.offer(try sample(129)))
        let spanResult = await spanCandidate.result()
        XCTAssertEqual(spanResult.reason, .inputRejected)
        let clock = MeasurementClock(), clockCandidate = measurement(clock: clock)
        try await clockCandidate.start()
        clock.set(9)
        XCTAssertFalse(clockCandidate.offer(try sample(0)))
        let clockResult = await clockCandidate.result()
        XCTAssertEqual(clockResult.reason, .deadline)
        XCTAssertTrue(clockResult.endedAt >= (clockResult.startedAt ?? 0))
    }

    func testCallingCancelCompletedCannotManufactureCompletion() async throws {
        let candidate = measurement()
        try await candidate.start()
        candidate.cancel(reason: .completed)
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .cancelled)
    }

    func testTimelyWindowMayJoinNativeFinishBeyondAdmissionDeadline() async throws {
        let fake = MeasurementEncoder(), clock = MeasurementClock(), gate = MeasurementGate()
        fake.finishGate = gate
        let candidate = measurement(fake, clock: clock)
        try await candidate.start()
        for n in 0...96 { XCTAssertTrue(candidate.offer(try sample(n, scale: 24))) }
        await fake.waitForFinish()
        clock.set(19); gate.open()
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .encoderFailed)
        XCTAssertEqual(result.endedAt, 19)
    }

    func testCancelDuringFinishClosesImmediatelyAndAllWaitersJoin() async throws {
        let fake = MeasurementEncoder(), gate = MeasurementGate()
        fake.finishGate = gate
        let candidate = measurement(fake)
        try await candidate.start()
        for n in 0...96 { XCTAssertTrue(candidate.offer(try sample(n, scale: 24))) }
        await fake.waitForFinish()
        candidate.cancel(reason: .ownerChanged)
        XCTAssertFalse(candidate.offer(try sample(97, scale: 24)))
        let first = Task { await candidate.result() }, second = Task { await candidate.result() }
        gate.open()
        let a = await first.value, b = await second.value
        XCTAssertEqual(a.reason, .ownerChanged)
        XCTAssertEqual(a.reason, b.reason)
        XCTAssertEqual(a.endedAt, b.endedAt)
        XCTAssertEqual(fake.finishes, 1)
    }

    func testCancellationDuringStartupJoinsBeforeReturning() async throws {
        let fake = MeasurementEncoder(), gate = MeasurementGate()
        fake.startGate = gate
        let candidate = measurement(fake)
        let startup = Task { try await candidate.start() }
        await fake.waitForStart()
        candidate.cancel()
        XCTAssertFalse(candidate.offer(try sample(0)))
        gate.open()
        do { try await startup.value; XCTFail("cancelled start") } catch {}
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertEqual(fake.cancels, 1)
        XCTAssertNil(result.startedAt)
    }

    func testOwnerReleaseClosesAndJoinsNativeCancellation() async throws {
        let fake = MeasurementEncoder()
        var candidate: PublishingCandidateMeasurement? = measurement(fake)
        try await candidate?.start()
        weak var weakCandidate = candidate
        candidate = nil
        XCTAssertNil(weakCandidate)
        await fake.waitForCancel()
        XCTAssertEqual(fake.cancels, 1)
    }

    func testRealEncoderProducesReconciledFourSecondWindow() async throws {
        let candidate = try PublishingCandidateMeasurement(scope: scope(), profile: .low240)
        try await candidate.start()
        for n in 0...96 {
            XCTAssertTrue(candidate.offer(try sample(n, scale: 24)))
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .completed)
        let encoding = try XCTUnwrap(result.encoding?.encoding)
        XCTAssertEqual(encoding.id, candidate.id)
        XCTAssertEqual(encoding.acceptedInputCount, 97)
        XCTAssertEqual(encoding.outputCount, 97)
        XCTAssertEqual(encoding.frames.count, 97)
        XCTAssertEqual(encoding.frames.first?.isSync, true)
        XCTAssertTrue(encoding.frames.allSatisfy { $0.byteCount > 0 && $0.width == 426 && $0.height == 240 })
    }

    func testSuccessfulNativePartialOutputCannotQualifyCompleteInputWindow() async throws {
        let scope = scope()
        let encoder = try PublishingCandidateEncoder(scope: scope, profile: .low240)
        try await encoder.start()
        XCTAssertTrue(encoder.offer(try sample(0).sampleBuffer))
        let partial = await encoder.finish()
        XCTAssertEqual(partial.encoding.outcome, .completed)
        let candidate = PublishingCandidateMeasurement(scope: scope, profile: .low240,
            operations: .init(id: encoder.id, start: {}, offer: { _ in true },
                finish: { partial }, cancel: { partial }))
        try await candidate.start()
        for n in 0...96 { XCTAssertTrue(candidate.offer(try sample(n, scale: 24))) }
        let result = await candidate.result()
        XCTAssertEqual(result.reason, .encoderFailed)
        XCTAssertEqual(result.acceptedInputCount, 97)
        XCTAssertEqual(result.encoding?.encoding.outputCount, 1)
    }

    private func sample(_ value: Int, scale: Int32 = 30) throws -> CapturedMediaSample {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let pointer = CVPixelBufferGetBaseAddress(image) { memset(pointer, 0, CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
            presentationTimeStamp: CMTime(value: Int64(value), timescale: scale), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &buffer), noErr)
        return try .init(sampleBuffer: XCTUnwrap(buffer), kind: .video)
    }
}

private final class MeasurementClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 10.0
    var now: Double { lock.withLock { value } }
    func set(_ value: Double) { lock.withLock { self.value = value } }
}
private final class MeasurementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.withLock { opened = true } }
    func wait() async {
        while !Task.isCancelled && !lock.withLock({ opened }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
private final class MeasurementEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, finished = 0, cancelled = 0
    var startGate: MeasurementGate?, finishGate: MeasurementGate?
    var failsStart = false
    var onOffer: (@Sendable () -> Void)?
    let accepts: Bool
    init(accepts: Bool = true) { self.accepts = accepts }
    var finishes: Int { lock.withLock { finished } }
    var cancels: Int { lock.withLock { cancelled } }
    var operations: PublishingCandidateMeasurement.Operations {
        .init(id: UUID(), start: { [self] in
            lock.withLock { starts += 1 }; await startGate?.wait()
            if failsStart { throw MeasurementFakeError.startup }
        }, offer: { [self] _ in onOffer?(); return accepts }, finish: { [self] in
            lock.withLock { finished += 1 }; await finishGate?.wait(); return nil
        }, cancel: { [self] in lock.withLock { cancelled += 1 }; return nil })
    }
    func waitForStart() async { await wait { self.lock.withLock { self.starts > 0 } } }
    func waitForFinish() async { await wait { self.finishes > 0 } }
    func waitForCancel() async { await wait { self.cancels > 0 } }
    private func wait(_ condition: @Sendable () -> Bool) async {
        let end = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(condition())
    }
}
private enum MeasurementFakeError: Error { case startup }

private final class MeasurementClosures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PublishingCandidateMeasurement.Reason] = []
    func record(_ reason: PublishingCandidateMeasurement.Reason) { lock.withLock { values.append(reason) } }
    var reasons: [PublishingCandidateMeasurement.Reason] { lock.withLock { values } }
}

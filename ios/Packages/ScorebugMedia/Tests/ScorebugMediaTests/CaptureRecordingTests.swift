@preconcurrency import AVFoundation
import XCTest
@testable import ScorebugMedia

@MainActor final class CaptureRecordingTests: XCTestCase {
    func testStartsArchiveAtSourceOriginBeforeDeliveryAndQuiescesBeforeFinish() async throws {
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        try await recording.start()
        XCTAssertEqual(sink.origin, source.origin)
        _ = try await recording.stop()
        XCTAssertEqual(sink.count, 2, "Includes the source's final callback during quiescence")
        XCTAssertTrue(sink.stoppedBeforeFinish)
        XCTAssertEqual(source.stops, 1)
        _ = try await recording.stop()
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(recording.snapshot.state, .finished)
        source.lateFailure()
        XCTAssertEqual(recording.snapshot.state, .finished)
    }

    func testSourceStartupFailureStopsSourceAndCannotFinishSuccessfully() async throws {
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink, startFails: true)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        do { try await recording.start(); XCTFail("Expected source failure") } catch {}
        await assertFailure(recording, .captureFailed("Capture startup failed"))
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(sink.finishes, 0)
    }

    func testInterruptionAndDropLatchFailure() async throws {
        for event in [CaptureSourceEvent.droppedSample, .interrupted, .failed] {
            let sink = CaptureSink()
            let source = CaptureFixture(sink: sink)
            let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
            try await recording.start()
            source.event(event)
            do { _ = try await recording.stop(); XCTFail("Capture loss must fail") } catch {}
            XCTAssertEqual(recording.snapshot.state, .failed)
            XCTAssertEqual(source.stops, 1)
        }
    }

    func testStopDuringPreparePreventsStartingSourceAndJoinsCleanup() async throws {
        let gate = CaptureGate()
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink, prepareGate: gate)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        let start = Task { try await recording.start() }
        await gate.waitUntilEntered()
        let stop = Task { try await recording.stop() }
        while recording.snapshot.failure == nil { await Task.yield() }
        gate.release()
        do { try await start.value; XCTFail("Aborted startup") } catch {}
        do { _ = try await stop.value; XCTFail("Aborted startup") } catch {}
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(source.stops, 1)
    }

    func testCancelDuringPrepareCannotResurrectRecording() async throws {
        let gate = CaptureGate()
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink, prepareGate: gate)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        let start = Task { try await recording.start() }
        await gate.waitUntilEntered()
        recording.cancel()
        gate.release()
        do { try await start.value; XCTFail("Cancelled startup") } catch {}
        await assertFailure(recording, .cancelled)
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(source.stops, 1)
    }

    func testPreparationFailureAndEventStillStopPartiallyPreparedSource() async throws {
        for fails in [true, false] {
            let sink = CaptureSink()
            let source = CaptureFixture(sink: sink, prepareFails: fails,
                                        prepareEvent: fails ? nil : .interrupted)
            let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
            do { try await recording.start(); XCTFail("Preparation must fail") } catch {}
            await assertFailure(recording, .captureFailed(fails ? "Capture startup failed" : "Capture interrupted"))
            XCTAssertEqual(source.starts, 0)
            XCTAssertEqual(source.stops, 1)
            XCTAssertNil(sink.origin)
        }
    }

    func testConcurrentStopWaitersJoinSourceQuiescenceAndIgnoreWaiterCancellation() async throws {
        let gate = CaptureGate()
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink, stopGate: gate)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        try await recording.start()
        let first = Task { try await recording.stop() }
        await gate.waitUntilEntered()
        let second = Task { try await recording.stop() }
        first.cancel()
        XCTAssertEqual(sink.finishes, 0, "Do not drain before source teardown finishes")
        gate.release()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(sink.finishes, 1)
    }

    func testErrorDuringSourceTeardownCannotBecomeSuccessfulArchive() async throws {
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink, stopEvent: .failed)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        try await recording.start()
        await assertFailure(recording, .captureFailed("Capture failed"))
        XCTAssertEqual(sink.finishes, 0)
    }

    func testReleasingOwnerStopsCaptureAndCancelsRecording() async throws {
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink)
        let session = try RecordingSession(sink: sink)
        var recording: CaptureRecording? = CaptureRecording(source: source, session: session)
        weak let owner = recording
        try await recording!.start()
        recording = nil
        XCTAssertNil(owner)
        let deadline = ContinuousClock.now + .seconds(1)
        while source.stops == 0 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(session.snapshot.failure, .cancelled)
    }

    func testFailedAdmissionAutomaticallyStopsSourceAndPreservesOverflowReason() async throws {
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink)
        let session = try RecordingSession(sink: sink, maxBytes: 1)
        let recording = CaptureRecording(source: source, session: session)
        do { try await recording.start(); XCTFail("Oversized source sample must fail") } catch {}
        await assertFailure(recording, .overflow)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(sink.count, 0)
    }

    func testStopBeforeStartDoesNotConsumeSourceAndSecondStartIsRejected() async throws {
        let sink = CaptureSink()
        let source = CaptureFixture(sink: sink)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink))
        await assertFailure(recording, .invalidState)
        try await recording.start()
        do { try await recording.start(); XCTFail("One-use owner") }
        catch { XCTAssertEqual(error as? RecordingSessionError, .invalidState) }
        _ = try await recording.stop()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 1)
    }

    func testPublishingCanAttachAfterCaptureStartsAndFailureNeverStopsArchive() async throws {
        let sink = CaptureSink(), publisher = CapturePublisher(appendFails: true)
        let source = CaptureFixture(sink: sink)
        let tap = PublishingTap()
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink), publishingTap: tap)
        let publishing = try PublishingSession(publisher: publisher)
        try await recording.start()
        try await publishing.start()
        XCTAssertTrue(tap.attach(publishing))
        source.sample(12)
        let deadline = ContinuousClock.now + .seconds(2)
        while publishing.snapshot.failure == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(publishing.snapshot.failure, .appendFailed)
        XCTAssertEqual(recording.snapshot.state, .recording)
        source.sample(13)
        await publishing.stop()
        source.sample(14)
        _ = try await recording.stop()
        XCTAssertEqual(sink.count, 5)
        XCTAssertEqual(recording.snapshot.state, .finished)
        XCTAssertEqual(source.stops, 1)
    }

    func testCaptureShutdownClosesTapAndLateCallbacksWithoutOwningPublishingStop() async throws {
        let sink = CaptureSink(), publisher = CapturePublisher()
        let source = CaptureFixture(sink: sink)
        let tap = PublishingTap()
        let publishing = try PublishingSession(publisher: publisher)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink), publishingTap: tap)
        try await publishing.start()
        XCTAssertTrue(tap.attach(publishing))
        try await recording.start()
        _ = try await recording.stop()
        XCTAssertEqual(publishing.snapshot.state, .publishing)
        let admitted = publishing.snapshot.queue.acceptedCount
        source.lateSample(99)
        XCTAssertFalse(tap.offer(try captureAudio(98)))
        XCTAssertFalse(tap.attach(publishing), "A closed recording tap cannot be reused by another capture")
        XCTAssertEqual(publishing.snapshot.queue.acceptedCount, admitted)
        XCTAssertEqual(recording.snapshot.state, .finished)
        await publishing.stop()
    }

    func testArchiveAdmissionFailureDoesNotForwardRejectedSampleToPublisher() async throws {
        let sink = CaptureSink(), publisher = CapturePublisher()
        let source = CaptureFixture(sink: sink)
        let tap = PublishingTap()
        let publishing = try PublishingSession(publisher: publisher)
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink, maxBytes: 1), publishingTap: tap)
        try await publishing.start()
        tap.attach(publishing)
        do { try await recording.start(); XCTFail("Expected archive overflow") } catch {}
        XCTAssertEqual(publishing.snapshot.queue.acceptedCount, 0)
        XCTAssertEqual(publishing.snapshot.state, .publishing)
        await assertFailure(recording, .overflow)
        await publishing.stop()
    }

    private func assertFailure(_ recording: CaptureRecording, _ failure: RecordingSessionError) async {
        do { _ = try await recording.stop(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? RecordingSessionError, failure) }
    }
}

private final class CaptureFixture: CaptureSource, @unchecked Sendable {
    let origin = CMTime(value: 10, timescale: 1)
    private let lock = NSLock()
    private var callbacks: CaptureSourceCallbacks?
    private var oldCallbacks: CaptureSourceCallbacks?
    private var startCount = 0
    private var stopCount = 0
    let sink: CaptureSink
    let startFails: Bool
    let prepareGate: CaptureGate?
    let stopGate: CaptureGate?
    let prepareFails: Bool
    let prepareEvent: CaptureSourceEvent?
    let stopEvent: CaptureSourceEvent?
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    init(sink: CaptureSink, startFails: Bool = false, prepareGate: CaptureGate? = nil,
         stopGate: CaptureGate? = nil, prepareFails: Bool = false,
         prepareEvent: CaptureSourceEvent? = nil, stopEvent: CaptureSourceEvent? = nil) {
        self.sink = sink; self.startFails = startFails; self.prepareGate = prepareGate
        self.stopGate = stopGate; self.prepareFails = prepareFails
        self.prepareEvent = prepareEvent; self.stopEvent = stopEvent
    }
    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        lock.withLock { self.callbacks = callbacks; oldCallbacks = callbacks }
        callbacks.sample(try captureAudio(9)) // Not admitted before the explicit origin/start.
        await prepareGate?.block()
        if let prepareEvent { callbacks.event(prepareEvent) }
        if prepareFails { throw RecordingSessionError.invalidState }
        return origin
    }
    func start() async throws {
        lock.withLock { startCount += 1 }
        XCTAssertEqual(sink.origin, origin)
        if startFails { throw RecordingSessionError.invalidState }
        lock.withLock { callbacks }?.sample(try captureAudio(10))
    }
    func stop() async {
        let detached = lock.withLock { stopCount += 1; let result = callbacks; callbacks = nil; return result }
        if starts > 0, !startFails { detached?.sample(try! captureAudio(11)) }
        await stopGate?.block()
        if let stopEvent { detached?.event(stopEvent) }
        sink.markSourceStopped()
    }
    func event(_ event: CaptureSourceEvent) { lock.withLock { callbacks }?.event(event) }
    func sample(_ second: Int64) { lock.withLock { callbacks }?.sample(try! captureAudio(second)) }
    func lateSample(_ second: Int64) { lock.withLock { oldCallbacks }?.sample(try! captureAudio(second)) }
    func lateFailure() { lock.withLock { oldCallbacks }?.event(.failed) }
}

private final class CaptureSink: RecordingArchiveSink, @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: CMTime?
    private var samples = 0
    private var finishCount = 0
    private var sourceStopped = false
    private var observedStopped = false
    var origin: CMTime? { lock.withLock { startTime } }
    var count: Int { lock.withLock { samples } }
    var finishes: Int { lock.withLock { finishCount } }
    var stoppedBeforeFinish: Bool { lock.withLock { observedStopped } }
    func markSourceStopped() { lock.withLock { sourceStopped = true } }
    func start(at timestamp: CMTime) throws { lock.withLock { startTime = timestamp } }
    func append(_ sample: CapturedMediaSample) throws -> Bool { lock.withLock { samples += 1 }; return true }
    func finish() async throws -> RecoveredArchive {
        lock.withLock { finishCount += 1; observedStopped = sourceStopped }
        return RecoveredArchive(directory: URL(fileURLWithPath: "/unused"), profile: ArchiveProfile(), segments: [])
    }
    func cancel() {}
}

private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() async {
        await withCheckedContinuation { pending in
            let immediate = lock.withLock {
                entered = true
                if released { return true }
                continuation = pending
                return false
            }
            if immediate { pending.resume() }
        }
    }
    func waitUntilEntered() async { while !lock.withLock({ entered }) { await Task.yield() } }
    func release() {
        let pending = lock.withLock { released = true; let result = continuation; continuation = nil; return result }
        pending?.resume()
    }
}

private func captureAudio(_ second: Int64) throws -> CapturedMediaSample {
    var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
        mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format), noErr)
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: 2, flags: 0, blockBufferOut: &block), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: second, timescale: 1), decodeTimeStamp: .invalid)
    var sampleSize = 2
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: try XCTUnwrap(format), sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .audio)
}

private actor CapturePublisher: MediaPublisher {
    private var active = false
    let appendFails: Bool
    init(appendFails: Bool = false) { self.appendFails = appendFails }
    var isPublishing: Bool { active }
    func start() async throws { active = true }
    func append(_ sample: CapturedMediaSample) async throws {
        if appendFails { throw PublishingSessionError.appendFailed }
    }
    func stop() async { active = false }
}

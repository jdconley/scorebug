@preconcurrency import AVFoundation
import XCTest
@testable import ScorebugMedia

@MainActor final class CaptureVideoObservationTests: XCTestCase {
    func testOnlyAdmittedReadyVideoCallbacksAreObservedBeforeAndAfterAudio() async throws {
        let observations = try observationOwner()
        let sink = ObservationArchiveSink()
        let source = ObservationCaptureSource(sink: sink)
        let publishing = try PublishingSession(publisher: ObservationPublisher())
        let tap = PublishingTap()
        XCTAssertTrue(tap.attach(publishing, observations: observations))
        let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink), publishingTap: tap)
        try await recording.start()
        XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, 1,
                       "Preparation video must remain outside capture admission")
        source.send(try observationAudio())
        source.send(try observationVideo(11))
        source.send(try observationAudio())
        source.send(try observationVideo(12))
        XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, 3)
        XCTAssertEqual(observations.snapshot.current.captureVideo.firstSourcePTS, CMTime(value: 10, timescale: 1))
        XCTAssertEqual(observations.snapshot.current.captureVideo.lastSourcePTS, CMTime(value: 12, timescale: 1))
        XCTAssertEqual(observations.snapshot.current.encodedVideo.callbackCount, 0)
        _ = try await recording.stop()
        source.send(try observationVideo(99))
        XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, 3)
        XCTAssertEqual(sink.count, 6, "Source quiescence still delivers its final archive sample")
        XCTAssertTrue(sink.stoppedBeforeFinish)
        XCTAssertFalse(observations.snapshot.isClosed, "Controller owns observation closure after encoder drain")
        await publishing.stop()
    }

    func testCaptureObservationDoesNotWaitForPreparedOrStartingPublisher() async throws {
        for starting in [false, true] {
            let observations = try observationOwner()
            let gate = ObservationStartGate()
            let publisher = ObservationPublisher(startGate: gate)
            let publishing = try PublishingSession(publisher: publisher)
            let tap = PublishingTap()
            XCTAssertTrue(tap.attach(publishing, observations: observations))
            let startup: Task<Void, Error>? = starting ? Task { try await publishing.start() } : nil
            if starting { await gate.waitUntilEntered() }
            let sink = ObservationArchiveSink()
            let source = ObservationCaptureSource(sink: sink)
            let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink), publishingTap: tap)
            try await recording.start()
            source.send(try observationVideo(11))
            XCTAssertEqual(publishing.snapshot.state, starting ? .starting : .prepared)
            XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, 2)
            XCTAssertEqual(publishing.snapshot.queue.acceptedCount, 0)
            let appends = await publisher.appends
            XCTAssertEqual(appends, 0)
            _ = try await recording.stop()
            XCTAssertEqual(sink.count, 3)
            XCTAssertTrue(sink.stoppedBeforeFinish)
            gate.release()
            try await startup?.value
            await publishing.stop()
        }
    }

    func testRejectedArchiveVideoIsStillObservedWithoutChangingFailureOrTeardown() async throws {
        for observed in [false, true] {
            let observations = try observationOwner()
            let publishing = try PublishingSession(publisher: ObservationPublisher())
            try await publishing.start()
            let tap = PublishingTap()
            tap.attach(publishing, observations: observed ? observations : nil)
            let sink = ObservationArchiveSink()
            let source = ObservationCaptureSource(sink: sink)
            let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink, maxBytes: 1), publishingTap: tap)
            do { try await recording.start(); XCTFail("Expected overflow") }
            catch { XCTAssertEqual(error as? RecordingSessionError, .overflow) }
            do { _ = try await recording.stop(); XCTFail("Expected overflow") }
            catch { XCTAssertEqual(error as? RecordingSessionError, .overflow) }
            XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, observed ? 1 : 0,
                           "The rejected video callback must be observed before archive admission fails")
            XCTAssertEqual(recording.snapshot.failure, .overflow)
            XCTAssertEqual(source.stops, 1)
            XCTAssertEqual(sink.count, 0)
            XCTAssertEqual(sink.finishes, 0)
            XCTAssertEqual(sink.cancels, 1)
            XCTAssertEqual(publishing.snapshot.queue.acceptedCount, 0)
            XCTAssertEqual(publishing.snapshot.state, .publishing)
            await publishing.stop()
        }
    }

    func testClosedOwnerAndInvalidPTSObservationDoNotGateArchiveOrPublishing() async throws {
        for closed in [false, true] {
            let observations = try observationOwner()
            if closed { observations.close() }
            let publishing = try PublishingSession(publisher: ObservationPublisher())
            try await publishing.start()
            let tap = PublishingTap()
            tap.attach(publishing, observations: observations)
            let sink = ObservationArchiveSink()
            let source = ObservationCaptureSource(sink: sink)
            let recording = CaptureRecording(source: source, session: try RecordingSession(sink: sink), publishingTap: tap)
            try await recording.start()
            source.send(try observationVideo(11, invalidPTS: true))
            XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, closed ? 0 : 2)
            XCTAssertEqual(observations.snapshot.current.captureVideo.invalidSourcePTSCount, closed ? 0 : 1)
            XCTAssertEqual(publishing.snapshot.queue.acceptedCount, 2)
            _ = try await recording.stop()
            XCTAssertEqual(recording.snapshot.state, .finished)
            XCTAssertEqual(sink.count, 3)
            XCTAssertTrue(sink.stoppedBeforeFinish)
            await publishing.stop()
        }
    }

    func testReplacementBetweenObservationAndArchiveAdmissionCannotRerouteOldCallback() async throws {
        let oldOwner = try observationOwner(), newOwner = try observationOwner()
        let old = try PublishingSession(publisher: ObservationPublisher())
        let replacement = try PublishingSession(publisher: ObservationPublisher())
        try await old.start()
        try await replacement.start()
        let archive = try RecordingSession(sink: ObservationArchiveSink())
        try await archive.start(at: CMTime(value: 10, timescale: 1))
        let tap = PublishingTap()
        tap.attach(old, observations: oldOwner)
        let oldSample = try observationVideo(10)
        let resolved = try XCTUnwrap(tap.beginCapture(oldSample))
        XCTAssertEqual(oldOwner.snapshot.current.captureVideo.callbackCount, 1)

        // Deterministic interleaving at the real callback boundary: observation
        // has returned, archive admission and publication are still outstanding.
        let attached = await Task.detached { tap.attach(replacement, observations: newOwner) }.value
        XCTAssertTrue(attached)
        tap.detach(old)
        XCTAssertTrue(archive.offer(oldSample))
        XCTAssertFalse(resolved.offer(oldSample), "Replacement synchronously invalidates old publication admission")
        XCTAssertEqual(old.snapshot.queue.acceptedCount, 0)
        XCTAssertEqual(replacement.snapshot.queue.acceptedCount, 0)
        XCTAssertEqual(oldOwner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertEqual(newOwner.snapshot.current.captureVideo.callbackCount, 0)

        let newSample = try observationVideo(11)
        let newResolved = try XCTUnwrap(tap.beginCapture(newSample))
        XCTAssertTrue(archive.offer(newSample))
        XCTAssertTrue(newResolved.offer(newSample), "Stale detach must not remove the replacement")
        XCTAssertEqual(replacement.snapshot.queue.acceptedCount, 1)
        XCTAssertEqual(newOwner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertEqual(newOwner.snapshot.current.captureVideo.firstSourcePTS, CMTime(value: 11, timescale: 1))
        XCTAssertEqual(oldOwner.snapshot.current.captureVideo.lastSourcePTS, CMTime(value: 10, timescale: 1))
        XCTAssertNotEqual(oldOwner.snapshot.scope, newOwner.snapshot.scope)
        XCTAssertFalse(oldOwner.snapshot.isClosed)
        XCTAssertTrue(oldOwner.observe(.encodedVideo, sourcePTS: oldSample.sampleBuffer.presentationTimeStamp),
                      "Encoder drain may still report to its old owner until controller closure")
        XCTAssertEqual(newOwner.snapshot.current.encodedVideo.callbackCount, 0)
        _ = try await archive.stop()
        XCTAssertEqual(archive.snapshot.writtenSamples, 2)
        await old.stop()
        await replacement.stop()
    }

    func testDetachInvalidatesResolvedPublicationEvenWhenSameSessionReattaches() async throws {
        let oldOwner = try observationOwner(), newOwner = try observationOwner()
        let session = try PublishingSession(publisher: ObservationPublisher())
        try await session.start()
        let tap = PublishingTap()
        tap.attach(session, observations: oldOwner)
        let sample = try observationVideo(10)
        let resolved = try XCTUnwrap(tap.beginCapture(sample))
        await Task.detached { tap.detach(session) }.value
        XCTAssertFalse(resolved.offer(sample))
        XCTAssertNil(tap.beginCapture(sample))
        XCTAssertTrue(tap.attach(session, observations: newOwner))
        XCTAssertFalse(resolved.offer(sample), "A new attachment cannot revive an old callback")
        XCTAssertEqual(session.snapshot.queue.acceptedCount, 0)
        XCTAssertEqual(oldOwner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertEqual(newOwner.snapshot.current.captureVideo.callbackCount, 0)
        let fresh = try XCTUnwrap(tap.beginCapture(sample))
        XCTAssertTrue(fresh.offer(sample))
        XCTAssertEqual(session.snapshot.queue.acceptedCount, 1)
        XCTAssertEqual(newOwner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertFalse(oldOwner.snapshot.isClosed)
        await session.stop()
    }

    func testCloseInvalidatesResolvedPublicationAndPermanentlyRejectsLateAttachment() async throws {
        let owner = try observationOwner(), lateOwner = try observationOwner()
        let session = try PublishingSession(publisher: ObservationPublisher())
        let lateSession = try PublishingSession(publisher: ObservationPublisher())
        try await session.start()
        let tap = PublishingTap()
        tap.attach(session, observations: owner)
        let sample = try observationVideo(10)
        let resolved = try XCTUnwrap(tap.beginCapture(sample))
        await Task.detached { tap.close() }.value
        XCTAssertFalse(resolved.offer(sample))
        XCTAssertFalse(tap.offer(sample))
        XCTAssertFalse(tap.attach(lateSession, observations: lateOwner))
        XCTAssertNil(tap.beginCapture(sample))
        XCTAssertFalse(resolved.offer(sample))
        XCTAssertEqual(session.snapshot.queue.acceptedCount, 0)
        XCTAssertEqual(session.snapshot.state, .publishing, "Tap closure does not stop a publisher")
        XCTAssertEqual(owner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertEqual(lateOwner.snapshot.current.captureVideo.callbackCount, 0)
        XCTAssertFalse(owner.snapshot.isClosed)
        XCTAssertFalse(lateOwner.snapshot.isClosed)
        XCTAssertTrue(owner.observe(.encodedVideo, sourcePTS: sample.sampleBuffer.presentationTimeStamp))
        await session.stop()
        await lateSession.stop()
    }

    func testDirectTapOffersDoNotPretendToBeCaptureCallbacks() async throws {
        let observations = try observationOwner()
        let publishing = try PublishingSession(publisher: ObservationPublisher())
        try await publishing.start()
        let tap = PublishingTap()
        tap.attach(publishing, observations: observations)
        XCTAssertTrue(tap.offer(try observationVideo(10)))
        XCTAssertEqual(observations.snapshot.current.captureVideo.callbackCount, 0)
        XCTAssertEqual(observations.snapshot.current.encodedVideo.callbackCount, 0)
        await publishing.stop()
    }
}

private func observationOwner() throws -> VideoFrameObservationOwner {
    try VideoFrameObservationOwner(scope: VideoFrameObservationScope(recordingID: "capture-test", matchID: "match",
        broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1), windowDuration: 86400)
}

private final class ObservationCaptureSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: CaptureSourceCallbacks?
    private var stopCount = 0
    let sink: ObservationArchiveSink
    var stops: Int { lock.withLock { stopCount } }
    init(sink: ObservationArchiveSink) { self.sink = sink }
    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        lock.withLock { self.callbacks = callbacks }
        callbacks.sample(try observationVideo(9))
        return CMTime(value: 10, timescale: 1)
    }
    func start() async throws { send(try observationVideo(10)) }
    func stop() async {
        lock.withLock { stopCount += 1 }
        send(try! observationVideo(13))
        sink.markStopped()
    }
    func send(_ sample: CapturedMediaSample) { lock.withLock { callbacks }?.sample(sample) }
}

private final class ObservationArchiveSink: RecordingArchiveSink, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0, finishCount = 0, cancelCount = 0
    private var stopped = false, finishedAfterStop = false
    var count: Int { lock.withLock { samples } }
    var finishes: Int { lock.withLock { finishCount } }
    var cancels: Int { lock.withLock { cancelCount } }
    var stoppedBeforeFinish: Bool { lock.withLock { finishedAfterStop } }
    func markStopped() { lock.withLock { stopped = true } }
    func start(at timestamp: CMTime) throws {}
    func append(_ sample: CapturedMediaSample) throws -> Bool { lock.withLock { samples += 1 }; return true }
    func finish() async throws -> RecoveredArchive {
        lock.withLock { finishCount += 1; finishedAfterStop = stopped }
        return RecoveredArchive(directory: URL(fileURLWithPath: "/unused"), profile: ArchiveProfile(), segments: [])
    }
    func cancel() { lock.withLock { cancelCount += 1 } }
}

private actor ObservationPublisher: MediaPublisher {
    let startGate: ObservationStartGate?
    private var active = false
    private(set) var appends = 0
    init(startGate: ObservationStartGate? = nil) { self.startGate = startGate }
    var isPublishing: Bool { active }
    func start() async throws { await startGate?.block(); active = true }
    func append(_ sample: CapturedMediaSample) async throws { appends += 1 }
    func stop() async { active = false; startGate?.release() }
}

private final class ObservationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false, released = false
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
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !lock.withLock({ entered }), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(lock.withLock { entered })
    }
    func release() {
        let pending = lock.withLock { released = true; let result = continuation; continuation = nil; return result }
        pending?.resume()
    }
}

private func observationVideo(_ second: Int64, invalidPTS: Bool = false) throws -> CapturedMediaSample {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: invalidPTS ? .invalid : CMTime(value: second, timescale: 1), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
}

private func observationAudio() throws -> CapturedMediaSample {
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
        presentationTimeStamp: CMTime(value: 10, timescale: 1), decodeTimeStamp: .invalid)
    var size = 2
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: try XCTUnwrap(format), sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .audio)
}


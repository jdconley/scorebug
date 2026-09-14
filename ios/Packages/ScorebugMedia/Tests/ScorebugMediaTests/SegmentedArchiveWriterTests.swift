@preconcurrency import AVFoundation
import XCTest
@testable import ScorebugMedia

@MainActor final class SegmentedArchiveWriterTests: XCTestCase {
    #if DEBUG
    func testDiagnosticsCaptureActualPersistenceAtPressureAndCloseBeforeLateDelegateEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PersistenceGate()
        defer { gate.release() }
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "persist-pressure", now: clock.now)
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let writer = try SegmentedArchiveWriter(directory: root, profile: profile, storeFailureInjection: { point in
            if case .beforeCommit = point {
                gate.blockOnce()
                throw ArchiveWriterError.storageFailed
            }
        })
        defer { gate.release(); writer.cancel() }
        XCTAssertTrue(writer.attachArchivePressureDiagnostics(owner))
        XCTAssertFalse(writer.attachArchivePressureDiagnostics(owner))
        // Model the protocol-supported case where cancellation does not join the
        // native delegate. This Mac's native cancelWriting may itself join it.
        let session = try RecordingSession(sink: NonJoiningNativeSink(writer: writer), maxItems: 2)
        XCTAssertTrue(session.attachArchivePressureDiagnostics(owner))
        try await session.start(at: .zero)
        XCTAssertFalse(writer.attachArchivePressureDiagnostics(ArchivePressureDiagnostics(recordingID: "late")))
        var offered = 0
        outer: for frame in 0..<90 {
            for (buffer, kind) in [(try makeVideoSample(frame: frame, profile: profile), CapturedMediaSample.Kind.video),
                                   (try makeAudioSample(frame: frame, profile: profile), CapturedMediaSample.Kind.audio)] {
                if gate.entered { break outer }
                XCTAssertTrue(session.offer(try CapturedMediaSample(sampleBuffer: buffer, kind: kind)))
                offered += 1
                let deadline = ContinuousClock.now + .seconds(5)
                while session.snapshot.writtenSamples < offered && !gate.entered && ContinuousClock.now < deadline {
                    await Task.yield()
                }
                XCTAssertTrue(session.snapshot.writtenSamples == offered || gate.entered)
            }
        }
        XCTAssertTrue(gate.entered, "Actual AVAssetWriter delegate must reach the existing store failure-injection seam")
        clock.advance(2)
        let sample = try CapturedMediaSample(sampleBuffer: makeAudioSample(frame: 91, profile: profile), kind: .audio)
        // The delegate is blocked in persistence; append readiness may or may not also be blocked.
        for _ in 0..<100 where session.snapshot.failure == nil { _ = session.offer(sample) }
        XCTAssertEqual(session.snapshot.failure, .overflow)
        let failure = try XCTUnwrap(owner.snapshot.firstFailure)
        XCTAssertEqual(failure.observations.activePersistences.count, 1)
        XCTAssertEqual(failure.observations.activePersistences.first?.elapsed, 2)
        XCTAssertNil(failure.observations.activePersistences.first?.result)
        do { _ = try await session.stop(); XCTFail("Overflow must win") } catch {}
        let closed = owner.close(snapshot: session.snapshot)
        XCTAssertEqual(closed.profile, profile)
        XCTAssertTrue(closed.coverage.persistence)
        XCTAssertEqual(closed.observations.activePersistences.count, 1)
        let reads = clock.reads
        gate.release()
        await fulfillment(of: [gate.exited], timeout: 5)
        // Observe receiver failure only after store cleanup and the late diagnostic
        // end have returned, so temporary-directory removal cannot race storage.
        let delegateDeadline = ContinuousClock.now + .seconds(5)
        while writer.snapshot.failure != .storageFailed && ContinuousClock.now < delegateDeadline { await Task.yield() }
        XCTAssertEqual(writer.snapshot.failure, .storageFailed)
        clock.advance(5)
        XCTAssertEqual(owner.snapshot, closed)
        XCTAssertEqual(owner.snapshot.firstFailure, failure)
        XCTAssertEqual(clock.reads, reads)
        // Complete real writer cleanup after releasing the storage callback.
        writer.cancel()
    }

    func testSnapshotWaitingForDurableStoreDoesNotHoldWriterLifecycleLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PersistenceGate()
        defer { gate.release() }
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let store = try ArchiveSegmentStore(directory: root.appendingPathComponent("store"),
            profile: profile, availableBytes: { Int64.max }, failureInjection: { point in
                if case .beforeCommit = point { gate.blockOnce() }
            })
        let writer = try SegmentedArchiveWriter(directory: root.appendingPathComponent("writer"), profile: profile)
        let persisted = expectation(description: "durable append joined")
        DispatchQueue.global().async {
            defer { persisted.fulfill() }
            do { try store.append(data: Data([1, 2, 3]), kind: .initialization) }
            catch { XCTFail("Unexpected store error: \(error)") }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(gate.entered)
        let readEntered = expectation(description: "snapshot entered actual store read")
        let snapshotReturned = expectation(description: "snapshot returned after durable append")
        let result = SnapshotResult()
        DispatchQueue.global().async {
            result.set(writer.snapshot(readSegments: {
                readEntered.fulfill()
                return store.segments
            }))
            snapshotReturned.fulfill()
        }
        await fulfillment(of: [readEntered], timeout: 5)
        XCTAssertNil(result.value, "Store remains gated before commit")
        let lifecycleReturned = DispatchSemaphore(value: 0)
        let lifecycleJoined = expectation(description: "lifecycle operation joined")
        DispatchQueue.global().async {
            defer { lifecycleReturned.signal(); lifecycleJoined.fulfill() }
            // This exercises the real lifecycle lock but rejects before making
            // any AVFoundation call; encoder readiness cannot affect the result.
            do {
                try writer.start(at: .invalid)
                XCTFail("Invalid start unexpectedly succeeded")
            } catch {
                XCTAssertEqual(error as? ArchiveWriterError, .invalidTimestamp)
            }
        }
        let prompt = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: lifecycleReturned.wait(timeout: .now() + 1) == .success)
            }
        }
        XCTAssertTrue(prompt, "A storage snapshot must not hold the lifecycle lock while waiting for persistence")
        gate.release()
        await fulfillment(of: [persisted, snapshotReturned, lifecycleJoined], timeout: 5)
        let snapshot = try XCTUnwrap(result.value)
        XCTAssertEqual(snapshot.state, .prepared)
        XCTAssertEqual(snapshot.videoFrames, 0)
        XCTAssertEqual(snapshot.acceptedDuration, 0)
        XCTAssertEqual(snapshot.segments, store.segments)
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: store.directory).segments, snapshot.segments)
    }

    func testUnattachedDiagnosticsClockIsNeverReadByNativeWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PressureClock()
        let owner = ArchivePressureDiagnostics(recordingID: "unused-writer", now: clock.now)
        let reads = clock.reads
        let writer = try SegmentedArchiveWriter(directory: root,
            profile: ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1))
        try writer.start(at: .zero)
        try await appendGeneratedMedia(to: writer)
        _ = try await writer.finish()
        XCTAssertEqual(clock.reads, reads)
        XCTAssertFalse(owner.snapshot.coverage.persistence)
    }
    #endif

    func testFinishRejectsRecordingWithoutBothTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SegmentedArchiveWriter(directory: root)
        try archive.start(at: .zero)
        do {
            _ = try await archive.finish()
            XCTFail("An empty recording must not be reported as a finished archive")
        } catch {
            XCTAssertEqual(error as? ArchiveWriterError, .missingMedia)
            XCTAssertEqual(archive.snapshot.state, .failed)
            XCTAssertEqual(archive.snapshot.failure, .missingMedia)
        }
    }

    func testRejectsInvalidProfileBeforeCreatingArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = ArchiveProfile(width: 1919)
        XCTAssertThrowsError(try SegmentedArchiveWriter(directory: root, profile: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAppendRequiresExplicitSharedTimestampOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try SegmentedArchiveWriter(directory: root, profile: ArchiveProfile())
        XCTAssertThrowsError(try archive.start(at: .invalid))
        XCTAssertEqual(archive.snapshot.state, .prepared)
        try archive.start(at: .zero)
        XCTAssertThrowsError(try archive.start(at: .zero))
        archive.cancel()
        XCTAssertEqual(archive.snapshot.state, .cancelled)
        XCTAssertTrue(archive.snapshot.segments.isEmpty)
    }

    func testCancelAtFinishInitiationIsSerializedAndPreservesCommittedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let finishEntered = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let cancelAttempted = DispatchSemaphore(value: 0)
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let archive = try SegmentedArchiveWriter(directory: root, profile: profile, finishCheckpoint: { checkpoint in
            guard case .beforeInitiation = checkpoint else { return }
            finishEntered.signal()
            XCTAssertEqual(cancelAttempted.wait(timeout: .now() + 5), .success)
            // Cancellation must wait until AVAssetWriter has accepted finishWriting.
            // In the old implementation it returns here, and finishWriting then aborts.
            XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.2), .timedOut)
        })
        try archive.start(at: .zero)
        try await appendGeneratedMedia(to: archive)
        let committed = try ArchiveSegmentStore.recover(directory: root).segments
        XCTAssertTrue(committed.contains { $0.kind == .media })
        let originalPayloads = try committed.map {
            try Data(contentsOf: root.appendingPathComponent(String(format: "%06d.segment/payload.bin", $0.sequence)))
        }
        let cancelled = expectation(description: "cancel returns")
        DispatchQueue.global().async {
            guard finishEntered.wait(timeout: .now() + 5) == .success else {
                XCTFail("finish never reached its initiation boundary")
                cancelled.fulfill()
                return
            }
            cancelAttempted.signal()
            archive.cancel()
            cancelReturned.signal()
            cancelled.fulfill()
        }
        let finished = expectation(description: "finish resolves")
        let result = FinishResult()
        Task.detached {
            do { result.set(.success(try await archive.finish())) }
            catch { result.set(.failure(error)) }
            finished.fulfill()
        }
        await fulfillment(of: [cancelled, finished], timeout: 10)
        switch try XCTUnwrap(result.value) {
        case .success(let recovered):
            // Either operation may win after initiation, but cancellation cannot
            // be reported as successful finalization.
            XCTAssertEqual(archive.snapshot.state, .finished)
            XCTAssertNil(archive.snapshot.failure)
            XCTAssertFalse(recovered.segments.isEmpty)
        case .failure(let error):
            XCTAssertEqual(error as? ArchiveWriterError, .encodingFailed)
            XCTAssertEqual(archive.snapshot.state, .cancelled)
        }
        let recovered = try ArchiveSegmentStore.recover(directory: root)
        XCTAssertEqual(Array(recovered.segments.prefix(committed.count)), committed)
        for (segment, payload) in zip(committed, originalPayloads) {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(
                String(format: "%06d.segment/payload.bin", segment.sequence))), payload)
        }
    }

    func testLateNativeCompletionDoesNotUndoCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let completionEntered = DispatchSemaphore(value: 0)
        let allowCompletion = DispatchSemaphore(value: 0)
        let completionProcessed = expectation(description: "late native completion is processed")
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let archive = try SegmentedArchiveWriter(directory: root, profile: profile, finishCheckpoint: { checkpoint in
            switch checkpoint {
            case .beforeInitiation: break
            case .beforeCompletion:
                completionEntered.signal()
                XCTAssertEqual(allowCompletion.wait(timeout: .now() + 5), .success)
            case .afterCompletion:
                completionProcessed.fulfill()
            }
        })
        try archive.start(at: .zero)
        try await appendGeneratedMedia(to: archive)
        let committed = try ArchiveSegmentStore.recover(directory: root).segments
        let cancelled = expectation(description: "cancel returns before completion is processed")
        DispatchQueue.global().async {
            defer { allowCompletion.signal(); cancelled.fulfill() }
            guard completionEntered.wait(timeout: .now() + 5) == .success else {
                XCTFail("native finish callback never arrived")
                return
            }
            archive.cancel()
        }
        let finished = expectation(description: "cancelled finish resolves exactly once")
        let result = FinishResult()
        Task.detached {
            do { result.set(.success(try await archive.finish())) }
            catch { result.set(.failure(error)) }
            finished.fulfill()
        }
        await fulfillment(of: [cancelled, finished, completionProcessed], timeout: 10)
        switch try XCTUnwrap(result.value) {
        case .success: XCTFail("A late native completion must not turn cancellation into success")
        case .failure(let error): XCTAssertEqual(error as? ArchiveWriterError, .encodingFailed)
        }
        XCTAssertEqual(archive.snapshot.state, .cancelled)
        XCTAssertEqual(archive.snapshot.failure, .encodingFailed)
        XCTAssertEqual(Array(try ArchiveSegmentStore.recover(directory: root).segments.prefix(committed.count)), committed)
    }

    func testAcceptedDurationProgressesWithAcceptedSamplesAndSurvivesFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let writer = try SegmentedArchiveWriter(directory: root, profile: profile)
        XCTAssertEqual(writer.acceptedDuration, 0)
        try writer.start(at: .zero)
        XCTAssertEqual(writer.acceptedDuration, 0)
        try await appendGeneratedMedia(to: writer)
        XCTAssertEqual(writer.acceptedDuration, 3, accuracy: 0.000001)
        _ = try await writer.finish()
        XCTAssertEqual(writer.acceptedDuration, 3, accuracy: 0.000001)
        writer.cancel()
        XCTAssertEqual(writer.acceptedDuration, writer.snapshot.acceptedDuration)
    }

    func testSnapshotKeepsPreFinishStateWhileItsSegmentReadIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let writer = try SegmentedArchiveWriter(directory: root, profile: profile)
        try writer.start(at: .zero)
        try await appendGeneratedMedia(to: writer)
        let beforeFinish = writer.snapshot.segments
        let readEntered = expectation(description: "snapshot segment view captured before finish")
        let snapshotReturned = expectation(description: "earlier snapshot returned")
        let releaseRead = DispatchSemaphore(value: 0)
        defer { releaseRead.signal() }
        let result = SnapshotResult()
        DispatchQueue.global().async {
            result.set(writer.snapshot(readSegments: {
                readEntered.fulfill()
                XCTAssertEqual(releaseRead.wait(timeout: .now() + 10), .success)
                return beforeFinish
            }))
            snapshotReturned.fulfill()
        }
        await fulfillment(of: [readEntered], timeout: 5)
        let recovered = try await writer.finish()
        releaseRead.signal()
        await fulfillment(of: [snapshotReturned], timeout: 5)
        let earlier = try XCTUnwrap(result.value)
        XCTAssertEqual(earlier.state, .writing, "An earlier segment view must not be labeled finished")
        XCTAssertEqual(earlier.segments, beforeFinish)
        XCTAssertEqual(writer.snapshot.state, .finished)
        XCTAssertEqual(writer.snapshot.segments, recovered.segments)
    }

    func testFinishCompletesGeneratedVideoAndAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 200_000, segmentDuration: 1)
        let archive = try SegmentedArchiveWriter(directory: root, profile: profile)
        try archive.start(at: .zero)
        try await appendGeneratedMedia(to: archive)
        let finished = expectation(description: "finish resolves with real media")
        let result = FinishResult()
        Task.detached {
            do { result.set(.success(try await archive.finish())) }
            catch { result.set(.failure(error)) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        let recovered = try XCTUnwrap(result.value).get()
        XCTAssertEqual(archive.snapshot.state, .finished)
        XCTAssertNil(archive.snapshot.failure)
        XCTAssertEqual(archive.snapshot.videoFrames, 90)
        XCTAssertEqual(archive.snapshot.audioSamples, 144_000)
        XCTAssertEqual(recovered.segments, archive.snapshot.segments)
        XCTAssertTrue(recovered.segments.contains { $0.kind == .media })
        archive.cancel()
        XCTAssertEqual(archive.snapshot.state, .finished)
    }

    private func appendGeneratedMedia(to archive: SegmentedArchiveWriter) async throws {
        // Three seconds forces at least one real fragment to commit before finish.
        // Samples are generated in memory; no fixture or ignored artifact is needed.
        for frame in 0..<90 {
            let video = try makeVideoSample(frame: frame, profile: archive.profile)
            let audio = try makeAudioSample(frame: frame, profile: archive.profile)
            for (sample, isVideo) in [(video, true), (audio, false)] {
                let deadline = ContinuousClock.now + .seconds(5)
                while try !archive.append(sample, isVideo: isVideo) {
                    guard ContinuousClock.now < deadline else { throw FixtureError.encoderTimedOut }
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !archive.snapshot.segments.contains(where: { $0.kind == .media }) {
            guard ContinuousClock.now < deadline else { throw FixtureError.encoderTimedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeVideoSample(frame: Int, profile: ArchiveProfile) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, profile.width, profile.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? Int32(32 + frame % 180) : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                   imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeAudioSample(frame: Int, profile: ArchiveProfile) throws -> CMSampleBuffer {
        let sampleCount = Int(profile.audioSampleRate) / profile.framesPerSecond
        var description = AudioStreamBasicDescription(mSampleRate: profile.audioSampleRate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: sampleCount * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: sampleCount * 2, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                               dataLength: sampleCount * 2), kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(frame * sampleCount), timescale: 48_000), decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try XCTUnwrap(format), sampleCount: sampleCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

}


private enum FixtureError: Error { case encoderTimedOut }

private final class FinishResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<RecoveredArchive, Error>?
    var value: Result<RecoveredArchive, Error>? { lock.withLock { result } }
    func set(_ value: Result<RecoveredArchive, Error>) { lock.withLock { result = value } }
}

private final class SnapshotResult: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ArchiveWriterSnapshot?
    var value: ArchiveWriterSnapshot? { lock.withLock { snapshot } }
    func set(_ value: ArchiveWriterSnapshot) { lock.withLock { snapshot = value } }
}

#if DEBUG
private struct NonJoiningNativeSink: RecordingArchiveSink {
    let writer: SegmentedArchiveWriter
    func start(at timestamp: CMTime) throws { try writer.start(at: timestamp) }
    func append(_ sample: CapturedMediaSample) throws -> Bool {
        try writer.append(sample.sampleBuffer, isVideo: sample.kind == .video)
    }
    func finish() async throws -> RecoveredArchive { try await writer.finish() }
    func cancel() {} // Permitted by the protocol: diagnostic close cannot assume delegate quiescence.
}

private final class PersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private let semaphore = DispatchSemaphore(value: 0)
    let exited = XCTestExpectation(description: "persistence gate exited")
    var entered: Bool { lock.withLock { didEnter } }
    func blockOnce() {
        let first = lock.withLock { let first = !didEnter; didEnter = true; return first }
        if first {
            XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success)
            exited.fulfill()
        }
    }
    func release() { semaphore.signal() }
}
#endif

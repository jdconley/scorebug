@preconcurrency import AVFoundation
import XCTest
@testable import ScorebugMedia

@MainActor final class SegmentedArchiveWriterTests: XCTestCase {
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

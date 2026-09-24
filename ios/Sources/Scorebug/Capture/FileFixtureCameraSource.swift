#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia

struct FileFixtureStatistics: Sendable {
    var videoFrames: Int64 = 0
    var audioSamples: Int64 = 0
    /// Relative to the original wall/source anchor, before pacing adjustments.
    var maximumSourceLagSeconds = 0.0
}

/// Local, finite test input. As with CaptureSource, its owner serializes
/// prepare/start/stop. One detached pump owns the reader until stop joins it.
/// There is no per-sample task or unbounded queue, and no synthetic fallback.
final class FileFixtureCameraSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let profile: ArchiveProfile
    private let ledger = FileFixtureLedger()
    private var used = false
    private var stopped = false
    private var reader: FileFixtureReader?
    private var callbacks: CaptureSourceCallbacks?
    private var pump: Task<Void, Never>?

    init(url: URL, profile: ArchiveProfile = .init()) { self.url = url; self.profile = profile }
    deinit { pump?.cancel() }
    var statistics: FileFixtureStatistics { ledger.snapshot }

    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        try lock.withLock {
            guard !used else { throw FileFixtureError.invalidState }
            used = true
        }
        do {
            let url = url, profile = profile
            let opened = try await Task.detached { try await FileFixtureReader.open(url: url, profile: profile) }.value
            if Task.isCancelled { opened.cancel(); throw CancellationError() }
            lock.withLock { reader = opened; self.callbacks = callbacks }
            return opened.origin
        } catch {
            callbacks.event(.failed)
            throw (error as? FileFixtureError) ?? FileFixtureError.invalidMedia
        }
    }

    func start() async throws {
        try lock.withLock {
            guard !stopped, pump == nil, let reader, let callbacks else { throw FileFixtureError.invalidState }
            let ledger = ledger
            // Capture the reader/callbacks, never the source owner. Its deinit can
            // therefore cancel this task even if a caller abandons the fixture.
            pump = Task.detached {
                var cadence = FileFixtureCadence(origin: .now)
                do {
                    while true {
                        try Task.checkCancellation()
                        guard let sample = try autoreleasepool(invoking: { try reader.nextSample() }) else {
                            try Task.checkCancellation()
                            callbacks.event(.interrupted)
                            return
                        }
                        let elapsed = (sample.sampleBuffer.presentationTimeStamp - reader.origin).seconds
                        try await ContinuousClock().sleep(until: cadence.deadline(sourceSeconds: elapsed))
                        try Task.checkCancellation()
                        let now = ContinuousClock.now
                        cadence.began(sourceSeconds: elapsed, at: now)
                        ledger.record(sample, lag: cadence.nominalLag(sourceSeconds: elapsed, at: now))
                        callbacks.sample(sample)
                    }
                } catch is CancellationError {
                    // Explicit stop cancels pacing and joins the current callback.
                } catch {
                    callbacks.event(.failed)
                }
            }
        }
    }

    func stop() async {
        let pending = lock.withLock {
            stopped = true; used = true
            return (pump, reader)
        }
        pending.0?.cancel()
        await pending.0?.value
        // Never mutate AVAssetReader concurrently with copyNextSampleBuffer.
        pending.1?.cancel()
        lock.withLock { pump = nil; reader = nil; callbacks = nil }
    }
}

struct FileFixtureCadence {
    let origin: ContinuousClock.Instant
    private var adjustment: Duration = .zero
    init(origin: ContinuousClock.Instant) { self.origin = origin }
    func deadline(sourceSeconds: Double) -> ContinuousClock.Instant {
        origin + .seconds(sourceSeconds) + adjustment
    }
    mutating func began(sourceSeconds: Double, at now: ContinuousClock.Instant) {
        let late = deadline(sourceSeconds: sourceSeconds).duration(to: now)
        if late >= .seconds(1.0 / 30) { adjustment += late }
    }
    func nominalLag(sourceSeconds: Double, at now: ContinuousClock.Instant) -> Double {
        let duration = (origin + .seconds(sourceSeconds)).duration(to: now).components
        return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
}

private final class FileFixtureLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var value = FileFixtureStatistics()
    var snapshot: FileFixtureStatistics { lock.withLock { value } }
    func record(_ sample: CapturedMediaSample, lag: Double) {
        lock.withLock {
            if sample.kind == .video { value.videoFrames += 1 }
            else { value.audioSamples += Int64(sample.sampleBuffer.numSamples) }
            value.maximumSourceLagSeconds = max(value.maximumSourceLagSeconds, lag)
        }
    }
}

private enum FileFixtureError: Error { case invalidState, invalidMedia, invalidTimeline, readerFailed }

/// Ownership transfers from the prepare task to the pump, then to joined teardown.
/// The unchecked conformance permits that transfer, not concurrent reader access.
private final class FileFixtureReader: @unchecked Sendable {
    let origin: CMTime
    private let videoReader: AVAssetReader
    private let audioReader: AVAssetReader
    private let video: AVAssetReaderTrackOutput
    private let audio: AVAssetReaderTrackOutput
    private let profile: ArchiveProfile
    private var nextVideo: CMSampleBuffer?
    private var nextAudio: CMSampleBuffer?
    private let videoOrigin: CMTime
    private let audioOrigin: CMTime
    private var videoCount: Int64 = 0
    private var audioCount: Int64 = 0

    private init(videoReader: AVAssetReader, audioReader: AVAssetReader, video: AVAssetReaderTrackOutput, audio: AVAssetReaderTrackOutput,
                 firstVideo: CMSampleBuffer, firstAudio: CMSampleBuffer, profile: ArchiveProfile) throws {
        self.videoReader = videoReader; self.audioReader = audioReader
        self.video = video; self.audio = audio; self.profile = profile
        nextVideo = firstVideo; nextAudio = firstAudio
        videoOrigin = firstVideo.presentationTimeStamp; audioOrigin = firstAudio.presentationTimeStamp
        guard videoOrigin.isNumeric, audioOrigin.isNumeric, videoOrigin.epoch == 0, audioOrigin.epoch == 0 else { throw FileFixtureError.invalidTimeline }
        origin = min(videoOrigin, audioOrigin)
    }

    static func open(url: URL, profile: ArchiveProfile) async throws -> FileFixtureReader {
        try profile.validate()
        guard url.isFileURL, profile.framesPerSecond == 30, profile.audioSampleRate == 48_000,
              profile.audioChannels == 1,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw FileFixtureError.invalidMedia
        }
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count == 1 else { throw FileFixtureError.invalidMedia }
        let formats = try await videos[0].load(.formatDescriptions)
        let audioFormats = try await audios[0].load(.formatDescriptions)
        let rate = try await videos[0].load(.nominalFrameRate)
        let transform = try await videos[0].load(.preferredTransform)
        guard formats.count == 1, audioFormats.count == 1, abs(rate - 30) < 0.0001,
              transform == .identity, CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormats[0])?.pointee,
              asbd.mSampleRate == 48_000, asbd.mChannelsPerFrame == 1 else { throw FileFixtureError.invalidMedia }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formats[0])
        guard dimensions.width == profile.width, dimensions.height == profile.height else { throw FileFixtureError.invalidMedia }
        if let transfer = CMFormatDescriptionGetExtension(formats[0], extensionKey: kCVImageBufferTransferFunctionKey) as? String {
            guard [kCVImageBufferTransferFunction_ITU_R_709_2 as String, kCVImageBufferTransferFunction_sRGB as String].contains(transfer)
            else { throw FileFixtureError.invalidMedia }
        }
        let videoRange = try await mediaRange(videos[0]), audioRange = try await mediaRange(audios[0])
        // Independent ranges prevent AVAssetReader from synthesizing pixels or
        // silence for a leading empty edit on either track.
        let videoReader = try AVAssetReader(asset: asset)
        let audioReader = try AVAssetReader(asset: asset)
        do {
            let video = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            let audio = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
            guard videoReader.canAdd(video), audioReader.canAdd(audio) else { throw FileFixtureError.invalidMedia }
            videoReader.add(video); audioReader.add(audio)
            videoReader.timeRange = videoRange; audioReader.timeRange = audioRange
            guard videoReader.startReading(), audioReader.startReading(),
                  let firstVideo = video.copyNextSampleBuffer(), let firstAudio = audio.copyNextSampleBuffer()
            else { throw FileFixtureError.readerFailed }
            return try FileFixtureReader(videoReader: videoReader, audioReader: audioReader, video: video, audio: audio,
                                         firstVideo: firstVideo, firstAudio: firstAudio, profile: profile)
        } catch { videoReader.cancelReading(); audioReader.cancelReading(); throw error }
    }

    private static func mediaRange(_ track: AVAssetTrack) async throws -> CMTimeRange {
        let segments = try await track.load(.segments)
        let content = segments.drop(while: { $0.isEmpty })
        guard let first = content.first, let last = content.last,
              content.allSatisfy({ !$0.isEmpty }) else { throw FileFixtureError.invalidTimeline }
        var end = first.timeMapping.target.start
        for segment in content {
            let mapping = segment.timeMapping
            guard mapping.target.start.isNumeric, mapping.target.duration.isNumeric,
                  mapping.target.duration > .zero, mapping.source.duration.isNumeric,
                  CMTimeCompare(mapping.source.duration, mapping.target.duration) == 0,
                  CMTimeCompare(mapping.target.start, end) == 0 else { throw FileFixtureError.invalidTimeline }
            end = mapping.target.end
        }
        return CMTimeRange(start: first.timeMapping.target.start, end: last.timeMapping.target.end)
    }

    func cancel() { videoReader.cancelReading(); audioReader.cancelReading() }

    func nextSample() throws -> CapturedMediaSample? {
        guard nextVideo != nil || nextAudio != nil else {
            guard videoReader.status == .completed, audioReader.status == .completed else { throw FileFixtureError.readerFailed }
            return nil
        }
        let isVideo = nextAudio == nil || (nextVideo != nil && nextVideo!.presentationTimeStamp <= nextAudio!.presentationTimeStamp)
        var buffer = isVideo ? nextVideo! : nextAudio!
        let pts = buffer.presentationTimeStamp
        guard pts.isNumeric, pts.epoch == 0 else { throw FileFixtureError.invalidTimeline }
        let expected = isVideo ? videoOrigin + CMTime(value: videoCount, timescale: 30)
            : audioOrigin + CMTime(value: audioCount, timescale: 48_000)
        guard abs((pts - expected).seconds) <= 0.000_002 else { throw FileFixtureError.invalidTimeline }
        if isVideo {
            guard buffer.numSamples == 1, let pixel = buffer.imageBuffer,
                  CVPixelBufferGetWidth(pixel) == profile.width, CVPixelBufferGetHeight(pixel) == profile.height,
                  CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            else { throw FileFixtureError.invalidMedia }
            videoCount += 1
            nextVideo = video.copyNextSampleBuffer()
        } else {
            guard buffer.numSamples > 0, let format = buffer.formatDescription,
                  let pcm = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  pcm.mFormatID == kAudioFormatLinearPCM, pcm.mSampleRate == 48_000, pcm.mChannelsPerFrame == 1,
                  pcm.mBitsPerChannel == 16, pcm.mBytesPerFrame == 2,
                  pcm.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                  pcm.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0
            else { throw FileFixtureError.invalidMedia }
            // AVAssetReader can return 8192 PCM samples (~171 ms). Delivering
            // them at their first PTS lets audio run ahead of a requested stop.
            // Split to one video period, preserving timing and every PCM value.
            let count = min(buffer.numSamples, 1600)
            if count < buffer.numSamples {
                let whole = buffer
                buffer = try Self.audioSlice(whole, start: 0, count: count)
                nextAudio = try Self.audioSlice(whole, start: count, count: whole.numSamples - count)
            } else { nextAudio = audio.copyNextSampleBuffer() }
            audioCount += Int64(count)
        }
        if [videoReader.status, audioReader.status].contains(where: { $0 == .failed || $0 == .cancelled }) { throw FileFixtureError.readerFailed }
        return try CapturedMediaSample(sampleBuffer: buffer, kind: isVideo ? .video : .audio)
    }

    private static func audioSlice(_ buffer: CMSampleBuffer, start: Int, count: Int) throws -> CMSampleBuffer {
        var output: CMSampleBuffer?
        guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleRange: CFRange(location: start, length: count), sampleBufferOut: &output) == noErr,
              let output else { throw FileFixtureError.invalidMedia }
        return output
    }
}
#endif

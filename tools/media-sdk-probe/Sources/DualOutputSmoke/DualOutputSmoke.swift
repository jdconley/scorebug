@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import SDKProbe

private func emit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private enum Failure: Error { case arguments, missingTracks, reader, archiveOverflow, pcm }

private final class PublisherHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    var isFailed: Bool { lock.withLock { failed } }
    func fail() { lock.withLock { failed = true } }
}

@main struct DualOutputSmoke {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            // Network exercise is deliberately restricted to an owned local sink.
            guard args.count == 3 else { throw Failure.arguments }
            let url: URL?
            if args[2] == "record-only" { url = nil }
            else {
                guard let candidate = URL(string: args[2]), candidate.scheme == "srt",
                      candidate.host == "127.0.0.1", candidate.port != nil else { throw Failure.arguments }
                url = candidate
            }
            try await run(source: URL(fileURLWithPath: args[0]), directory: URL(fileURLWithPath: args[1]), url: url)
        } catch {
            try? emit(["event": "failed", "reason": String(describing: error)])
            exit(1)
        }
    }

    private static func run(source: URL, directory: URL, url: URL?) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.missingTracks }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        let audio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(video), reader.canAdd(audio) else { throw Failure.reader }
        reader.add(video); reader.add(audio)
        guard reader.startReading() else { throw Failure.reader }
        var nextVideo = video.copyNextSampleBuffer()
        var nextAudio = audio.copyNextSampleBuffer()
        guard let firstVideo = nextVideo, let firstAudio = nextAudio else { throw Failure.missingTracks }
        let origin = min(firstVideo.presentationTimeStamp, firstAudio.presentationTimeStamp)
        let originSeconds = origin.seconds
        let archive = try SegmentedArchiveWriter(directory: directory)
        let recording = try RecordingSession(sink: SegmentedArchiveSink(writer: archive))
        try await recording.start(at: origin)
        let liveQueue = try BoundedMailbox<CapturedMediaSample>(maxItems: 8, maxBytes: 12 * 1024 * 1024, overflowPolicy: .dropOldest)
        let publisherTask = Task.detached {
            guard let url else {
                liveQueue.cancel()
                try emit(["event": "publisher-disabled"])
                return
            }
            let publisher = SDKProbe()
            var publishedVideo = 0
            var publishedAudio = 0
            var changed = false
            let health = PublisherHealth()
            var monitor: Task<Void, Never>?
            do {
                try await publisher.configure()
                try await publisher.start(url)
                try emit(["event": "publisher-started"])
                // Telemetry has one independent task. A slow socket observation
                // must not stall the consumer responsible for live sample ingress.
                monitor = Task {
                    do {
                        while !Task.isCancelled {
                            let publishing = await publisher.isPublishing()
                            let transport = await publisher.metrics()
                            try emit(["event": "publisher-observation", "publishing": publishing,
                                      "sentBytes": transport.map { $0.2 as Any } ?? NSNull(),
                                      "packetDrops": transport.map { $0.1 as Any } ?? NSNull()])
                            if !publishing { health.fail(); liveQueue.cancel(); return }
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch {
                        if !Task.isCancelled { health.fail(); liveQueue.cancel() }
                    }
                }
                while let sample = try await liveQueue.next() {
                    if !changed && sample.sampleBuffer.presentationTimeStamp.seconds - originSeconds >= 5 {
                        try await publisher.setBitRate(2_000_000)
                        changed = true
                        try emit(["event": "bitrate-changed", "bitsPerSecond": 2_000_000])
                    }
                    if sample.kind == .video {
                        await publisher.video(sample.sampleBuffer)
                        publishedVideo += 1
                    } else {
                        guard let (pcm, when) = copyPCM(sample.sampleBuffer) else { throw Failure.pcm }
                        await publisher.audio(pcm, when: when)
                        publishedAudio += sample.sampleBuffer.numSamples
                    }
                }
                guard !health.isFailed else { throw SDKProbe.ProbeError.notPublishing }
                // Allow the final encoded packets to reach the local sink; this
                // interval is part of the experiment, not an SDK flush guarantee.
                try await Task.sleep(for: .seconds(1))
                let status = await publisher.metrics()
                let publishing = await publisher.isPublishing()
                monitor?.cancel()
                await publisher.stop()
                await monitor?.value
                try emit(["event": "publisher-finished", "videoSubmitted": publishedVideo,
                          "audioSamplesSubmitted": publishedAudio, "changedBitrate": changed,
                          "sentBytes": status.map { $0.2 as Any } ?? NSNull(),
                          "packetDrops": status.map { $0.1 as Any } ?? NSNull(),
                          "publishingBeforeStop": publishing])
            } catch {
                liveQueue.cancel()
                monitor?.cancel()
                await publisher.stop()
                await monitor?.value
                // Network failure is reported independently; it cannot cancel the archive.
                try emit(["event": "publisher-failed", "reason": String(describing: error)])
            }
        }
        let started = ContinuousClock.now
        var capturedVideo = 0
        var maximumSourceLag = 0.0
        do {
            while nextVideo != nil || nextAudio != nil {
                try Task.checkCancellation()
                let isVideo = nextAudio == nil || (nextVideo != nil && nextVideo!.presentationTimeStamp <= nextAudio!.presentationTimeStamp)
                let buffer = isVideo ? nextVideo! : nextAudio!
                let elapsed = buffer.presentationTimeStamp.seconds - originSeconds
                try await ContinuousClock().sleep(until: started.advanced(by: .seconds(elapsed)))
                let sample = try CapturedMediaSample(sampleBuffer: buffer, kind: isVideo ? .video : .audio)
                guard recording.offer(sample) else { throw Failure.archiveOverflow }
                if url != nil { _ = liveQueue.offer(sample, bytes: sample.retainedByteCount) }
                if isVideo {
                    capturedVideo += 1
                    let wall = started.duration(to: .now).components
                    maximumSourceLag = max(maximumSourceLag, Double(wall.seconds) + Double(wall.attoseconds) / 1e18 - elapsed)
                    if capturedVideo % 30 == 0 {
                        try emit(["event": "capturing", "sourceSeconds": elapsed,
                                  "archiveQueueBytes": recording.snapshot.queue.currentBytes,
                                  "liveQueueBytes": liveQueue.statistics.currentBytes])
                    }
                    nextVideo = video.copyNextSampleBuffer()
                } else { nextAudio = audio.copyNextSampleBuffer() }
            }
            guard reader.status == .completed else { throw Failure.reader }
            liveQueue.finish()
            let recovered = try await recording.stop()
            let status = archive.snapshot
            try emit(["event": "archive-finished", "videoFrames": status.videoFrames,
                      "audioSamples": status.audioSamples, "segments": recovered.segments.count,
                      "archivePeakBytes": recording.snapshot.queue.peakBytes,
                      "livePeakBytes": liveQueue.statistics.peakBytes,
                      "liveDroppedSamples": liveQueue.statistics.droppedCount,
                      "liveRejectedSamples": liveQueue.statistics.rejectedCount,
                      "maximumSourceLagSeconds": maximumSourceLag,
                      "archiveRejected": recording.snapshot.queue.rejectedCount])
            try await publisherTask.value
        } catch {
            recording.failCapture(reason: "Fixture source failed")
            liveQueue.cancel(); publisherTask.cancel()
            _ = try? await recording.stop()
            _ = await publisherTask.result
            throw error
        }
    }
}

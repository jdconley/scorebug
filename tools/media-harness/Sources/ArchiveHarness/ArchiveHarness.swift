@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia

private func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}

private enum HarnessError: Error { case arguments, missingTracks, readerFailed, backpressureTimeout }

private final class CheckpointPause: @unchecked Sendable {
    private let lock = NSLock()
    private let point: ArchiveStoreFailurePoint
    private let ordinal: Int
    private var count = 0
    init(point: ArchiveStoreFailurePoint, ordinal: Int) { self.point = point; self.ordinal = ordinal }
    func visit(_ current: ArchiveStoreFailurePoint) throws {
        guard current == point else { return }
        let pause = lock.withLock { count += 1; return count == ordinal }
        guard pause else { return }
        try emit(["event": "checkpoint", "point": String(describing: point), "ordinal": ordinal])
        // The parent deliberately kills this owned process at the storage boundary.
        // Bound the pause so a missing parent cannot leave this experiment running.
        Thread.sleep(forTimeInterval: 30)
        throw HarnessError.backpressureTimeout
    }
}

@main struct ArchiveHarness {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 3 else { throw HarnessError.arguments }
            switch args[0] {
            case "record":
                var realtime = false
                var pause: CheckpointPause?
                for option in args.dropFirst(3) {
                    if option == "--realtime" { realtime = true }
                    else if option == "--pause-before-commit" { pause = CheckpointPause(point: .beforeCommit, ordinal: 3) }
                    else if option == "--pause-after-rename" { pause = CheckpointPause(point: .afterRename, ordinal: 3) }
                    else { throw HarnessError.arguments }
                }
                try await record(source: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2]), realtime: realtime, pause: pause)
            case "recover":
                guard args.count == 3 else { throw HarnessError.arguments }
                let recovered = try ArchiveSegmentStore.recover(directory: URL(fileURLWithPath: args[1]))
                try recovered.assemble(to: URL(fileURLWithPath: args[2]))
                try emit(["event": "recovered", "segments": recovered.segments.count])
            case "export":
                guard args.count == 3 else { throw HarnessError.arguments }
                let recovered = try ArchiveSegmentStore.recover(directory: URL(fileURLWithPath: args[1]))
                let exported = try await ArchiveExporter().export(recovered, to: URL(fileURLWithPath: args[2]))
                try emit(["event": "exported", "videoFrames": exported.videoFrames,
                          "audioSamples": exported.audioSamples, "duration": exported.duration])
            case "check-export-failures":
                guard args.count == 3 else { throw HarnessError.arguments }
                let recovered = try ArchiveSegmentStore.recover(directory: URL(fileURLWithPath: args[1]))
                try await ExportChecks.run(archive: recovered, directory: URL(fileURLWithPath: args[2]))
                try emit(["event": "export-failures-checked", "cases": 2])
            default: throw HarnessError.arguments
            }
        } catch {
            try? emit(["event": "failed", "reason": String(describing: error)])
            exit(1)
        }
    }

    private static func record(source: URL, directory: URL, realtime: Bool, pause: CheckpointPause?) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw HarnessError.missingTracks }
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else { throw HarnessError.readerFailed }
        reader.add(videoOutput); reader.add(audioOutput)
        guard reader.startReading() else { throw HarnessError.readerFailed }
        var nextVideo = videoOutput.copyNextSampleBuffer()
        var nextAudio = audioOutput.copyNextSampleBuffer()
        guard let firstVideo = nextVideo, let firstAudio = nextAudio else { throw HarnessError.missingTracks }
        let origin = min(firstVideo.presentationTimeStamp, firstAudio.presentationTimeStamp)
        let injection: (@Sendable (ArchiveStoreFailurePoint) throws -> Void)?
        if let pause { injection = { point in try pause.visit(point) } }
        else { injection = nil }
        let archive = try SegmentedArchiveWriter(directory: directory, storeFailureInjection: injection)
        try archive.start(at: origin)
        let startedAt = ContinuousClock.now
        var reportedSegments = 0
        do {
            while nextVideo != nil || nextAudio != nil {
                try Task.checkCancellation()
                let isVideo = nextAudio == nil || (nextVideo != nil && nextVideo!.presentationTimeStamp <= nextAudio!.presentationTimeStamp)
                let sample = isVideo ? nextVideo! : nextAudio!
                let elapsed = sample.presentationTimeStamp.seconds - origin.seconds
                if realtime {
                    try await ContinuousClock().sleep(until: startedAt.advanced(by: .seconds(elapsed)))
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while try !archive.append(sample, isVideo: isVideo) {
                    guard ContinuousClock.now < deadline else { throw HarnessError.backpressureTimeout }
                    try await Task.sleep(for: .milliseconds(1))
                }
                let status = archive.snapshot
                if isVideo {
                    try emit(["event": "accepted", "videoFrames": status.videoFrames,
                              "videoEnd": elapsed + 1 / 30.0, "segments": status.segments.count])
                }
                if status.segments.count > reportedSegments {
                    try emit(["event": "committed", "segments": status.segments.count,
                              "lastDuration": status.segments.last?.duration ?? 0])
                    reportedSegments = status.segments.count
                }
                if isVideo { nextVideo = videoOutput.copyNextSampleBuffer() }
                else { nextAudio = audioOutput.copyNextSampleBuffer() }
            }
            guard reader.status == .completed else { throw HarnessError.readerFailed }
            let recovered = try await archive.finish()
            let status = archive.snapshot
            try emit(["event": "finished", "videoFrames": status.videoFrames,
                      "audioSamples": status.audioSamples, "acceptedDuration": status.acceptedDuration,
                      "segments": recovered.segments.count])
        } catch {
            archive.cancel()
            throw error
        }
    }
}

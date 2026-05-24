import AVFoundation

/// Fragmented MP4 writer for the local archive. Camera buffers are passed
/// through without re-encoding — the H.264 came straight from the camera
/// hardware encoder via AVCaptureVideoDataOutput; we just package it.
///
/// Setting `movieFragmentInterval` flushes a moof box periodically, so a
/// crash mid-game still yields a playable file up to the last fragment.
final class ArchiveWriter {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private var started = false
    private var sessionStartedAt: CMTime?
    let outputURL: URL

    static func startNew() throws -> ArchiveWriter {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: docs.appending(path: "archives"), withIntermediateDirectories: true)
        let url = docs.appending(path: "archives/game-\(ISO8601DateFormatter().string(from: Date())).mp4")
        return try ArchiveWriter(url: url)
    }

    init(url: URL) throws {
        self.outputURL = url
        self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        self.writer.shouldOptimizeForNetworkUse = true

        // Pass-through video — relies on AVAssetWriterInput accepting the
        // existing format description from the capture format on append.
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        self.videoInput.expectsMediaDataInRealTime = true
        if self.writer.canAdd(self.videoInput) { self.writer.add(self.videoInput) }

        self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        self.audioInput.expectsMediaDataInRealTime = true
        if self.writer.canAdd(self.audioInput) { self.writer.add(self.audioInput) }
    }

    func append(_ sample: CMSampleBuffer, isVideo: Bool) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        if !started {
            writer.startWriting()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            writer.startSession(atSourceTime: pts)
            sessionStartedAt = pts
            started = true
        }
        let input = isVideo ? videoInput : audioInput
        if input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    func finish() {
        guard started else { return }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        writer.finishWriting {}
    }
}

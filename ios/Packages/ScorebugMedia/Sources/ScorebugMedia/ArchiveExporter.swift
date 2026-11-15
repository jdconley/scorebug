@preconcurrency import AVFoundation
import CoreVideo
import Darwin
import Foundation

public struct ArchiveExportResult: Sendable, Equatable {
    public let url: URL
    public let videoFrames: Int64
    public let audioSamples: Int64
    public let duration: Double
}

public enum ArchiveExportError: Error, Equatable, Sendable {
    case destinationExists
    case unsupportedFile(String)
    case unknownCapacity
    case insufficientCapacity
    case invalidMedia(String)
    case exportFailed(String)
    case posix(operation: String, code: Int32)
}

/// Remuxes a recovered part without reencoding, then decodes every output sample before
/// publishing it. The original segment bundles are retained on every outcome.
public actor ArchiveExporter {
    private let availableBytes: @Sendable (URL) -> Int64?

    public init() {
        availableBytes = { directory in
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        }
    }

    init(availableBytes: @escaping @Sendable (URL) -> Int64?) {
        self.availableBytes = availableBytes
    }

    public func export(_ archive: RecoveredArchive, to destination: URL) async throws -> ArchiveExportResult {
        try Task.checkCancellation()
        guard destination.isFileURL else { throw ArchiveExportError.unsupportedFile(destination.absoluteString) }
        let parent = destination.deletingLastPathComponent()
        try ExportDisk.requireDirectory(parent)
        try ExportDisk.requireAbsent(destination)
        try requireCapacity(archive, at: parent)

        // An exclusively created private directory establishes ownership before any cleanup.
        // Both intermediates remain on the destination filesystem for atomic publication.
        let workspace = parent.appendingPathComponent(".archive-export-\(UUID().uuidString)")
        guard mkdir(workspace.path, S_IRWXU) == 0 else { throw ExportDisk.posix("create export workspace") }
        defer { try? FileManager.default.removeItem(at: workspace) }
        let assembled = workspace.appendingPathComponent("assembled.mp4")
        let staged = workspace.appendingPathComponent("export.mp4")
        try archive.assemble(to: assembled)
        try Task.checkCancellation()

        let asset = AVURLAsset(url: assembled)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else {
            throw ArchiveExportError.invalidMedia("This archive cannot be remuxed to MP4")
        }
        session.outputURL = staged
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let operation = ExportOperation(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start { continuation.resume() }
            }
        } onCancel: {
            operation.cancel()
        }
        // Completion is awaited even on cancellation: AVFoundation must release its file
        // before the private workspace is removed.
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw ArchiveExportError.exportFailed(session.error?.localizedDescription ?? "Export did not complete (\(session.status.rawValue))")
        }
        let result = try await validate(staged, destination: destination)
        try Task.checkCancellation()
        try ExportDisk.syncRegular(staged)
        try Task.checkCancellation()
        // RENAME_EXCL performs the absence check atomically, including a target created
        // after preflight. Never remove the target when this fails.
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ArchiveExportError.destinationExists }
            throw ExportDisk.posix("publish MP4")
        }
        try ExportDisk.syncDirectory(parent)
        return result
    }

    private func requireCapacity(_ archive: RecoveredArchive, at parent: URL) throws {
        var bytes: Int64 = 0
        for segment in archive.segments {
            let (sum, overflow) = bytes.addingReportingOverflow(Int64(segment.byteCount))
            guard segment.byteCount > 0, !overflow else { throw ArchiveExportError.insufficientCapacity }
            bytes = sum
        }
        // Assembly plus export, 10% MP4/index overhead, and a 64 MiB reserve.
        let (copies, overflow) = bytes.multipliedReportingOverflow(by: 2)
        let (withOverhead, overflow2) = copies.addingReportingOverflow(bytes / 10)
        let (required, overflow3) = withOverhead.addingReportingOverflow(64 * 1024 * 1024)
        guard !overflow, !overflow2, !overflow3 else { throw ArchiveExportError.insufficientCapacity }
        guard let free = availableBytes(parent) else { throw ArchiveExportError.unknownCapacity }
        guard free >= required else { throw ArchiveExportError.insufficientCapacity }
    }

    private func validate(_ staged: URL, destination: URL) async throws -> ArchiveExportResult {
        let asset = AVURLAsset(url: staged)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        guard videos.count == 1, audios.count == 1, duration.isFinite, duration > 0 else {
            throw ArchiveExportError.invalidMedia("Expected one video track, one audio track, and a positive duration")
        }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        let audio = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        video.alwaysCopiesSampleData = false
        audio.alwaysCopiesSampleData = false
        guard reader.canAdd(video), reader.canAdd(audio) else {
            throw ArchiveExportError.invalidMedia("Raw video/audio decoding is unavailable")
        }
        reader.add(video)
        reader.add(audio)
        guard reader.startReading() else {
            throw ArchiveExportError.invalidMedia(reader.error?.localizedDescription ?? "Cannot start full decode")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var videoFrames: Int64 = 0
        var audioSamples: Int64 = 0
        var videoEnded = false
        var audioEnded = false
        // Each iteration releases both decoded buffers; memory is independent of duration.
        while !videoEnded || !audioEnded {
            try Task.checkCancellation()
            try autoreleasepool {
                if !videoEnded {
                    if let sample = video.copyNextSampleBuffer() {
                        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetImageBuffer(sample) != nil,
                              CMSampleBufferGetNumSamples(sample) > 0 else {
                            throw ArchiveExportError.invalidMedia("Invalid decoded video sample")
                        }
                        videoFrames += Int64(CMSampleBufferGetNumSamples(sample))
                    } else { videoEnded = true }
                }
                if !audioEnded {
                    if let sample = audio.copyNextSampleBuffer() {
                        guard CMSampleBufferDataIsReady(sample), let data = CMSampleBufferGetDataBuffer(sample),
                              CMBlockBufferGetDataLength(data) > 0, CMSampleBufferGetNumSamples(sample) > 0 else {
                            throw ArchiveExportError.invalidMedia("Invalid decoded audio sample")
                        }
                        audioSamples += Int64(CMSampleBufferGetNumSamples(sample))
                    } else { audioEnded = true }
                }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed, videoFrames > 0, audioSamples > 0 else {
            throw ArchiveExportError.invalidMedia(reader.error?.localizedDescription ?? "Full video/audio decode did not complete")
        }
        return ArchiveExportResult(url: destination, videoFrames: videoFrames, audioSamples: audioSamples, duration: duration)
    }
}

/// AVFoundation permits cancellation from another thread. The lock closes the race
/// between task cancellation and starting the legacy, iOS 17/macOS 13 export API.
private final class ExportOperation: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let lock = NSLock()
    private var cancelled = false

    init(_ session: AVAssetExportSession) { self.session = session }

    func start(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            completion()
            return
        }
        session.exportAsynchronously(completionHandler: completion)
        lock.unlock()
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            session.cancelExport()
        }
    }
}

private enum ExportDisk {
    static func posix(_ operation: String) -> ArchiveExportError { .posix(operation: operation, code: errno) }

    static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posix("inspect export directory") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ArchiveExportError.unsupportedFile(url.path) }
    }

    static func requireAbsent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw ArchiveExportError.unsupportedFile(url.path) }
            throw ArchiveExportError.destinationExists
        }
        guard errno == ENOENT else { throw posix("inspect export target") }
    }

    static func syncRegular(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posix("open exported MP4") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posix("inspect exported MP4") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ArchiveExportError.unsupportedFile(url.path) }
        guard info.st_size > 0 else { throw ArchiveExportError.invalidMedia("Empty exported MP4") }
        guard fsync(descriptor) == 0 else { throw posix("sync exported MP4") }
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posix("open export parent") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posix("sync export parent") }
    }
}

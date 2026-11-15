import AVFoundation
import Darwin
import Foundation
import ImageIO
import ScorebugMedia
import UniformTypeIdentifiers

struct RecordingEntry: Identifiable, Sendable {
    enum Status: String, Sendable { case completed, recoverable, unavailable }
    let id: String
    let createdAt: Date
    let status: Status
    let reason: String?
    let duration: Double
    let byteCount: Int64
    /// Recorded picture height (1080 or 2160); nil when the archive is unreadable.
    var height: Int? = nil
    var canExport: Bool { status != .unavailable }
    var resolutionLabel: String? { height.map { $0 >= 2160 ? "4K" : "\($0)p" } }
}

struct RecordingDraft: Sendable {
    let id: String
    let directory: URL
    let sink: any RecordingArchiveSink
}

enum RecordingLibraryError: Error, LocalizedError {
    case unsafePath, activeRecording, exportInProgress, noMedia, metadata(String)
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "The recording path is not a safe local directory."
        case .activeRecording: return "Stop this recording before recovering or exporting it."
        case .exportInProgress: return "An export is already in progress."
        case .noMedia: return "No recoverable video is available. The original files were kept."
        case .metadata(let reason): return "Recording status could not be saved: \(reason). The original files were kept."
        }
    }
}

/// Filesystem work, recovery hashing and export run on this actor, never MainActor.
/// Capture directories are immutable after finish; exporting always creates a new file.
actor RecordingLibrary {
    typealias SinkFactory = @Sendable (URL, ArchiveProfile) throws -> any RecordingArchiveSink
    static let defaultSinkFactory: SinkFactory = { directory, profile in
        SegmentedArchiveSink(writer: try SegmentedArchiveWriter(directory: directory, profile: profile))
    }
    private struct StatusRecord: Codable {
        let version: Int
        let id: String
        let createdAt: Date
        var completedAt: Date?
        var failure: String?
    }
    private let statusSync: @Sendable (URL) throws -> Void
    private let rootDirectory: URL
    private var active: [String: StatusRecord] = [:]
    private var exporting = false
    private let exporter = ArchiveExporter()

    init(rootDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scorebug/Recordings", isDirectory: true),
         statusSync: @escaping @Sendable (URL) throws -> Void = { try RecordingLibrary.syncStatusDirectory($0) }) {
        self.statusSync = statusSync
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func begin(profile: ArchiveProfile, sinkFactory: SinkFactory = defaultSinkFactory) throws -> RecordingDraft {
        try prepareRoot()
        let id = UUID().uuidString
        let directory = try recordingURL(id)
        let sink = try sinkFactory(directory, profile)
        let status = StatusRecord(version: 1, id: id, createdAt: Date())
        do { try writeStatus(status, directory: directory) }
        catch { sink.cancel(); throw error }
        active[id] = status
        return RecordingDraft(id: id, directory: directory, sink: sink)
    }

    func finish(id: String, failure: String?) throws {
        guard var status = active.removeValue(forKey: id) else { throw RecordingLibraryError.activeRecording }
        let directory = try recordingURL(id)
        if let failure {
            status.failure = failure
        } else {
            let archive = try ArchiveSegmentStore.recover(directory: directory)
            guard archive.segments.contains(where: { $0.kind == .media }) else { throw RecordingLibraryError.noMedia }
            status.completedAt = Date()
        }
        try writeStatus(status, directory: directory)
    }

    func list(excludingID: String? = nil) throws -> [RecordingEntry] {
        try prepareRoot()
        return try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && active[$0.lastPathComponent] == nil && $0.lastPathComponent != excludingID }
            .map { inspect($0) }.sorted { $0.createdAt > $1.createdAt }
    }

    func export(id: String) async throws -> URL {
        guard active[id] == nil else { throw RecordingLibraryError.activeRecording }
        guard !exporting else { throw RecordingLibraryError.exportInProgress }
        exporting = true
        defer { exporting = false }
        try prepareRoot()
        let directory = try recordingURL(id)
        try requireDirectory(directory)
        let archive = try ArchiveSegmentStore.recover(directory: directory)
        guard archive.segments.contains(where: { $0.kind == .media }) else { throw RecordingLibraryError.noMedia }
        let exports = rootDirectory.appendingPathComponent("Exports", isDirectory: true)
        try createSafeDirectory(exports)
        let destination = exports.appendingPathComponent("\(id)-\(UUID().uuidString).mp4")
        let result = try await exporter.export(archive, to: destination)
        #if DEBUG && os(iOS) && !targetEnvironment(simulator)
        // Persist only scalars after the production exporter has decoded the entire
        // published MP4. This avoids a second 4K decode or copying the raw archive
        // during qualification. Missing diagnostics never change successful export.
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber {
            let report: [String: Any] = ["contract": "scorebug-native-export-v1", "recordingID": id,
                "fileName": destination.lastPathComponent, "bytes": bytes.int64Value,
                "videoFrames": result.videoFrames, "audioSamples": result.audioSamples,
                "duration": result.duration, "fullDecodeCompleted": true,
                "completedUptimeSeconds": ProcessInfo.processInfo.systemUptime]
            let qa = rootDirectory.deletingLastPathComponent().appendingPathComponent("QA", isDirectory: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
                try? data.write(to: qa.appendingPathComponent("export-validation-\(id).json"), options: .atomic)
            }
        }
        #endif
        return result.url
    }

    /// A JPEG still from early in the recording, cached beside the recordings.
    /// Only the first few fragments are assembled, never the whole match.
    func thumbnail(id: String) async -> URL? {
        guard active[id] == nil, let directory = try? recordingURL(id) else { return nil }
        let thumbnails = rootDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        let destination = thumbnails.appendingPathComponent("\(id).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        do {
            try createSafeDirectory(thumbnails)
            let archive = try ArchiveSegmentStore.recover(directory: directory)
            guard archive.segments.contains(where: { $0.kind == .media }) else { return nil }
            let preview = thumbnails.appendingPathComponent(".preview-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: preview) }
            try archive.assemblePrefix(mediaSegments: 2, to: preview)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: preview))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            return CGImageDestinationFinalize(sink) ? destination : nil
        } catch { return nil }
    }

    func availableBytes() -> Int64? {
        guard (try? prepareRoot()) != nil else { return nil }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: rootDirectory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private func inspect(_ directory: URL) -> RecordingEntry {
        let id = directory.lastPathComponent
        var createdAt = Date.distantPast
        var status: StatusRecord?
        var statusIssue: String?
        do {
            try requireDirectory(directory)
            createdAt = (try? FileManager.default.attributesOfItem(atPath: directory.path)[.creationDate] as? Date) ?? .distantPast
            status = try readStatus(directory)
            guard status?.id == id, status?.version == 1 else { throw RecordingLibraryError.metadata("Invalid status record") }
            createdAt = status!.createdAt
        } catch {
            status = nil
            statusIssue = "Completion status is missing or unreadable; this recording may have been interrupted."
        }
        do {
            let archive = try ArchiveSegmentStore.recover(directory: directory)
            guard archive.segments.contains(where: { $0.kind == .media }) else { throw RecordingLibraryError.noMedia }
            let mediaTimes = archive.segments.compactMap { segment -> (start: Double, end: Double)? in
                guard let start = segment.startTime, let duration = segment.duration else { return nil }
                return (start, start + duration)
            }
            let duration = max(0, (mediaTimes.map(\.end).max() ?? 0) - (mediaTimes.map(\.start).min() ?? 0))
            let bytes = archive.segments.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
            let completed = status?.completedAt != nil && status?.failure == nil
            let reason = completed ? nil : status?.failure ?? statusIssue ?? "Recording was interrupted. Recover the video saved so far."
            return RecordingEntry(id: id, createdAt: createdAt, status: completed ? .completed : .recoverable,
                                  reason: reason, duration: duration, byteCount: bytes, height: archive.profile.height)
        } catch {
            return RecordingEntry(id: id, createdAt: createdAt, status: .unavailable,
                                  reason: "Archive unavailable: \(error.localizedDescription)", duration: 0, byteCount: 0)
        }
    }

    private func recordingURL(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw RecordingLibraryError.unsafePath }
        return rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func prepareRoot() throws { try createSafeDirectory(rootDirectory) }

    private func createSafeDirectory(_ url: URL) throws {
        // Platform Application Support/temporary ancestors are trusted locations.
        // The configured root and all recording/export children must be actual
        // directories; never follow a substituted recording or export symlink.
        var info = stat()
        if lstat(url.path, &info) == 0 { try requireDirectory(url); return }
        guard errno == ENOENT else { throw RecordingLibraryError.unsafePath }
        if url != rootDirectory { try requireDirectory(rootDirectory) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: url == rootDirectory)
        try requireDirectory(url)
    }

    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw RecordingLibraryError.unsafePath }
    }

    private func readStatus(_ directory: URL) throws -> StatusRecord {
        let path = directory.appendingPathComponent("recording-status.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RecordingLibraryError.metadata("Cannot open status") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 64 * 1024 else {
            throw RecordingLibraryError.metadata("Invalid status file")
        }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        return try JSONDecoder().decode(StatusRecord.self, from: data)
    }

    static func syncStatusDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw RecordingLibraryError.metadata("Cannot sync status") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RecordingLibraryError.metadata("Cannot sync status") }
    }

    private func writeStatus(_ status: StatusRecord, directory: URL) throws {
        var committedStatus: URL?
        do {
            try requireDirectory(directory)
            let destination = directory.appendingPathComponent("recording-status.json")
            var info = stat()
            if lstat(destination.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw RecordingLibraryError.unsafePath }
            } else if errno != ENOENT { throw RecordingLibraryError.unsafePath }
            let temporary = directory.appendingPathComponent(".status-\(UUID().uuidString)")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw RecordingLibraryError.metadata("Cannot create status") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: JSONEncoder().encode(status))
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else { throw RecordingLibraryError.metadata("Cannot commit status") }
            committedStatus = destination
            try statusSync(directory)
        } catch {
            // A rename can succeed before directory sync reports failure. Never
            // leave that unconfirmed completion marker visible on the next launch.
            // This removes only our status file, never an archive fragment.
            if status.completedAt != nil, let committedStatus {
                if unlink(committedStatus.path) == 0 { try? Self.syncStatusDirectory(directory) }
            }
            throw RecordingLibraryError.metadata(error.localizedDescription)
        }
    }
}

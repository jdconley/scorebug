import CryptoKit
import Darwin
import Foundation

public enum ArchiveSegmentKind: String, Codable, Sendable { case initialization, media }

public struct ArchiveSegment: Codable, Equatable, Sendable {
    public let sequence: Int
    public let kind: ArchiveSegmentKind
    public let startTime: Double?
    public let duration: Double?
    public let byteCount: Int
    public let sha256: String
}

public enum ArchiveStoreFailurePoint: Sendable { case beforeCommit, afterRename, beforeManifest }

public enum ArchiveStoreError: Error, Equatable, Sendable {
    case invalidProfile
    case invalidSegment
    case initializationRequired
    case duplicateInitialization
    case stopped
    case unknownCapacity
    case insufficientCapacity
    case corruptArchive(String)
    case unsupportedFile(String)
    case posix(operation: String, code: Int32)
}

private struct ArchiveHeader: Codable {
    let version: Int
    let profile: ArchiveProfile
}

/// A new, exclusive recording part. A committed segment directory is authoritative;
/// manifest.json is only a cache, so a crash while replacing it cannot hide media.
public final class ArchiveSegmentStore: @unchecked Sendable {
    public let directory: URL
    public let profile: ArchiveProfile
    public static let maximumSegmentBytes = 64 * 1024 * 1024
    private let reserveBytes: Int64
    private let availableBytes: @Sendable () -> Int64?
    private let failureInjection: (@Sendable (ArchiveStoreFailurePoint) throws -> Void)?
    private let lock = NSLock()
    private var committed: [ArchiveSegment] = []
    private var stopped = false
    private var failures = 0

    public var segments: [ArchiveSegment] { lock.withLock { committed } }
    public var failureCount: Int { lock.withLock { failures } }

    public init(directory: URL, profile: ArchiveProfile, reserveBytes: Int64 = 64 * 1024 * 1024,
                availableBytes: (@Sendable () -> Int64?)? = nil,
                failureInjection: (@Sendable (ArchiveStoreFailurePoint) throws -> Void)? = nil) throws {
        try profile.validate()
        guard reserveBytes >= 0 else { throw ArchiveStoreError.invalidProfile }
        self.directory = directory
        self.profile = profile
        self.reserveBytes = reserveBytes
        self.availableBytes = availableBytes ?? {
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        }
        self.failureInjection = failureInjection
        try Disk.requireDirectory(directory.deletingLastPathComponent())
        try Disk.makeDirectory(directory)
        // Keep a failed new part for diagnosis. Never reuse or erase its directory.
        try Disk.writeNew(try JSONEncoder().encode(ArchiveHeader(version: 1, profile: profile)),
                          to: directory.appendingPathComponent("part.json"))
        try Disk.syncDirectory(directory)
        try Disk.syncDirectory(directory.deletingLastPathComponent())
    }

    @discardableResult
    public func append(data: Data, kind: ArchiveSegmentKind, startTime: Double? = nil,
                       duration: Double? = nil) throws -> ArchiveSegment {
        try lock.withLock {
            guard !stopped else { throw ArchiveStoreError.stopped }
            guard !data.isEmpty, data.count <= Self.maximumSegmentBytes,
                  startTime.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  duration.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw ArchiveStoreError.invalidSegment
            }
            if committed.isEmpty && kind != .initialization { throw ArchiveStoreError.initializationRequired }
            if !committed.isEmpty && kind == .initialization { throw ArchiveStoreError.duplicateInitialization }
            let segment = ArchiveSegment(sequence: committed.count, kind: kind, startTime: startTime,
                                         duration: duration, byteCount: data.count, sha256: Disk.hash(data))
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
            do {
                let encoder = JSONEncoder()
                let metadata = try encoder.encode(segment)
                let manifest = try encoder.encode(committed + [segment])
                let pendingBytes = Self.pendingWriteBytes(payloadByteCount: data.count,
                                                         metadata: metadata, manifest: manifest)
                guard let free = availableBytes() else { throw ArchiveStoreError.unknownCapacity }
                // Subtraction avoids overflow for injected or unusually large reserve values.
                guard free >= reserveBytes, free - reserveBytes >= pendingBytes else {
                    throw ArchiveStoreError.insufficientCapacity
                }
                try Disk.makeDirectory(staging)
                try Disk.writeNew(data, to: staging.appendingPathComponent("payload.bin"))
                try Disk.writeNew(metadata, to: staging.appendingPathComponent("metadata.json"))
                try Disk.syncDirectory(staging)
                try failureInjection?(.beforeCommit)
                try Disk.renameExclusive(staging, to: directory.appendingPathComponent(Disk.bundleName(segment.sequence)))
                try Disk.syncDirectory(directory)
                committed.append(segment)
                try failureInjection?(.afterRename)
                try failureInjection?(.beforeManifest)
                try replaceManifest(with: manifest)
                return segment
            } catch {
                stopped = true
                failures += 1
                // Only the staging path belonging to this append is eligible for cleanup.
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
    }

    /// Includes the new manifest's temporary copy; the old cache already consumes free space.
    /// The fixed allowance covers directory entries and filesystem allocation overhead.
    static func pendingWriteBytes(payloadByteCount: Int, metadata: Data, manifest: Data) -> Int64 {
        Int64(payloadByteCount) + Int64(metadata.count) + Int64(manifest.count) + 1024 * 1024
    }

    private func replaceManifest(with encoded: Data) throws {
        let temporary = directory.appendingPathComponent(".manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Disk.writeNew(encoded, to: temporary)
        let target = directory.appendingPathComponent("manifest.json")
        guard rename(temporary.path, target.path) == 0 else { throw Disk.posix("replace manifest") }
        try Disk.syncDirectory(directory)
    }

    public static func recover(directory: URL) throws -> RecoveredArchive {
        try Disk.requireDirectory(directory)
        let headerURL = directory.appendingPathComponent("part.json")
        let header = try JSONDecoder().decode(ArchiveHeader.self, from: Disk.readMetadata(headerURL))
        guard header.version == 1 else { throw ArchiveStoreError.corruptArchive("Unsupported part version") }
        try header.profile.validate()
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let bundles = children.filter { $0.lastPathComponent.hasSuffix(".segment") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var segments: [ArchiveSegment] = []
        for bundle in bundles {
            try Disk.requireDirectory(bundle)
            let segment = try JSONDecoder().decode(ArchiveSegment.self, from: Disk.readMetadata(bundle.appendingPathComponent("metadata.json")))
            guard segment.sequence == segments.count, bundle.lastPathComponent == Disk.bundleName(segment.sequence),
                  segment.kind == (segments.isEmpty ? .initialization : .media),
                  segment.byteCount > 0, segment.byteCount <= maximumSegmentBytes,
                  segment.startTime.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  segment.duration.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw ArchiveStoreError.corruptArchive("Invalid or noncontiguous segment \(bundle.lastPathComponent)")
            }
            try Disk.verifyAndCopy(bundle.appendingPathComponent("payload.bin"), segment: segment, output: nil)
            segments.append(segment)
        }
        return RecoveredArchive(directory: directory, profile: header.profile, segments: segments)
    }
}

public struct RecoveredArchive: Sendable {
    public let directory: URL
    public let profile: ArchiveProfile
    public let segments: [ArchiveSegment]

    /// Streams verified fragments into a new fragmented MP4; it does not remux them.
    public func assemble(to output: URL) throws {
        guard !segments.isEmpty else { throw ArchiveStoreError.initializationRequired }
        try Disk.requireDirectory(directory)
        try Disk.requireDirectory(output.deletingLastPathComponent())
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".assembly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Disk.posix("create assembly") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        for segment in segments {
            let bundle = directory.appendingPathComponent(Disk.bundleName(segment.sequence))
            try Disk.requireDirectory(bundle)
            try Disk.verifyAndCopy(bundle.appendingPathComponent("payload.bin"), segment: segment, output: handle)
        }
        try handle.synchronize()
        try handle.close()
        try Disk.renameExclusive(temporary, to: output)
        try Disk.syncDirectory(output.deletingLastPathComponent())
    }
}

private enum Disk {
    static func posix(_ operation: String) -> ArchiveStoreError { .posix(operation: operation, code: errno) }
    static func bundleName(_ sequence: Int) -> String { String(format: "%06d.segment", sequence) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posix("inspect directory") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ArchiveStoreError.unsupportedFile(url.lastPathComponent) }
    }

    static func makeDirectory(_ url: URL) throws {
        guard mkdir(url.path, S_IRWXU) == 0 else { throw posix("create directory") }
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posix("open directory") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posix("sync directory") }
    }

    static func renameExclusive(_ source: URL, to target: URL) throws {
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw posix("commit new path") }
    }

    static func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posix("create file") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    static func openRegular(_ url: URL) throws -> (FileHandle, Int64) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posix("open regular file") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = posix("inspect file")
            close(descriptor)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ArchiveStoreError.unsupportedFile(url.lastPathComponent)
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), info.st_size)
    }

    static func readMetadata(_ url: URL) throws -> Data {
        let (handle, size) = try openRegular(url)
        defer { try? handle.close() }
        guard size > 0, size <= 64 * 1024 else { throw ArchiveStoreError.corruptArchive("Invalid metadata size") }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count == size else { throw ArchiveStoreError.corruptArchive("Metadata changed while reading") }
        return data
    }

    static func verifyAndCopy(_ url: URL, segment: ArchiveSegment, output: FileHandle?) throws {
        let (input, size) = try openRegular(url)
        defer { try? input.close() }
        guard size == segment.byteCount else { throw ArchiveStoreError.corruptArchive("Payload size mismatch") }
        var hash = SHA256()
        var read = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            read += chunk.count
            guard read <= segment.byteCount else { throw ArchiveStoreError.corruptArchive("Payload grew while reading") }
            hash.update(data: chunk)
            try output?.write(contentsOf: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard read == segment.byteCount, digest == segment.sha256 else { throw ArchiveStoreError.corruptArchive("Payload checksum mismatch") }
    }
}

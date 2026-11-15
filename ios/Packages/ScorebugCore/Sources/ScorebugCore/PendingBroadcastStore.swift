import Foundation

/// The scope must identify both the canonical server endpoint and the account,
/// using a nonsecret identifier. Never put an authentication token in this record.
public struct PendingBroadcastCommand: Codable, Equatable, Sendable {
    public let endpointScope: String
    public let command: BroadcastCommand
    public let captureDeviceId: String

    public init(endpointScope: String, command: BroadcastCommand, captureDeviceId: String) {
        self.endpointScope = endpointScope
        self.command = command
        self.captureDeviceId = captureDeviceId
    }
}

/// Each store must have one active coordinator owner. A save must atomically
/// replace the previous value, including when clearing with nil, or throw.
/// A thrown save must leave the previous committed value unchanged, so a new
/// coordinator can recover the same uncertainty after process termination.
public protocol PendingBroadcastStore: Sendable {
    func load() throws -> PendingBroadcastCommand?
    func save(_ pending: PendingBroadcastCommand?) throws
}

/// An atomic JSON outbox. Missing files mean empty; malformed/unreadable files
/// throw and are never silently replaced. Use an app-private directory.
public struct JSONFilePendingBroadcastStore: PendingBroadcastStore {
    public let url: URL

    enum FileOperation { case permissions, install }
    private let beforeFileOperation: @Sendable (FileOperation, URL) throws -> Void

    public init(url: URL) { self.init(url: url, beforeFileOperation: { _, _ in }) }

    init(url: URL, beforeFileOperation: @escaping @Sendable (FileOperation, URL) throws -> Void) {
        self.url = url
        self.beforeFileOperation = beforeFileOperation
    }

    public func load() throws -> PendingBroadcastCommand? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(PendingBroadcastCommand?.self, from: data)
    }

    public func save(_ pending: PendingBroadcastCommand?) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(pending)
        let temporary = directory.appendingPathComponent(".broadcast-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // Prepare a private sibling completely before changing the outbox.
        // Exclusive creation avoids following any pre-existing temporary path.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Self.fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try beforeFileOperation(.permissions, temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try beforeFileOperation(.install, temporary)

        // Same-directory POSIX rename atomically installs the prepared file.
        // This is the last fallible operation: success cannot subsequently be
        // reported as a failed clear with the old pending record already gone.
        guard rename(temporary.path, url.path) == 0 else { throw Self.fileError() }
    }

    private static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

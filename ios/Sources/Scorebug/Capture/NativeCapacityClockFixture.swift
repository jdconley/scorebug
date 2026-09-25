#if DEBUG
import Darwin
import Foundation
import ScorebugMedia

/// Bounded lab-only timestamps. This owns no publishing or quality authority.
struct NativeCapacityClockAudit {
    enum Failure: Error { case invalidRequest, capacity, serialization }
    struct Scope: Codable, Equatable {
        let recordingID: String
        let matchID: String
        let broadcastGeneration: Int
        var publishingAttemptID: String
        let appliedProfileRevision: String
        static let keys: Set<String> = ["recordingID", "matchID", "broadcastGeneration", "publishingAttemptID", "appliedProfileRevision"]
        init(_ value: VideoFrameObservationScope) throws {
            guard !value.recordingID.isEmpty, value.recordingID.utf16.count <= 512,
                  !value.matchID.isEmpty, value.matchID.utf16.count <= 512,
                  value.broadcastGeneration > 0, value.broadcastGeneration <= 9_007_199_254_740_991,
                  value.appliedProfileRevision == 1 else { throw Failure.invalidRequest }
            recordingID = value.recordingID; matchID = value.matchID
            broadcastGeneration = value.broadcastGeneration
            publishingAttemptID = value.publishingAttemptID.uuidString.lowercased()
            appliedProfileRevision = "1"
        }
    }
    struct Sample: Codable { let sequence: Int; let nonce: String; let nativeAt: Double }
    private struct Request: Decodable {
        let formatVersion: Int; var scope: Scope; let sequence: Int; let nonce: String
    }
    private struct Response: Encodable { let formatVersion = 1; let scope: Scope; let sample: Sample }
    private struct Export: Encodable {
        let formatVersion = 1; let scope: Scope; let maximumSamples = 4
        let closed: Bool; let invalid: Bool; let overflow: Bool; let samples: [Sample]
    }
    private let scope: Scope
    private var samples: [Sample] = []
    private(set) var closed = false
    private var invalid = false, overflow = false
    init(scope: VideoFrameObservationScope) throws { self.scope = try Scope(scope) }
    mutating func invalidate() { guard !closed else { return }; invalid = true }
    mutating func close() { closed = true }
    mutating func respond(to bytes: Data, at nativeAt: Double) throws -> Data? {
        guard !closed, !invalid, !overflow else { return nil }
        do {
            guard bytes.count <= 4096,
                  let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(raw.keys) == ["formatVersion", "scope", "sequence", "nonce"],
                  let rawScope = raw["scope"] as? [String: Any], Set(rawScope.keys) == Scope.keys
            else { throw Failure.invalidRequest }
            var request = try JSONDecoder().decode(Request.self, from: bytes)
            guard let attempt = UUID(uuidString: request.scope.publishingAttemptID),
                  let nonce = UUID(uuidString: request.nonce), request.formatVersion == 1,
                  nativeAt.isFinite, nativeAt >= 0, nativeAt <= 1e12 else { throw Failure.invalidRequest }
            request.scope.publishingAttemptID = attempt.uuidString.lowercased()
            guard request.scope == scope else { throw Failure.invalidRequest }
            let nonceText = nonce.uuidString.lowercased()
            // The host leaves its atomic challenge in place until the next request.
            // Seeing it again must never update the original recorded timestamp.
            if let last = samples.last, request.sequence == last.sequence, nonceText == last.nonce { return nil }
            guard request.sequence == samples.count + 1,
                  !samples.contains(where: { $0.nonce == nonceText }),
                  samples.last.map({ nativeAt > $0.nativeAt }) ?? true else { throw Failure.invalidRequest }
            guard samples.count < 4 else { overflow = true; throw Failure.capacity }
            let sample = Sample(sequence: request.sequence, nonce: nonceText, nativeAt: nativeAt)
            let reply = try Self.encode(Response(scope: scope, sample: sample))
            samples.append(sample)
            return reply
        } catch {
            invalid = true
            throw error
        }
    }
    func data() throws -> Data {
        try Self.encode(Export(scope: scope, closed: closed, invalid: invalid, overflow: overflow, samples: samples))
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 16384 else { throw Failure.serialization }
        return data
    }
}

/// Owned by one native publishing attempt. Poll/close calls are awaited; no timer,
/// unstructured task, camera work or network work is started by this fixture.
actor NativeCapacityClockFixture {
    private var audit: NativeCapacityClockAudit
    private let directory: URL
    private var exported = false
    init(scope: VideoFrameObservationScope, directory: URL) throws {
        audit = try NativeCapacityClockAudit(scope: scope)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["capacity-clock-request.json", "capacity-clock-response.json", "capacity-clock.json"] {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            catch CocoaError.fileNoSuchFile { }
        }
    }
    func poll() {
        guard !audit.closed else { return }
        do {
            let url = directory.appendingPathComponent("capacity-clock-request.json")
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                if errno == ENOENT { return }
                throw NativeCapacityClockAudit.Failure.invalidRequest
            }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  status.st_size >= 0, status.st_size <= 4096,
                  let bytes = try file.read(upToCount: 4097), bytes.count == status.st_size,
                  bytes.count <= 4096 else { throw NativeCapacityClockAudit.Failure.invalidRequest }
            if let response = try audit.respond(to: bytes, at: ProcessInfo.processInfo.systemUptime) {
                try response.write(to: directory.appendingPathComponent("capacity-clock-response.json"), options: .atomic)
            }
        } catch { audit.invalidate() }
    }
    func closeAndExport() {
        guard !exported else { return }
        audit.close(); exported = true
        // Failure is visible as a missing/invalid qualification artifact and
        // must never interrupt recording or publisher cleanup.
        if let data = try? audit.data() {
            try? data.write(to: directory.appendingPathComponent("capacity-clock.json"), options: .atomic)
        }
    }
}
#endif

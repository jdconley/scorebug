#if DEBUG
import Foundation
import ScorebugMedia

/// Closed scalar observations only. Export does not participate in media policy.
enum ArchivePressureFixture {
    static func requested(environment: [String: String]) -> Bool {
        environment["SCOREBUG_TEST_VIDEO_OBSERVATIONS"] == "1"
    }

    static func data(for snapshot: ArchivePressureDiagnostics.Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(VersionedSnapshot(snapshot: snapshot))
    }

    private struct VersionedSnapshot: Encodable {
        let snapshot: ArchivePressureDiagnostics.Snapshot
        enum CodingKeys: String, CodingKey { case formatVersion }
        func encode(to encoder: Encoder) throws {
            // Preserve the core Codable shape, including omitted optional fields.
            try snapshot.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(1, forKey: .formatVersion)
        }
    }

    #if targetEnvironment(simulator)
    static func writeClosed(_ snapshot: ArchivePressureDiagnostics.Snapshot) async throws {
        guard snapshot.closed else { return }
        try await Task.detached(priority: .utility) {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Scorebug/QA", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data(for: snapshot).write(to: directory.appendingPathComponent("archive-diagnostics.json"), options: .atomic)
        }.value
    }
    #endif
}
#endif

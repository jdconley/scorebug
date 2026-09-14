import Foundation
import ScorebugMedia

enum ExportChecks {
    enum Failure: Error { case exportNotObserved, unexpectedSuccess, wrongError, changedFiles }

    /// Exercises cancellation and a competing destination against real native
    /// export/decoding. The caller supplies a new directory owned by this check.
    static func run(archive: RecoveredArchive, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for cancel in [false, true] {
            let part = directory.appendingPathComponent(cancel ? "cancel" : "race")
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: false)
            let target = part.appendingPathComponent("movie.mp4")
            let task = Task { try await ArchiveExporter().export(archive, to: target) }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                var observed = false
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    let children = try FileManager.default.contentsOfDirectory(at: part, includingPropertiesForKeys: nil)
                    if let workspace = children.first(where: { $0.lastPathComponent.hasPrefix(".archive-export-") }),
                       !cancel || FileManager.default.fileExists(atPath: workspace.appendingPathComponent("export.mp4").path) {
                        observed = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard observed else { throw Failure.exportNotObserved }
                let competing = Data("Unrelated destination created during export".utf8)
                if cancel { task.cancel() }
                else { try competing.write(to: target, options: .withoutOverwriting) }
                do {
                    _ = try await task.value
                    throw Failure.unexpectedSuccess
                } catch {
                    guard cancel ? error is CancellationError : error as? ArchiveExportError == .destinationExists else {
                        throw Failure.wrongError
                    }
                }
                let remaining = try FileManager.default.contentsOfDirectory(atPath: part.path)
                if cancel {
                    guard remaining.isEmpty else { throw Failure.changedFiles }
                } else {
                    guard remaining == ["movie.mp4"], try Data(contentsOf: target) == competing else {
                        throw Failure.changedFiles
                    }
                }
                guard try ArchiveSegmentStore.recover(directory: archive.directory).segments == archive.segments else {
                    throw Failure.changedFiles
                }
            } catch {
                task.cancel()
                _ = await task.result
                throw error
            }
        }
    }
}

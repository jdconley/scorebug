import Foundation
import XCTest
@testable import ScorebugMedia

final class ArchiveExporterTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, RecoveredArchive) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ArchiveSegmentStore(directory: root.appendingPathComponent("part"), profile: ArchiveProfile(), availableBytes: { Int64.max })
        try store.append(data: Data("invalid initialization".utf8), kind: .initialization)
        try store.append(data: Data("invalid media".utf8), kind: .media, startTime: 0, duration: 2)
        return (root, try ArchiveSegmentStore.recover(directory: store.directory))
    }

    func testExistingDestinationIsPreservedAndRejectedBeforeReadingMedia() async throws {
        let (root, archive) = try fixture()
        let target = root.appendingPathComponent("movie.mp4")
        let original = Data("unrelated file".utf8)
        try original.write(to: target)
        do {
            _ = try await ArchiveExporter().export(archive, to: target)
            XCTFail("Existing output must not be replaced")
        } catch {
            XCTAssertEqual(error as? ArchiveExportError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: archive.directory).segments, archive.segments)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["part", "movie.mp4"])
    }

    func testSymlinkAndDirectoryDestinationsAreNeverRemoved() async throws {
        for isSymlink in [false, true] {
            let (root, archive) = try fixture()
            let target = root.appendingPathComponent("movie.mp4")
            let outside = root.appendingPathComponent("outside")
            try Data([42]).write(to: outside)
            if isSymlink {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            do {
                _ = try await ArchiveExporter().export(archive, to: target)
                XCTFail("Unsupported destination must be rejected")
            } catch {
                XCTAssertEqual(error as? ArchiveExportError, .unsupportedFile(target.path))
            }
            XCTAssertEqual(try Data(contentsOf: outside), Data([42]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testSymlinkParentIsRejectedWithoutFollowingIt() async throws {
        let (root, archive) = try fixture()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        do {
            _ = try await ArchiveExporter().export(archive, to: alias.appendingPathComponent("movie.mp4"))
            XCTFail("Symlink parent must be rejected")
        } catch {
            XCTAssertEqual(error as? ArchiveExportError, .unsupportedFile(alias.path))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["part", "alias"])
    }

    func testInvalidMediaPreservesSourceAndCleansOnlyOwnedOutputs() async throws {
        let (root, archive) = try fixture()
        let unrelated = root.appendingPathComponent(".archive-export-unrelated")
        try Data([99]).write(to: unrelated)
        do {
            _ = try await ArchiveExporter().export(archive, to: root.appendingPathComponent("movie.mp4"))
            XCTFail("Invalid MP4 must never be published")
        } catch { }
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: archive.directory).segments, archive.segments)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([99]))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["part", unrelated.lastPathComponent])
    }

    func testAssemblyRechecksPayloadBeforeExport() async throws {
        let (root, archive) = try fixture()
        let payload = archive.directory.appendingPathComponent("000001.segment/payload.bin")
        try Data("tampered media".utf8).write(to: payload)
        do {
            _ = try await ArchiveExporter().export(archive, to: root.appendingPathComponent("movie.mp4"))
            XCTFail("Tampered source must fail verification")
        } catch {
            XCTAssertNotNil(error as? ArchiveStoreError)
        }
        XCTAssertEqual(try Data(contentsOf: payload), Data("tampered media".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["part"])
    }

    func testCancellationPreservesSourceAndLeavesNoOutput() async throws {
        let (root, archive) = try fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArchiveExporter().export(archive, to: root.appendingPathComponent("movie.mp4"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled export must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: archive.directory).segments, archive.segments)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["part"])
    }

    func testUnknownAndInsufficientCapacityFailClosedBeforeAssembly() async throws {
        for free: Int64? in [nil, 0, 64 * 1024 * 1024] {
            let (root, archive) = try fixture()
            let exporter = ArchiveExporter(availableBytes: { _ in free })
            do {
                _ = try await exporter.export(archive, to: root.appendingPathComponent("movie.mp4"))
                XCTFail("Insufficient capacity must fail before output creation")
            } catch {
                XCTAssertEqual(error as? ArchiveExportError, free == nil ? .unknownCapacity : .insufficientCapacity)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["part"])
            XCTAssertEqual(try ArchiveSegmentStore.recover(directory: archive.directory).segments, archive.segments)
        }
    }
}

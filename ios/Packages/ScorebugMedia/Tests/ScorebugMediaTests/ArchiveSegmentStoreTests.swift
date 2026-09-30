import Foundation
import Darwin
import XCTest
@testable import ScorebugMedia

final class ArchiveSegmentStoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func store(at directory: URL) throws -> ArchiveSegmentStore {
        try ArchiveSegmentStore(directory: directory, profile: ArchiveProfile(), availableBytes: { Int64.max })
    }

    private func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return info.resident_size
    }

    private func largeArchive() throws -> URL {
        let directory = try temporaryRoot().appendingPathComponent("part")
        let writer = try store(at: directory)
        try writer.append(data: Data([1]), kind: .initialization)
        let payload = Data(repeating: 42, count: 8 * 1024 * 1024)
        for sequence in 0..<16 {
            _ = try autoreleasepool {
                try writer.append(data: payload, kind: .media, startTime: Double(sequence * 2), duration: 2)
            }
        }
        return directory
    }

    func testRecoveryMemoryDoesNotGrowWithVerifiedPayloadBytes() throws {
        let directory = try largeArchive()
        try autoreleasepool {
            let before = try residentBytes()
            let archive = try ArchiveSegmentStore.recover(directory: directory)
            XCTAssertEqual(archive.segments.count, 17)
            for _ in 0..<8 { _ = try ArchiveSegmentStore.recover(directory: directory) }
            let growth = Int64(try residentBytes()) - Int64(before)
            XCTAssertLessThan(growth, 32 * 1024 * 1024,
                              "Repeated recovery retained verified payloads")
        }
    }

    func testAssemblyMemoryDoesNotGrowWithCopiedPayloadBytes() throws {
        let directory = try largeArchive()
        let archive = try autoreleasepool { try ArchiveSegmentStore.recover(directory: directory) }
        let output = directory.deletingLastPathComponent().appendingPathComponent("assembled.mp4")
        try autoreleasepool {
            let before = try residentBytes()
            try archive.assemble(to: output)
            for index in 0..<8 {
                try archive.assemble(to: directory.deletingLastPathComponent().appendingPathComponent("copy-\(index).mp4"))
            }
            let growth = Int64(try residentBytes()) - Int64(before)
            XCTAssertLessThan(growth, 32 * 1024 * 1024,
                              "Repeated assembly retained copied payloads")
        }
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 128 * 1024 * 1024 + 1)
    }

    func testProfileDefaultsAndValidation() throws {
        let profile = ArchiveProfile()
        XCTAssertEqual(profile.width, 1920)
        XCTAssertEqual(profile.height, 1080)
        XCTAssertEqual(profile.framesPerSecond, 30)
        XCTAssertEqual(profile.videoBitRate, 12_000_000)
        XCTAssertEqual(profile.segmentDuration, 2)
        try profile.validate()
        XCTAssertThrowsError(try ArchiveProfile(width: 1919).validate())
        XCTAssertThrowsError(try ArchiveProfile(segmentDuration: 4).validate())
        XCTAssertThrowsError(try ArchiveProfile(audioSampleRate: .nan).validate())
    }

    func testOrderingValidationDoesNotPoisonStore() throws {
        let store = try store(at: temporaryRoot().appendingPathComponent("part"))
        XCTAssertThrowsError(try store.append(data: Data([1]), kind: .media))
        XCTAssertEqual(try store.append(data: Data([1]), kind: .initialization).sequence, 0)
        XCTAssertThrowsError(try store.append(data: Data([1]), kind: .initialization))
        XCTAssertThrowsError(try store.append(data: Data([1]), kind: .media, startTime: .nan))
        XCTAssertEqual(try store.append(data: Data([2]), kind: .media, startTime: 0, duration: 2).sequence, 1)
        XCTAssertEqual(store.segments.count, 2)
    }

    func testExistingPartIsNeverOverwritten() throws {
        let directory = try temporaryRoot().appendingPathComponent("part")
        let first = try store(at: directory)
        try first.append(data: Data([42]), kind: .initialization)
        XCTAssertThrowsError(try store(at: directory))
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: directory).segments.count, 1)
    }

    func testRecoveryIgnoresManifestAndStagingAndAssemblesInOrder() throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("part")
        let store = try store(at: directory)
        try store.append(data: Data([1, 2]), kind: .initialization)
        try store.append(data: Data([3, 4]), kind: .media, startTime: 0, duration: 2)
        try store.append(data: Data([5]), kind: .media)
        try Data("invalid manifest".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".staging-abandoned"), withIntermediateDirectories: false)
        let recovered = try ArchiveSegmentStore.recover(directory: directory)
        XCTAssertEqual(recovered.profile, ArchiveProfile())
        XCTAssertEqual(recovered.segments.map(\.sequence), [0, 1, 2])
        let output = root.appendingPathComponent("assembled.mp4")
        try recovered.assemble(to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3, 4, 5]))
        XCTAssertThrowsError(try recovered.assemble(to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3, 4, 5]))
    }

    func testMissingManifestDoesNotLoseSegments() throws {
        let directory = try temporaryRoot().appendingPathComponent("part")
        let store = try store(at: directory)
        try store.append(data: Data([1]), kind: .initialization)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: directory).segments.count, 1)
    }

    func testFailureBoundariesPreserveCommittedBundlesAndStopWrites() throws {
        for point in [ArchiveStoreFailurePoint.beforeCommit, .afterRename, .beforeManifest] {
            let directory = try temporaryRoot().appendingPathComponent("part")
            let store = try ArchiveSegmentStore(directory: directory, profile: ArchiveProfile(), availableBytes: { Int64.max }, failureInjection: { current in
                if current == point { throw CocoaError(.fileWriteUnknown) }
            })
            XCTAssertThrowsError(try store.append(data: Data([1]), kind: .initialization))
            XCTAssertThrowsError(try store.append(data: Data([2]), kind: .initialization))
            let recovered = try ArchiveSegmentStore.recover(directory: directory)
            XCTAssertEqual(recovered.segments.count, point == .beforeCommit ? 0 : 1)
        }
    }

    func testInsufficientAndUnknownCapacityFailClosed() throws {
        for available: Int64? in [0, nil] {
            let directory = try temporaryRoot().appendingPathComponent("part")
            let store = try ArchiveSegmentStore(directory: directory, profile: ArchiveProfile(), availableBytes: { available })
            XCTAssertThrowsError(try store.append(data: Data([1]), kind: .initialization))
            XCTAssertEqual(try ArchiveSegmentStore.recover(directory: directory).segments, [])
        }
    }

    func testRejectsPayloadHashCorruption() throws {
        let directory = try temporaryRoot().appendingPathComponent("part")
        let store = try store(at: directory)
        try store.append(data: Data([1, 2]), kind: .initialization)
        try Data([3, 4]).write(to: directory.appendingPathComponent("000000.segment/payload.bin"))
        XCTAssertThrowsError(try ArchiveSegmentStore.recover(directory: directory))
    }

    func testRejectsMissingOrInvalidCommittedMetadata() throws {
        for bytes: Data? in [nil, Data("{}".utf8)] {
            let directory = try temporaryRoot().appendingPathComponent("part")
            let store = try store(at: directory)
            try store.append(data: Data([1]), kind: .initialization)
            let metadata = directory.appendingPathComponent("000000.segment/metadata.json")
            try FileManager.default.removeItem(at: metadata)
            if let bytes { try bytes.write(to: metadata) }
            XCTAssertThrowsError(try ArchiveSegmentStore.recover(directory: directory))
        }
    }

    func testRejectsGapInCommittedSequence() throws {
        let directory = try temporaryRoot().appendingPathComponent("part")
        let store = try store(at: directory)
        try store.append(data: Data([1]), kind: .initialization)
        try store.append(data: Data([2]), kind: .media)
        try store.append(data: Data([3]), kind: .media)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("000001.segment"))
        XCTAssertThrowsError(try ArchiveSegmentStore.recover(directory: directory))
    }

    func testRecoveryRejectsSymlinkPayloadAndRoot() throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("part")
        let store = try store(at: directory)
        try store.append(data: Data([1]), kind: .initialization)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try ArchiveSegmentStore.recover(directory: alias))
        let payload = directory.appendingPathComponent("000000.segment/payload.bin")
        let outside = root.appendingPathComponent("outside.bin")
        try Data([1]).write(to: outside)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
        XCTAssertThrowsError(try ArchiveSegmentStore.recover(directory: directory))
    }

    func testAssemblyRevalidatesSourceAndPreservesExistingFilesOnFailure() throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("part")
        let store = try store(at: directory)
        try store.append(data: Data([1]), kind: .initialization)
        let recovered = try ArchiveSegmentStore.recover(directory: directory)
        try Data([2]).write(to: directory.appendingPathComponent("000000.segment/payload.bin"))
        let output = root.appendingPathComponent("output.mp4")
        XCTAssertThrowsError(try recovered.assemble(to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAssemblyStreamsPayloadsLargerThanReadBuffer() throws {
        let root = try temporaryRoot()
        let store = try store(at: root.appendingPathComponent("part"))
        let payload = Data(repeating: 0xAB, count: 2 * 1024 * 1024 + 17)
        try store.append(data: Data([1, 2, 3]), kind: .initialization)
        try store.append(data: payload, kind: .media)
        let output = root.appendingPathComponent("output.mp4")
        try ArchiveSegmentStore.recover(directory: store.directory).assemble(to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3]) + payload)
    }

    func testFailureAfterEarlierSegmentKeepsEarlierAndNewlyCommittedSegments() throws {
        let root = try temporaryRoot()
        let marker = root.appendingPathComponent("fail-now")
        let store = try ArchiveSegmentStore(directory: root.appendingPathComponent("part"), profile: ArchiveProfile(), availableBytes: { Int64.max }, failureInjection: { point in
            if point == .beforeManifest && FileManager.default.fileExists(atPath: marker.path) {
                throw CocoaError(.fileWriteUnknown)
            }
        })
        try store.append(data: Data([1]), kind: .initialization)
        try Data([0]).write(to: marker)
        XCTAssertThrowsError(try store.append(data: Data([2]), kind: .media))
        XCTAssertEqual(store.failureCount, 1)
        XCTAssertEqual(store.segments.map(\.sequence), [0, 1])
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: store.directory).segments.map(\.sequence), [0, 1])
    }

    func testRecoveryRejectsSymlinkMetadataAndSegmentDirectory() throws {
        for component in ["000000.segment/metadata.json", "000000.segment"] {
            let root = try temporaryRoot()
            let store = try store(at: root.appendingPathComponent("part"))
            try store.append(data: Data([1]), kind: .initialization)
            let original = store.directory.appendingPathComponent(component)
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            XCTAssertThrowsError(try ArchiveSegmentStore.recover(directory: store.directory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        }
    }

    func testEmptyAndOversizedPayloadsDoNotPoisonStore() throws {
        let store = try store(at: temporaryRoot().appendingPathComponent("part"))
        XCTAssertThrowsError(try store.append(data: Data(), kind: .initialization))
        XCTAssertThrowsError(try store.append(data: Data(count: ArchiveSegmentStore.maximumSegmentBytes + 1), kind: .initialization))
        XCTAssertEqual(try store.append(data: Data([1]), kind: .initialization).sequence, 0)
    }

    func testCapacityIncludesMetadataAndReplacementManifest() throws {
        let directory = try temporaryRoot().appendingPathComponent("part")
        // Enough for the payload and filesystem allowance, but no JSON files.
        let store = try ArchiveSegmentStore(directory: directory, profile: ArchiveProfile(), reserveBytes: 0,
                                            availableBytes: { 1024 * 1024 + 1 })
        XCTAssertThrowsError(try store.append(data: Data([1]), kind: .initialization)) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .insufficientCapacity)
        }
        XCTAssertEqual(try ArchiveSegmentStore.recover(directory: directory).segments, [])
    }

    func testPendingEstimateIncludesLargeEncodedManifest() throws {
        // Exercise a long recording without thousands of durable filesystem writes.
        let segments = (0..<10_000).map { sequence in
            ArchiveSegment(sequence: sequence, kind: sequence == 0 ? .initialization : .media,
                           startTime: Double(sequence * 2), duration: 2, byteCount: 3_000_000,
                           sha256: String(repeating: "a", count: 64))
        }
        let metadata = try JSONEncoder().encode(segments.last!)
        let manifest = try JSONEncoder().encode(segments)
        XCTAssertGreaterThan(manifest.count, 1024 * 1024)
        let pending = ArchiveSegmentStore.pendingWriteBytes(payloadByteCount: 3_000_000,
                                                            metadata: metadata, manifest: manifest)
        XCTAssertEqual(pending, 3_000_000 + Int64(metadata.count) + Int64(manifest.count) + 1024 * 1024)
        XCTAssertGreaterThan(pending, 3_000_000 + 2 * 1024 * 1024)
    }
}

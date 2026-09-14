import AVFoundation

import Foundation
import ScorebugMedia
import XCTest

final class RecordingLibraryTests: XCTestCase {
    func testRelaunchDistinguishesCompletedFromInterruptedWithoutChangingFragments() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(rootDirectory: root)
        let complete = try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink)
        let interrupted = try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink)
        try await library.finish(id: complete.id, failure: nil)
        let reopened = RecordingLibrary(rootDirectory: root)
        let rows = try await reopened.list()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == complete.id }?.status, .completed)
        XCTAssertEqual(rows.first { $0.id == interrupted.id }?.status, .recoverable)
        XCTAssertNotNil(rows.first { $0.id == interrupted.id }?.reason)
        let bytes = try Data(contentsOf: complete.directory.appendingPathComponent("000001.segment/payload.bin"))
        do { _ = try await reopened.export(id: complete.id); XCTFail("Fixture bytes are not valid media") } catch {}
        XCTAssertEqual(try Data(contentsOf: complete.directory.appendingPathComponent("000001.segment/payload.bin")), bytes)
        let afterExport = try await reopened.list()
        XCTAssertEqual(afterExport.count, 2)
    }

    func testRecoveredDurationUsesMediaSpanRatherThanAbsoluteSourceClock() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(rootDirectory: root)
        let draft = try await library.begin(profile: ArchiveProfile(), sinkFactory: { directory, profile in
            let store = try ArchiveSegmentStore(directory: directory, profile: profile)
            try store.append(data: Data("init".utf8), kind: .initialization)
            try store.append(data: Data("media".utf8), kind: .media, startTime: 3600, duration: 2)
            try store.append(data: Data("media2".utf8), kind: .media, startTime: 3602, duration: 1)
            return LibraryTestSink(directory: directory)
        })
        try await library.finish(id: draft.id, failure: nil)
        let rows = try await library.list()
        XCTAssertEqual(rows.first?.duration, 3)
    }

    func testMissingCorruptAndZeroMediaStayVisibleAndCannotClaimComplete() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        let corrupt = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: false)
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent("part.json"))
        let empty = root.appendingPathComponent(UUID().uuidString)
        _ = try ArchiveSegmentStore(directory: empty, profile: ArchiveProfile())
        let rows = try await RecordingLibrary(rootDirectory: root).list()
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.status == .unavailable && $0.reason != nil && !$0.canExport })
    }

    func testActiveArchiveCannotBeScannedOrExportedAndUnsafePathsAreRejected() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(rootDirectory: root)
        let active = try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink)
        let activeRows = try await library.list()
        XCTAssertTrue(activeRows.isEmpty)
        do { _ = try await library.export(id: active.id); XCTFail("Active archive must not export") } catch {}
        do { _ = try await library.export(id: "../outside"); XCTFail("Traversal must fail") } catch {}
        let linked = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: active.directory)
        let rows = try await library.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .unavailable)
        do { _ = try await library.export(id: linked.lastPathComponent); XCTFail("Symlink must fail") } catch {}
    }

    func testStatusSyncFailureAfterRenameCannotAppearCompletedAfterRelaunch() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = FailingStatusSync()
        let library = RecordingLibrary(rootDirectory: root, statusSync: { try sync.run($0) })
        let draft = try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink)
        do { try await library.finish(id: draft.id, failure: nil); XCTFail("Status durability failure must propagate") } catch {}
        let rows = try await RecordingLibrary(rootDirectory: root).list()
        XCTAssertEqual(rows.first?.status, .recoverable)
        XCTAssertTrue(rows.first?.canExport == true)
    }

    func testStatusWriteFailureCannotBecomeCompleted() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(rootDirectory: root)
        let draft = try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink)
        let status = draft.directory.appendingPathComponent("recording-status.json")
        try FileManager.default.removeItem(at: status)
        try FileManager.default.createDirectory(at: status, withIntermediateDirectories: false)
        do { try await library.finish(id: draft.id, failure: nil); XCTFail("Marker failure must propagate") } catch {}
        let rows = try await RecordingLibrary(rootDirectory: root).list()
        XCTAssertEqual(rows.first?.status, .recoverable)
        XCTAssertNotNil(rows.first?.reason)
    }
}

func testRecordingRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("film-tests-\(UUID().uuidString)") }

let testArchiveSink: RecordingLibrary.SinkFactory = { directory, profile in
    let store = try ArchiveSegmentStore(directory: directory, profile: profile)
    try store.append(data: Data("initialization fixture".utf8), kind: .initialization)
    try store.append(data: Data("media fixture".utf8), kind: .media, startTime: 0, duration: 1)
    return LibraryTestSink(directory: directory)
}

struct LibraryTestSink: RecordingArchiveSink {
    let directory: URL
    func start(at timestamp: CMTime) throws {}
    func append(_ sample: CapturedMediaSample) throws -> Bool { true }
    func finish() async throws -> RecoveredArchive { try ArchiveSegmentStore.recover(directory: directory) }
    func cancel() {}
}

final class FailingStatusSync: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func run(_ directory: URL) throws {
        let call = lock.withLock { calls += 1; return calls }
        if call > 1 { throw CocoaError(.fileWriteUnknown) }
    }
}

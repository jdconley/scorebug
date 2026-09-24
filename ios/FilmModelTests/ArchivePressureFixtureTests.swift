#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia
import XCTest

@MainActor final class ArchivePressureFixtureTests: XCTestCase {
    func testExactFlagAndMacDefaultDisabled() async throws {
        XCTAssertTrue(ArchivePressureFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1"]))
        for value in ["", "0", "true", "01", " 1"] {
            XCTAssertFalse(ArchivePressureFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": value]))
        }
        XCTAssertFalse(ArchivePressureFixture.requested(environment: [:]))
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink)
        XCTAssertNil(model.archivePressureFactory)
        XCTAssertNil(model.archivePressureWriter)
        XCTAssertNil(model.fileFixtureStatisticsWriter)
        var exports = 0
        model.archivePressureWriter = { _ in exports += 1 }
        await model.start(); await model.stop()
        XCTAssertEqual(exports, 0)
    }

    func testDraftScopeUnsupportedCoverageAndRepeatedStop() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink)
        var owners: [ArchivePressureDiagnostics] = []
        var exports: [ArchivePressureDiagnostics.Snapshot] = []
        model.archivePressureFactory = { id in
            let owner = ArchivePressureDiagnostics(recordingID: id)
            owners.append(owner); return owner
        }
        model.archivePressureWriter = { exports.append($0) }
        await model.start()
        let firstID = try XCTUnwrap(model.currentCapture?.id)
        await model.stop(); await model.stop()
        XCTAssertEqual(exports.count, 1)
        let closed = try XCTUnwrap(exports.first)
        XCTAssertEqual(closed.recordingID, firstID)
        XCTAssertTrue(closed.closed)
        XCTAssertEqual(closed.terminal?.state, "finished")
        XCTAssertTrue(closed.coverage.session)
        XCTAssertFalse(closed.coverage.producer)
        XCTAssertFalse(closed.coverage.persistence)
        XCTAssertNotNil(closed.queueLimits)
        XCTAssertNil(closed.profile)
        let data = try ArchivePressureFixture.data(for: closed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["recordingID"] as? String, firstID)
        XCTAssertNil(object["firstFailure"], "Swift optional fields are omitted")
        await model.start(); await model.stop()
        XCTAssertEqual(exports.count, 2)
        XCTAssertNotEqual(exports.last?.recordingID, firstID)
        XCTAssertEqual(owners[0].snapshot, closed)
    }

    func testJoinedExportBlocksRestartAndClosesBeforeDurationRead() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = BlockingFilmDurationReader()
        let gate = FilmTestGate()
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink,
                              durationReader: { reader.read($0) })
        var owner: ArchivePressureDiagnostics?
        var exports = 0
        model.archivePressureFactory = { id in
            let created = ArchivePressureDiagnostics(recordingID: id); owner = created; return created
        }
        model.archivePressureWriter = { _ in exports += 1; await gate.enter() }
        await model.start()
        let id = model.currentCapture?.id
        reader.arm()
        let stopping = Task { await model.stop() }
        await fulfillment(of: [reader.entered], timeout: 3)
        XCTAssertTrue(try XCTUnwrap(owner).snapshot.closed, "Close precedes metrics I/O")
        reader.release()
        await gate.waitUntilEntered()
        XCTAssertEqual(model.state, .stopping)
        XCTAssertFalse(model.canStart)
        await model.start()
        XCTAssertEqual(exports, 1)
        var secondStopFinished = false
        let repeated = Task { await model.stop(); secondStopFinished = true }
        await Task.yield()
        XCTAssertFalse(secondStopFinished)
        await gate.release()
        await stopping.value; await repeated.value
        XCTAssertEqual(exports, 1)
        XCTAssertTrue(model.canStart)
        model.archivePressureWriter = { _ in exports += 1 }
        await model.start()
        XCTAssertNotEqual(model.currentCapture?.id, id)
        await model.stop()
        XCTAssertEqual(exports, 2)
    }

    func testExporterErrorPreservesSuccessAndCaptureFailure() async throws {
        for fail in [false, true] {
            let root = testRecordingRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = FilmTestSource()
            let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
            var exported: ArchivePressureDiagnostics.Snapshot?
            model.archivePressureFactory = { ArchivePressureDiagnostics(recordingID: $0) }
            model.archivePressureWriter = { snapshot in exported = snapshot; throw CocoaError(.fileWriteUnknown) }
            await model.start()
            if fail { source.interrupt() }
            await model.stop()
            XCTAssertEqual(model.state, fail ? .failed : .idle)
            XCTAssertEqual(model.recordings.first?.status, fail ? .recoverable : .completed)
            XCTAssertEqual(exported?.terminal?.failure, fail ? .captureFailed : nil)
            XCTAssertEqual(exported?.closed, true)
            XCTAssertFalse(model.message?.contains("write") ?? true)
        }
    }

    func testCancelledStartupExportsMatchingClosedOwner() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FilmTestGate()
        let source = FilmTestSource(gate: gate)
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        var exported: ArchivePressureDiagnostics.Snapshot?
        model.archivePressureFactory = { ArchivePressureDiagnostics(recordingID: $0) }
        model.archivePressureWriter = { exported = $0 }
        let starting = Task { await model.start() }
        await gate.waitUntilEntered()
        let stopping = Task { await model.stop() }
        while model.state != .stopping { await Task.yield() }
        await gate.release()
        await starting.value; await stopping.value
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(exported?.closed, true)
        XCTAssertEqual(exported?.terminal?.failure, .cancelled)
        XCTAssertEqual(exported?.recordingID, model.recordings.first?.id)
    }

    func testCancellationBeforeLibraryBeginReturnsDoesNotCreateSourceOrDiagnostics() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FilmScanStorageGate()
        let library = RecordingLibrary(rootDirectory: root, statusSync: { gate.waitOnce($0) })
        var sources = 0, owners = 0, exports = 0
        let model = FilmModel(library: library, sourceFactory: { sources += 1; return FilmTestSource() }, sinkFactory: testArchiveSink)
        model.archivePressureFactory = { id in owners += 1; return ArchivePressureDiagnostics(recordingID: id) }
        model.archivePressureWriter = { _ in exports += 1 }
        let starting = Task { await model.start() }
        await fulfillment(of: [gate.entered], timeout: 3)
        let stopping = Task { await model.stop() }
        while model.state != .stopping { await Task.yield() }
        gate.release()
        await starting.value; await stopping.value
        XCTAssertEqual(sources, 0)
        XCTAssertEqual(owners, 0)
        XCTAssertEqual(exports, 0)
        XCTAssertEqual(model.state, .failed)
        XCTAssertFalse(gate.timedOut)
    }

    func testThrownSourceStartupClosesOwnedDiagnostics() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FilmTestSource(failOnStart: true)
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        var exported: ArchivePressureDiagnostics.Snapshot?
        model.archivePressureFactory = { ArchivePressureDiagnostics(recordingID: $0) }
        model.archivePressureWriter = { exported = $0 }
        await model.start()
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(exported?.recordingID, model.recordings.first?.id)
        XCTAssertEqual(exported?.closed, true)
        XCTAssertEqual(exported?.terminal?.failure, .captureFailed)
    }

    func testSinkFinishAndExporterErrorsPreserveOriginalFailure() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() },
            sinkFactory: { directory, profile in
                FailingFinishArchiveSink(underlying: try testArchiveSink(directory, profile))
            })
        var exported: ArchivePressureDiagnostics.Snapshot?
        model.archivePressureFactory = { ArchivePressureDiagnostics(recordingID: $0) }
        model.archivePressureWriter = { snapshot in exported = snapshot; throw CocoaError(.fileWriteUnknown) }
        await model.start(); await model.stop()
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(exported?.terminal?.failure, .sinkFailed)
        XCTAssertEqual(exported?.firstFailure?.reason, .sinkFailed)
        XCTAssertEqual(exported?.closed, true)
        XCTAssertTrue(model.message?.contains("sinkFailed") ?? false)
        XCTAssertEqual(model.recordings.first?.status, .recoverable)
    }

    func testFilmAttachesSameOwnerToNativeComponentsBeforeStartup() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ArchiveProfile(width: 320, height: 240)
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), profile: profile,
            sourceFactory: { FixtureCameraSource(profile: profile, failAfterFrames: 0) })
        var exported: ArchivePressureDiagnostics.Snapshot?
        model.archivePressureFactory = { ArchivePressureDiagnostics(recordingID: $0) }
        model.archivePressureWriter = { exported = $0 }
        await model.start(); await model.stop()
        let closed = try XCTUnwrap(exported)
        XCTAssertEqual(closed.recordingID, model.recordings.first?.id)
        XCTAssertTrue(closed.closed)
        XCTAssertTrue(closed.coverage.producer)
        XCTAssertTrue(closed.coverage.session)
        XCTAssertTrue(closed.coverage.persistence)
        XCTAssertEqual(closed.profile, profile)
        XCTAssertEqual(closed.queueLimits?.maxItems, "24")
    }

    func testNativeComponentAttachmentsEncodeActualCoverageAndProfile() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let instant = ContinuousClock.now
        let diagnostics = ArchivePressureDiagnostics(recordingID: "encoded-fixture", now: { instant })
        let profile = ArchiveProfile(width: 320, height: 240)
        let writer = try SegmentedArchiveWriter(directory: root, profile: profile)
        let session = try RecordingSession(sink: SegmentedArchiveSink(writer: writer))
        let source = FixtureCameraSource(profile: profile)
        XCTAssertTrue(session.attachArchivePressureDiagnostics(diagnostics))
        XCTAssertTrue(writer.attachArchivePressureDiagnostics(diagnostics))
        XCTAssertTrue(source.attachArchivePressureDiagnostics(diagnostics))
        session.cancel()
        let closed = diagnostics.close(snapshot: session.snapshot)
        XCTAssertEqual(closed.profile, profile)
        XCTAssertTrue(closed.coverage.persistence)
        XCTAssertTrue(closed.coverage.producer)
        let data = try ArchivePressureFixture.data(for: closed)
        // Both language suites share an actual deterministic Swift encoding. This
        // catches encoder/validator drift, including nil fields being omitted.
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test/fixtures/archive-diagnostics-swift.json")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(actual, expected)
    }

    func testWrongFactoryIdentityCannotExportAnotherRecording() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink)
        var exports = 0
        model.archivePressureFactory = { _ in ArchivePressureDiagnostics(recordingID: "wrong-draft") }
        model.archivePressureWriter = { _ in exports += 1 }
        await model.start(); await model.stop()
        XCTAssertEqual(exports, 0)
        XCTAssertEqual(model.state, .idle)
    }
}
private struct FailingFinishArchiveSink: RecordingArchiveSink {
    let underlying: any RecordingArchiveSink
    func start(at timestamp: CMTime) throws { try underlying.start(at: timestamp) }
    func append(_ sample: CapturedMediaSample) throws -> Bool { try underlying.append(sample) }
    func finish() async throws -> RecoveredArchive { throw RecordingSessionError.sinkFailed }
    func cancel() { underlying.cancel() }
}
#endif

import AVFoundation
import Foundation
import ScorebugMedia
import XCTest

@MainActor final class FilmModelTests: XCTestCase {
    func testCaptureContextExistsOnlyWhileRecordingAndClearsBeforeShutdown() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink)
        var transitions: [String?] = []
        model.onCaptureChanged = { transitions.append($0?.id) }
        XCTAssertNil(model.currentCapture)
        await model.start()
        let first = try XCTUnwrap(model.currentCapture)
        XCTAssertFalse(first.startedAt.isEmpty)
        await model.stop()
        XCTAssertNil(model.currentCapture)
        XCTAssertEqual(transitions.count, 2)
        XCTAssertNil(transitions.last!)
        await model.start()
        XCTAssertNotEqual(model.currentCapture?.id, first.id)
        XCTAssertFalse(model.currentCapture?.tap === first.tap)
        await model.stop()
    }

    func testConstructionAndRefreshDoNotCreateSourceAndRecordingWorksWithoutServer() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var creations = 0
        let source = FilmTestSource()
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: {
            creations += 1
            return source
        }, sinkFactory: testArchiveSink)
        await model.refreshRecordings()
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(model.state, .idle)
        await model.start()
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(creations, 1)
        await model.start()
        XCTAssertEqual(creations, 1)
        await model.stop()
        await model.stop()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(model.recordings.first?.status, .completed)
    }

    func testCaptureFailureIsVisibleAndPreservesRecoverableOriginal() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FilmTestSource()
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        await model.start()
        source.interrupt()
        await model.pollHealth()
        XCTAssertEqual(model.state, .failed)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(model.recordings.first?.status, .recoverable)
        XCTAssertTrue(model.canStart)
    }

    func testRecordingRefreshUsesCachedRowsUntilStop() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(rootDirectory: root)
        var creations = 0
        let model = FilmModel(library: library, sourceFactory: {
            creations += 1
            return FilmTestSource()
        }, sinkFactory: testArchiveSink)
        await model.refreshRecordings()
        XCTAssertTrue(model.recordings.isEmpty)
        XCTAssertEqual(creations, 0)
        await model.start()
        // Another process/relaunch could have left historical media on disk.
        let historical = try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink)
        try await library.finish(id: historical.id, failure: nil)
        await model.refreshRecordings()
        XCTAssertTrue(model.recordings.isEmpty, "Opening Recordings during capture must serve cached rows")
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(creations, 1)
        await model.stop()
        XCTAssertEqual(model.recordings.count, 2)
        XCTAssertTrue(model.recordings.contains { $0.id == historical.id })
        XCTAssertEqual(creations, 1)
    }

    func testStartIsRejectedWhileFilesystemScanIsPending() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FilmScanStorageGate()
        let library = RecordingLibrary(rootDirectory: root, statusSync: { gate.waitOnce($0) })
        let preparingDisk = Task { try await library.begin(profile: ArchiveProfile(), sinkFactory: testArchiveSink) }
        await fulfillment(of: [gate.entered], timeout: 3)
        var creations = 0
        let model = FilmModel(library: library, sourceFactory: {
            creations += 1
            return FilmTestSource()
        }, sinkFactory: testArchiveSink)
        let scan = Task { await model.refreshRecordings() }
        while !model.isScanning { await Task.yield() }
        XCTAssertFalse(model.canStart)
        var startReturned = false
        let attemptedStart = Task { await model.start(); startReturned = true }
        // A correct rejection returns immediately. The old behavior enters starting
        // and waits behind the disk gate, which must still be released for cleanup.
        while !startReturned && model.state == .idle { await Task.yield() }
        XCTAssertEqual(model.state, .idle)
        gate.release()
        let historical = try await preparingDisk.value
        await scan.value
        await attemptedStart.value
        XCTAssertEqual(creations, 0)
        XCTAssertTrue(model.canStart)
        XCTAssertFalse(model.isScanning)
        XCTAssertFalse(gate.timedOut)
        if model.canStop { await model.stop() }
        try await library.finish(id: historical.id, failure: nil)
    }

    func testBlockedDurationReadLeavesMainActorResponsiveAndDoesNotAccumulatePolls() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = BlockingFilmDurationReader()
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() },
                              sinkFactory: testArchiveSink, durationReader: { reader.read($0) })
        await model.start()
        reader.arm()
        let polling = Task { await model.pollHealth() }
        await fulfillment(of: [reader.entered], timeout: 3)
        XCTAssertFalse(reader.timedOut, "MainActor must resume while the storage metrics reader is blocked")
        XCTAssertEqual(model.state, .recording)
        await model.pollHealth()
        XCTAssertEqual(reader.readCount, 1, "Only one metrics read may be outstanding")
        reader.release()
        await polling.value
        XCTAssertFalse(reader.readOnMainThread)
        await model.stop()
    }

    func testOldBlockedDurationCannotOverwriteNewRecordingMetrics() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = BlockingFilmDurationReader()
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() },
                              sinkFactory: testArchiveSink, durationReader: { reader.read($0) })
        await model.start()
        reader.arm()
        let oldPoll = Task { await model.pollHealth() }
        await fulfillment(of: [reader.entered], timeout: 3)
        await model.stop()
        await model.start()
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(model.elapsedSeconds, 0, "The new recording resets duration while an old read is pending")
        reader.release()
        await oldPoll.value
        XCTAssertEqual(model.elapsedSeconds, 0, "An old archive's duration must not replace the new recording's metrics")
        await model.pollHealth()
        XCTAssertEqual(model.elapsedSeconds, 7)
        XCTAssertFalse(reader.timedOut)
        await model.stop()
    }

    func testStopDuringStartupCannotReturnToRecording() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FilmTestGate()
        let source = FilmTestSource(gate: gate)
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        let starting = Task { await model.start() }
        await gate.waitUntilEntered()
        let stopping = Task { await model.stop() }
        while model.state != .stopping { await Task.yield() }
        await gate.release()
        await starting.value
        await stopping.value
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertTrue(model.canStart)
    }
}

final class FilmTestSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: CaptureSourceCallbacks?
    private var stops = 0
    let gate: FilmTestGate?
    let failOnStart: Bool
    init(gate: FilmTestGate? = nil, failOnStart: Bool = false) { self.gate = gate; self.failOnStart = failOnStart }
    var stopCount: Int { lock.withLock { stops } }
    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        lock.withLock { self.callbacks = callbacks }
        if let gate { await gate.enter() }
        return .zero
    }
    func start() async throws { if failOnStart { throw CocoaError(.fileReadUnknown) } }
    func stop() async { lock.withLock { stops += 1; callbacks = nil } }
    func interrupt() { lock.withLock { callbacks }?.event(.interrupted) }
    func send(_ sample: CapturedMediaSample) { lock.withLock { callbacks }?.sample(sample) }
}

actor FilmTestGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func waitUntilEntered(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        return entered
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Simulates a storage lock without blocking test cleanup indefinitely on a regression.
final class BlockingFilmDurationReader: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Duration read entered storage wait")
    private let lock = NSLock()
    private let permit = DispatchSemaphore(value: 0)
    private var armed = false
    private var reads = 0
    private var expired = false
    private var onMain = false
    var timedOut: Bool { lock.withLock { expired } }
    var readCount: Int { lock.withLock { reads } }
    var readOnMainThread: Bool { lock.withLock { onMain } }
    func arm() { lock.withLock { armed = true; reads = 0 } }
    func release() { permit.signal() }
    func read(_ sink: any RecordingArchiveSink) -> Double? {
        let shouldBlock = lock.withLock {
            onMain = onMain || Thread.isMainThread
            reads += 1
            if armed { armed = false; return true }
            return false
        }
        guard shouldBlock else { return 7 }
        entered.fulfill()
        let result = permit.wait(timeout: .now() + 2)
        lock.withLock { expired = result == .timedOut }
        return 999
    }
}

final class FilmScanStorageGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Storage actor is held before scan")
    private let lock = NSLock()
    private let permit = DispatchSemaphore(value: 0)
    private var waited = false
    private var expired = false
    var timedOut: Bool { lock.withLock { expired } }
    func release() { permit.signal() }
    func waitOnce(_ directory: URL) {
        let shouldWait = lock.withLock {
            if waited { return false }
            waited = true
            return true
        }
        guard shouldWait else { return }
        entered.fulfill()
        let result = permit.wait(timeout: .now() + 3)
        lock.withLock { expired = result == .timedOut }
    }
}

import AVFoundation
import Foundation
import ScorebugMedia
import ScorebugCore
import ScorebugStreaming
import XCTest

@MainActor final class FilmModelTests: XCTestCase {
    func testUHDRequiresFreshMatchingWorkerOutputAndRealSourceGeometry() throws {
        func response(_ profile: String) throws -> WorkerCapabilitiesResponse {
            try JSONDecoder().decode(WorkerCapabilitiesResponse.self, from: Data("""
            {"workerId":"mac","state":"fresh","serverTime":"now","validForMs":5000,
             "capabilities":{"version":1,"outputId":"main","encoder":"software","outputProfile":"\(profile)",
             "outputMode":"rtmp+record","startup":"passed","sustainedPerformance":"unqualified"}}
            """.utf8))
        }
        let uhd = try response("2160p30")
        XCTAssertTrue(uhd.permitsUHDInput(worker: "mac", output: "main", sourceWidth: 3840, sourceHeight: 2160, requestDuration: .milliseconds(20)))
        XCTAssertFalse(uhd.permitsUHDInput(worker: "mac", output: "other", sourceWidth: 3840, sourceHeight: 2160, requestDuration: .milliseconds(20)))
        XCTAssertFalse(uhd.permitsUHDInput(worker: "mac", output: "main", sourceWidth: 1920, sourceHeight: 1080, requestDuration: .milliseconds(20)))
        XCTAssertFalse(uhd.permitsUHDInput(worker: "mac", output: "main", sourceWidth: 3840, sourceHeight: 2160, requestDuration: .seconds(5)))
        XCTAssertFalse(try response("1080p30").permitsUHDInput(worker: "mac", output: "main", sourceWidth: 3840, sourceHeight: 2160, requestDuration: .milliseconds(20)))
        XCTAssertEqual(RecordingQuality.uhd2160.profile.captureQueueScale, 4)
        XCTAssertEqual(RecordingQuality.hd1080.profile.captureQueueScale, 1)
    }

    func testRecordingQualityConfiguresSourceAndArchiveAndLocksDuringCapture() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceProfiles: [ArchiveProfile] = []
        let model = FilmModel(library: RecordingLibrary(rootDirectory: root), configuredSourceFactory: { profile in
            sourceProfiles.append(profile)
            return FilmTestSource()
        }, sinkFactory: testArchiveSink)
        XCTAssertEqual(model.profile, RecordingQuality.hd1080.profile)
        XCTAssertTrue(model.selectQuality(.uhd2160))
        await model.start()
        XCTAssertEqual(model.state, .recording)
        XCTAssertFalse(model.selectQuality(.hd1080))
        XCTAssertEqual(model.currentCapture?.profile, RecordingQuality.uhd2160.profile)
        let id = try XCTUnwrap(model.currentCapture?.id)
        XCTAssertEqual(sourceProfiles, [RecordingQuality.uhd2160.profile])
        let archive = try ArchiveSegmentStore.recover(directory: root.appendingPathComponent(id))
        XCTAssertEqual(archive.profile, RecordingQuality.uhd2160.profile)
        await model.stop()
        XCTAssertTrue(model.selectQuality(.hd1080))
        await model.start()
        XCTAssertEqual(sourceProfiles, [RecordingQuality.uhd2160.profile, RecordingQuality.hd1080.profile])
        await model.stop()
    }

    func testSourceFactoryFailureCancelsUnusedSinkAndAllowsRetry() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(rootDirectory: root)
        var reject = true
        let cancellations = SourceFactoryCancellationCounter()
        let model = FilmModel(library: library, sourceFactory: {
            if reject { throw CocoaError(.fileReadCorruptFile) }
            return FilmTestSource()
        }, sinkFactory: { directory, profile in
            SourceFactoryTestSink(wrapped: try testArchiveSink(directory, profile), cancellations: cancellations)
        })
        await model.start()
        XCTAssertEqual(model.state, .failed)
        XCTAssertNotNil(model.message)
        XCTAssertNil(model.currentCapture)
        XCTAssertTrue(model.canStart)
        let entries = try await library.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.status, .recoverable)
        XCTAssertEqual(cancellations.count, 1)
        reject = false
        await model.start()
        XCTAssertEqual(model.state, .recording)
        await model.stop()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.recordings.count, 2)
        XCTAssertEqual(model.recordings.filter { $0.status == .completed }.count, 1)
        XCTAssertEqual(cancellations.count, 1)
    }

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
        XCTAssertFalse(model.selectQuality(.uhd2160), "Quality locks during source preparation")
        let stopping = Task { await model.stop() }
        while model.state != .stopping { await Task.yield() }
        XCTAssertFalse(model.selectQuality(.uhd2160), "Quality locks until shutdown joins")
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

private final class SourceFactoryCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func cancelled() { lock.withLock { value += 1 } }
}
private struct SourceFactoryTestSink: RecordingArchiveSink {
    let wrapped: any RecordingArchiveSink
    let cancellations: SourceFactoryCancellationCounter
    func start(at timestamp: CMTime) throws { try wrapped.start(at: timestamp) }
    func append(_ sample: CapturedMediaSample) throws -> Bool { try wrapped.append(sample) }
    func finish() async throws -> RecoveredArchive { try await wrapped.finish() }
    func cancel() { cancellations.cancelled(); wrapped.cancel() }
}

// Opt-in real media diagnostic. Ordinary unit-test runs skip this test. It uses
// production models and transport; UI, Watch routing and media acceptance remain
// the responsibility of the simulator lanes.
extension FilmModelTests {
    /// Reuse a completed diagnostic archive without repeating camera/network capture.
    func testExportExistingDiagnosticArchive() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCOREBUG_EXISTING_ARCHIVE_ROOT"] else {
            throw XCTSkip("Set an existing diagnostic archive root to export retained media")
        }
        let root = try XCTUnwrap(path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil)
        let library = RecordingLibrary(rootDirectory: root)
        let entries = try await library.list()
        let entry = try XCTUnwrap(entries.count == 1 ? entries.first : nil,
            "Select a diagnostic containing one recording")
        guard entry.status == .completed else {
            XCTFail("Do not promote interrupted media to completed"); return
        }
        let exported = try await library.export(id: entry.id)
        let result: [String: Any] = ["recordingID": entry.id, "export": exported.path,
            "scope": "native archive export only; no media qualification"]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(
            to: root.appendingPathComponent("native-export.json"), options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
    }

    func testHeadlessLocalStreamingDiagnostic() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCOREBUG_HEADLESS_CONFIG"] else {
            throw XCTSkip("Run scripts/test-headless-streaming.mjs to enable real local media")
        }
        struct Configuration: Decodable {
            struct Setup: Decodable {
                let endpoint: String, installationToken: String, workerId: String, outputId: String
            }
            let setup: Setup
            let source: String, artifact: String
            let duration: Double
            let uhd: Bool
            let timingAudit: Bool?
            let expectReconnect: Bool?
            let fixedUHD: Bool?
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard (10...600).contains(config.duration) else { throw URLError(.badURL) }
        let artifact = URL(fileURLWithPath: config.artifact)
        let streaming = CaptureStreamingModel(storage: CaptureMemoryStorage(nil), pendingStore: CaptureMemoryPending())
        streaming.endpoint = config.setup.endpoint; streaming.installationToken = config.setup.installationToken
        streaming.workerId = config.setup.workerId; streaming.outputId = config.setup.outputId
        let fixedUHD = config.fixedUHD == true
        guard !fixedUHD || (config.uhd && config.duration <= 60 && config.timingAudit == false && config.expectReconnect != true) else { throw URLError(.badURL) }
        streaming.nativeFixedUHDForDiagnostics = fixedUHD
        let nativeBoundaries = HeadlessNativeBoundaries()
        if config.uhd {
            streaming.nativeHealthFixtureObserver = { nativeBoundaries.health($0) }
            streaming.nativeSubmissionFixtureObserver = { nativeBoundaries.submission($0) }
        }
        let timingAudit = config.timingAudit ?? true
        if timingAudit {
            streaming.cadenceReportFixtureWriter = { data in
                try? data.write(to: artifact.appendingPathComponent("cadence.json"), options: .atomic)
            }
        }
        let film = FilmModel(library: RecordingLibrary(rootDirectory: artifact.appendingPathComponent("archive")),
            profile: config.uhd ? RecordingQuality.uhd2160.profile : RecordingQuality.hd1080.profile,
            configuredSourceFactory: { FileFixtureCameraSource(url: URL(fileURLWithPath: config.source), profile: $0) })
        film.onCaptureChanged = { streaming.captureChanged($0) }
        film.onCaptureFinished = { streaming.captureFinished($0, interrupted: $1) }
        await streaming.connect()
        await film.start()
        await streaming.startStreaming()
        let started = ContinuousClock.now
        try Data("ready".utf8).write(to: artifact.appendingPathComponent("native-ready.json"), options: .atomic)
        var lifecycle: [[String: String]] = []
        let worker = Task { await ControlPollSchedule.run(interval: { streaming.controlPollInterval }, poll: { await streaming.pollWorkerStatus() }) }
        let control = Task { await ControlPollSchedule.run(interval: { streaming.controlPollInterval }, poll: { await streaming.pollBackgroundControl() }) }
        let health = Task {
            while !Task.isCancelled {
                streaming.pollLocalHealth()
                do { try await Task.sleep(for: CaptureStreamingModel.publishingHealthInterval) } catch { return }
            }
        }
        var samples: [[String: String]] = []
        var boundaries: [[String: String]] = []
        var diagnosticError: Error?
        var lastProfileState: String?
        do {
            while ContinuousClock.now < started + .seconds(config.duration), film.state == .recording,
                  (config.expectReconnect == true || streaming.localState == .publishing) {
                await film.pollHealth()
                if lifecycle.last?["state"] != streaming.localState.rawValue {
                    lifecycle.append(["state": streaming.localState.rawValue,
                        "recording": streaming.activeRecordingID ?? "none",
                        "attempt": streaming.videoObservation?.scope.publishingAttemptID.uuidString ?? "none",
                        "generation": streaming.videoObservation.map { String($0.scope.broadcastGeneration) } ?? "none",
                        "elapsedSeconds": String(started.duration(to: .now).components.seconds)])
                }
                if config.uhd {
                    var row = nativeBoundaries.snapshot()
                    row["at"] = String(ProcessInfo.processInfo.systemUptime)
                    row["profile"] = streaming.qualityDiagnostic.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }?["policyAppliedProfile"]
                    if let ingress = streaming.ingressObservation {
                        row["attempt"] = ingress.scope.publishingAttemptID.uuidString
                        row["appVideoAdmitted"] = String(ingress.totalDispositions[.admitted]?[.video]?.count ?? 0)
                        row["appVideoDequeued"] = String(ingress.totalDispositions[.dequeued]?[.video]?.count ?? 0)
                        row["appVideoEvicted"] = String(ingress.totalDispositions[.overflowEvicted]?[.video]?.count ?? 0)
                        row["appVideoRejected"] = String(ingress.totalDispositions.reduce(UInt64(0)) { sum, entry in
                            if case .rejected = entry.key { return sum + (entry.value[.video]?.count ?? 0) }; return sum
                        })
                    }
                    if let video = streaming.videoObservation {
                        let windows = video.completed + [video.current]
                        row["retainedCaptureCallbacks"] = String(windows.reduce(UInt64(0)) { $0 + $1.captureVideo.callbackCount })
                        row["retainedEncodedCallbacks"] = String(windows.reduce(UInt64(0)) { $0 + $1.encodedVideo.callbackCount })
                        row["omittedVideoWindows"] = String(video.omittedCompletedWindowCount)
                    }
                    if fixedUHD { row["profile"] = "2160p30-fixed-diagnostic" }
                    boundaries.append(row)
                }
                if let text = streaming.qualityDiagnostic,
                   let fields = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] {
                    samples.append(fields)
                    let profileState = "\(fields["policyAppliedProfile"] ?? "unknown") trial=\(fields["policyTrialActive"] ?? "unknown")"
                    if profileState != lastProfileState {
                        print("HEADLESS_QUALITY \(profileState) elapsed=\(started.duration(to: .now).components.seconds)s")
                        if let transition = fields["appliedTransition"],
                           let cause = (try? JSONSerialization.jsonObject(with: Data(transition.utf8))) as? [String: String] {
                            print("HEADLESS_TRANSITION kind=\(cause["kind"] ?? "unknown") input=\(cause["input"] ?? "unknown") reasons=\(cause["reasons"] ?? "unknown")")
                        }
                        lastProfileState = profileState
                    }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch { diagnosticError = error }
        let wasRecording = film.state == .recording, wasPublishing = streaming.localState == .publishing
        worker.cancel(); control.cancel(); health.cancel()
        await worker.value; await control.value; await health.value
        await streaming.stopStreaming()
        await film.stop()
        let result: [String: Any] = ["scope": "headless-native-diagnostic-v1", "samples": samples, "lifecycle": lifecycle,
            "recordingAtEnd": wasRecording, "publishingAtEnd": wasPublishing,
            "timingAuditEnabled": timingAudit, "fixedUHD": fixedUHD, "boundarySampleCount": boundaries.count,
            "elapsedSeconds": Double(started.duration(to: .now).components.seconds), "mediaQualified": false]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(
            to: artifact.appendingPathComponent("diagnostic.json"), options: .atomic)
        if config.uhd {
            try JSONSerialization.data(withJSONObject: ["scope": "Sequential local boundary observations, not atomic delivery proof", "samples": boundaries], options: [.sortedKeys]).write(
                to: artifact.appendingPathComponent("native-boundaries.json"), options: .atomic)
        }
        if let diagnosticError { throw diagnosticError }
        XCTAssertTrue(wasRecording, "Native archive stopped early")
        XCTAssertTrue(wasPublishing, "Native publisher stopped early")
        if fixedUHD { XCTAssertFalse(boundaries.isEmpty, "Expected native boundary diagnostics") }
        else { XCTAssertFalse(samples.isEmpty, "Expected real quality diagnostics") }
        XCTAssertEqual(film.state, .idle, "Archive finalization must complete")
        XCTAssertEqual(streaming.localState, .idle, "Native publisher must join")
    }
}

/// Scalar headless diagnostics only. No media retained and no publishing decisions.
private final class HeadlessNativeBoundaries: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String: String] = [:]
    private var submitted = 0, failed = 0
    private var maximumSubmissionSeconds = 0.0
    func health(_ value: SRTPublisher.HealthSnapshot) {
        lock.withLock {
            fields["healthAt"] = String(ProcessInfo.processInfo.systemUptime)
            fields["sdkRawVideoDropped"] = value.rawVideoFramesDropped.map(String.init)
        }
    }
    func submission(_ value: SRTPublisher.EncoderSubmission) {
        lock.withLock {
            submitted += 1
            if value.status != noErr { failed += 1 }
            maximumSubmissionSeconds = max(maximumSubmissionSeconds, value.returnedAt - value.startedAt)
            fields["nativeSubmitted"] = String(submitted)
            fields["nativeSubmitErrors"] = String(failed)
            fields["maximumNativeSubmissionSeconds"] = String(maximumSubmissionSeconds)
            fields["lastNativeSubmissionSeconds"] = String(value.returnedAt - value.startedAt)
            fields["submissionAt"] = String(value.returnedAt)
            fields["encoder"] = value.encoderSessionID.uuidString
        }
    }
    func snapshot() -> [String: String] { lock.withLock { fields } }
}

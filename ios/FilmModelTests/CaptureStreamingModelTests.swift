import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

@MainActor final class CaptureStreamingModelTests: XCTestCase {
    func testOfflineRecordDoesNotCallAPI() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, saved: nil)
        let context = captureContext()
        model.captureChanged(context)
        await model.pollControl()
        model.captureChanged(nil)
        await model.pollControl()
        let count = await server.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.localState, .idle)
    }

    func testStreamingStartAndStopLeaveLocalCaptureActive() async throws {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        let context = captureContext()
        model.captureChanged(context)
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)
        let isPublishing = await publisher.isPublishing
        XCTAssertTrue(isPublishing)
        await model.stopStreaming()
        let stopped = await publisher.isPublishing
        XCTAssertFalse(stopped)
        XCTAssertEqual(model.activeRecordingID, context.id)
        XCTAssertEqual(model.localState, .idle)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testStopDuringPublishAccessCannotStartLatePublisher() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        await server.setPublishGate(gate)
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        await model.pollControl()
        let stopped = await publisher.isPublishing
        XCTAssertFalse(stopped)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertNil(model.activeRecordingID)
    }

    func testNetworkFailureDoesNotClearLocalRecording() async throws {
        let server = CaptureTestServer()
        await server.setOffline(true)
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNotNil(model.message)
    }

    func testRelaunchReplacesLiveReportWithHigherSequenceInterruptedReport() async throws {
        let server = CaptureTestServer()
        let saved = captureSetup()
        let storage = CaptureMemoryStorage(saved)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let before = try XCTUnwrap(storage.value?.reports.first)
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        XCTAssertNil(relaunched.activeRecordingID)
        let terminal = try XCTUnwrap(storage.value?.reports.first)
        XCTAssertEqual(terminal.report.status, .interrupted)
        XCTAssertGreaterThan(terminal.report.sequence, before.report.sequence)
        XCTAssertEqual(terminal.report.startedAt, before.report.startedAt)
        await relaunched.pollControl()
        let lastStatus = await server.reports.last?.status
        XCTAssertEqual(lastStatus, .interrupted)
        await model.stopStreaming()
    }

    func testStorageFailureCanRetryRestoreWithoutDiscardingSetup() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        storage.fails = true
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        XCTAssertTrue(model.needsStorageRetry)
        storage.fails = false
        await model.pollControl()
        XCTAssertEqual(model.connectedGameID, "game-1")
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testWorkerReplyAfterLocalStopCannotReappearAsCurrent() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusGate(gate)
        let polling = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await polling.value
        XCTAssertEqual(model.workerState, .unknown)
    }

    func testWorkerObservationExpiresIndependentlyOfControlRequests() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await model.pollControl()
        XCTAssertEqual(model.workerState, .stale)
        await model.stopStreaming()
    }

    func testLostStartReplyRecoversReceiptAndStopsOnlyOwnedRecording() async throws {
        let server = CaptureTestServer()
        await server.setDropReply()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertNotNil(model.commandState?.pending)
        model.captureChanged(nil)
        await model.pollControl()
        XCTAssertNil(model.commandState?.pending)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testStopNeverStopsAnotherCaptureSelection() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.selectAnotherCapture()
        await model.stopStreaming()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start"])
    }

    func testStopDuringPublisherStartupIsTerminal() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        let active = await publisher.isPublishing
        XCTAssertFalse(active)
        XCTAssertEqual(model.localState, .idle)
    }

    func testStopDuringCaptureJoinPreventsAnyBroadcastOrPublisherStart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        await server.setJoinGate(gate)
        var saved = captureSetup(); saved.credential = nil
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, saved: saved, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        let operations = await server.operations
        let starts = await publisher.startCount
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(model.activeRecordingID)
    }

    func testBroadcastStorageFailureIsVisibleAndDoesNotPOST() async throws {
        let server = CaptureTestServer()
        let pending = CaptureMemoryPending()
        let model = CaptureStreamingModel(storage: CaptureMemoryStorage(captureSetup()), pendingStore: pending,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
            publisherFactory: { _ in CaptureTestPublisher() })
        await model.restore()
        pending.fails = true
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertTrue(model.needsStorageRetry)
        XCTAssertFalse(model.canChangeSetup)
        let operations = await server.operations
        XCTAssertTrue(operations.isEmpty)
        pending.fails = false
        await model.pollControl()
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testSetupPersistsDeviceIdentityBeforeFailedJoin() async throws {
        let server = CaptureTestServer()
        await server.setOffline(true)
        let storage = CaptureMemoryStorage(nil)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.installationToken = "token"
        await model.connect()
        let first = try XCTUnwrap(storage.value?.deviceId)
        XCTAssertNotNil(UUID(uuidString: first))
        let next = makeModel(server: server, storage: storage)
        await next.restore()
        await next.connect()
        XCTAssertEqual(storage.value?.deviceId, first)
    }

    func testStopStreamingDoesNotReplayAnUncommittedStartWhileArchiveContinues() async throws {
        let server = CaptureTestServer()
        await server.setFailBeforeCommand()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertNotNil(model.commandState?.pending)
        await model.stopStreaming()
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        let operations = await server.operations
        XCTAssertTrue(operations.isEmpty)
        XCTAssertNotNil(model.commandState?.pending)
    }

    func testSecondRelaunchRetainsStopOwnershipAfterTerminalReportAcknowledgment() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        model.captureChanged(nil)
        await server.setFailMedia(true)
        await model.pollControl()
        XCTAssertTrue(storage.value?.reports.isEmpty == true, "Terminal report was acknowledged before media lookup failed")
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        await server.setFailMedia(false)
        await relaunched.pollControl()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testSetupSaveFailureCannotBeBypassedByRetryingSameFields() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(nil)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.installationToken = "test-token"
        storage.fails = true
        await model.connect()
        await model.connect()
        let requestsBeforeSave = await server.requestCount
        XCTAssertEqual(requestsBeforeSave, 0, "No join may use an identity that has not been saved")
        storage.fails = false
        await model.connect()
        XCTAssertEqual(model.connectedGameID, "game-1")
    }

    func testBlockedPublisherStopPreventsOverlappingRestart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await gate.release()
        await stopping.value
        XCTAssertTrue(model.canStart)
    }

    func testCaptureFailureReportsInterruptedAfterArchiveOutcome() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let streaming = makeModel(server: server, storage: storage)
        await streaming.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { streaming.captureChanged($0, terminalStatus: nil) }
        film.onCaptureFinished = { streaming.captureFinished($0, interrupted: $1) }
        await film.start()
        source.interrupt()
        await film.pollHealth()
        XCTAssertNil(film.currentCapture)
        XCTAssertEqual(storage.value?.reports.last?.report.status, .interrupted)
        XCTAssertEqual(storage.value?.reports.last?.report.sequence, 2)
    }

    func testRejectedStopKeepsOwnershipAcrossRelaunch() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        model.captureChanged(nil)
        await server.setRejectStop()
        await model.pollControl()
        XCTAssertEqual(storage.value?.stopRecordingIDs, ["recording-1"])
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        await relaunched.pollControl()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertTrue(storage.value?.stopRecordingIDs?.isEmpty == true)
    }

    func testHealthFailureTeardownBlocksRestartUntilOldPublisherStops() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await publisher.failHealth()
        await gate.waitUntilEntered()
        model.pollLocalHealth()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await gate.release()
        await model.stopStreaming()
        XCTAssertTrue(model.canStart)
    }

    private func makeModel(server: CaptureTestServer, saved: SavedCaptureSetup? = captureSetup(),
                           storage: CaptureMemoryStorage? = nil,
                           publisher: CaptureTestPublisher = CaptureTestPublisher()) -> CaptureStreamingModel {
        CaptureStreamingModel(storage: storage ?? CaptureMemoryStorage(saved), pendingStore: CaptureMemoryPending(),
                              clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
                              publisherFactory: { _ in publisher })
    }
}

func captureContext() -> CurrentCapture { CurrentCapture(id: "recording-1", startedAt: "2026-09-14T00:00:00Z", tap: PublishingTap()) }
func captureSetup() -> SavedCaptureSetup {
    SavedCaptureSetup(endpoint: "http://localhost:18787", installationToken: "test-token", deviceId: "capture-1", workerId: "worker-1", outputId: "output-1",
                      credential: MatchCredential(gameId: "game-1", deviceId: "capture-1", role: .capture, token: "capture-token"), reports: [])
}
final class CaptureMemoryStorage: CaptureSetupStorage {
    var value: SavedCaptureSetup?
    var fails = false
    init(_ value: SavedCaptureSetup?) { self.value = value }
    func load() throws -> SavedCaptureSetup? { if fails { throw URLError(.cannotWriteToFile) }; return value }
    func save(_ value: SavedCaptureSetup) throws { if fails { throw URLError(.cannotWriteToFile) }; self.value = value }
}
final class CaptureMemoryPending: PendingBroadcastStore, @unchecked Sendable {
    var value: PendingBroadcastCommand?
    var fails = false
    func load() throws -> PendingBroadcastCommand? { if fails { throw URLError(.cannotWriteToFile) }; return value }
    func save(_ value: PendingBroadcastCommand?) throws { if fails { throw URLError(.cannotWriteToFile) }; self.value = value }
}
actor CaptureTestPublisher: MediaPublisher {
    var isPublishing = false
    var startCount = 0
    var terminated = false
    let gate: FilmTestGate?
    let stopGate: FilmTestGate?
    init(gate: FilmTestGate? = nil, stopGate: FilmTestGate? = nil) { self.gate = gate; self.stopGate = stopGate }
    func start() async throws {
        startCount += 1
        if let gate { await gate.enter() }
        guard !terminated else { throw CancellationError() }
        isPublishing = true
    }
    func append(_ sample: CapturedMediaSample) async throws {}
    func failHealth() { isPublishing = false }
    func stop() async {
        guard !terminated else { return }
        terminated = true; isPublishing = false
        if let stopGate { await stopGate.enter() }
    }
}
actor CaptureTestServer {
    var requestCount = 0
    var operations: [String] = []
    var reports: [RecordingReport] = []
    var broadcast = MediaBroadcast(desired: .stopped, generation: 0, selection: nil)
    var receipts: [String: BroadcastOutcome] = [:]
    var offline = false
    var failMedia = false
    func setFailMedia(_ value: Bool) { failMedia = value }
    var publishGate: FilmTestGate?
    var statusGate: FilmTestGate?
    var joinGate: FilmTestGate?
    func setJoinGate(_ value: FilmTestGate) { joinGate = value }
    var dropReply = false
    var failBeforeCommand = false
    var rejectStop = false
    func setRejectStop() { rejectStop = true }
    func setFailBeforeCommand() { failBeforeCommand = true }
    func setDropReply() { dropReply = true }
    func setStatusGate(_ value: FilmTestGate) { statusGate = value }
    func selectAnotherCapture() { broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: .init(workerId: "worker-1", outputId: "output-1", captureDeviceId: "another-device", recordingId: "other-recording")) }
    func setOffline(_ value: Bool) { offline = value }
    func setPublishGate(_ value: FilmTestGate) { publishGate = value }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        if failMedia && path.hasSuffix("/media") { throw URLError(.notConnectedToInternet) }
        let time = ISO8601DateFormatter().string(from: Date())
        let data: Data
        if path.hasSuffix("/active") {
            data = try JSONEncoder().encode(ActiveMatchResponse(snapshot: matchSnapshot(), serverTime: time))
        } else if path.hasSuffix("/join") {
            if let joinGate { await joinGate.enter() }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            data = try JSONEncoder().encode(MatchSessionResponse(snapshot: matchSnapshot(), credential: .init(gameId: "game-1", deviceId: body["deviceId"]!, role: .capture, token: "capture-token"), serverTime: time))
        } else if path.hasSuffix("/recordings") {
            let report = try JSONDecoder().decode(RecordingReport.self, from: request.httpBody!)
            reports.append(report)
            data = try JSONEncoder().encode(RecordingReportResponse(recording: .init(gameId: "game-1", recordingId: report.recordingId, deviceId: "capture-1", startedAt: report.startedAt, updatedAt: time, status: report.status, sequence: report.sequence), serverTime: time))
        } else if path.hasSuffix("/commands") {
            if failBeforeCommand { failBeforeCommand = false; throw URLError(.networkConnectionLost) }
            let command = try JSONDecoder().decode(BroadcastCommand.self, from: request.httpBody!)
            if case .stop = command.operation, rejectStop {
                rejectStop = false
                let rejected = BroadcastOutcome(commandId: command.commandId, accepted: false, error: "generation_conflict", snapshot: snapshot())
                return (try JSONEncoder().encode(rejected), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            switch command.operation {
            case .start(let selection): broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: selection); operations.append("start")
            case .stop: broadcast = .init(desired: .stopped, generation: broadcast.generation + 1, selection: nil); operations.append("stop")
            }
            let result = BroadcastOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot())
            receipts[command.commandId] = result
            if dropReply { dropReply = false; throw URLError(.networkConnectionLost) }
            data = try JSONEncoder().encode(result)
        } else if path.contains("/commands/") {
            if let receipt = receipts[request.url!.lastPathComponent] { data = try JSONEncoder().encode(receipt) }
            else { return (Data("{\"error\":\"command_not_found\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        } else if path.hasSuffix("/publish") {
            if let publishGate { await publishGate.enter() }
            data = try JSONSerialization.data(withJSONObject: ["gameId": "game-1", "recordingId": "recording-1", "generation": broadcast.generation, "publishUrl": "srt://localhost:19000?streamid=test", "serverTime": time])
        } else if path.hasSuffix("/status") {
            if let statusGate { await statusGate.enter() }
            data = try JSONEncoder().encode(WorkerMediaStatusResponse(status: .init(gameId: "game-1", generation: broadcast.generation, workerId: "worker-1", state: .producingOutput, observation: nil, observedAt: time, expiresAt: time), serverTime: time))
        } else { data = try JSONEncoder().encode(MediaSnapshotResponse(snapshot: snapshot(), serverTime: time)) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func snapshot() -> MediaSnapshot { .init(gameId: "game-1", recordings: [], broadcast: broadcast) }
}

private func matchSnapshot() throws -> MatchSnapshot {
    let json = ##"{"id":"game-1","createdAt":"2026-09-14T00:00:00Z","revision":0,"teams":{"home":{"name":"Home","shortName":"HOM","color":"#112233"},"away":{"name":"Away","shortName":"AWY","color":"#445566"}},"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":0,"away":0,"set":1,"homeSets":0,"awaySets":0},"completedSets":[],"status":"active","endReason":null,"canUndo":false,"scorer":{"deviceId":"scorer-1","epoch":1},"broadcast":{"desired":"stopped","generation":0}}"##
    return try JSONDecoder().decode(MatchSnapshot.self, from: Data(json.utf8))
}

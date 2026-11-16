import AVFoundation
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

@MainActor final class CaptureStreamingModelTests: XCTestCase {
    private var server: CaptureTestServer!
    private var publishers: [LadderTestPublisher] = []
    private var profiles: [PublishingVideoProfile] = []
    private var now = 1_000.0
    private var thermal = QualityLadder.Thermal.nominal

    override func setUp() async throws {
        server = CaptureTestServer(); publishers = []; profiles = []; now = 1_000; thermal = .nominal
    }

    private func makeModel(storage: CaptureMemoryStorage = CaptureMemoryStorage(captureSetup())) -> CaptureStreamingModel {
        let server = self.server!
        return CaptureStreamingModel(storage: storage, pendingStore: CaptureMemoryPending(),
            clientFactory: { MatchHTTPClient(endpoint: $0, transport: { try await server.respond($0) }) },
            publisherFactory: { [unowned self] _, profile in
                let publisher = LadderTestPublisher()
                publishers.append(publisher); profiles.append(profile)
                return publisher
            },
            thermalReader: { [unowned self] in thermal },
            clock: { [unowned self] in now },
            healthCheckInterval: .milliseconds(2))
    }

    private func goLive(_ model: CaptureStreamingModel, _ context: CurrentCapture = captureContext()) async {
        await model.restore()
        model.captureChanged(context)
        await model.startStreaming()
    }

    /// Advances the synthetic SRT feed by half a second and lets the ladder observe it.
    private func tick(_ model: CaptureStreamingModel, bufferMs: Int = 100, retransmits: Int64 = 0, drops: Int64 = 0) async {
        guard let publisher = publishers.last else { return }
        publisher.advance(bufferMs: bufferMs, retransmits: retransmits, drops: drops)
        await eventually { model.status != .live || publisher.statisticsReads > publisher.lastObservedReads + 1 }
        publisher.lastObservedReads = publisher.statisticsReads
        model.pollLocalHealth()
        await settle(model)
    }

    private func settle(_ model: CaptureStreamingModel) async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    func testGoLiveStartsTheStreamAt720pAndReportsLive() async throws {
        let model = makeModel()
        XCTAssertEqual(model.status, .off)
        await model.restore()
        model.captureChanged(captureContext())
        XCTAssertEqual(model.status, .recordingOnly)
        await model.startStreaming()
        XCTAssertEqual(model.status, .live, String(describing: model.message))
        XCTAssertEqual(model.streamQuality, .p720)
        XCTAssertEqual(profiles, [.hd720])
        let operations = await server.operations
        XCTAssertEqual(operations, ["start"])
        // The app names no worker or output; the server picks them.
        let sent = await server.startSelections
        XCTAssertEqual(sent, [BroadcastSelection(captureDeviceId: "capture-1", recordingId: "recording-1")])
        let selected = await server.broadcast.selection
        XCTAssertEqual(selected?.workerId, "home-1")
    }

    func testWorkerRejectionsExplainWhatHappened() async throws {
        let cases = [
            ("no_worker", "No streaming worker is connected to the server."),
            ("worker_ambiguous", "More than one streaming worker is connected"),
            ("output_unknown", "The streaming worker needs an update"),
        ]
        for (code, text) in cases {
            server = CaptureTestServer()
            await server.rejectStarts(with: code)
            let model = makeModel()
            await model.restore()
            model.captureChanged(captureContext())
            await model.startStreaming()
            XCTAssertEqual(model.status, .recordingOnly, code)
            XCTAssertTrue(model.message?.contains(text) == true, "\(code): \(String(describing: model.message))")
        }
    }

    func testHostedGoLiveRefusalsAndWatchLink() async throws {
        server = CaptureTestServer()
        await server.rejectStarts(with: "busy")
        var model = makeModel()
        await goLive(model)
        XCTAssertEqual(model.status, .recordingOnly)
        XCTAssertEqual(model.message, "Scorebug is busy, try again shortly. Recording continues.")
        XCTAssertNil(model.youtube)

        server = CaptureTestServer()
        let link = MatchYouTube(broadcastId: "abc123", watchUrl: "https://www.youtube.com/watch?v=abc123",
                                channelTitle: "Wildcats", channelThumbnail: nil, privacy: "unlisted")
        await server.setYouTube(link)
        model = makeModel()
        await goLive(model)
        XCTAssertEqual(model.status, .live, String(describing: model.message))
        XCTAssertEqual(model.youtube, link, "the Go Live reply carries the watch link")
    }

    /// A phone that used the self-hosted build may still hold reports for a server that's gone.
    func testANewServerStartsCleanInsteadOfWaitingOnTheOldOne() async throws {
        var old = captureSetup()
        old.endpoint = "https://old.example"
        old.reports = [PendingCaptureReport(credential: MatchCredential(gameId: "old-game", deviceId: "capture-1", role: .capture, token: "old"),
                                            report: RecordingReport(recordingId: "old-recording", sequence: 2, status: .stopped,
                                                                    startedAt: "2026-09-13T00:00:00Z"),
                                            delivered: false)]
        old.stopRecordingIDs = ["old-recording"]
        let storage = CaptureMemoryStorage(old)
        let model = makeModel(storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        model.endpoint = "http://localhost:18787"
        model.installationToken = "session"
        model.teamId = "t1"
        await model.connect()
        XCTAssertNil(model.message)
        XCTAssertEqual(storage.value?.endpoint, "http://localhost:18787")
        XCTAssertEqual(storage.value?.teamId, "t1")
        XCTAssertFalse(storage.value?.reports.contains { $0.credential.gameId == "old-game" } ?? true)
        await model.startStreaming()
        XCTAssertEqual(model.status, .live, String(describing: model.message))
    }

    func testReportsForAMatchTheServerForgotAreDropped() async throws {
        var setup = captureSetup()
        setup.reports = [PendingCaptureReport(credential: MatchCredential(gameId: "gone", deviceId: "capture-1", role: .capture, token: "x"),
                                              report: RecordingReport(recordingId: "old-recording", sequence: 2, status: .stopped,
                                                                      startedAt: "2026-09-13T00:00:00Z"),
                                              delivered: false)]
        await server.forget(game: "gone")
        let storage = CaptureMemoryStorage(setup)
        let model = makeModel(storage: storage)
        await goLive(model)
        XCTAssertEqual(model.status, .live, String(describing: model.message))
        XCTAssertFalse(storage.value?.reports.contains { $0.credential.gameId == "gone" } ?? true)
    }

    func testFourKRecordingStillStreamsAtMost1080p() async throws {
        let model = makeModel()
        let uhd = CurrentCapture(id: "recording-4k", startedAt: "2026-11-15T00:00:00Z", tap: PublishingTap(),
                                 profile: RecordingQuality.uhd2160.profile)
        await goLive(model, uhd)
        XCTAssertEqual(profiles, [.hd720])
        for _ in 0..<80 { await tick(model, bufferMs: 50) }
        XCTAssertEqual(model.streamQuality, .p1080)
        XCTAssertEqual(publishers.last?.appliedProfiles, [.hd1080])
    }

    func testSustainedSenderPressureStepsTheLiveEncoderDown() async throws {
        let model = makeModel()
        await goLive(model)
        for _ in 0..<4 { await tick(model) }
        for _ in 0..<8 { await tick(model, bufferMs: 1500) }
        XCTAssertEqual(model.streamQuality, .p540)
        XCTAssertEqual(publishers.last?.appliedProfiles, [.sd540])
        XCTAssertEqual(model.status, .live)
    }

    func testSeriousThermalStepsDown() async throws {
        let model = makeModel()
        await goLive(model)
        await tick(model)
        thermal = .serious
        await tick(model)
        XCTAssertEqual(model.streamQuality, .p540)
    }

    func testDisconnectReconnectsWithBackoffOneRungBelowLastStable() async throws {
        let model = makeModel()
        let context = captureContext()
        await goLive(model, context)
        for _ in 0..<14 { await tick(model) }
        publishers.last?.disconnect()
        await eventually { self.publishers.last?.stops == 1 }
        model.pollLocalHealth()
        XCTAssertEqual(model.status, .reconnecting)
        XCTAssertNil(model.streamQuality)
        model.pollLocalHealth()
        await settle(model)
        XCTAssertEqual(publishers.count, 1, "waits for the 1 s backoff")
        now += 1
        model.pollLocalHealth()
        await eventually { model.status == .live }
        XCTAssertEqual(profiles, [.hd720, .sd540])
        XCTAssertEqual(model.streamQuality, .p540)
        // The second stream is attached to the same recording tap.
        XCTAssertTrue(context.tap.offer(try XCTUnwrap(publishers.last).sample()))
    }

    func testFailedReconnectAttemptsBackOffTwoThenFourSeconds() async throws {
        let model = makeModel()
        await goLive(model)
        publishers.last?.disconnect()
        await eventually { self.publishers.last?.stops == 1 }
        model.pollLocalHealth()
        await server.setOffline(true)
        now += 1; model.pollLocalHealth()
        await eventually { !model.busy }
        XCTAssertEqual(model.status, .reconnecting)
        now += 1.5; model.pollLocalHealth(); await settle(model)
        let attemptsAfterShortWait = await server.requestCount
        now += 0.5; model.pollLocalHealth()
        await eventually { !model.busy }
        let attemptsAfterTwoSeconds = await server.requestCount
        XCTAssertGreaterThan(attemptsAfterTwoSeconds, attemptsAfterShortWait)
        await server.setOffline(false)
        now += 4; model.pollLocalHealth()
        await eventually { model.status == .live }
        XCTAssertEqual(publishers.count, 2)
    }

    func testStopLiveStopsTheBroadcastAndKeepsRecording() async throws {
        let model = makeModel()
        await goLive(model)
        await model.stopStreaming()
        XCTAssertEqual(model.status, .recordingOnly)
        XCTAssertEqual(publishers.last?.stops, 1)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testRecordingEndDetachesTheStreamImmediately() async throws {
        let model = makeModel()
        let context = captureContext()
        await goLive(model, context)
        model.captureChanged(nil)
        XCTAssertEqual(model.status, .off)
        XCTAssertFalse(context.tap.offer(try XCTUnwrap(publishers.last).sample()))
        await eventually { self.publishers.last?.stops == 1 }
    }

    func testRemoteStopEndsTheStreamAndCancelsReconnect() async throws {
        let model = makeModel()
        await goLive(model)
        await server.stopBroadcastRemotely()
        await model.pollControl()
        XCTAssertEqual(model.status, .recordingOnly)
        XCTAssertNotNil(model.message)
    }

    func testNoSetupExplainsWhatToDo() async throws {
        let model = makeModel(storage: CaptureMemoryStorage(nil))
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.status, .recordingOnly)
        XCTAssertEqual(model.localState, .failed)
        XCTAssertTrue(model.message?.contains("Connect this phone") == true)
    }

    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }
}

func captureContext() -> CurrentCapture { CurrentCapture(id: "recording-1", startedAt: "2026-09-14T00:00:00Z", tap: PublishingTap()) }
func captureSetup() -> SavedCaptureSetup {
    SavedCaptureSetup(endpoint: "http://localhost:18787", installationToken: "test-token", deviceId: "capture-1",
                      credential: MatchCredential(gameId: "game-1", deviceId: "capture-1", role: .capture, token: "capture-token"), reports: [])
}
final class CaptureMemoryStorage: CaptureSetupStorage {
    var value: SavedCaptureSetup?
    init(_ value: SavedCaptureSetup?) { self.value = value }
    func load() throws -> SavedCaptureSetup? { value }
    func save(_ value: SavedCaptureSetup) throws { self.value = value }
}
final class CaptureMemoryPending: PendingBroadcastStore, @unchecked Sendable {
    var value: PendingBroadcastCommand?
    func load() throws -> PendingBroadcastCommand? { value }
    func save(_ value: PendingBroadcastCommand?) throws { self.value = value }
}

/// Fake SRT publisher with a controllable cumulative-counter feed.
final class LadderTestPublisher: MediaPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var stopCount = 0, reads = 0
    private var applied: [PublishingVideoProfile] = []
    private var stats = PublishingTransportStatistics(sampledAt: 0, sentPackets: 0, retransmittedPackets: 0,
        droppedPackets: 0, senderBufferMilliseconds: 100, rttMilliseconds: 30, sendRateMbps: 3)
    var lastObservedReads = 0
    var stops: Int { lock.withLock { stopCount } }
    var statisticsReads: Int { lock.withLock { reads } }
    var appliedProfiles: [PublishingVideoProfile] { lock.withLock { applied } }
    var isPublishing: Bool { get async { lock.withLock { active } } }
    func start() async throws { lock.withLock { active = true } }
    func append(_ sample: CapturedMediaSample) async throws {}
    func stop() async { lock.withLock { stopCount += 1; active = false } }
    func disconnect() { lock.withLock { active = false } }
    func transportStatistics() async -> PublishingTransportStatistics? { lock.withLock { reads += 1; return stats } }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws { lock.withLock { applied.append(profile) } }
    func advance(bufferMs: Int, retransmits: Int64, drops: Int64) {
        lock.withLock {
            stats = .init(sampledAt: stats.sampledAt + 0.5, sentPackets: stats.sentPackets + 150,
                retransmittedPackets: stats.retransmittedPackets + retransmits, droppedPackets: stats.droppedPackets + drops,
                senderBufferMilliseconds: bufferMs, rttMilliseconds: 30, sendRateMbps: 3)
        }
    }
    func sample() throws -> CapturedMediaSample {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
    }
}

actor CaptureTestServer {
    var requestCount = 0
    var operations: [String] = []
    var reports: [RecordingReport] = []
    var broadcast = MediaBroadcast(desired: .stopped, generation: 0, selection: nil)
    var receipts: [String: BroadcastOutcome] = [:]
    var offline = false
    /// What the app sent in each start command.
    var startSelections: [BroadcastSelection] = []
    var startRejection: String?
    /// Matches this server has never heard of: their reports answer 404.
    var unknownGames: Set<String> = []
    var youtube: MatchYouTube?
    func setOffline(_ value: Bool) { offline = value }
    func forget(game: String) { unknownGames.insert(game) }
    func setYouTube(_ link: MatchYouTube) { youtube = link }
    func rejectStarts(with code: String) { startRejection = code }
    func stopBroadcastRemotely() { broadcast = .init(desired: .stopped, generation: broadcast.generation + 1, selection: nil) }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        // The old self-hosted server is gone.
        if request.url!.host == "old.example" { throw URLError(.cannotFindHost) }
        let time = ISO8601DateFormatter().string(from: Date())
        let data: Data
        if path.hasSuffix("/active") {
            data = try JSONEncoder().encode(ActiveMatchResponse(snapshot: matchSnapshot(), serverTime: time))
        } else if path.hasSuffix("/join") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            data = try JSONEncoder().encode(MatchSessionResponse(snapshot: matchSnapshot(), credential: .init(gameId: "game-1", deviceId: body["deviceId"]!, role: .capture, token: "capture-token"), serverTime: time))
        } else if path.hasSuffix("/recordings"), unknownGames.contains(where: { path.contains("/\($0)/") }) {
            return (Data("{\"error\":\"match_not_found\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        } else if path.hasSuffix("/recordings") {
            let report = try JSONDecoder().decode(RecordingReport.self, from: request.httpBody!)
            reports.append(report)
            data = try JSONEncoder().encode(RecordingReportResponse(recording: .init(gameId: "game-1", recordingId: report.recordingId, deviceId: "capture-1", startedAt: report.startedAt, updatedAt: time, status: report.status, sequence: report.sequence), serverTime: time))
        } else if path.hasSuffix("/commands") {
            let command = try JSONDecoder().decode(BroadcastCommand.self, from: request.httpBody!)
            if case .start(let selection) = command.operation { startSelections.append(selection) }
            if case .start = command.operation, let startRejection {
                let result = BroadcastOutcome(commandId: command.commandId, accepted: false, error: startRejection, snapshot: snapshot())
                receipts[command.commandId] = result
                return (try JSONEncoder().encode(result), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            switch command.operation {
            case .start(var selection):
                // Like the API: fill in the worker the phone left out.
                selection.workerId = selection.workerId ?? "home-1"
                selection.outputId = selection.outputId ?? "youtube"
                broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: selection); operations.append("start")
            case .stop: broadcast = .init(desired: .stopped, generation: broadcast.generation + 1, selection: nil); operations.append("stop")
            }
            let result = BroadcastOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot(), youtube: youtube)
            receipts[command.commandId] = result
            data = try JSONEncoder().encode(result)
        } else if path.contains("/commands/") {
            if let receipt = receipts[request.url!.lastPathComponent] { data = try JSONEncoder().encode(receipt) }
            else { return (Data("{\"error\":\"command_not_found\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        } else if path.hasSuffix("/publish") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let attempt = body["publishingAttemptId"] as? String
            var response: [String: Any] = ["gameId": "game-1", "recordingId": body["recordingId"]!, "generation": broadcast.generation, "serverTime": time]
            if let attempt { response["publishingAttemptId"] = attempt }
            let streamID = attempt.map { "publish:scorebug-0123456789abcdef-0123456789abcdef0123456789abcdef:sbp1=\($0)." + String(repeating: "a", count: 64) } ?? "test"
            response["publishUrl"] = "srt://localhost:19000?streamid=\(streamID)"
            data = try JSONSerialization.data(withJSONObject: response)
        } else {
            data = try JSONEncoder().encode(MediaSnapshotResponse(snapshot: snapshot(), serverTime: time))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func snapshot() -> MediaSnapshot { .init(gameId: "game-1", recordings: [], broadcast: broadcast) }
}

private func matchSnapshot() throws -> MatchSnapshot {
    let json = ##"{"id":"game-1","createdAt":"2026-09-14T00:00:00Z","revision":0,"teams":{"home":{"name":"Home","shortName":"HOM","color":"#112233"},"away":{"name":"Away","shortName":"AWY","color":"#445566"}},"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":0,"away":0,"set":1,"homeSets":0,"awaySets":0},"completedSets":[],"status":"active","endReason":null,"canUndo":false,"scorer":{"deviceId":"scorer-1","epoch":1},"broadcast":{"desired":"stopped","generation":0}}"##
    return try JSONDecoder().decode(MatchSnapshot.self, from: Data(json.utf8))
}

@preconcurrency import AVFoundation
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

/// Functional native-model integration with real local A/V. The injected
/// callbacks do not qualify physical WatchConnectivity or recording throughput.
@MainActor
final class NativeWatchRelayRecordingTests: XCTestCase {
    func testTwoPairedWatchesRecoverAndTransferScoringDuringOneRealRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = RelayRecordingHTTP()
        let pairA = try RelayRecordingPair(number: 1, root: root, server: server)
        let pairB = try RelayRecordingPair(number: 2, root: root, server: server)
        await server.register(pairA.credential, store: pairA.outbox)
        await server.register(pairB.credential, store: pairB.outbox)
        pairA.phone.restoreRelayAssociation()
        pairB.phone.restoreRelayAssociation()
        XCTAssertEqual(pairA.phone.relayBinding, pairA.scope)
        XCTAssertEqual(pairB.phone.relayBinding, pairB.scope)
        XCTAssertTrue(pairA.bindingErrors.isEmpty)
        XCTAssertTrue(pairB.bindingErrors.isEmpty)
        await pairA.watch.wake()
        await pairB.watch.wake()
        XCTAssertTrue(pairA.watch.canScore)
        XCTAssertTrue(pairB.watch.canTakeOver)

        let profile = ArchiveProfile(width: 320, height: 240, videoBitRate: 500_000)
        let library = RecordingLibrary(rootDirectory: root.appendingPathComponent("recordings"))
        let film = FilmModel(library: library, profile: profile,
            sourceFactory: { FixtureCameraSource(profile: profile) })
        await film.start()
        do {
            let captureID = try XCTUnwrap(film.currentCapture?.id)
            try await waitForMedia(film, seconds: 0.5)
            let beforeScoring = film.writtenSamples
            pairA.link.dropNextMutationReply = true
            await pairA.watch.send(.awardPoint(side: .home))
            XCTAssertEqual(pairA.link.droppedReplies, 1)
            XCTAssertFalse(pairA.watch.pending)
            XCTAssertNil(try pairA.outbox.load())
            XCTAssertEqual(pairA.watch.snapshot?.score.home, 1)
            XCTAssertEqual(pairA.haptics, 1)
            XCTAssertEqual(pairA.link.pendingAtLostReply?.command.operation, .awardPoint(side: .home))
            XCTAssertEqual(pairA.link.hapticsAtLostReply, 0)
            XCTAssertEqual(film.currentCapture?.id, captureID)
            XCTAssertEqual(film.state, .recording)

            await pairB.watch.poll()
            await pairB.watch.send(.takeOver)
            XCTAssertTrue(pairB.watch.canScore)
            await pairB.watch.send(.awardPoint(side: .away))
            XCTAssertEqual(pairB.watch.snapshot?.score.home, 1)
            XCTAssertEqual(pairB.watch.snapshot?.score.away, 1)
            XCTAssertEqual(pairB.haptics, 2)
            XCTAssertNil(try pairB.outbox.load())
            await pairA.watch.poll()
            XCTAssertFalse(pairA.watch.canScore)
            XCTAssertTrue(pairA.watch.canTakeOver)
            XCTAssertEqual(pairA.watch.snapshot?.scorer.deviceId, pairB.credential.deviceId)
            try await waitForMedia(film, seconds: 2.6)
            XCTAssertGreaterThan(film.writtenSamples, beforeScoring)
            XCTAssertEqual(film.currentCapture?.id, captureID)
            XCTAssertEqual(film.state, .recording)

            let evidence = await server.evidence()
            XCTAssertEqual(evidence.commands.map(\.operation), [.awardPoint(side: .home), .takeOver, .awardPoint(side: .away)])
            XCTAssertEqual(evidence.commands.map(\.deviceId), [pairA.credential.deviceId, pairB.credential.deviceId, pairB.credential.deviceId])
            XCTAssertEqual(evidence.commands, evidence.persistedCommands, "HTTP must carry the exact command already committed to each Watch outbox")
            XCTAssertEqual(evidence.receipts, [RelayRecordingHTTP.Receipt(deviceId: pairA.credential.deviceId,
                commandId: try XCTUnwrap(evidence.commands.first?.commandId))])
            XCTAssertEqual(Set(evidence.tokens), Set([pairA.credential.token, pairB.credential.token]))
            XCTAssertGreaterThanOrEqual(evidence.offlineReads, 3, "Both initial reads and lost-reply recovery exercise direct HTTP before companion fallback")
            XCTAssertEqual(evidence.offlineMutations, 0)
            XCTAssertTrue(pairA.link.requests.allSatisfy { $0.scope == pairA.scope && $0.credential == pairA.credential })
            XCTAssertTrue(pairB.link.requests.allSatisfy { $0.scope == pairB.scope && $0.credential == pairB.credential })

            await film.stop()
            XCTAssertEqual(film.state, .idle)
            XCTAssertNil(film.currentCapture)
            let entry = try XCTUnwrap(film.recordings.first { $0.id == captureID })
            XCTAssertEqual(entry.status, .completed)
            XCTAssertNil(entry.reason)
            XCTAssertGreaterThanOrEqual(entry.duration, 2.5)
            XCTAssertLessThan(entry.duration, 6)
            let archive = try ArchiveSegmentStore.recover(directory: root.appendingPathComponent("recordings").appendingPathComponent(captureID))
            let assembled = root.appendingPathComponent("local-archive.mp4")
            try archive.assemble(to: assembled)
            let media = try await inspectMedia(assembled)
            XCTAssertGreaterThanOrEqual(media.videoFrames, 75)
            XCTAssertGreaterThanOrEqual(media.audioSamples, 120_000)
            XCTAssertGreaterThan(media.audibleSamples, 1_000)
            XCTAssertGreaterThanOrEqual(media.duration, 2.5)
            XCTAssertLessThan(media.duration, 6, "The fixture's nonzero source PTS must be rebased")
            XCTAssertTrue(media.cleanLowerBand, "The local archive retains the fixture's plain lower band without a score overlay")
            print("Native relay recording: duration=\(media.duration), frames=\(media.videoFrames), audioSamples=\(media.audioSamples), audibleSamples=\(media.audibleSamples), mutations=\(evidence.commands.count), recoveredReceipts=\(evidence.receipts.count), cleanLowerBand=\(media.cleanLowerBand)")
        } catch {
            await film.stop()
            await pairA.watch.suspend(); await pairB.watch.suspend()
            throw error
        }
        await pairA.watch.suspend(); await pairB.watch.suspend()
    }

    private func waitForMedia(_ film: FilmModel, seconds: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while film.elapsedSeconds < seconds {
            await film.pollHealth()
            guard film.state == .recording, ContinuousClock.now < deadline else {
                throw RelayRecordingError.mediaDidNotAdvance
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func inspectMedia(_ url: URL) async throws -> RelayRecordingMedia {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        let video = AVAssetReaderTrackOutput(track: try XCTUnwrap(videoTracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let videoReader = try AVAssetReader(asset: asset)
        videoReader.add(video)
        guard videoReader.startReading() else { throw RelayRecordingError.invalidMedia }
        var frames = 0, clean = true
        while let sample = video.copyNextSampleBuffer() {
            frames += 1
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)).assumingMemoryBound(to: UInt8.self)
            // Fixture barcode occupies the top third and motion ends at y=160.
            // Every decoded frame must preserve the plain lower band (Y=32).
            for y in Swift.stride(from: 184, to: 232, by: 8) {
                for x in Swift.stride(from: 8, to: 312, by: 8) {
                    if !(24...40).contains(Int(base[y * stride + x])) { clean = false }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        }
        XCTAssertEqual(videoReader.status, .completed)
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        let audioReader = try AVAssetReader(asset: asset)
        audioReader.add(audio)
        guard audioReader.startReading() else { throw RelayRecordingError.invalidMedia }
        var samples = 0, audible = 0
        while let sample = audio.copyNextSampleBuffer() {
            samples += CMSampleBufferGetNumSamples(sample)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var pcm = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            let status = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            audible += pcm.filter { abs(Int($0)) > 500 }.count
        }
        XCTAssertEqual(audioReader.status, .completed)
        return RelayRecordingMedia(videoFrames: frames, audioSamples: samples, audibleSamples: audible,
            duration: try await asset.load(.duration).seconds, cleanLowerBand: clean)
    }
}

private enum RelayRecordingError: Error { case unexpectedRequest, invalidMedia, mediaDidNotAdvance }
private struct RelayRecordingMedia { let videoFrames: Int; let audioSamples: Int; let audibleSamples: Int; let duration: Double; let cleanLowerBand: Bool }

@MainActor private final class RelayRecordingPair {
    let credential: MatchCredential
    let scope: WatchRelayScope
    let outbox: JSONFilePendingCommandStore
    let link: RelayRecordingLink
    var phone: PhoneWatchModel!
    var watch: WatchScoringModel!
    var bindingErrors: [String] = []
    var haptics = 0

    init(number: Int, root: URL, server: RelayRecordingHTTP) throws {
        let device = String(format: "00000000-0000-4000-8000-%012d", number)
        credential = MatchCredential(gameId: "recording-game", deviceId: device, role: .score,
            token: String(repeating: number == 1 ? "a" : "b", count: 43))
        scope = WatchRelayScope(endpoint: "https://relay.example/control", gameId: credential.gameId,
            watchDeviceId: device, pairingId: UUID().uuidString)
        outbox = JSONFilePendingCommandStore(url: root.appendingPathComponent("watch-\(number)/pending.json"))
        let forwarder = WatchRelayPhoneForwarder(clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { try await server.send($0) })
        })
        link = RelayRecordingLink(forwarder: forwarder, outbox: outbox)
        let link = link
        let transport = WatchRelayMessageTransport(isReachable: { true }, now: { link.time },
            schedule: { delay, fire in link.schedule(delay, fire: fire) },
            send: { data, reply in try link.send(data, reply: reply) })
        let companion = WatchRelayScoringClient(scope: scope, send: { try await transport.send($0) })
        let direct = MatchHTTPClient(endpoint: try ScoringEndpoint(scope.endpoint), transport: { try await server.offline($0) })
        let routed = WatchRoutedScoringClient(direct: direct, companion: companion, companionAvailable: { true })
        let paired = WatchPairedSetup(endpoint: scope.endpoint, pairingId: scope.pairingId,
            redemptionId: UUID().uuidString, credential: credential)
        let setup = WatchSetupCoordinator(storage: RelayRecordingWatchStore(record: WatchSetupRecord(deviceId: device, paired: paired)), scoringOutbox: outbox)
        phone = PhoneWatchModel(storage: RelayRecordingPhoneStore(record: PhoneWatchSetupRecord(relayBinding: scope)),
            onRelayBindingChanged: { [weak self] binding in
                do { try forwarder.updateBinding(binding) }
                catch { self?.bindingErrors.append(String(describing: error)) }
            }, sendEnvelope: { _ in XCTFail("Pre-paired fixture must not issue a new setup") })
        watch = WatchScoringModel(setupCoordinator: setup, pendingStore: outbox,
            scoringClientFactory: { _ in routed }, recoverUncertainSendImmediately: true,
            onNotice: { [weak self] notice in self?.phone.receive(notice) },
            acknowledgmentHaptic: { [weak self] in self?.haptics += 1 })
        link.readHaptics = { [weak self] in self?.haptics ?? -1 }
    }
}

/// An injected delegate boundary, retaining the same gate and reply ownership
/// as the native bridge. No actual radio/session behavior is inferred from it.
@MainActor private final class RelayRecordingLink {
    let forwarder: WatchRelayPhoneForwarder
    let outbox: JSONFilePendingCommandStore
    let gate = WatchRelaySessionGate()
    var time: TimeInterval = 100
    var timer: (id: UUID, deadline: TimeInterval, fire: @MainActor @Sendable () -> Void)?
    var requests: [WatchRelayRequest] = []
    var dropNextMutationReply = false
    var droppedReplies = 0
    var pendingAtLostReply: PendingMatchCommand?
    var hapticsAtLostReply: Int?
    var readHaptics: () -> Int = { -1 }
    init(forwarder: WatchRelayPhoneForwarder, outbox: JSONFilePendingCommandStore) {
        self.forwarder = forwarder; self.outbox = outbox
    }
    func schedule(_ delay: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) -> WatchRelayMessageTransport.ScheduledCancellation {
        let id = UUID()
        timer = (id, time + delay, fire)
        return { [weak self] in if self?.timer?.id == id { self?.timer = nil } }
    }
    func send(_ data: Data, reply: @escaping WatchRelayMessageTransport.Callback) throws {
        let request = try WatchRelayCodec.decodeRequest(data)
        requests.append(request)
        guard let token = gate.admit() else { throw WatchRelayFailure.busy }
        let once = WatchRelayReplyOnce { reply(.success($0)) }
        Task { @MainActor in
            let response = await forwarder.forward(data)
            let current = gate.isCurrent(token)
            gate.release(token)
            guard current else { once.send(Data()); return }
            if dropNextMutationReply, case .execute = request.operation {
                dropNextMutationReply = false
                do {
                    guard case .outcome(let outcome) = try WatchRelayCodec.decodeReply(response, for: request).result,
                          outcome.accepted else { throw RelayRecordingError.unexpectedRequest }
                    pendingAtLostReply = try outbox.load()
                    hapticsAtLostReply = readHaptics()
                    droppedReplies += 1
                    let scheduled = try XCTUnwrap(timer)
                    time = scheduled.deadline
                    scheduled.fire()
                } catch { XCTFail("Could not drop a committed reply: \(error)"); once.send(response) }
            } else { once.send(response) }
        }
    }
}

private struct RelayRecordingWatchStore: WatchSetupStorage {
    let record: WatchSetupRecord
    func load() throws -> WatchSetupRecord? { record }
    func save(_ record: WatchSetupRecord) throws { throw RelayRecordingError.unexpectedRequest }
}
private struct RelayRecordingPhoneStore: PhoneWatchRequestStorage {
    let record: PhoneWatchSetupRecord
    func load() throws -> PhoneWatchSetupRecord? { record }
    func save(_ record: PhoneWatchSetupRecord) throws { throw RelayRecordingError.unexpectedRequest }
}

private actor RelayRecordingHTTP {
    struct Receipt: Equatable { let deviceId: String; let commandId: String }
    struct Evidence {
        let commands: [MatchCommand]; let persistedCommands: [MatchCommand]; let receipts: [Receipt]
        let tokens: [String]; let offlineReads: Int; let offlineMutations: Int
    }
    private var credentials: [String: MatchCredential] = [:]
    private var stores: [String: JSONFilePendingCommandStore] = [:]
    private var outcomes: [String: CommandOutcome] = [:]
    private var commands: [MatchCommand] = [], persistedCommands: [MatchCommand] = []
    private var receipts: [Receipt] = [], tokens: [String] = []
    private var offlineReads = 0, offlineMutations = 0
    private var snapshot = MatchSnapshot(id: "recording-game", createdAt: "2026-09-15T12:00:00.000Z", revision: 0,
        teams: MatchTeams(home: MatchTeam(name: "Home", shortName: "HOM", color: "#112233"),
            away: MatchTeam(name: "Away", shortName: "AWY", color: "#445566")),
        rules: MatchRules(bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil),
        score: MatchScore(home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0), completedSets: [],
        status: .active, endReason: nil, canUndo: false,
        scorer: MatchScorer(deviceId: "00000000-0000-4000-8000-000000000001", epoch: 1),
        broadcast: MatchBroadcast(desired: .stopped, generation: 0))
    func register(_ credential: MatchCredential, store: JSONFilePendingCommandStore) {
        credentials["Bearer \(credential.token)"] = credential; stores[credential.deviceId] = store
    }
    func offline(_ request: URLRequest) throws -> (Data, URLResponse) {
        if request.httpMethod == "GET" { offlineReads += 1 } else { offlineMutations += 1 }
        throw URLError(.notConnectedToInternet)
    }
    func evidence() -> Evidence {
        Evidence(commands: commands, persistedCommands: persistedCommands, receipts: receipts,
            tokens: tokens, offlineReads: offlineReads, offlineMutations: offlineMutations)
    }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == "relay.example",
              let credential = credentials[request.value(forHTTPHeaderField: "Authorization") ?? ""] else {
            throw RelayRecordingError.unexpectedRequest
        }
        tokens.append(credential.token)
        let prefix = "/control/v1/matches/\(credential.gameId)"
        if request.httpMethod == "GET", url.path == prefix {
            return try response(MatchSnapshotResponse(snapshot: snapshot, serverTime: "2026-09-15T12:00:00.000Z"), url: url)
        }
        if request.httpMethod == "POST", url.path == prefix + "/commands" {
            let command = try JSONDecoder().decode(MatchCommand.self, from: XCTUnwrap(request.httpBody))
            guard command.deviceId == credential.deviceId, command.gameId == credential.gameId,
                  command.expectedRevision == snapshot.revision, command.scorerEpoch == snapshot.scorer.epoch,
                  let pending = try stores[credential.deviceId]?.load(), pending.command == command else {
                throw RelayRecordingError.unexpectedRequest
            }
            commands.append(command); persistedCommands.append(pending.command)
            guard outcomes[credential.deviceId + "|" + command.commandId] == nil else { throw RelayRecordingError.unexpectedRequest }
            switch command.operation {
            case .takeOver:
                snapshot.scorer = MatchScorer(deviceId: credential.deviceId, epoch: snapshot.scorer.epoch + 1)
            case .awardPoint(let side):
                guard snapshot.scorer.deviceId == credential.deviceId else { throw RelayRecordingError.unexpectedRequest }
                if side == .home { snapshot.score.home += 1 } else { snapshot.score.away += 1 }
                snapshot.canUndo = true
            default: throw RelayRecordingError.unexpectedRequest
            }
            snapshot.revision += 1
            let outcome = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot)
            outcomes[credential.deviceId + "|" + command.commandId] = outcome
            return try response(outcome, url: url)
        }
        if request.httpMethod == "GET", url.path.hasPrefix(prefix + "/commands/") {
            let commandID = url.lastPathComponent
            receipts.append(Receipt(deviceId: credential.deviceId, commandId: commandID))
            guard let outcome = outcomes[credential.deviceId + "|" + commandID] else { throw RelayRecordingError.unexpectedRequest }
            return try response(outcome, url: url)
        }
        throw RelayRecordingError.unexpectedRequest
    }
    private func response<T: Encodable>(_ value: T, url: URL) throws -> (Data, URLResponse) {
        (try JSONEncoder().encode(value), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

import Foundation
import ScorebugCore
import XCTest

private final class MemoryRequest: PhoneWatchRequestStorage {
    var value: PhoneWatchRequest?
    var writesLeft = Int.max
    func load() throws -> PhoneWatchRequest? { value }
    func save(_ value: PhoneWatchRequest?) throws {
        guard writesLeft > 0 else { throw CocoaError(.fileWriteUnknown) }
        writesLeft -= 1; self.value = value
    }
}
private actor PhoneNetwork {
    var requests: [URLRequest] = []
    var failIssue = false
    var pauseIssue = false
    var continuation: CheckedContinuation<Void, Never>?
    let snapshot: MatchSnapshot
    init() throws {
        let team = MatchTeam(name: "Home", shortName: "HOM", color: "#112233")
        snapshot = try JSONDecoder().decode(MatchSnapshot.self, from: Data("""
        {"id":"fixture-game","createdAt":"2026-09-14T10:00:00.000Z","revision":0,"teams":\(String(decoding: JSONEncoder().encode(MatchTeams(home: team, away: team)), as: UTF8.self)),"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":0,"away":0,"set":1,"homeSets":0,"awaySets":0},"completedSets":[],"status":"active","endReason":null,"canUndo":false,"scorer":{"deviceId":"phone","epoch":1},"broadcast":{"desired":"stopped","generation":0}}
        """.utf8))
    }
    func configure(fail: Bool = false, pause: Bool = false) { failIssue = fail; pauseIssue = pause }
    func release() { continuation?.resume(); continuation = nil }
    func all() -> [URLRequest] { requests }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body: Data
        if request.url!.path.hasSuffix("/active") {
            struct Active: Encodable { let snapshot: MatchSnapshot; let serverTime: String }
            body = try JSONEncoder().encode(Active(snapshot: snapshot, serverTime: "2026-09-14T10:00:00.000Z"))
        } else {
            if pauseIssue { await withCheckedContinuation { continuation = $0 } }
            if failIssue { throw URLError(.networkConnectionLost) }
            let input = try JSONDecoder().decode(WatchPairingIssueRequest.self, from: request.httpBody!)
            body = try JSONEncoder().encode(WatchPairingIssued(pairingId: input.pairingId, gameId: snapshot.id,
                watchDeviceId: input.watchDeviceId, pairingToken: String(repeating: "A", count: 43),
                expiresAt: "2026-09-14T10:05:00.000Z", serverTime: "2026-09-14T10:00:00.000Z"))
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class PhoneWatchModelTests: XCTestCase {
    private let device = "20000000-0000-4000-8000-000000000002"
    private let connection = PhoneWatchConnection(label: "Recording server", endpoint: "https://example.com/control", installationToken: "installation-secret")
    private func model(_ store: MemoryRequest, _ network: PhoneNetwork, send: @escaping (WatchPairingEnvelope) throws -> Void) -> PhoneWatchModel {
        let model = PhoneWatchModel(storage: store, clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { try await network.send($0) })
        }, sendEnvelope: send)
        model.resume(); model.receive(WatchCompanionNotice(deviceId: device, phase: .unpaired))
        return model
    }
    func testPersistsBeforeIssuanceAndSendsOnlyScopedSetup() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        var sent: [WatchPairingEnvelope] = []
        let model = model(store, network) { envelope in
            XCTAssertEqual(store.value?.offer, envelope.offer)
            sent.append(envelope)
        }
        await model.connect(using: connection)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.offer.watchDeviceId, device)
        XCTAssertEqual(sent.first?.offer.role, .score)
        XCTAssertEqual(sent.first?.endpoint, connection.endpoint)
        let requests = await network.all()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { !$0.url!.path.contains("commands") && !$0.url!.path.contains("media") })
        XCTAssertEqual(store.value?.request.pairingId, sent.first?.offer.pairingId)
    }
    func testFailedPendingSavePreventsIssuance() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        store.writesLeft = 0
        let model = model(store, network) { _ in XCTFail("Must not send") }
        await model.connect(using: connection)
        let requests = await network.all()
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("watch-pairings") }.count, 0)
        XCTAssertNil(store.value)
        XCTAssertNotNil(model.message)
    }
    func testLostIssuanceResponseRetriesOriginalIDAndConnectionAfterRelaunch() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        await network.configure(fail: true)
        await model(store, network) { _ in XCTFail("No response yet") }.connect(using: connection)
        let original = try XCTUnwrap(store.value)
        await network.configure()
        var sent: WatchPairingEnvelope?
        let replacement = model(store, network) { sent = $0 }
        await replacement.connect(using: PhoneWatchConnection(label: "Changed", endpoint: "https://other.example", installationToken: "other-secret"))
        XCTAssertEqual(sent?.offer.pairingId, original.request.pairingId)
        let requests = await network.all().filter { $0.url!.path.hasSuffix("watch-pairings") }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
        XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
    }
    private func awaitIssue(_ network: PhoneNetwork) async {
        for _ in 0..<1000 {
            if await network.continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Issuance did not reach pause")
    }
    func testPeerChangeRejectsLateIssuanceWithoutSendingOrOverwriting() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        await network.configure(pause: true)
        let model = model(store, network) { _ in XCTFail("Stale peer must not receive setup") }
        let connecting = Task { await model.connect(using: connection) }
        await awaitIssue(network)
        let original = try XCTUnwrap(store.value)
        model.peerChanged()
        model.receive(WatchCompanionNotice(deviceId: "30000000-0000-4000-8000-000000000003", phase: .unpaired))
        await network.release(); await connecting.value
        XCTAssertEqual(store.value, original)
        XCTAssertNil(store.value?.offer)
        XCTAssertFalse(model.busy)
    }
    func testSuspendJoinsLateResponseAndKeepsDurableRetry() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        await network.configure(pause: true)
        let model = model(store, network) { _ in XCTFail("Suspended app must not send") }
        let connecting = Task { await model.connect(using: connection) }
        await awaitIssue(network)
        let suspending = Task { await model.suspend() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.busy)
        await network.release(); await suspending.value; await connecting.value
        XCTAssertNotNil(store.value)
        XCTAssertNil(store.value?.offer)
        XCTAssertFalse(model.busy)
    }
    func testFailedOfferSaveDoesNotSendAndRetryUsesOriginalRequest() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        store.writesLeft = 1
        var sent = 0
        let model = model(store, network) { _ in sent += 1 }
        await model.connect(using: connection)
        let original = try XCTUnwrap(store.value?.request)
        XCTAssertEqual(sent, 0)
        XCTAssertNil(store.value?.offer)
        store.writesLeft = 10
        await model.retry()
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(store.value?.request, original)
    }
    func testConfirmationDuringIssuanceCannotResurrectSavedRequest() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        await network.configure(pause: true)
        let model = model(store, network) { _ in XCTFail("Already confirmed") }
        let connecting = Task { await model.connect(using: connection) }
        await awaitIssue(network)
        let saved = try XCTUnwrap(store.value)
        model.receive(WatchCompanionNotice(deviceId: device, phase: .paired, gameId: saved.gameId,
            pairingId: saved.request.pairingId))
        XCTAssertNil(store.value)
        await network.release(); await connecting.value
        XCTAssertNil(store.value)
        XCTAssertNil(model.pending)
    }
    func testFailedConfirmationClearRetainsRecoverableRequest() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        let model = model(store, network) { _ in }
        await model.connect(using: connection)
        let saved = try XCTUnwrap(store.value)
        store.writesLeft = 0
        model.receive(WatchCompanionNotice(deviceId: device, phase: .paired, gameId: saved.gameId,
            pairingId: saved.request.pairingId))
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(model.pending, saved)
        XCTAssertTrue(model.message?.contains("could not be saved") == true)
    }

    func testSameGameNoticeDoesNotSuppressIssuanceOnSelectedServer() async throws {
        let store = MemoryRequest(), network = try PhoneNetwork()
        var sent: WatchPairingEnvelope?
        let model = model(store, network) { sent = $0 }
        model.receive(WatchCompanionNotice(deviceId: device, phase: .paired, gameId: "fixture-game",
            pairingId: "40000000-0000-4000-8000-000000000004"))
        let selected = PhoneWatchConnection(label: "Other server", endpoint: "https://other.example/control", installationToken: "other-secret")
        await model.connect(using: selected)
        XCTAssertEqual(sent?.endpoint, selected.endpoint)
        XCTAssertEqual(store.value?.connection, selected)
        let requests = await network.all()
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("watch-pairings") }.count, 1)
    }

}

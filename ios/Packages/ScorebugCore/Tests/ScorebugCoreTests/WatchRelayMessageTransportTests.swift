import Foundation
import XCTest
@testable import ScorebugCore

@MainActor
final class WatchRelayMessageTransportTests: XCTestCase {
    private let scope = WatchRelayScope(endpoint: "https://example.com", gameId: "fixture-game",
        watchDeviceId: "00000000-0000-4000-8000-000000000014", pairingId: "00000000-0000-4000-8000-000000000015")
    private var credential: MatchCredential {
        MatchCredential(gameId: scope.gameId, deviceId: scope.watchDeviceId, role: .score, token: String(repeating: "a", count: 43))
    }
    private func request() throws -> Data {
        try WatchRelayCodec.encodeRequest(WatchRelayRequest(requestId: UUID().uuidString, scope: scope, credential: credential, operation: .snapshot))
    }
    private func owner(_ harness: MessageHarness, timeout: TimeInterval = 4) -> WatchRelayMessageTransport {
        WatchRelayMessageTransport(timeout: timeout, isReachable: { harness.reachable }, now: { harness.time },
            schedule: { delay, fire in harness.schedule(delay, fire: fire) },
            send: { data, callback in try harness.send(data, callback: callback) })
    }
    private func expectFailure<T>(_ task: Task<T, Error>, _ expected: WatchRelayFailure) async {
        do { _ = try await task.value; XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, expected) }
    }

    func testOnePendingExactDataAndBusyAdmission() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let first = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        XCTAssertEqual(harness.requests, [bytes])
        do { _ = try await transport.send(bytes); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .busy) }
        let reply = Data("exact callback bytes".utf8)
        harness.callbacks[0](.success(reply))
        let delivered = try await first.value
        XCTAssertEqual(delivered, reply)
        XCTAssertEqual(harness.cancelledTimers, [0])
    }

    func testUnavailableAndMalformedRequestsFailBeforeDispatch() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        harness.reachable = false
        do { _ = try await transport.send(bytes); XCTFail("Expected unavailable") }
        catch { XCTAssertEqual(error as? WatchRelayFailure, .unavailable) }
        harness.reachable = true
        for invalid in [Data(), Data("not-json".utf8), Data(repeating: 32, count: WatchRelayCodec.maximumRequestBytes + 1)] {
            do { _ = try await transport.send(invalid); XCTFail("Expected invalid request") }
            catch { XCTAssertEqual(error as? WatchRelayFailure, .invalidRequest) }
        }
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertTrue(harness.timers.isEmpty)
    }

    func testInvalidTimeoutClockAndDeadlineFailWithoutPublicPreconditions() async throws {
        let bytes = try request()
        let invalidTimeouts: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
        for timeout in invalidTimeouts {
            let harness = MessageHarness()
            do { _ = try await owner(harness, timeout: timeout).send(bytes); XCTFail("Expected unavailable") }
            catch { XCTAssertEqual(error as? WatchRelayFailure, .unavailable) }
            XCTAssertTrue(harness.requests.isEmpty)
        }
        for time in [TimeInterval.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let harness = MessageHarness(); harness.time = time
            do { _ = try await owner(harness, timeout: .greatestFiniteMagnitude).send(bytes); XCTFail("Expected unavailable") }
            catch { XCTAssertEqual(error as? WatchRelayFailure, .unavailable) }
            XCTAssertTrue(harness.requests.isEmpty)
        }
    }

    func testSynchronousSenderFailureSettlesAndCancelsDeadline() async throws {
        let harness = MessageHarness(), bytes = try request()
        harness.throwOnSend = true
        let task = Task { try await owner(harness).send(bytes) }
        await expectFailure(task, .unavailable)
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(harness.cancelledTimers, [0])
    }

    func testCallbackFailuresAndReplyBoundsSettleOnce() async throws {
        for response in [Result<Data, WatchRelayFailure>.failure(.unavailable), .failure(.forbidden),
                         .success(Data()), .success(Data(repeating: 0, count: WatchRelayCodec.maximumReplyBytes + 1))] {
            let harness = MessageHarness(), bytes = try request()
            let transport = owner(harness)
            let task = Task { try await transport.send(bytes) }
            await harness.waitForSend(1)
            harness.callbacks[0](response)
            harness.callbacks[0](.success(Data("late duplicate".utf8)))
            let expected: WatchRelayFailure
            switch response { case .failure(let value): expected = value; case .success: expected = .invalidResponse }
            await expectFailure(task, expected)
            XCTAssertEqual(harness.cancelledTimers, [0])
        }
    }

    func testMaximumReplyBytesCanBeDeliveredWithoutChangingData() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let task = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        let reply = Data(repeating: 65, count: WatchRelayCodec.maximumReplyBytes)
        harness.callbacks[0](.success(reply))
        let delivered = try await task.value
        XCTAssertEqual(delivered, reply)
    }

    func testFailureCallbackMetadataIsBoundedBeforeActorAdmission() async throws {
        for failure in [WatchRelayFailure.http(status: 500, code: String(repeating: "x", count: 129)),
                        .http(status: 500, code: "raw body\nsecret"), .http(status: 999, code: nil)] {
            let harness = MessageHarness(), bytes = try request()
            let transport = owner(harness)
            let task = Task { try await transport.send(bytes) }
            await harness.waitForSend(1)
            harness.callbacks[0](.failure(failure))
            await expectFailure(task, .invalidResponse)
        }
    }

    func testDuplicateAndOldCallbacksCannotSettleANewerRequest() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let first = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        harness.callbacks[0](.success(Data("first".utf8)))
        harness.callbacks[0](.success(Data("duplicate".utf8)))
        let firstReply = try await first.value
        XCTAssertEqual(firstReply, Data("first".utf8))
        let second = Task { try await transport.send(bytes) }
        await harness.waitForSend(2)
        harness.callbacks[0](.failure(.forbidden))
        harness.fire(0, evenIfCancelled: true)
        harness.callbacks[1](.success(Data("second".utf8)))
        let secondReply = try await second.value
        XCTAssertEqual(secondReply, Data("second".utf8))
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testReplyAtDeadlineFailsEvenBeforeScheduledTimerRuns() async throws {
        for offset in [4.0, 4.001] {
            let harness = MessageHarness(), bytes = try request()
            let transport = owner(harness)
            let task = Task { try await transport.send(bytes) }
            await harness.waitForSend(1)
            harness.time += offset
            harness.callbacks[0](.success(Data("expired".utf8)))
            await expectFailure(task, .unavailable)
            XCTAssertEqual(harness.cancelledTimers, [0])
        }
    }

    func testReplyBeforeDeadlineSucceedsAndTimerExpiryFailsWithoutRetry() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let first = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        harness.time += 3.999
        harness.callbacks[0](.success(Data("in time".utf8)))
        let delivered = try await first.value
        XCTAssertEqual(delivered, Data("in time".utf8))
        let second = Task { try await transport.send(bytes) }
        await harness.waitForSend(2)
        harness.time += 4
        harness.fire(1)
        await expectFailure(second, .unavailable)
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testEarlyTimerRearmsAgainstAbsoluteDeadline() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let task = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        harness.time += 1
        harness.fire(0)
        XCTAssertEqual(harness.timers.count, 2)
        XCTAssertEqual(harness.timers[1].delay, 3)
        harness.time += 3
        harness.fire(1)
        await expectFailure(task, .unavailable)
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testInvalidClockAtCallbackCannotAdmitSuccess() async throws {
        for time in [TimeInterval.nan, .infinity, 99] {
            let harness = MessageHarness(), bytes = try request()
            let transport = owner(harness)
            let task = Task { try await transport.send(bytes) }
            await harness.waitForSend(1)
            harness.time = time
            harness.callbacks[0](.success(Data("unqualified clock".utf8)))
            await expectFailure(task, .unavailable)
        }
    }

    func testCancellationBeforeDispatchAndAfterDispatchPreservesOwnership() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(bytes)
        }
        do { _ = try await before.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(harness.requests.isEmpty)
        let active = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        active.cancel()
        do { _ = try await active.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(harness.cancelledTimers, [0])
        let replacement = Task { try await transport.send(bytes) }
        await harness.waitForSend(2)
        harness.callbacks[0](.success(Data("canceled".utf8)))
        harness.callbacks[1](.success(Data("replacement".utf8)))
        let replacementReply = try await replacement.value
        XCTAssertEqual(replacementReply, Data("replacement".utf8))
    }

    func testPeerInvalidationSettlesOldRequestAndIgnoresItsLateReply() async throws {
        let harness = MessageHarness(), bytes = try request()
        let transport = owner(harness)
        let first = Task { try await transport.send(bytes) }
        await harness.waitForSend(1)
        transport.invalidatePeer()
        transport.invalidatePeer()
        await expectFailure(first, .unavailable)
        let second = Task { try await transport.send(bytes) }
        await harness.waitForSend(2)
        harness.callbacks[0](.success(Data("old peer".utf8)))
        harness.callbacks[1](.success(Data("new peer".utf8)))
        let delivered = try await second.value
        XCTAssertEqual(delivered, Data("new peer".utf8))
    }

    func testTimedOutCommittedCommandRecoversThroughTypedClientAndDurableOutbox() async throws {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        var snapshot = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)).snapshot
        snapshot.scorer.deviceId = credential.deviceId
        let date = Date(timeIntervalSince1970: 1_789_347_600)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let phone = MessagePhone(snapshot: snapshot, serverTime: formatter.string(from: date), store: store)
        let harness = MessageHarness()
        harness.onSend = { data, callback in try phone.receive(data, callback: callback) }
        let transport = owner(harness)
        let client = WatchRelayScoringClient(scope: scope, send: { try await transport.send($0) })
        let first = MatchCommandCoordinator(client: client, credential: credential, endpointScope: "paired-watch", store: store, now: { date })
        _ = try await first.refresh()
        let submit = Task { try await first.submit(.awardPoint(side: .home)) }
        await harness.waitForSend(2)
        let pending = try XCTUnwrap(store.load())
        XCTAssertEqual(phone.durableAtExecute, pending)
        XCTAssertEqual(phone.applications, 1)
        harness.time += 4
        harness.fire(1)
        await expectFailure(submit, .unavailable)
        let uncertain = await first.state()
        XCTAssertEqual(uncertain.status, .pending); XCTAssertNil(uncertain.outcome)
        let second = MatchCommandCoordinator(client: client, credential: credential, endpointScope: "paired-watch",
            store: JSONFilePendingCommandStore(url: url), now: { date })
        let recovered = try await second.recover()
        phone.lateReply?()
        XCTAssertEqual(recovered.outcome?.commandId, pending.command.commandId)
        XCTAssertEqual(recovered.outcome?.accepted, true)
        XCTAssertNil(try store.load())
        XCTAssertEqual(phone.operations, [.snapshot, .execute, .receipt])
        XCTAssertEqual(phone.applications, 1)
    }
}

@MainActor
private final class MessageHarness {
    typealias Callback = @Sendable (Result<Data, WatchRelayFailure>) -> Void
    struct Timer { let delay: TimeInterval; let fire: @MainActor @Sendable () -> Void }
    var time: TimeInterval = 100
    var reachable = true
    var throwOnSend = false
    var requests: [Data] = []
    var callbacks: [Callback] = []
    var timers: [Timer] = []
    var cancelledTimers: [Int] = []
    var onSend: ((Data, @escaping Callback) throws -> Void)?
    private var waits: [(Int, CheckedContinuation<Void, Never>)] = []
    func schedule(_ delay: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        let id = timers.count; timers.append(Timer(delay: delay, fire: fire))
        return { [weak self] in self?.cancelledTimers.append(id) }
    }
    func fire(_ id: Int, evenIfCancelled: Bool = false) {
        if evenIfCancelled || !cancelledTimers.contains(id) { timers[id].fire() }
    }
    func send(_ data: Data, callback: @escaping Callback) throws {
        requests.append(data); callbacks.append(callback)
        let ready = waits.filter { $0.0 <= requests.count }; waits.removeAll { $0.0 <= requests.count }
        for (_, wait) in ready { wait.resume() }
        if throwOnSend { throw WatchRelayFailure.unavailable }
        try onSend?(data, callback)
    }
    func waitForSend(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waits.append((count, $0)) }
    }
}

@MainActor
private final class MessagePhone {
    private var snapshot: MatchSnapshot
    private let serverTime: String
    private let store: any PendingCommandStore
    private var outcome: CommandOutcome?
    private(set) var applications = 0
    private(set) var operations: [WatchRelayOperationKind] = []
    private(set) var durableAtExecute: PendingMatchCommand?
    var lateReply: (() -> Void)?
    init(snapshot: MatchSnapshot, serverTime: String, store: any PendingCommandStore) {
        self.snapshot = snapshot; self.serverTime = serverTime; self.store = store
    }
    func receive(_ data: Data, callback: @escaping MessageHarness.Callback) throws {
        let request = try WatchRelayCodec.decodeRequest(data)
        operations.append(request.operation.kind)
        let result: WatchRelayResult
        switch request.operation {
        case .snapshot: result = .snapshot(MatchSnapshotResponse(snapshot: snapshot, serverTime: serverTime))
        case .execute(let command):
            durableAtExecute = try store.load()
            snapshot.revision += 1; snapshot.score.home += 1; applications += 1
            let value = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot)
            outcome = value
            let reply = try WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: .outcome(value)), for: request)
            lateReply = { callback(.success(reply)) }
            return
        case .receipt: result = outcome.map(WatchRelayResult.receiptFound) ?? .receiptAbsent
        }
        callback(.success(try WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: result), for: request)))
    }
}

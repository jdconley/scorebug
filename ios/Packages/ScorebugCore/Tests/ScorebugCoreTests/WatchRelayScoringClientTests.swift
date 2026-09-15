import Foundation
import XCTest
@testable import ScorebugCore

final class WatchRelayScoringClientTests: XCTestCase {
    private let device = "00000000-0000-4000-8000-000000000014"
    private let pairing = "00000000-0000-4000-8000-000000000015"
    private let date = Date(timeIntervalSince1970: 1_789_347_600)
    private var scope: WatchRelayScope {
        WatchRelayScope(endpoint: "https://example.com", gameId: "fixture-game", watchDeviceId: device, pairingId: pairing)
    }
    private var credential: MatchCredential {
        MatchCredential(gameId: scope.gameId, deviceId: device, role: .score, token: String(repeating: "a", count: 43))
    }
    private func command() -> MatchCommand {
        MatchCommand(commandId: "durable-original-command", gameId: scope.gameId, deviceId: device,
            expectedRevision: 0, scorerEpoch: 1, issuedAt: relayDate(date), operation: .awardPoint(side: .home))
    }
    private func phone(store: (any PendingCommandStore)? = nil) throws -> CodecPhone {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        var snapshot = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot
        snapshot.scorer.deviceId = device
        return CodecPhone(snapshot: snapshot, serverTime: relayDate(date), store: store)
    }
    private func client(_ phone: CodecPhone) -> WatchRelayScoringClient {
        WatchRelayScoringClient(scope: scope, send: { try await phone.send($0) })
    }
    private func coordinator(_ client: any MatchScoringClient, store: any PendingCommandStore) -> MatchCommandCoordinator {
        let now = date.addingTimeInterval(3600)
        return MatchCommandCoordinator(client: client, credential: credential,
            endpointScope: "watch|https://example.com|paired-generation", store: store, now: { now })
    }
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
    }

    func testTypedClientUsesWatchCredentialAndFreshRequestIDsForAllOperations() async throws {
        let phone = try phone()
        let client = client(phone)
        let snapshot = try await client.snapshot(credential: credential)
        XCTAssertEqual(snapshot.snapshot.revision, 0)
        let outcome = try await client.execute(command(), credential: credential)
        XCTAssertTrue(outcome.accepted)
        XCTAssertEqual(outcome.snapshot.score.home, 1)
        let found = try await client.receipt(commandId: command().commandId, credential: credential)
        XCTAssertEqual(found, outcome)
        let absent = try await client.receipt(commandId: "absent-command", credential: credential)
        XCTAssertNil(absent)
        await phone.setReject(true)
        var rejectedCommand = command()
        rejectedCommand.commandId = "durable-rejected-command"
        rejectedCommand.expectedRevision = 1
        rejectedCommand.operation = .endSet(winner: nil, overrideReason: nil)
        let rejection = try await client.execute(rejectedCommand, credential: credential)
        XCTAssertFalse(rejection.accepted)
        XCTAssertEqual(rejection.error, "set_not_won")
        let calls = await phone.calls
        XCTAssertEqual(calls.map { $0.request.operation.kind }, [.snapshot, .execute, .receipt, .receipt, .execute])
        XCTAssertEqual(Set(calls.map { $0.request.requestId }).count, 5)
        XCTAssertTrue(calls.allSatisfy { UUID(uuidString: $0.request.requestId) != nil })
        XCTAssertTrue(calls.allSatisfy { $0.request.credential == credential && $0.request.scope == scope })
        XCTAssertEqual(calls[1].request.operation, .execute(command()))
        XCTAssertEqual(calls[4].request.operation, .execute(rejectedCommand))
    }

    func testInjectedRequestIDIsTransportIdentityNotDurableCommandIdentity() async throws {
        let phone = try phone()
        let id = "00000000-0000-4000-8000-000000000016"
        let client = WatchRelayScoringClient(scope: scope, requestId: { id }, send: { try await phone.send($0) })
        _ = try await client.execute(command(), credential: credential)
        let calls = await phone.calls
        XCTAssertEqual(calls.first?.request.requestId, id)
        XCTAssertEqual(calls.first?.request.operation, .execute(command()))
    }

    func testLostCommittedReplyRecoversReceiptThroughNewCoordinatorAndRealFileOutbox() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let phone = try phone(store: store)
        await phone.setLoseReply(true)
        let first = coordinator(client(phone), store: store)
        _ = try await first.refresh()
        do { _ = try await first.submit(.awardPoint(side: .home)); XCTFail("Expected lost reply") }
        catch let failure as RelayTestError { XCTAssertEqual(failure, .lostReply) }
        let pending = try XCTUnwrap(store.load())
        let calls = await phone.calls
        XCTAssertEqual(calls.map { $0.request.operation.kind }, [.snapshot, .execute])
        XCTAssertEqual(calls.last?.request.operation, .execute(pending.command))
        XCTAssertEqual(calls.last?.durable, pending)
        XCTAssertEqual(calls.last?.request.credential, credential)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(credential.token))
        let uncertain = await first.state()
        XCTAssertEqual(uncertain.status, .pending)
        XCTAssertNil(uncertain.outcome)
        let reopened = JSONFilePendingCommandStore(url: url)
        let second = coordinator(client(phone), store: reopened)
        let recovered = try await second.recover()
        let finalCalls = await phone.calls
        XCTAssertEqual(finalCalls.map { $0.request.operation.kind }, [.snapshot, .execute, .receipt])
        XCTAssertEqual(finalCalls.last?.request.operation, .receipt(commandId: pending.command.commandId))
        XCTAssertEqual(finalCalls.last?.durable, pending)
        XCTAssertEqual(recovered.outcome?.commandId, pending.command.commandId)
        XCTAssertEqual(recovered.outcome?.accepted, true)
        XCTAssertEqual(recovered.snapshot?.score.home, 1)
        XCTAssertNil(recovered.pending)
        XCTAssertNil(try reopened.load())
        let applications = await phone.applications
        XCTAssertEqual(applications, 1)
    }

    func testFailureRepliesThrowTypedErrorsAndNeverBecomeReceiptAbsence() async throws {
        let failures: [WatchRelayFailure] = [.unauthorized, .forbidden, .http(status: 503, code: "unavailable"),
            .invalidResponse, .invalidRequest, .scopeMismatch, .unavailable, .cancelled, .busy]
        for failure in failures {
            let client = WatchRelayScoringClient(scope: scope, send: { data in
                let request = try WatchRelayCodec.decodeRequest(data)
                return try WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: .failure(failure)), for: request)
            })
            do { _ = try await client.receipt(commandId: "original-command", credential: credential); XCTFail("Failure cannot mean absent") }
            catch {
                switch failure {
                case .unauthorized: XCTAssertEqual(error as? MatchClientError, .unauthorized)
                case .forbidden: XCTAssertEqual(error as? MatchClientError, .forbidden)
                case .http(let status, let code): XCTAssertEqual(error as? MatchClientError, .http(status: status, code: code))
                case .invalidResponse: XCTAssertEqual(error as? MatchClientError, .invalidResponse)
                default: XCTAssertEqual(error as? WatchRelayFailure, failure)
                }
            }
        }
    }

    func testTransportErrorPropagatesWithoutRetryOrInventedReceipt() async throws {
        let counter = RelayCounter()
        let client = WatchRelayScoringClient(scope: scope, send: { _ in
            await counter.increment(); throw RelayTestError.lostReply
        })
        do { _ = try await client.receipt(commandId: "original-command", credential: credential); XCTFail("Expected transport failure") }
        catch let error as RelayTestError { XCTAssertEqual(error, .lostReply) }
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testMalformedUncorrelatedAndCrossScopeRepliesThrowWithoutResendingMutation() async throws {
        for mutation in RelayReplyMutation.allCases {
            let phone = try phone()
            let client = WatchRelayScoringClient(scope: scope, send: { data in
                try mutation.apply(await phone.send(data))
            })
            do { _ = try await client.execute(command(), credential: credential); XCTFail("Expected invalid reply: \(mutation)") }
            catch { }
            let calls = await phone.calls
            let applications = await phone.applications
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(applications, 1)
        }
    }

    func testInvalidLocalCredentialDoesNotDispatch() async throws {
        let phone = try phone()
        var credential = credential; credential.role = .capture
        do { _ = try await client(phone).execute(command(), credential: credential); XCTFail("Expected invalid request") }
        catch { }
        let calls = await phone.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAlreadyCancelledTaskDoesNotDispatchMutation() async throws {
        let phone = try phone()
        let client = client(phone), command = command(), credential = credential
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.execute(command, credential: credential)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await phone.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancelledLateCommittedReplyDoesNotAcknowledgeAndRecoversOriginalReceipt() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let phone = try phone(store: store)
        let gate = RelayReplyGate()
        let client = WatchRelayScoringClient(scope: scope, send: { data in
            let request = try WatchRelayCodec.decodeRequest(data)
            let reply = try await phone.send(data)
            if request.operation.kind == .execute { await gate.suspendReply() }
            return reply
        })
        let first = coordinator(client, store: store)
        _ = try await first.refresh()
        let task = Task { try await first.submit(.awardPoint(side: .home)) }
        await gate.waitForReply()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Canceled operation must not acknowledge late reply") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pending = try XCTUnwrap(store.load())
        let state = await first.state()
        XCTAssertNil(state.outcome); XCTAssertEqual(state.status, .pending)
        let calls = await phone.calls
        XCTAssertEqual(calls.map { $0.request.operation.kind }, [.snapshot, .execute])
        let second = coordinator(self.client(phone), store: JSONFilePendingCommandStore(url: url))
        let recovered = try await second.recover()
        XCTAssertEqual(recovered.outcome?.commandId, pending.command.commandId)
        XCTAssertEqual(recovered.outcome?.accepted, true)
        XCTAssertNil(try store.load())
        let finalCalls = await phone.calls
        let applications = await phone.applications
        XCTAssertEqual(finalCalls.map { $0.request.operation.kind }, [.snapshot, .execute, .receipt])
        XCTAssertEqual(applications, 1)
    }
}

private func relayDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
private enum RelayTestError: Error, Equatable { case lostReply }
private actor RelayCounter { private(set) var count = 0; func increment() { count += 1 } }

/// A typed phone stand-in. It records transient Watch credentials solely for
/// assertions; it provides no HTTP authorization or physical companion proof.
private actor CodecPhone {
    struct Call: Sendable { let request: WatchRelayRequest; let durable: PendingMatchCommand? }
    private var snapshot: MatchSnapshot
    private let serverTime: String
    private let store: (any PendingCommandStore)?
    private var loseReply = false
    private var reject = false
    private var outcomes: [String: CommandOutcome] = [:]
    private(set) var calls: [Call] = []
    private(set) var applications = 0
    init(snapshot: MatchSnapshot, serverTime: String, store: (any PendingCommandStore)?) {
        self.snapshot = snapshot; self.serverTime = serverTime; self.store = store
    }
    func setLoseReply(_ value: Bool) { loseReply = value }
    func setReject(_ value: Bool) { reject = value }
    func send(_ data: Data) throws -> Data {
        let request = try WatchRelayCodec.decodeRequest(data)
        calls.append(Call(request: request, durable: try store?.load()))
        let result: WatchRelayResult
        switch request.operation {
        case .snapshot: result = .snapshot(MatchSnapshotResponse(snapshot: snapshot, serverTime: serverTime))
        case .receipt(let id): result = outcomes[id].map(WatchRelayResult.receiptFound) ?? .receiptAbsent
        case .execute(let command):
            if let previous = outcomes[command.commandId] { result = .outcome(previous) }
            else if reject {
                let outcome = CommandOutcome(commandId: command.commandId, accepted: false, error: "set_not_won", snapshot: snapshot)
                outcomes[command.commandId] = outcome; result = .outcome(outcome)
            }
            else {
                snapshot.revision += 1; snapshot.score.home += 1; applications += 1
                let outcome = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot)
                outcomes[command.commandId] = outcome
                if loseReply { throw RelayTestError.lostReply }
                result = .outcome(outcome)
            }
        }
        return try WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: result), for: request)
    }
}

private enum RelayReplyMutation: CaseIterable, Sendable {
    case malformed, scope, requestId, operation, commandId
    func apply(_ data: Data) throws -> Data {
        if self == .malformed { return Data("not-json".utf8) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        switch self {
        case .malformed: break
        case .scope:
            var scope = object["scope"] as! [String: Any]; scope["endpoint"] = "https://different.example"; object["scope"] = scope
        case .requestId: object["requestId"] = "00000000-0000-4000-8000-000000000099"
        case .operation: object["operation"] = "receipt"
        case .commandId:
            var result = object["result"] as! [String: Any]
            var value = result["value"] as! [String: Any]; value["commandId"] = "different-command"
            result["value"] = value; object["result"] = result
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private actor RelayReplyGate {
    private var reached = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var reply: CheckedContinuation<Void, Never>?
    func suspendReply() async {
        reached = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { reply = $0 }
    }
    func waitForReply() async {
        if reached { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { reply?.resume(); reply = nil }
}

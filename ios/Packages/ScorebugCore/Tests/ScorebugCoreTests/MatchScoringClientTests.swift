import Foundation
import XCTest
@testable import ScorebugCore

// Acceptance tests for the scoring-client interface only. These do not
// implement or qualify WatchConnectivity delivery, route selection, or radio use.
final class MatchScoringClientTests: XCTestCase {
    private let credential = MatchCredential(gameId: "fixture-game",
        deviceId: "00000000-0000-4000-8000-000000000014", role: .score, token: "watch-scoped-secret")
    private let serverDate = Date(timeIntervalSince1970: 1_789_347_600)
    private let scope = "watch|https://example.com|test-credential-generation"

    func testNonHTTPClientRefreshesAndSubmitsPersistedWatchCommand() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let stub = try client(store: store)
        let coordinator = coordinator(stub, store: store)

        let refreshed = try await coordinator.refresh()
        XCTAssertEqual(refreshed.snapshot?.revision, 0)
        XCTAssertEqual(refreshed.snapshot?.scorer.deviceId, credential.deviceId)
        let result = try await coordinator.submit(.awardPoint(side: .home))

        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.operation), [.snapshot, .execute])
        XCTAssertTrue(calls.allSatisfy { $0.credential == credential })
        let command = try XCTUnwrap(calls.last?.command)
        XCTAssertEqual(command.gameId, credential.gameId)
        XCTAssertEqual(command.deviceId, credential.deviceId)
        XCTAssertEqual(command.expectedRevision, 0)
        XCTAssertEqual(command.scorerEpoch, 1)
        XCTAssertEqual(command.issuedAt, clientISO(serverDate))
        XCTAssertEqual(command.operation, .awardPoint(side: .home))
        XCTAssertNotNil(UUID(uuidString: command.commandId))
        XCTAssertEqual(calls.last?.durable?.command, command, "Persistence precedes the non-HTTP send")
        XCTAssertEqual(calls.last?.durable?.endpointScope, scope)
        XCTAssertEqual(result.outcome?.commandId, command.commandId)
        XCTAssertEqual(result.outcome?.accepted, true)
        XCTAssertEqual(result.snapshot?.score.home, 1)
        XCTAssertEqual(result.status, .idle)
        XCTAssertNil(result.pending)
        XCTAssertNil(try store.load(), "Authoritative acknowledgment includes successful outbox clear")
    }

    func testLostNonHTTPReplyRecoversDurableWatchReceiptBeforeAnySnapshotOrResend() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let stub = try client(store: store)
        await stub.setMode(.loseAfterApply)
        let first = coordinator(stub, store: store)
        _ = try await first.refresh()
        do {
            _ = try await first.submit(.awardPoint(side: .home))
            XCTFail("Expected an uncertain transport outcome")
        } catch let failure as ScoringStubFailure {
            XCTAssertEqual(failure, .lostReply)
        }
        let pending = try XCTUnwrap(store.load())
        XCTAssertEqual(pending.command.deviceId, credential.deviceId)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(credential.token))
        let before = await first.state()
        XCTAssertEqual(before.pending, pending)
        XCTAssertNil(before.outcome)
        XCTAssertEqual(before.status, .pending)
        let initialCalls = await stub.calls
        XCTAssertEqual(initialCalls.last?.command, pending.command)
        XCTAssertEqual(initialCalls.last?.durable, pending)

        // A new coordinator and file-store instance stand in for Watch relaunch.
        let reopened = JSONFilePendingCommandStore(url: url)
        let second = coordinator(stub, store: reopened)
        await stub.clearCalls()
        let recovered = try await second.recover()
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.operation), [.receipt])
        XCTAssertEqual(calls.first?.receiptID, pending.command.commandId)
        XCTAssertEqual(calls.first?.credential, credential)
        XCTAssertEqual(calls.first?.durable, pending)
        XCTAssertEqual(recovered.outcome?.commandId, pending.command.commandId)
        XCTAssertEqual(recovered.outcome?.accepted, true)
        XCTAssertEqual(recovered.snapshot?.score.home, 1)
        XCTAssertEqual(recovered.status, .idle)
        XCTAssertNil(recovered.pending)
        XCTAssertNil(try reopened.load())
        let applications = await stub.applications
        XCTAssertEqual(applications, 1)
    }

    func testAbsentReceiptReplaysExactlyTheDurableWatchCommandAfterFreshSnapshot() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let stub = try client(store: store)
        await stub.setMode(.loseBeforeApply)
        let first = coordinator(stub, store: store)
        _ = try await first.refresh()
        do {
            _ = try await first.submit(.awardPoint(side: .home))
            XCTFail("Expected an uncertain transport outcome")
        } catch let failure as ScoringStubFailure {
            XCTAssertEqual(failure, .lostReply)
        }
        let pending = try XCTUnwrap(store.load())
        let originalCalls = await stub.calls
        XCTAssertEqual(originalCalls.last?.command, pending.command)
        XCTAssertEqual(originalCalls.last?.durable, pending)
        await stub.setMode(.normal)
        await stub.clearCalls()
        let second = coordinator(stub, store: JSONFilePendingCommandStore(url: url))
        let recovered = try await second.recover()

        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.operation), [.receipt, .snapshot, .execute])
        XCTAssertTrue(calls.allSatisfy { $0.credential == credential })
        XCTAssertEqual(calls.first?.receiptID, pending.command.commandId)
        XCTAssertEqual(calls.last?.command, pending.command, "No new UUID, revision, epoch, timestamp, or payload")
        XCTAssertEqual(calls.last?.durable, pending)
        XCTAssertEqual(recovered.outcome?.commandId, pending.command.commandId)
        XCTAssertEqual(recovered.outcome?.accepted, true)
        XCTAssertEqual(recovered.snapshot?.score.home, 1)
        XCTAssertNil(recovered.pending)
        XCTAssertNil(try store.load())
        let applications = await stub.applications
        XCTAssertEqual(applications, 1)
    }

    private func coordinator(_ client: any MatchScoringClient, store: any PendingCommandStore) -> MatchCommandCoordinator {
        let localDate = serverDate.addingTimeInterval(3600)
        return MatchCommandCoordinator(client: client, credential: credential, endpointScope: scope,
            store: store, now: { localDate })
    }

    private func client(store: any PendingCommandStore) throws -> NonHTTPScoringClient {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        var snapshot = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot
        snapshot.scorer.deviceId = credential.deviceId
        return NonHTTPScoringClient(snapshot: snapshot, serverTime: clientISO(serverDate), store: store)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("pending.json")
    }
}

private func clientISO(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private enum ScoringStubFailure: Error, Equatable { case lostReply }

/// Typed actor fake deliberately uses neither URLRequest nor MatchHTTPClient.
private actor NonHTTPScoringClient: MatchScoringClient {
    enum Mode { case normal, loseBeforeApply, loseAfterApply }
    enum Operation: Equatable, Sendable { case snapshot, execute, receipt }
    struct Call: Sendable {
        let operation: Operation
        let credential: MatchCredential
        let command: MatchCommand?
        let receiptID: String?
        let durable: PendingMatchCommand?
    }
    private var value: MatchSnapshot
    private let serverTime: String
    private let store: any PendingCommandStore
    private var mode: Mode = .normal
    private var outcomes: [String: CommandOutcome] = [:]
    private(set) var calls: [Call] = []
    private(set) var applications = 0

    init(snapshot: MatchSnapshot, serverTime: String, store: any PendingCommandStore) {
        value = snapshot; self.serverTime = serverTime; self.store = store
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func clearCalls() { calls = [] }

    func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse {
        calls.append(Call(operation: .snapshot, credential: credential, command: nil,
            receiptID: nil, durable: try store.load()))
        return MatchSnapshotResponse(snapshot: value, serverTime: serverTime)
    }

    func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome {
        calls.append(Call(operation: .execute, credential: credential, command: command,
            receiptID: nil, durable: try store.load()))
        if mode == .loseBeforeApply { throw ScoringStubFailure.lostReply }
        if let previous = outcomes[command.commandId] { return previous }
        value.revision += 1
        value.score.home += 1
        applications += 1
        let outcome = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: value)
        outcomes[command.commandId] = outcome
        if mode == .loseAfterApply { throw ScoringStubFailure.lostReply }
        return outcome
    }

    func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome? {
        calls.append(Call(operation: .receipt, credential: credential, command: nil,
            receiptID: commandId, durable: try store.load()))
        return outcomes[commandId]
    }
}

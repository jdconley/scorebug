import Foundation
import XCTest
@testable import ScorebugCore

final class MatchCoordinatorTests: XCTestCase {
    private let credential = MatchCredential(gameId: "fixture-game", deviceId: "fixture-phone", role: .score, token: "scoped-secret")
    private let date = Date(timeIntervalSince1970: 1_789_347_600)

    func testLostAcknowledgementRecoversFromFileWithReceiptFirstAndAppliesOnce() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingCommandStore(url: url)
        let server = try server()
        await server.setMode(.loseAfterApply)
        let first = try coordinator(server, store: store)
        _ = try await first.refresh()
        do { _ = try await first.submit(.awardPoint(side: .home)); XCTFail("Expected lost reply") } catch is URLError { }
        let pending = try XCTUnwrap(store.load())
        let bytes = try String(contentsOf: url)
        XCTAssertFalse(bytes.contains(credential.token))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertNotNil(UUID(uuidString: pending.command.commandId))
        let second = try coordinator(server, store: JSONFilePendingCommandStore(url: url))
        await server.clearRequests()
        let result = try await second.recover()
        XCTAssertNil(result.pending)
        XCTAssertTrue(result.outcome?.accepted == true)
        XCTAssertEqual(result.snapshot?.score.home, 1)
        XCTAssertNil(try store.load())
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt"])
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
    }

    func testRetryKeepsExactCommandAndUsesServerClock() async throws {
        let store = MemoryStore()
        let server = try server()
        await server.setMode(.loseBeforeApply)
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.undo); XCTFail("Expected lost reply") } catch is URLError { }
        let original = try XCTUnwrap(store.load()).command
        XCTAssertEqual(original.issuedAt, iso(date)) // Local clock is deliberately one hour ahead.
        await server.setMode(.normal)
        await server.clearRequests()
        let result = try await coordinator.recover()
        XCTAssertTrue(result.outcome?.accepted == true)
        let commands = await server.commands
        XCTAssertEqual(commands, [original, original])
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt", "snapshot", "execute"])
    }

    func testExpiredUnknownRequiresExplicitDiscardAndFreshReceiptCheck() async throws {
        let store = MemoryStore()
        let server = try server()
        await server.setMode(.loseBeforeApply)
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.awardPoint(side: .away)); XCTFail("Expected lost reply") } catch is URLError { }
        await server.advance(seconds: 11)
        let recovered = try await coordinator.recover()
        XCTAssertEqual(recovered.status, .reconciliationRequired)
        XCTAssertNotNil(recovered.pending)
        XCTAssertNil(recovered.outcome)
        await server.clearRequests()
        let discarded = try await coordinator.discardExpired()
        XCTAssertNil(discarded.pending)
        XCTAssertNil(try store.load())
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt", "snapshot", "receipt"])
    }

    func testUnexpiredUnknownCannotBeDiscarded() async throws {
        let store = MemoryStore()
        let server = try server()
        await server.setMode(.loseBeforeApply)
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.undo) } catch is URLError { }
        do { _ = try await coordinator.discardExpired(); XCTFail("Must retain uncertain request") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .notExpired) }
        XCTAssertNotNil(try store.load())
    }

    func testRevisionEpochOrScorerChangeRequiresReconciliationWithoutReplay() async throws {
        for change in ["revision", "epoch", "scorer"] {
            let store = MemoryStore()
            let server = try server()
            await server.setMode(.loseBeforeApply)
            let coordinator = try coordinator(server, store: store)
            _ = try await coordinator.refresh()
            do { _ = try await coordinator.submit(.undo) } catch is URLError { }
            await server.changeContext(change)
            let result = try await coordinator.recover()
            XCTAssertEqual(result.status, .reconciliationRequired, change)
            let commands = await server.commands
            XCTAssertEqual(commands.count, 1)
        }
    }

    func testScopeGameAndDeviceMismatchFailClosed() async throws {
        let server = try server()
        let store = MemoryStore()
        await server.setMode(.loseBeforeApply)
        let first = try coordinator(server, store: store)
        _ = try await first.refresh()
        do { _ = try await first.submit(.undo) } catch is URLError { }
        for mismatch in ["scope", "game", "device"] {
            var otherCredential = credential
            if mismatch == "game" { otherCredential.gameId = "other-game" }
            if mismatch == "device" { otherCredential.deviceId = "other-device" }
            let second = try coordinator(server, store: store, scope: mismatch == "scope" ? "other-account" : "server/account", credential: otherCredential)
            await server.clearRequests()
            do { _ = try await second.recover(); XCTFail("Must block wrong scope") }
            catch let error as MatchCoordinatorError { XCTAssertEqual(error, .scopeMismatch) }
            let requests = await server.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNotNil(try store.load())
        }
    }

    func testStorageWriteFailurePreventsSendAndClearFailurePreventsSuccess() async throws {
        let store = MemoryStore()
        let server = try server()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        store.failSave = true
        do { _ = try await coordinator.submit(.undo); XCTFail("Expected storage failure") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .storageFailure) }
        let commands = await server.commands
        XCTAssertTrue(commands.isEmpty)
        do { _ = try await coordinator.recover(); XCTFail("Retry must persist before sending") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .storageFailure) }
        let retriedCommands = await server.commands
        XCTAssertTrue(retriedCommands.isEmpty)
        store.failSave = false
        store.failClear = true
        do { _ = try await coordinator.recover(); XCTFail("Clear failure cannot acknowledge") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .storageFailure) }
        let state = await coordinator.state()
        XCTAssertNil(state.outcome)
        XCTAssertNotNil(state.pending)
        XCTAssertNotNil(try store.load())
        store.failClear = false
        let recovered = try await coordinator.recover()
        XCTAssertTrue(recovered.outcome?.accepted == true)
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
    }

    func testFailedFileClearPreservesDurableCommandForNewCoordinator() async throws {
        for failure in [JSONFilePendingCommandStore.FileOperation.permissions, .install] {
            let url = temporaryFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = JSONFilePendingCommandStore(url: url)
            let server = try server()
            await server.setMode(.loseAfterApply)
            let first = try coordinator(server, store: store)
            _ = try await first.refresh()
            do { _ = try await first.submit(.undo); XCTFail("Expected lost reply") }
            catch is URLError { }
            let pending = try XCTUnwrap(store.load())
            let failingStore = JSONFilePendingCommandStore(url: url, beforeFileOperation: { operation, stagedFile in
                // Remove only the uncommitted sibling. The real chmod/rename
                // must now fail while the committed outbox remains untouched.
                if operation == failure { try FileManager.default.removeItem(at: stagedFile) }
            })
            let failedRecovery = try coordinator(server, store: failingStore)
            do { _ = try await failedRecovery.recover(); XCTFail("Clear must report failure") }
            catch let error as MatchCoordinatorError { XCTAssertEqual(error, .storageFailure) }
            XCTAssertEqual(try store.load(), pending, "Failed clear must preserve the old file")
            let failedState = await failedRecovery.state()
            XCTAssertNil(failedState.outcome)
            let restarted = try coordinator(server, store: JSONFilePendingCommandStore(url: url))
            await server.clearRequests()
            let recovered = try await restarted.recover()
            let requests = await server.requests
            XCTAssertEqual(requests, ["receipt"])
            XCTAssertTrue(recovered.outcome?.accepted == true)
            XCTAssertNil(try store.load())
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            XCTAssertEqual(contents, [url.lastPathComponent], "Prepared temporary files must be removed")
        }
    }

    func testCorruptFileAndLoadFailureNeverSendOrReset() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        let server = try server()
        let coordinator = try coordinator(server, store: JSONFilePendingCommandStore(url: url))
        do { _ = try await coordinator.submit(.undo); XCTFail("Must fail closed") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .storageFailure) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectedEndMatchClearsPendingButRetainsErrorForUI() async throws {
        let server = try server()
        await server.setMode(.reject)
        let store = MemoryStore()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        let result = try await coordinator.submit(.endMatch(reason: "Finished"))
        XCTAssertNil(result.pending)
        XCTAssertFalse(result.outcome?.accepted ?? true)
        XCTAssertEqual(result.outcome?.error, "revision_conflict")
        XCTAssertEqual(result.snapshot?.status, .active)
        XCTAssertNil(try store.load())
    }

    func testPersistedRejectedEndMatchRecoversBeforeAnyExpiryOrTakeoverChecks() async throws {
        let server = try server()
        await server.setMode(.loseRejectedReply)
        let store = MemoryStore()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.endMatch(reason: "Finished")); XCTFail("Expected lost reply") }
        catch is URLError { }
        await server.advance(seconds: 30)
        await server.changeContext("ended")
        await server.clearRequests()
        let recovered = try await coordinator.recover()
        XCTAssertNil(recovered.pending)
        XCTAssertEqual(recovered.outcome?.error, "revision_conflict")
        XCTAssertFalse(recovered.outcome?.accepted ?? true)
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt"])
    }

    func testDiscardFindsReceiptCommittedBetweenInitialQueryAndExpiryProof() async throws {
        let server = try server()
        await server.setMode(.loseBeforeApply)
        let store = MemoryStore()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.undo) } catch is URLError { }
        await server.advance(seconds: 11)
        await server.commitOnNextSnapshot()
        let result = try await coordinator.discardExpired()
        XCTAssertNil(result.pending)
        XCTAssertTrue(result.outcome?.accepted == true)
        XCTAssertEqual(result.snapshot?.score.home, 1)
    }

    func testMalformedReceiptDoesNotAcknowledgeOrClearPending() async throws {
        let server = try server()
        await server.setMode(.loseAfterApply)
        let store = MemoryStore()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.undo) } catch is URLError { }
        await server.corruptReceiptIdentity()
        do { _ = try await coordinator.recover(); XCTFail("Wrong receipt must fail closed") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .invalidResponse) }
        XCTAssertNotNil(try store.load())
        let state = await coordinator.state()
        XCTAssertNil(state.outcome)
    }

    func testOldReceiptAfterTakeoverAndEndDoesNotRollBackNewerSnapshot() async throws {
        let server = try server()
        await server.setMode(.loseAfterApply)
        let coordinator = try coordinator(server, store: MemoryStore())
        _ = try await coordinator.refresh()
        do { _ = try await coordinator.submit(.undo) } catch is URLError { }
        await server.changeContext("ended")
        let fresh = try await coordinator.refresh()
        XCTAssertEqual(fresh.snapshot?.revision, 10)
        let recovered = try await coordinator.recover()
        XCTAssertTrue(recovered.outcome?.accepted == true)
        XCTAssertEqual(recovered.outcome?.snapshot.revision, 1)
        XCTAssertEqual(recovered.snapshot?.revision, 10)
        XCTAssertEqual(recovered.snapshot?.status, .ended)
    }

    func testOverlappingSubmissionsCannotBothSend() async throws {
        let server = try server()
        await server.setMode(.hold)
        let store = MemoryStore()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.refresh()
        let first = Task { try await coordinator.submit(.awardPoint(side: .home)) }
        await server.waitForHeldRequest()
        XCTAssertNotNil(try store.load())
        do { _ = try await coordinator.submit(.awardPoint(side: .away)); XCTFail("Second submit must be blocked") }
        catch let error as MatchCoordinatorError { XCTAssertEqual(error, .busy) }
        await server.release()
        _ = try await first.value
        let commands = await server.commands
        XCTAssertEqual(commands.count, 1)
    }

    private func coordinator(_ server: FakeMatchServer, store: any PendingCommandStore,
                             scope: String = "server/account", credential: MatchCredential? = nil) throws -> MatchCommandCoordinator {
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { request in try await server.handle(request) })
        let local = date.addingTimeInterval(3600)
        return MatchCommandCoordinator(client: client, credential: credential ?? self.credential,
                                       endpointScope: scope, store: store, now: { local })
    }

    private func server() throws -> FakeMatchServer {
        struct Fixture: Decodable { let snapshot: MatchSnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match-v1", withExtension: "json", subdirectory: "Fixtures"))
        return FakeMatchServer(snapshot: try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).snapshot, date: date)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
    }
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private final class MemoryStore: PendingCommandStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingMatchCommand?
    var failSave = false
    var failClear = false
    func load() throws -> PendingMatchCommand? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ pending: PendingMatchCommand?) throws {
        lock.lock(); defer { lock.unlock() }
        if failSave || (failClear && pending == nil) { throw CocoaError(.fileWriteNoPermission) }
        value = pending
    }
}

private actor FakeMatchServer {
    enum Mode { case normal, loseAfterApply, loseBeforeApply, reject, loseRejectedReply, hold }
    var snapshot: MatchSnapshot
    var date: Date
    var requests: [String] = []
    var commands: [MatchCommand] = []
    var applications = 0
    private var receipts: [String: CommandOutcome] = [:]
    private var mode: Mode = .normal
    private var held: CheckedContinuation<Void, Never>?
    private var holdWaiter: CheckedContinuation<Void, Never>?
    private var shouldCommitOnSnapshot = false
    init(snapshot: MatchSnapshot, date: Date) { self.snapshot = snapshot; self.date = date }
    func setMode(_ mode: Mode) { self.mode = mode }
    func clearRequests() { requests = [] }
    func commitOnNextSnapshot() { shouldCommitOnSnapshot = true }
    func corruptReceiptIdentity() {
        for id in receipts.keys { receipts[id]?.commandId = "wrong-command" }
    }
    func advance(seconds: Double) { date.addTimeInterval(seconds) }
    func changeContext(_ change: String) {
        switch change {
        case "revision": snapshot.revision += 1
        case "epoch": snapshot.scorer.epoch += 1
        case "scorer": snapshot.scorer.deviceId = "other-device"
        default: snapshot.revision = 10; snapshot.scorer = MatchScorer(deviceId: "other", epoch: 3); snapshot.status = .ended
        }
    }
    func waitForHeldRequest() async {
        if held != nil { return }
        await withCheckedContinuation { holdWaiter = $0 }
    }
    func release() { held?.resume(); held = nil }
    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-secret")
        let path = request.url!.path
        if request.httpMethod == "POST" {
            requests.append("execute")
            let command = try JSONDecoder().decode(MatchCommand.self, from: request.httpBody!)
            commands.append(command)
            if mode == .hold {
                await withCheckedContinuation { continuation in
                    held = continuation
                    holdWaiter?.resume(); holdWaiter = nil
                }
            }
            if mode == .loseBeforeApply { throw URLError(.networkConnectionLost) }
            if let receipt = receipts[command.commandId] { return try response(receipt, request: request) }
            let rejected = mode == .reject || mode == .loseRejectedReply
            if !rejected { snapshot.revision += 1; snapshot.score.home += 1; applications += 1 }
            let outcome = CommandOutcome(commandId: command.commandId, accepted: !rejected,
                                         error: rejected ? "revision_conflict" : nil, snapshot: snapshot)
            receipts[command.commandId] = outcome
            if mode == .loseAfterApply || mode == .loseRejectedReply { throw URLError(.networkConnectionLost) }
            return try response(outcome, request: request, status: rejected ? 409 : 200)
        }
        if path.contains("/commands/") {
            requests.append("receipt")
            if let receipt = receipts[request.url!.lastPathComponent] { return try response(receipt, request: request) }
            return (Data(#"{"error":"command_not_found"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        requests.append("snapshot")
        if shouldCommitOnSnapshot, let command = commands.last {
            shouldCommitOnSnapshot = false
            snapshot.revision += 1; snapshot.score.home += 1; applications += 1
            receipts[command.commandId] = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot)
        }
        return try response(MatchSnapshotResponse(snapshot: snapshot, serverTime: iso(date)), request: request)
    }
    private func response<T: Encodable>(_ value: T, request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

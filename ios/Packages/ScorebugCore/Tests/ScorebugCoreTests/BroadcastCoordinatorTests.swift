import Foundation
import XCTest
@testable import ScorebugCore

final class BroadcastCoordinatorTests: XCTestCase {
    private let credential = MatchCredential(gameId: "match", deviceId: "camera", role: .capture, token: "capture-secret")
    private let selection = BroadcastSelection(captureDeviceId: "camera", recordingId: "recording")

    func testLostReplyRecoversDurableReceiptWithoutRepeatingStart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("broadcast.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFilePendingBroadcastStore(url: url)
        let server = BroadcastServer()
        await server.setMode(.loseAfterApply)
        let first = try coordinator(server, store: store)
        do { _ = try await first.submit(.start(selection: selection), activeRecordingId: "recording"); XCTFail("Lost response") }
        catch is URLError {}
        let pending = try XCTUnwrap(store.load())
        XCTAssertNotNil(UUID(uuidString: pending.command.commandId))
        let data = try String(contentsOf: url)
        XCTAssertFalse(data.contains("secret"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let recovered = try coordinator(server, store: JSONFilePendingBroadcastStore(url: url))
        await server.clearRequests()
        let result = try await recovered.recover(activeRecordingId: nil)
        XCTAssertNil(result.pending)
        XCTAssertEqual(result.outcome?.accepted, true)
        XCTAssertEqual(result.snapshot?.broadcast.generation, 1)
        XCTAssertNil(try store.load())
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt"])
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
    }

    func testMissingReceiptNeverReplaysStartAfterLocalRecordingStopped() async throws {
        let store = BroadcastMemoryStore()
        let server = BroadcastServer()
        await server.setMode(.loseBeforeApply)
        let first = try coordinator(server, store: store)
        do { _ = try await first.submit(.start(selection: selection), activeRecordingId: "recording") } catch is URLError {}
        let original = try XCTUnwrap(store.load())
        await server.setMode(.normal)
        await server.clearRequests()
        let recovered = try coordinator(server, store: store)
        let result = try await recovered.recover(activeRecordingId: nil)
        XCTAssertEqual(result.status, .reconciliationRequired)
        XCTAssertEqual(result.pending, original)
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt", "snapshot"])
        let applications = await server.applications
        XCTAssertEqual(applications, 0)
    }

    func testRetryUsesSameDurableCommandAndFreshMatchingLocalRecording() async throws {
        let store = BroadcastMemoryStore()
        let server = BroadcastServer()
        await server.setMode(.loseBeforeApply)
        let coordinator = try coordinator(server, store: store)
        do { _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording") } catch is URLError {}
        let original = try XCTUnwrap(store.load()).command
        XCTAssertEqual(original.issuedAt, "2026-09-14T03:00:00.000Z", "Use server time despite a wrong local clock")
        await server.setMode(.normal)
        await server.clearRequests()
        let result = try await coordinator.recover(activeRecordingId: "recording")
        XCTAssertEqual(result.outcome?.accepted, true)
        let commands = await server.commands
        XCTAssertEqual(commands, [original, original])
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt", "snapshot", "execute"])
    }

    func testExpiredUnknownRequiresSecondReceiptAfterFreshServerTime() async throws {
        let store = BroadcastMemoryStore()
        let server = BroadcastServer()
        await server.setMode(.loseBeforeApply)
        let coordinator = try coordinator(server, store: store)
        do { _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording") } catch is URLError {}
        do { _ = try await coordinator.discardExpired(); XCTFail("Still possible to commit") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .notExpired) }
        await server.advance(11)
        await server.clearRequests()
        let state = try await coordinator.discardExpired()
        XCTAssertNil(state.pending)
        let requests = await server.requests
        XCTAssertEqual(requests, ["receipt", "snapshot", "receipt"])
    }

    func testCannotSubmitStartForInactiveOrAnotherDevicesRecording() async throws {
        let server = BroadcastServer()
        let coordinator = try coordinator(server, store: BroadcastMemoryStore())
        for active in [nil, "other"] as [String?] {
            do { _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: active); XCTFail("No active local recording") }
            catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .recordingNotActive) }
        }
        var other = selection
        other.captureDeviceId = "another-phone"
        do { _ = try await coordinator.submit(.start(selection: other), activeRecordingId: "recording"); XCTFail("Wrong device") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .recordingNotActive) }
        let applications = await server.applications
        XCTAssertEqual(applications, 0)
    }

    func testLocalStopDuringSnapshotReadPreventsSendingStart() async throws {
        let server = BroadcastServer()
        let gate = BroadcastGate()
        await server.gateNextSnapshot(gate)
        let store = BroadcastMemoryStore()
        let coordinator = try coordinator(server, store: store)
        let task = Task { try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording") }
        await gate.waitUntilEntered()
        do { _ = try await coordinator.refresh(); XCTFail("One network operation at a time") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .busy) }
        await coordinator.setActiveRecording(nil)
        await gate.release()
        do { _ = try await task.value; XCTFail("Recording stopped during await") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .recordingNotActive) }
        XCTAssertNil(try store.load())
        let requests = await server.requests
        XCTAssertEqual(requests, ["snapshot"])
    }

    func testStopCannotRetargetAnotherSelectionDuringRefresh() async throws {
        let server = BroadcastServer()
        let store = BroadcastMemoryStore()
        let coordinator = try coordinator(server, store: store)
        _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording")
        let gate = BroadcastGate()
        await server.gateNextSnapshot(gate)
        let task = Task { try await coordinator.submit(.stop, activeRecordingId: nil, requiredStopSelection: selection) }
        await gate.waitUntilEntered()
        var other = selection
        other.captureDeviceId = "other-phone"
        await server.replaceSelection(other)
        await gate.release()
        do { _ = try await task.value; XCTFail("Must not stop another phone") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .selectionChanged) }
        XCTAssertNil(try store.load())
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
        _ = try await coordinator.submit(.stop, activeRecordingId: nil, requiredStopSelection: other)
        let afterStop = await server.applications
        XCTAssertEqual(afterStop, 2)
    }

    func testFailedPersistenceNeverSendsUntilDurableRecoveryAndFailedClearNeverAcknowledges() async throws {
        let server = BroadcastServer()
        let store = BroadcastMemoryStore()
        store.failSave = true
        let coordinator = try coordinator(server, store: store)
        do { _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording"); XCTFail("Storage failed") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .storageFailure) }
        let failed = await coordinator.state()
        XCTAssertNotNil(failed.pending)
        var commands = await server.commands
        XCTAssertTrue(commands.isEmpty)
        store.failSave = false
        store.failClear = true
        do { _ = try await coordinator.recover(activeRecordingId: "recording"); XCTFail("Clear failed") }
        catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .storageFailure) }
        let unclear = await coordinator.state()
        XCTAssertEqual(unclear.pending, failed.pending)
        XCTAssertNil(unclear.outcome)
        XCTAssertNotNil(try store.load())
        store.failClear = false
        let acknowledged = try await coordinator.recover(activeRecordingId: nil)
        XCTAssertNil(acknowledged.pending)
        XCTAssertEqual(acknowledged.outcome?.accepted, true)
        commands = await server.commands
        XCTAssertEqual(commands.count, 1)
    }

    func testScopeAndDeviceMismatchBlockAllNetworkUse() async throws {
        let server = BroadcastServer()
        let store = BroadcastMemoryStore()
        await server.setMode(.loseBeforeApply)
        let original = try coordinator(server, store: store)
        do { _ = try await original.submit(.start(selection: selection), activeRecordingId: "recording") } catch is URLError {}
        await server.clearRequests()
        for (scope, deviceId) in [("different-account", "camera"), ("endpoint|account", "another-camera")] {
            let next = try coordinator(server, store: store, scope: scope, deviceId: deviceId)
            do { _ = try await next.recover(activeRecordingId: "recording"); XCTFail("Wrong scope") }
            catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .scopeMismatch) }
        }
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testChangedGenerationPreventsReplayAndMalformedReceiptPreservesUncertainty() async throws {
        for applied in [false, true] {
            let server = BroadcastServer()
            let store = BroadcastMemoryStore()
            await server.setMode(applied ? .loseAfterApply : .loseBeforeApply)
            let coordinator = try coordinator(server, store: store)
            do { _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording") } catch is URLError {}
            let original = try XCTUnwrap(store.load())
            await server.changeGeneration()
            await server.setMode(.badReceipt)
            if applied {
                do { _ = try await coordinator.recover(activeRecordingId: "recording"); XCTFail("Wrong receipt") }
                catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .invalidResponse) }
            } else {
                let state = try await coordinator.recover(activeRecordingId: "recording")
                XCTAssertEqual(state.status, .reconciliationRequired)
            }
            XCTAssertEqual(try store.load(), original)
            let commands = await server.commands
            XCTAssertEqual(commands.count, 1)
        }
    }

    func testStopCanRecoverWithoutActiveRecordingAndRejectedCommandsAreAcknowledged() async throws {
        let server = BroadcastServer()
        let store = BroadcastMemoryStore()
        let coordinator = try coordinator(server, store: store)
        await server.setMode(.loseBeforeApply)
        do { _ = try await coordinator.submit(.stop, activeRecordingId: nil) } catch is URLError {}
        await server.setMode(.normal)
        let stopped = try await coordinator.recover(activeRecordingId: nil)
        XCTAssertEqual(stopped.outcome?.accepted, true)
        XCTAssertNil(stopped.pending)
        await server.setMode(.reject)
        let rejected = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording")
        XCTAssertEqual(rejected.outcome?.accepted, false)
        XCTAssertNil(rejected.pending)
        XCTAssertNil(try store.load())
    }

    func testContradictoryMatchingReceiptCannotClearDurableUncertainty() async throws {
        for corruption in ["acceptedError", "rejectedNoError", "generation", "desired", "selection"] {
            let server = BroadcastServer()
            let store = BroadcastMemoryStore()
            await server.setMode(.loseAfterApply)
            let coordinator = try coordinator(server, store: store)
            do { _ = try await coordinator.submit(.start(selection: selection), activeRecordingId: "recording") } catch is URLError {}
            let original = try XCTUnwrap(store.load())
            await server.corruptReceipt(corruption)
            do { _ = try await coordinator.recover(activeRecordingId: "recording"); XCTFail("Invalid receipt: \(corruption)") }
            catch let error as BroadcastCoordinatorError { XCTAssertEqual(error, .invalidResponse) }
            XCTAssertEqual(try store.load(), original)
        }
    }

    func testAtomicFileStorePreservesCommittedUncertaintyOnFailedClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broadcast.json")
        let pending = PendingBroadcastCommand(endpointScope: "endpoint|account",
            command: .init(commandId: "one", gameId: "match", expectedGeneration: 0, issuedAt: "2026-09-14T03:00:00Z", operation: .stop),
            captureDeviceId: "camera")
        let store = JSONFilePendingBroadcastStore(url: url)
        try store.save(pending)
        for failingOperation in [JSONFilePendingBroadcastStore.FileOperation.permissions, .install] {
            let failed = JSONFilePendingBroadcastStore(url: url, beforeFileOperation: { operation, _ in
                if operation == failingOperation { throw CocoaError(.fileWriteUnknown) }
            })
            XCTAssertThrowsError(try failed.save(nil))
            XCTAssertEqual(try store.load(), pending)
        }
        try store.save(nil)
        XCTAssertNil(try store.load())
        try Data("broken json".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }

    private func coordinator(_ server: BroadcastServer, store: any PendingBroadcastStore,
                             scope: String = "endpoint|account", deviceId: String = "camera") throws -> BroadcastCommandCoordinator {
        let credential = MatchCredential(gameId: "match", deviceId: deviceId, role: .capture, token: "capture-secret")
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { try await server.respond($0) }).team("t1")
        return BroadcastCommandCoordinator(client: client, credential: credential, sessionToken: "session-secret",
                                           endpointScope: scope, store: store,
                                           now: { Date(timeIntervalSince1970: 1_789_361_200) })
    }
}

private final class BroadcastMemoryStore: PendingBroadcastStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingBroadcastCommand?
    private var failsSave = false
    private var failsClear = false
    var failSave: Bool { get { lock.withLock { failsSave } } set { lock.withLock { failsSave = newValue } } }
    var failClear: Bool { get { lock.withLock { failsClear } } set { lock.withLock { failsClear = newValue } } }
    func load() throws -> PendingBroadcastCommand? { lock.withLock { value } }
    func save(_ pending: PendingBroadcastCommand?) throws {
        try lock.withLock {
            if failsSave || (failsClear && pending == nil) { throw CocoaError(.fileWriteUnknown) }
            value = pending
        }
    }
}

private actor BroadcastServer {
    enum Mode { case normal, loseBeforeApply, loseAfterApply, reject, badReceipt }
    var mode = Mode.normal
    var requests: [String] = []
    var commands: [BroadcastCommand] = []
    var applications = 0
    private var time = Date(timeIntervalSince1970: 1_789_354_800)
    private var snapshot = MediaSnapshot(gameId: "match", recordings: [], broadcast: .init(desired: .stopped, generation: 0, selection: nil))
    private var receipt: BroadcastOutcome?
    private var snapshotGate: BroadcastGate?
    func gateNextSnapshot(_ gate: BroadcastGate) { snapshotGate = gate }
    func setMode(_ mode: Mode) { self.mode = mode }
    func clearRequests() { requests = [] }
    func advance(_ seconds: TimeInterval) { time = time.addingTimeInterval(seconds) }
    func replaceSelection(_ selection: BroadcastSelection) { snapshot.broadcast.selection = selection; snapshot.broadcast.generation += 1 }
    func changeGeneration() { snapshot.broadcast.generation += 1 }
    func corruptReceipt(_ corruption: String) {
        switch corruption {
        case "acceptedError": receipt?.error = "some-error"
        case "rejectedNoError": receipt?.accepted = false
        case "generation": receipt?.snapshot.broadcast.generation += 1
        case "desired": receipt?.snapshot.broadcast.desired = .stopped
        case "selection": receipt?.snapshot.broadcast.selection?.recordingId = "other"
        default: break
        }
    }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        if request.httpMethod == "POST" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-secret")
            requests.append("execute")
            let command = try JSONDecoder().decode(BroadcastCommand.self, from: request.httpBody!)
            commands.append(command)
            if mode == .loseBeforeApply { throw URLError(.timedOut) }
            if mode != .reject {
                applications += 1
                snapshot.broadcast.generation += 1
                switch command.operation {
                case .start(let selection):
                    snapshot.broadcast.desired = .running; snapshot.broadcast.selection = selection
                case .stop: snapshot.broadcast.desired = .stopped; snapshot.broadcast.selection = nil
                }
            }
            receipt = BroadcastOutcome(commandId: command.commandId, accepted: mode != .reject,
                                       error: mode == .reject ? "stale_generation" : nil, snapshot: snapshot)
            if mode == .loseAfterApply { throw URLError(.timedOut) }
            return try response(receipt!, request, status: mode == .reject ? 409 : 200)
        }
        if path.contains("/commands/") {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-secret")
            requests.append("receipt")
            if var receipt {
                if mode == .badReceipt { receipt.commandId = "wrong" }
                return try response(receipt, request)
            }
            return try response(["error": "command_not_found"], request, status: 404)
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capture-secret")
        requests.append("snapshot")
        if let gate = snapshotGate { snapshotGate = nil; await gate.wait() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try response(MediaSnapshotResponse(snapshot: snapshot, serverTime: formatter.string(from: time)), request)
    }
    private func response<T: Encodable>(_ body: T, _ request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONEncoder().encode(body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor BroadcastGate {
    private var entered = false
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered, "Expected the request to enter its gate")
    }
}

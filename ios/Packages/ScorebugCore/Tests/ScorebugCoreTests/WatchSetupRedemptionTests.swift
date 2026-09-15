import Foundation
import XCTest
@testable import ScorebugCore

final class WatchSetupRedemptionTests: XCTestCase {
    private typealias F = WatchPairingClientTests

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }
    private func owner(_ store: RedemptionFileStore, server: InjectedRedemptionServer,
                       freshIDs: Bool = false) -> WatchSetupCoordinator {
        WatchSetupCoordinator(storage: store,
            scoringOutbox: JSONFilePendingCommandStore(url: store.url.deletingLastPathComponent().appendingPathComponent("outbox.json")),
            clientFactory: { endpoint in
                XCTFail("An injected redemption must not construct the default HTTP client")
                return MatchHTTPClient(endpoint: endpoint, transport: { _ in throw RedemptionTestError.unexpectedHTTP })
            }, redemption: { try await server.redeem($0) },
            newDeviceId: { freshIDs ? UUID().uuidString : F.deviceId },
            newRedemptionId: { freshIDs ? UUID().uuidString : F.redemptionId },
            newRecoveryKey: { freshIDs ? String(repeating: "B", count: 42) + "A" : F.secret })
    }

    func testInjectedOperationObservesExactPendingOnDiskBeforeInvocation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RedemptionFileStore(url: root.appendingPathComponent("setup.json"))
        let response = try F.response()
        let server = InjectedRedemptionServer(store: store, response: response)
        let result = try await owner(store, server: server).accept(endpoint: "https://EXAMPLE.com:443/control/", offer: F.offer)
        let calls = await server.calls
        XCTAssertEqual(calls, [PendingWatchPairing(endpoint: "https://example.com/control", offer: F.offer,
            request: WatchPairingRedeemRequest(redemptionId: F.redemptionId, deviceId: F.deviceId), recoveryKey: F.secret)])
        let disk = try RedemptionFileStore(url: store.url).load()
        XCTAssertEqual(disk, result.record)
        XCTAssertNil(disk?.pending)
        XCTAssertEqual(disk?.paired?.credential, response.credential)
        XCTAssertEqual(result.snapshot, response.snapshot)
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
    }

    func testLostCommittedReplyRecoversExactDurableIdentityAfterRelaunchAndExpiry() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RedemptionFileStore(url: root.appendingPathComponent("setup.json"))
        let original = try F.response()
        // The recovered reply can arrive after the original capability expires.
        let response = WatchPairingRedeemed(pairingId: original.pairingId, redemptionId: original.redemptionId,
            credential: original.credential, snapshot: original.snapshot, serverTime: "2026-09-14T12:00:00.000Z")
        let server = InjectedRedemptionServer(store: store, response: response, loseFirstReply: true)
        do {
            _ = try await owner(store, server: server).accept(endpoint: "https://example.com/control", offer: F.offer)
            XCTFail("Expected a lost committed reply")
        } catch { XCTAssertEqual(error as? URLError, URLError(.networkConnectionLost)) }
        let pending = try XCTUnwrap(RedemptionFileStore(url: store.url).load()?.pending)
        XCTAssertNil(try store.load()?.paired)
        let relaunched = owner(RedemptionFileStore(url: store.url), server: server, freshIDs: true)
        let recovered = try await relaunched.recover()
        let calls = await server.calls
        XCTAssertEqual(calls, [pending, pending], "Recovery must reuse endpoint, capability, request ID, device, and key byte-for-byte")
        let applications = await server.applications
        XCTAssertEqual(applications, 1)
        XCTAssertEqual(recovered.record?.paired?.credential, original.credential)
        XCTAssertEqual(recovered.record?.paired?.redemptionId, pending.request.redemptionId)
        XCTAssertNil(try store.load()?.pending)
        XCTAssertEqual(try store.load(), recovered.record)
    }

    func testFailedFinalSaveKeepsPendingOnDiskAndRecoveryReusesCommittedRedemption() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RedemptionFileStore(url: root.appendingPathComponent("setup.json"), rejectPaired: true)
        let server = InjectedRedemptionServer(store: store, response: try F.response())
        let initial = owner(store, server: server)
        do {
            _ = try await initial.accept(endpoint: "https://example.com/control", offer: F.offer)
            XCTFail("Expected final storage failure")
        } catch { XCTAssertEqual(error as? WatchSetupError, .storageFailure) }
        let disk = try XCTUnwrap(RedemptionFileStore(url: store.url).load())
        let pending = try XCTUnwrap(disk.pending)
        XCTAssertNil(disk.paired)
        let state = await initial.state()
        XCTAssertEqual(state.record, disk)
        XCTAssertNil(state.snapshot)
        let recovered = try await owner(RedemptionFileStore(url: store.url), server: server, freshIDs: true).recover()
        let calls = await server.calls, applications = await server.applications
        XCTAssertEqual(calls, [pending, pending])
        XCTAssertEqual(applications, 1)
        XCTAssertNil(recovered.record?.pending)
        XCTAssertEqual(recovered.record?.paired?.credential, try F.response().credential)
        XCTAssertEqual(try store.load(), recovered.record)
    }

    func testPendingSaveFailurePreventsInjectedOperation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RedemptionFileStore(url: root.appendingPathComponent("setup.json"), rejectPending: true)
        let server = InjectedRedemptionServer(store: store, response: try F.response())
        do {
            _ = try await owner(store, server: server).accept(endpoint: "https://example.com/control", offer: F.offer)
            XCTFail("Expected pending storage failure")
        } catch { XCTAssertEqual(error as? WatchSetupError, .storageFailure) }
        let calls = await server.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try store.load(), WatchSetupRecord(deviceId: F.deviceId))
    }

    func testInjectedInvalidAuthorityStillCannotCommitPairedState() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RedemptionFileStore(url: root.appendingPathComponent("setup.json"))
        let server = InjectedRedemptionServer(store: store, response: try F.response(role: .capture))
        do {
            _ = try await owner(store, server: server).accept(endpoint: "https://example.com/control", offer: F.offer)
            XCTFail("Injected response must still pass coordinator validation")
        } catch { XCTAssertEqual(error as? WatchSetupError, .invalidResponse) }
        XCTAssertNotNil(try store.load()?.pending)
        XCTAssertNil(try store.load()?.paired)
    }

    func testCancellationOfInjectedAwaitedReplyRetainsPendingAndSuppressesPairedCommit() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RedemptionFileStore(url: root.appendingPathComponent("setup.json"))
        let server = InjectedRedemptionServer(store: store, response: try F.response(), pauseFirstReply: true)
        let initial = owner(store, server: server)
        let attempt = Task { try await initial.accept(endpoint: "https://example.com/control", offer: F.offer) }
        await server.waitForFirstCall()
        let pending = try XCTUnwrap(store.load())
        do { _ = try await initial.recover(); XCTFail("Awaited injection must retain busy ownership") }
        catch { XCTAssertEqual(error as? WatchSetupError, .busy) }
        attempt.cancel()
        await server.releaseReply()
        do { _ = try await attempt.value; XCTFail("Cancelled operation must not publish a late credential") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try store.load(), pending)
        let state = await initial.state()
        XCTAssertNil(state.record?.paired)
        XCTAssertNil(state.snapshot)
        let recovered = try await owner(RedemptionFileStore(url: store.url), server: server, freshIDs: true).recover()
        XCTAssertNotNil(recovered.record?.paired)
        let calls = await server.calls, applications = await server.applications
        XCTAssertEqual(calls, [try XCTUnwrap(pending.pending), try XCTUnwrap(pending.pending)])
        XCTAssertEqual(applications, 1)
    }
}

private enum RedemptionTestError: Error { case unexpectedHTTP, storage, missingDurablePending, changedIdentity }

/// Test-only atomic file storage: reopening reads committed bytes from disk.
/// Native production storage remains device Keychain; no secret storage policy changes.
private struct RedemptionFileStore: WatchSetupStorage {
    let url: URL
    var rejectPending = false
    var rejectPaired = false
    func load() throws -> WatchSetupRecord? {
        do { return try JSONDecoder().decode(WatchSetupRecord.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ record: WatchSetupRecord) throws {
        if rejectPending && record.pending != nil || rejectPaired && record.paired != nil { throw RedemptionTestError.storage }
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}

private actor InjectedRedemptionServer {
    let store: RedemptionFileStore
    let response: WatchPairingRedeemed
    let loseFirstReply: Bool
    let pauseFirstReply: Bool
    private var committed: PendingWatchPairing?
    private var firstCallWaiter: CheckedContinuation<Void, Never>?
    private var replyWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [PendingWatchPairing] = []
    private(set) var applications = 0
    init(store: RedemptionFileStore, response: WatchPairingRedeemed,
         loseFirstReply: Bool = false, pauseFirstReply: Bool = false) {
        self.store = store; self.response = response; self.loseFirstReply = loseFirstReply
        self.pauseFirstReply = pauseFirstReply
    }
    func waitForFirstCall() async {
        if calls.isEmpty { await withCheckedContinuation { firstCallWaiter = $0 } }
    }
    func releaseReply() { replyWaiter?.resume(); replyWaiter = nil }
    func redeem(_ pending: PendingWatchPairing) async throws -> WatchPairingRedeemed {
        // This independently opens the persisted file before applying anything.
        let disk = try RedemptionFileStore(url: store.url).load()
        guard disk?.pending == pending, disk?.paired == nil else { throw RedemptionTestError.missingDurablePending }
        calls.append(pending)
        if let committed {
            guard committed == pending else { throw RedemptionTestError.changedIdentity }
        } else { committed = pending; applications += 1 }
        firstCallWaiter?.resume(); firstCallWaiter = nil
        if calls.count == 1 {
            if pauseFirstReply { await withCheckedContinuation { replyWaiter = $0 } }
            if loseFirstReply { throw URLError(.networkConnectionLost) }
        }
        return response
    }
}

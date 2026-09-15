import Foundation
import XCTest
@testable import ScorebugCore

final class WatchBootstrapCodecTests: XCTestCase {
    func testSharedFixtureRoundTripsWithDistinctBootstrapDiscriminators() throws {
        let f = try BootstrapFixture()
        let request = f.request()
        let encoded = try WatchBootstrapCodec.encodeRequest(request)
        XCTAssertEqual(try WatchBootstrapCodec.decodeRequest(encoded), request)
        XCTAssertEqual(request.type, "watch_bootstrap_request")
        XCTAssertThrowsError(try WatchRelayCodec.decodeRequest(encoded))
        let reply = WatchBootstrapReply(request: request, result: .redeemed(f.redeemed))
        XCTAssertEqual(reply.type, "watch_bootstrap_reply")
        XCTAssertEqual(try WatchBootstrapCodec.decodeReply(WatchBootstrapCodec.encodeReply(reply, for: request), for: request), reply)
        let wire = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(wire.contains("installation")); XCTAssertFalse(wire.contains("expiresAt"))
        XCTAssertFalse(String(decoding: try WatchBootstrapCodec.encodeReply(reply, for: request), as: UTF8.self).contains(f.pending.recoveryKey))
    }

    func testAuthorityRequiresCanonicalEndpointScopeAndCanonicalCapability() throws {
        let f = try BootstrapFixture(), good = f.request().authority
        try WatchBootstrapCodec.validateAuthority(good)
        for token in ["", String(repeating: "A", count: 42), String(repeating: "A", count: 42) + "B", String(repeating: "+", count: 43)] {
            XCTAssertThrowsError(try WatchBootstrapCodec.validateAuthority(WatchBootstrapAuthority(scope: good.scope, pairingToken: token)))
        }
        for scope in [
            WatchRelayScope(endpoint: "https://example.com/control/", gameId: good.scope.gameId, watchDeviceId: good.scope.watchDeviceId, pairingId: good.scope.pairingId),
            WatchRelayScope(endpoint: good.scope.endpoint, gameId: "../wrong", watchDeviceId: good.scope.watchDeviceId, pairingId: good.scope.pairingId),
            WatchRelayScope(endpoint: good.scope.endpoint, gameId: good.scope.gameId, watchDeviceId: "watch", pairingId: good.scope.pairingId),
            WatchRelayScope(endpoint: good.scope.endpoint, gameId: good.scope.gameId, watchDeviceId: good.scope.watchDeviceId, pairingId: "pairing"),
        ] { XCTAssertThrowsError(try WatchBootstrapCodec.validateAuthority(WatchBootstrapAuthority(scope: scope, pairingToken: good.pairingToken))) }
    }

    func testRequestsRejectUnknownDuplicateMalformedDeepOversizedAndMismatchedFields() throws {
        let f = try BootstrapFixture(), request = f.request()
        let data = try WatchBootstrapCodec.encodeRequest(request)
        let mutations: [([String], Any)] = [
            (["version"], true), (["version"], 2), (["type"], "snapshot"), (["requestId"], "bad"),
            (["unexpected"], "secret"), (["authority", "installationToken"], "secret"),
            (["authority", "scope", "unknown"], 1), (["redemption", "unexpected"], 1),
            (["redemption", "deviceId"], UUID().uuidString), (["redemption", "redemptionId"], "bad"),
            (["recoveryKey"], String(repeating: "A", count: 42) + "B"), (["recoveryKey"], NSNull()),
        ]
        for (path, value) in mutations {
            XCTAssertThrowsError(try WatchBootstrapCodec.decodeRequest(bootstrapMutate(data, path, value)), "\(path)")
        }
        let duplicate = Data(("{\"version\":1," + String(decoding: data, as: UTF8.self).dropFirst()).utf8)
        let escapedDuplicate = Data(("{\"ver\\u0073ion\":1," + String(decoding: data, as: UTF8.self).dropFirst()).utf8)
        for malformed in [Data(), Data("[]".utf8), duplicate, escapedDuplicate,
            Data(String(repeating: "[", count: 12).appending(String(repeating: "]", count: 12)).utf8),
            Data(repeating: 32, count: WatchBootstrapCodec.maximumRequestBytes + 1),
            Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0").utf8)] {
            XCTAssertThrowsError(try WatchBootstrapCodec.decodeRequest(malformed))
        }
        XCTAssertThrowsError(try WatchBootstrapCodec.encodeRequest(WatchBootstrapRequest(requestId: "bad", authority: request.authority,
            redemption: request.redemption, recoveryKey: request.recoveryKey)))
    }

    func testReplyRequiresEveryScopeAndRedemptionIdentityAndStrictCredential() throws {
        let f = try BootstrapFixture(), request = f.request()
        let data = try WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: .redeemed(f.redeemed)), for: request)
        let mutations: [([String], Any)] = [
            (["type"], "watch_bootstrap_request"), (["requestId"], UUID().uuidString), (["redemptionId"], UUID().uuidString),
            (["scope", "endpoint"], "https://other.example"), (["scope", "gameId"], "other-game"),
            (["scope", "watchDeviceId"], UUID().uuidString), (["scope", "pairingId"], UUID().uuidString),
            (["result", "type"], "receipt_absent"), (["result", "value", "pairingId"], UUID().uuidString),
            (["result", "value", "redemptionId"], UUID().uuidString), (["result", "value", "serverTime"], "2026-02-30T00:00:00Z"),
            (["result", "value", "credential", "deviceId"], UUID().uuidString), (["result", "value", "credential", "gameId"], "other-game"),
            (["result", "value", "credential", "role"], "capture"), (["result", "value", "credential", "token"], "secret"),
            (["result", "value", "credential", "token"], String(repeating: "A", count: 42) + "B"),
            (["result", "value", "snapshot", "id"], "other-game"), (["result", "value", "extra"], 1),
            (["result", "value", "snapshot", "revision"], 9_007_199_254_740_992 as Int64),
            (["result", "value", "snapshot", "score", "home"], -1),
            (["result", "value", "snapshot", "teams", "home", "name"], String(repeating: "😀", count: 41)),
        ]
        for (path, value) in mutations {
            XCTAssertThrowsError(try WatchBootstrapCodec.decodeReply(bootstrapMutate(data, path, value), for: request), "\(path)")
        }
        XCTAssertThrowsError(try WatchBootstrapCodec.decodeReply(Data(repeating: 32, count: WatchBootstrapCodec.maximumReplyBytes + 1), for: request))
        let duplicate = Data(("{\"type\":\"watch_bootstrap_reply\"," + String(decoding: data, as: UTF8.self).dropFirst()).utf8)
        XCTAssertThrowsError(try WatchBootstrapCodec.decodeReply(duplicate, for: request))
    }

    func testMaximalEscapedFiveSetSnapshotFitsReplyBudgetWithoutArtificialScoreCap() throws {
        let f = try BootstrapFixture(), request = f.request()
        var snapshot = f.redeemed.snapshot
        let reason = String(repeating: "\u{0001}", count: 500)
        snapshot.rules.bestOf = 5
        snapshot.score = MatchScore(home: 500, away: 498, set: 5, homeSets: 3, awaySets: 2)
        snapshot.status = .ended; snapshot.endReason = reason
        snapshot.completedSets = (1...5).map { index in
            MatchSetResult(set: index, home: index.isMultiple(of: 2) ? 498 : 500, away: index.isMultiple(of: 2) ? 500 : 498,
                winner: index.isMultiple(of: 2) ? .away : .home, overrideReason: reason)
        }
        snapshot.teams.home.name = String(repeating: "\u{0001}", count: 80)
        snapshot.teams.away.name = String(repeating: "😀", count: 40)
        snapshot.teams.home.shortName = String(repeating: "\u{0001}", count: 8)
        let response = WatchPairingRedeemed(pairingId: f.redeemed.pairingId, redemptionId: f.redeemed.redemptionId,
            credential: f.redeemed.credential, snapshot: snapshot, serverTime: "2026-09-15T00:00:00Z")
        let reply = WatchBootstrapReply(request: request, result: .redeemed(response))
        let bytes = try WatchBootstrapCodec.encodeReply(reply, for: request)
        XCTAssertLessThan(bytes.count, WatchBootstrapCodec.maximumReplyBytes)
        XCTAssertEqual(try WatchBootstrapCodec.decodeReply(bytes, for: request), reply)
        snapshot.completedSets.append(snapshot.completedSets[0])
        let invalid = WatchPairingRedeemed(pairingId: response.pairingId, redemptionId: response.redemptionId,
            credential: response.credential, snapshot: snapshot, serverTime: response.serverTime)
        XCTAssertThrowsError(try WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: .redeemed(invalid)), for: request))
    }

    func testSanitizedFailuresRetainHTTPExpiryAndRejectRawErrorMetadata() throws {
        let request = try BootstrapFixture().request()
        for failure in [WatchRelayFailure.unauthorized, .forbidden, .cancelled, .unavailable, .scopeMismatch, .busy, .invalidRequest, .invalidResponse,
                        .http(status: 409, code: "pairing_expired"), .http(status: 503, code: nil)] {
            let reply = WatchBootstrapReply(request: request, result: .failure(failure))
            XCTAssertEqual(try WatchBootstrapCodec.decodeReply(WatchBootstrapCodec.encodeReply(reply, for: request), for: request), reply)
        }
        for failure in [WatchRelayFailure.http(status: 600, code: nil), .http(status: 403, code: "private raw body\n")] {
            XCTAssertThrowsError(try WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: .failure(failure)), for: request))
        }
    }
}

final class WatchBootstrapRelayClientTests: XCTestCase {
    func testTypedClientKeepsPendingPayloadExactAndUsesFreshTransportIdentity() async throws {
        let f = try BootstrapFixture(), phone = BootstrapPhone(response: try BootstrapFixture().redeemed)
        let client = WatchBootstrapRelayClient(send: { try await phone.send($0) })
        let first = try await client.redeem(f.pending), second = try await client.redeem(f.pending)
        XCTAssertEqual(first, f.redeemed); XCTAssertEqual(second, first)
        let calls = await phone.calls
        XCTAssertEqual(calls.count, 2); XCTAssertNotEqual(calls[0].requestId, calls[1].requestId)
        XCTAssertEqual(calls.map(\.redemption), [f.pending.request, f.pending.request])
        XCTAssertEqual(calls.map(\.recoveryKey), [f.pending.recoveryKey, f.pending.recoveryKey])
        XCTAssertEqual(calls.map(\.authority.pairingToken), [f.pending.offer.pairingToken, f.pending.offer.pairingToken])
    }

    func testFailureMappingAndMalformedRepliesNeverBecomeSuccessfulRedemptions() async throws {
        let f = try BootstrapFixture()
        for failure in [WatchRelayFailure.unauthorized, .forbidden, .invalidResponse, .http(status: 409, code: "pairing_expired"), .cancelled, .unavailable] {
            let client = WatchBootstrapRelayClient(send: { bytes in
                let request = try WatchBootstrapCodec.decodeRequest(bytes)
                return try WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: .failure(failure)), for: request)
            })
            do { _ = try await client.redeem(f.pending); XCTFail("Expected typed failure") }
            catch {
                switch failure {
                case .unauthorized: XCTAssertEqual(error as? MatchClientError, .unauthorized)
                case .forbidden: XCTAssertEqual(error as? MatchClientError, .forbidden)
                case .invalidResponse: XCTAssertEqual(error as? MatchClientError, .invalidResponse)
                case .http(let status, let code): XCTAssertEqual(error as? MatchClientError, .http(status: status, code: code))
                default: XCTAssertEqual(error as? WatchRelayFailure, failure)
                }
            }
        }
        let malformed = WatchBootstrapRelayClient(send: { _ in Data("{}".utf8) })
        do { _ = try await malformed.redeem(f.pending); XCTFail("Malformed reply") }
        catch { XCTAssertEqual(error as? WatchRelayCodecError, .invalidMessage) }
        let crossRequest = WatchBootstrapRelayClient(send: { _ in
            let another = f.request()
            return try WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: another, result: .redeemed(f.redeemed)), for: another)
        })
        do { _ = try await crossRequest.redeem(f.pending); XCTFail("Uncorrelated reply") }
        catch { XCTAssertEqual(error as? WatchRelayCodecError, .invalidMessage) }
    }

    func testRealCoordinatorRecoversCommittedLostReplyWithExactFilePendingAndNoClientRetry() async throws {
        let f = try BootstrapFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BootstrapFileStore(url: root.appendingPathComponent("setup.json"))
        let outbox = JSONFilePendingCommandStore(url: root.appendingPathComponent("outbox.json"))
        let phone = BootstrapPhone(response: f.redeemed, store: store, loseFirst: true)
        let client = WatchBootstrapRelayClient(send: { try await phone.send($0) })
        let owner = WatchSetupCoordinator(storage: store, scoringOutbox: outbox, redemption: { try await client.redeem($0) },
            newDeviceId: { f.pending.request.deviceId }, newRedemptionId: { f.pending.request.redemptionId }, newRecoveryKey: { f.pending.recoveryKey })
        do { _ = try await owner.accept(endpoint: f.pending.endpoint, offer: f.pending.offer); XCTFail("Lost reply must remain uncertain") }
        catch { XCTAssertEqual(error as? URLError, URLError(.networkConnectionLost)) }
        let firstCalls = await phone.calls; XCTAssertEqual(firstCalls.count, 1, "Client must not retry")
        XCTAssertEqual(try store.load()?.pending, f.pending)
        let relaunched = WatchSetupCoordinator(storage: BootstrapFileStore(url: store.url), scoringOutbox: outbox,
            redemption: { try await client.redeem($0) })
        let recovered = try await relaunched.recover()
        XCTAssertEqual(recovered.record?.paired?.credential, f.redeemed.credential)
        XCTAssertNil(try store.load()?.pending)
        let calls = await phone.calls, applications = await phone.applications
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(applications, 1)
        XCTAssertEqual(calls[0].authority, calls[1].authority)
        XCTAssertEqual(calls[0].redemption, calls[1].redemption)
        XCTAssertEqual(calls[0].recoveryKey, calls[1].recoveryKey)
    }

    func testCancellationBeforeDispatchAndAfterAwaitCannotPublishLateCredential() async throws {
        let f = try BootstrapFixture()
        let never = WatchBootstrapRelayClient(send: { _ in XCTFail("Cancelled client dispatched"); return Data() })
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await never.redeem(f.pending)
        }
        do { _ = try await before.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let phone = BootstrapPhone(response: f.redeemed, pause: true)
        let client = WatchBootstrapRelayClient(send: { try await phone.send($0) })
        let after = Task { try await client.redeem(f.pending) }
        await phone.waitForCall()
        after.cancel(); await phone.release()
        do { _ = try await after.value; XCTFail("Late reply acknowledged") } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await phone.calls; XCTAssertEqual(calls.count, 1)
    }
}

private struct BootstrapFixture: Sendable {
    let issued: WatchPairingIssued
    let redeemed: WatchPairingRedeemed
    init() throws {
        struct Fixture: Decodable { let issued: WatchPairingIssued; let redeemed: WatchPairingRedeemed }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "watch-pairing-v1", withExtension: "json", subdirectory: "Fixtures"))
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        issued = value.issued; redeemed = value.redeemed
    }
    var pending: PendingWatchPairing {
        PendingWatchPairing(endpoint: "https://example.com/control", offer: issued,
            request: WatchPairingRedeemRequest(redemptionId: redeemed.redemptionId, deviceId: issued.watchDeviceId),
            recoveryKey: String(repeating: "A", count: 43))
    }
    func request() -> WatchBootstrapRequest {
        WatchBootstrapRequest(requestId: UUID().uuidString, authority: WatchBootstrapAuthority(
            scope: WatchRelayScope(endpoint: pending.endpoint, gameId: issued.gameId, watchDeviceId: issued.watchDeviceId, pairingId: issued.pairingId),
            pairingToken: issued.pairingToken), redemption: pending.request, recoveryKey: pending.recoveryKey)
    }
}

private func bootstrapMutate(_ data: Data, _ path: [String], _ replacement: Any) throws -> Data {
    func set(_ object: [String: Any], path: ArraySlice<String>) -> [String: Any] {
        var object = object
        if path.count == 1 { object[path.first!] = replacement }
        else { object[path.first!] = set(object[path.first!] as! [String: Any], path: path.dropFirst()) }
        return object
    }
    return try JSONSerialization.data(withJSONObject: set(JSONSerialization.jsonObject(with: data) as! [String: Any], path: path[...]), options: [.sortedKeys])
}
private struct BootstrapFileStore: WatchSetupStorage {
    let url: URL
    func load() throws -> WatchSetupRecord? {
        do { return try JSONDecoder().decode(WatchSetupRecord.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ record: WatchSetupRecord) throws { try JSONEncoder().encode(record).write(to: url, options: .atomic) }
}
private actor BootstrapPhone {
    let response: WatchPairingRedeemed
    let store: BootstrapFileStore?
    let loseFirst: Bool
    let pause: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var replyWaiter: CheckedContinuation<Void, Never>?
    private var committed: WatchBootstrapRequest?
    private(set) var calls: [WatchBootstrapRequest] = []
    private(set) var applications = 0
    init(response: WatchPairingRedeemed, store: BootstrapFileStore? = nil, loseFirst: Bool = false, pause: Bool = false) {
        self.response = response; self.store = store; self.loseFirst = loseFirst; self.pause = pause
    }
    func waitForCall() async { if calls.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func release() { replyWaiter?.resume(); replyWaiter = nil }
    func send(_ data: Data) async throws -> Data {
        let request = try WatchBootstrapCodec.decodeRequest(data)
        if let store {
            let pending = try XCTUnwrap(store.load()?.pending)
            XCTAssertEqual(request.redemption, pending.request); XCTAssertEqual(request.recoveryKey, pending.recoveryKey)
            XCTAssertEqual(request.authority.pairingToken, pending.offer.pairingToken)
        }
        calls.append(request)
        if let committed {
            XCTAssertEqual(request.authority, committed.authority)
            XCTAssertEqual(request.redemption, committed.redemption); XCTAssertEqual(request.recoveryKey, committed.recoveryKey)
        } else { committed = request; applications += 1 }
        waiter?.resume(); waiter = nil
        if pause { await withCheckedContinuation { replyWaiter = $0 } }
        if loseFirst && calls.count == 1 { throw URLError(.networkConnectionLost) }
        return try WatchBootstrapCodec.encodeReply(WatchBootstrapReply(request: request, result: .redeemed(response)), for: request)
    }
}

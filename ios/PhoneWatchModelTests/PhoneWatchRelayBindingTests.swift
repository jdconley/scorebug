import Foundation
import ScorebugCore
import XCTest

private final class RelayBindingMemory: PhoneWatchRequestStorage {
    var value: PhoneWatchSetupRecord?
    var failLoad = false
    var failSave = false
    var saves: [PhoneWatchSetupRecord] = []
    init(_ value: PhoneWatchSetupRecord? = nil) { self.value = value }
    func load() throws -> PhoneWatchSetupRecord? {
        if failLoad { throw CocoaError(.fileReadUnknown) }; return value
    }
    func save(_ value: PhoneWatchSetupRecord) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        self.value = value; saves.append(value)
    }
}

@MainActor final class PhoneWatchRelayBindingTests: XCTestCase {
    private let device = "20000000-0000-4000-8000-000000000002"
    private let pairing = "40000000-0000-4000-8000-000000000004"
    private let endpoint = "https://example.com/control"
    private var scope: WatchRelayScope {
        WatchRelayScope(endpoint: endpoint, gameId: "fixture-game", watchDeviceId: device, pairingId: pairing)
    }
    private func request() -> PhoneWatchRequest {
        PhoneWatchRequest(connection: PhoneWatchConnection(label: "Camera server",
            endpoint: "https://EXAMPLE.com:443/control/", installationToken: "phone-installation-secret"),
            gameId: "fixture-game", request: WatchPairingIssueRequest(pairingId: pairing, watchDeviceId: device),
            offer: WatchPairingIssued(pairingId: pairing, gameId: "fixture-game", watchDeviceId: device,
                pairingToken: String(repeating: "A", count: 43), expiresAt: "2026-09-14T10:05:00.000Z",
                serverTime: "2026-09-14T10:00:00.000Z"))
    }
    private var notice: WatchCompanionNotice {
        WatchCompanionNotice(deviceId: device, phase: .paired, gameId: "fixture-game", pairingId: pairing)
    }
    private func model(_ storage: RelayBindingMemory,
                       changed: @escaping (WatchRelayScope?) -> Void = { _ in }) -> PhoneWatchModel {
        let model = PhoneWatchModel(storage: storage, clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { _ in
                XCTFail("Local confirmation must not require HTTP"); throw URLError(.notConnectedToInternet)
            })
        }, onRelayBindingChanged: changed,
            sendEnvelope: { _ in XCTFail("Confirmation and restore do not reissue setup") })
        model.resume(); return model
    }

    func testConfirmationAtomicallyInstallsCanonicalBindingAndRemovesSetupSecrets() throws {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request()))
        var changes: [(WatchRelayScope?, PhoneWatchSetupRecord?)] = []
        let model = model(storage) { changes.append(($0, storage.value)) }
        changes.removeAll()
        model.receive(notice)
        XCTAssertEqual(storage.saves.count, 1)
        XCTAssertNil(storage.value?.pending)
        XCTAssertNil(model.pending)
        XCTAssertEqual(storage.value?.relayBinding, scope)
        XCTAssertEqual(model.relayBinding, scope)
        XCTAssertEqual(changes.last?.0, scope)
        XCTAssertEqual(changes.last?.1, storage.value, "Notify only after the atomic write")
        let encoded = String(decoding: try JSONEncoder().encode(try XCTUnwrap(storage.value)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("phone-installation-secret"))
        XCTAssertFalse(encoded.contains(String(repeating: "A", count: 43)))
        XCTAssertFalse(encoded.contains("installationToken"))
        XCTAssertFalse(encoded.contains("pairingToken"))
    }

    func testFailedConfirmationKeepsPendingAndRetryPerformsOneAtomicCommit() {
        let original = PhoneWatchSetupRecord(pending: request())
        let storage = RelayBindingMemory(original)
        let model = model(storage)
        storage.failSave = true
        model.receive(notice)
        XCTAssertEqual(storage.value, original)
        XCTAssertEqual(model.pending, original.pending)
        XCTAssertNil(model.relayBinding)
        XCTAssertTrue(storage.saves.isEmpty)
        storage.failSave = false
        model.receive(notice)
        XCTAssertEqual(storage.saves.count, 1)
        XCTAssertNil(storage.value?.pending)
        XCTAssertEqual(model.relayBinding, scope)
    }

    func testFailedConfirmationCanRetryLocallyWithoutNetwork() async {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request()))
        let model = model(storage)
        storage.failSave = true
        model.receive(notice)
        storage.failSave = false
        await model.retry()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.relayBinding, scope)
        XCTAssertEqual(storage.saves.count, 1)
    }

    func testSamePairingCannotRestoreAsBothPendingAndConfirmed() {
        let original = PhoneWatchSetupRecord(pending: request(), relayBinding: scope)
        let storage = RelayBindingMemory(original)
        let model = model(storage)
        XCTAssertNil(model.relayBinding)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(storage.value, original)
    }

    func testConfirmedBindingRestoresWithoutIssuanceOrSavedSecrets() {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(relayBinding: scope))
        var seen: WatchRelayScope?
        let model = model(storage) { seen = $0 }
        XCTAssertEqual(model.relayBinding, scope)
        XCTAssertEqual(seen, scope)
        XCTAssertNil(model.pending)
        XCTAssertTrue(storage.saves.isEmpty)
    }

    func testLegacyPendingRequestMigratesWithoutChangingRetryIdentity() throws {
        let original = request()
        let legacy = try JSONEncoder().encode(original)
        let migrated = try JSONDecoder().decode(PhoneWatchSetupRecord.self, from: legacy)
        XCTAssertEqual(migrated.pending, original)
        XCTAssertNil(migrated.relayBinding)
        let encoded = try JSONEncoder().encode(migrated)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertNotNil(object["pending"])
        XCTAssertTrue(object["relayBinding"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(PhoneWatchSetupRecord.self, from: encoded), migrated)
    }

    func testFailedReplacementNeverActivatesNewBindingAndKeepsAtomicOldState() {
        let old = WatchRelayScope(endpoint: endpoint, gameId: "old-game", watchDeviceId: device,
            pairingId: "50000000-0000-4000-8000-000000000005")
        let original = PhoneWatchSetupRecord(pending: request(), relayBinding: old)
        let storage = RelayBindingMemory(original)
        let model = model(storage)
        XCTAssertEqual(model.relayBinding, old)
        storage.failSave = true
        model.receive(notice)
        XCTAssertEqual(storage.value, original)
        XCTAssertNil(model.relayBinding)
        storage.failSave = false
        model.receive(notice)
        XCTAssertEqual(storage.value?.relayBinding, scope)
        XCTAssertNil(storage.value?.pending)
    }

    func testUnsolicitedOrMismatchedNoticeCannotCreateRelayAuthority() {
        let empty = RelayBindingMemory()
        let emptyModel = model(empty)
        emptyModel.receive(notice)
        XCTAssertNil(emptyModel.relayBinding)
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request()))
        let model = model(storage)
        model.receive(WatchCompanionNotice(deviceId: device, phase: .paired, gameId: "different-game", pairingId: pairing))
        XCTAssertNil(model.relayBinding)
        XCTAssertEqual(model.pending, request())
        XCTAssertTrue(storage.saves.isEmpty)
    }

    func testPeerChangeDurablyClearsBindingAndNotifiesOwnerEvenWhenClearFails() {
        for fail in [false, true] {
            let original = PhoneWatchSetupRecord(relayBinding: scope)
            let storage = RelayBindingMemory(original)
            var changes: [WatchRelayScope?] = []
            let model = model(storage) { changes.append($0) }
            changes.removeAll(); storage.failSave = fail
            model.peerChanged()
            XCTAssertNil(model.relayBinding)
            XCTAssertNil(changes.last!)
            if fail { XCTAssertEqual(storage.value, original) }
            else { XCTAssertNil(storage.value?.relayBinding) }
            model.resume()
            XCTAssertNil(model.relayBinding, "A failed invalidation must not restore itself in the same process")
        }
    }

    func testUnorderedNoticesCannotRevokeConfirmedAssociation() {
        let notices = [WatchCompanionNotice(deviceId: device, phase: .unpaired),
            WatchCompanionNotice(deviceId: device, phase: .pending, gameId: "fixture-game", pairingId: pairing),
            WatchCompanionNotice(deviceId: device, phase: .paired, gameId: "fixture-game",
                pairingId: "50000000-0000-4000-8000-000000000005")]
        for notice in notices {
            let storage = RelayBindingMemory(PhoneWatchSetupRecord(relayBinding: scope))
            let model = model(storage)
            model.receive(notice)
            XCTAssertEqual(model.relayBinding, scope)
            XCTAssertEqual(storage.value?.relayBinding, scope)
            XCTAssertTrue(storage.saves.isEmpty)
        }
    }

    func testFailedPeerRevocationCannotBeReactivatedByResumeOrOldNotice() {
        let original = PhoneWatchSetupRecord(relayBinding: scope)
        let storage = RelayBindingMemory(original)
        let model = model(storage)
        storage.failSave = true
        model.peerChanged()
        XCTAssertEqual(storage.value, original)
        XCTAssertNil(model.relayBinding)
        model.resume(); model.receive(notice)
        XCTAssertNil(model.relayBinding)
        XCTAssertEqual(storage.value, original)
    }

    func testPeerChangeBeforeResumeNeverPublishesStoredBinding() {
        for failSave in [false, true] {
            let storage = RelayBindingMemory(PhoneWatchSetupRecord(relayBinding: scope))
            storage.failSave = failSave
            var changes: [WatchRelayScope?] = []
            let model = PhoneWatchModel(storage: storage, onRelayBindingChanged: { changes.append($0) },
                sendEnvelope: { _ in XCTFail("No setup issuance") })
            model.peerChanged()
            XCTAssertTrue(changes.allSatisfy { $0 == nil }, "Peer invalidation precedes restore publication")
            XCTAssertNil(model.relayBinding)
            model.resume()
            XCTAssertNil(model.relayBinding)
        }
    }

    func testCachedUnorderedNoticesBeforeResumePreserveConfirmedBinding() {
        for phase in [WatchCompanionPhase.unpaired, .pending, .paired] {
            let storage = RelayBindingMemory(PhoneWatchSetupRecord(relayBinding: scope))
            let model = PhoneWatchModel(storage: storage, sendEnvelope: { _ in XCTFail("No issuance") })
            let stale = WatchCompanionNotice(deviceId: device, phase: phase,
                gameId: phase == .unpaired ? nil : "old-game",
                pairingId: phase == .unpaired ? nil : "50000000-0000-4000-8000-000000000005")
            model.receive(stale); model.resume()
            XCTAssertEqual(model.relayBinding, scope)
            XCTAssertTrue(storage.saves.isEmpty)
        }
    }

    func testStaleNoticesAfterReplacementCannotEraseNewConfirmation() {
        let old = WatchRelayScope(endpoint: endpoint, gameId: "old-game", watchDeviceId: device,
            pairingId: "50000000-0000-4000-8000-000000000005")
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request(), relayBinding: old))
        let model = model(storage)
        model.receive(notice)
        XCTAssertEqual(model.relayBinding, scope)
        for phase in [WatchCompanionPhase.paired, .pending, .unpaired] {
            model.receive(WatchCompanionNotice(deviceId: device, phase: phase,
                gameId: phase == .unpaired ? nil : old.gameId,
                pairingId: phase == .unpaired ? nil : old.pairingId))
            XCTAssertEqual(model.relayBinding, scope)
            XCTAssertEqual(storage.value?.relayBinding, scope)
            XCTAssertNil(model.pending)
        }
        XCTAssertEqual(storage.saves.count, 1, "Only the matching confirmation mutates authority")
    }

    func testInvalidPersistedBindingBlocksRestoreWithoutDroppingPendingWork() {
        let invalid = WatchRelayScope(endpoint: "https://EXAMPLE.com:443/control/", gameId: "fixture-game",
            watchDeviceId: device, pairingId: pairing)
        let original = PhoneWatchSetupRecord(pending: request(), relayBinding: invalid)
        let storage = RelayBindingMemory(original)
        let model = model(storage)
        XCTAssertNil(model.relayBinding)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(storage.value, original)
        XCTAssertTrue(storage.saves.isEmpty)
    }

    func testSuspendRetainsConfirmedAssociationForAppScopedRelay() async {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(relayBinding: scope))
        let model = model(storage)
        await model.suspend()
        XCTAssertEqual(model.relayBinding, scope)
        XCTAssertEqual(storage.value?.relayBinding, scope)
    }

    private func encodedGate(_ record: PhoneWatchSetupRecord?) throws -> Bool? {
        let data = try JSONEncoder().encode(XCTUnwrap(record))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["requiresNewRequest"] as? Bool
    }

    private func gated(_ record: PhoneWatchSetupRecord) throws -> PhoneWatchSetupRecord {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        value["requiresNewRequest"] = true
        return try JSONDecoder().decode(PhoneWatchSetupRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testPeerChangeWithPendingBlocksDelayedConfirmationAndAllAutomaticRetry() async throws {
        for failSave in [false, true] {
            let old = WatchRelayScope(endpoint: endpoint, gameId: "old-game", watchDeviceId: device,
                pairingId: "50000000-0000-4000-8000-000000000005")
            let original = PhoneWatchSetupRecord(pending: request(), relayBinding: old)
            let storage = RelayBindingMemory(original)
            let model = model(storage)
            storage.failSave = failSave
            model.peerChanged()
            storage.failSave = false
            let afterPeerChange = storage.value
            model.receive(notice); model.resume()
            await model.retry()
            await model.connect(using: request().connection)
            XCTAssertNil(model.relayBinding)
            XCTAssertEqual(model.pending, original.pending)
            XCTAssertEqual(storage.value, afterPeerChange, "A delayed notice cannot undo peer invalidation")
            if failSave { XCTAssertEqual(storage.value, original) }
            else { XCTAssertEqual(try encodedGate(storage.value), true) }
        }
    }

    func testSuccessfulPeerInvalidationSurvivesSerializationAndRelaunch() async throws {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request()))
        model(storage).peerChanged()
        let restored = try JSONDecoder().decode(PhoneWatchSetupRecord.self,
            from: JSONEncoder().encode(XCTUnwrap(storage.value)))
        let replacementStore = RelayBindingMemory(restored)
        let replacement = model(replacementStore)
        replacement.receive(notice)
        await replacement.retry()
        XCTAssertNil(replacement.relayBinding)
        XCTAssertEqual(replacement.pending, request())
        XCTAssertEqual(try encodedGate(replacementStore.value), true)
        XCTAssertTrue(replacementStore.saves.isEmpty)
    }

    func testFailedExplicitResetKeepsPeerGateAndOriginalPending() async throws {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request()))
        let model = model(storage)
        model.peerChanged()
        let invalidated = storage.value
        storage.failSave = true
        model.resetRequest()
        storage.failSave = false
        model.receive(notice)
        await model.retry()
        XCTAssertEqual(storage.value, invalidated)
        XCTAssertEqual(model.pending, request())
        XCTAssertNil(model.relayBinding)
        XCTAssertEqual(try encodedGate(storage.value), true)
    }

    func testSuccessfulExplicitResetAllowsFreshUUIDIssuanceAfterPeerChange() async throws {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(pending: request()))
        let network = RelaySetupNetwork()
        var sent: [WatchPairingEnvelope] = []
        let model = PhoneWatchModel(storage: storage, clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { try await network.send($0) })
        }, sendEnvelope: { sent.append($0) })
        model.resume(); model.peerChanged(); model.receive(notice)
        model.resetRequest()
        XCTAssertNil(model.pending)
        XCTAssertEqual(try encodedGate(storage.value), false)
        await model.connect(using: request().connection)
        let fresh = try XCTUnwrap(model.pending)
        XCTAssertNotEqual(fresh.request.pairingId, pairing)
        XCTAssertEqual(fresh.request.watchDeviceId, device)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.offer.pairingId, fresh.request.pairingId)
        model.receive(WatchCompanionNotice(deviceId: device, phase: .paired,
            gameId: fresh.gameId, pairingId: fresh.request.pairingId))
        XCTAssertEqual(model.relayBinding?.pairingId, fresh.request.pairingId)
        XCTAssertNil(model.pending)
    }

    func testGatedRecordCannotRestoreConfirmedBinding() throws {
        let invalid = try gated(PhoneWatchSetupRecord(relayBinding: scope))
        let storage = RelayBindingMemory(invalid)
        let model = model(storage)
        XCTAssertNil(model.relayBinding)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(storage.value, invalid)
        XCTAssertTrue(storage.saves.isEmpty)
    }

    func testPeerChangeWithoutPendingAllowsFreshConnectWithoutHiddenReset() async throws {
        let storage = RelayBindingMemory(PhoneWatchSetupRecord(relayBinding: scope))
        let network = RelaySetupNetwork()
        var sent: [WatchPairingEnvelope] = []
        let model = PhoneWatchModel(storage: storage, clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { try await network.send($0) })
        }, sendEnvelope: { sent.append($0) })
        model.resume(); model.peerChanged()
        XCTAssertEqual(try encodedGate(storage.value), true)
        model.receive(notice)
        await model.connect(using: request().connection)
        let fresh = try XCTUnwrap(model.pending)
        XCTAssertNotEqual(fresh.request.pairingId, pairing)
        XCTAssertEqual(try encodedGate(storage.value), false)
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(model.relayBinding)
    }

    func testExistingVersionTwoRecordDefaultsGateToFalse() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(PhoneWatchSetupRecord(pending: request()))) as? [String: Any])
        object.removeValue(forKey: "requiresNewRequest")
        let decoded = try JSONDecoder().decode(PhoneWatchSetupRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.pending, request())
        XCTAssertEqual(try encodedGate(decoded), false)
    }
}

private actor RelaySetupNetwork {
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let data: Data
        if request.url!.path.hasSuffix("/active") {
            data = Data("""
            {"snapshot":{"id":"fixture-game","createdAt":"2026-09-14T10:00:00.000Z","revision":0,"teams":{"home":{"name":"Home","shortName":"HOM","color":"#112233"},"away":{"name":"Away","shortName":"AWY","color":"#112233"}},"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":0,"away":0,"set":1,"homeSets":0,"awaySets":0},"completedSets":[],"status":"active","endReason":null,"canUndo":false,"scorer":{"deviceId":"phone","epoch":1},"broadcast":{"desired":"stopped","generation":0}},"serverTime":"2026-09-14T10:00:00.000Z"}
            """.utf8)
        } else {
            let input = try JSONDecoder().decode(WatchPairingIssueRequest.self, from: XCTUnwrap(request.httpBody))
            data = try JSONEncoder().encode(WatchPairingIssued(pairingId: input.pairingId,
                gameId: "fixture-game", watchDeviceId: input.watchDeviceId,
                pairingToken: String(repeating: "A", count: 43), expiresAt: "2026-09-14T10:05:00.000Z",
                serverTime: "2026-09-14T10:00:00.000Z"))
        }
        return (data, try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
            httpVersion: nil, headerFields: nil)))
    }
}

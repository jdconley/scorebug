import Foundation
import ScorebugCore
import XCTest

@MainActor final class PhoneWatchBootstrapAuthorityTests: XCTestCase {
    private let device = "20000000-0000-4000-8000-000000000002"
    private let pairing = "40000000-0000-4000-8000-000000000004"
    private var scope: WatchRelayScope {
        WatchRelayScope(endpoint: "https://example.com/control", gameId: "fixture-game",
            watchDeviceId: device, pairingId: pairing)
    }
    private var offer: WatchPairingIssued {
        WatchPairingIssued(pairingId: pairing, gameId: scope.gameId, watchDeviceId: device,
            pairingToken: String(repeating: "A", count: 43), expiresAt: "2026-09-14T10:05:00.000Z",
            serverTime: "2026-09-14T10:00:00.000Z")
    }
    private var authority: WatchBootstrapAuthority {
        WatchBootstrapAuthority(scope: scope, pairingToken: offer.pairingToken)
    }
    private func request(includeOffer: Bool = true) -> PhoneWatchRequest {
        PhoneWatchRequest(connection: PhoneWatchConnection(label: "Saved server",
            endpoint: "https://EXAMPLE.com:443/control/", installationToken: "fixture-installation-secret"),
            gameId: scope.gameId, request: WatchPairingIssueRequest(pairingId: pairing, watchDeviceId: device),
            offer: includeOffer ? offer : nil)
    }
    private var pairedNotice: WatchCompanionNotice {
        WatchCompanionNotice(deviceId: device, phase: .paired, gameId: scope.gameId, pairingId: pairing)
    }
    private func owner(_ store: BootstrapAuthorityStore,
                       changed: @escaping (WatchBootstrapAuthority?) -> Void = { _ in }) -> PhoneWatchModel {
        PhoneWatchModel(storage: store, clientFactory: { endpoint in
            MatchHTTPClient(endpoint: endpoint, transport: { _ in
                XCTFail("Restoring authority must not issue HTTP"); throw URLError(.notConnectedToInternet)
            })
        }, onBootstrapAuthorityChanged: changed,
            sendEnvelope: { _ in XCTFail("Restoring authority must not send setup") })
    }

    func testBackgroundRestorePublishesOnlyCanonicalSavedOfferWithoutLocalExpiryGate() throws {
        let store = BootstrapAuthorityStore(PhoneWatchSetupRecord(pending: request()))
        var changes: [WatchBootstrapAuthority?] = []
        let model = owner(store) { changes.append($0) }
        model.restoreRelayAssociation()
        XCTAssertEqual(model.bootstrapAuthority, authority)
        XCTAssertEqual(changes, [authority])
        XCTAssertNil(model.relayBinding)
        XCTAssertTrue(store.saves.isEmpty)
        let payload = String(decoding: try JSONEncoder().encode(try XCTUnwrap(model.bootstrapAuthority)), as: UTF8.self)
        XCTAssertFalse(payload.contains("installation"))
        XCTAssertFalse(payload.contains("recoveryKey"))
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(authority)) as? [String: Any]).keys),
            Set(["scope", "pairingToken"]))
        model.restoreRelayAssociation()
        XCTAssertEqual(changes.count, 1, "Repeated restore must not invalidate an unchanged in-flight authorization")
    }

    func testMissingOfferConfirmedBindingAndDurablePeerGateNeverAuthorizeBootstrap() {
        let records = [PhoneWatchSetupRecord(), PhoneWatchSetupRecord(pending: request(includeOffer: false)),
            PhoneWatchSetupRecord(relayBinding: scope),
            PhoneWatchSetupRecord(pending: request(), requiresNewRequest: true)]
        for record in records {
            let store = BootstrapAuthorityStore(record)
            var changes: [WatchBootstrapAuthority?] = []
            let model = owner(store) { changes.append($0) }
            model.restoreRelayAssociation(); model.receive(pairedNotice)
            XCTAssertNil(model.bootstrapAuthority)
            XCTAssertTrue(changes.allSatisfy { $0 == nil })
        }
    }

    func testInvalidSavedOfferAndFailedLoadCannotPublishAuthority() {
        var invalid = request()
        invalid.offer = WatchPairingIssued(pairingId: pairing, gameId: "wrong-game", watchDeviceId: device,
            pairingToken: offer.pairingToken, expiresAt: offer.expiresAt, serverTime: offer.serverTime)
        let bad = owner(BootstrapAuthorityStore(PhoneWatchSetupRecord(pending: invalid)))
        bad.restoreRelayAssociation()
        XCTAssertNil(bad.bootstrapAuthority)
        let store = BootstrapAuthorityStore(PhoneWatchSetupRecord(pending: request()))
        store.failLoad = true
        let model = owner(store)
        model.restoreRelayAssociation()
        XCTAssertNil(model.bootstrapAuthority)
        store.failLoad = false; model.restoreRelayAssociation()
        XCTAssertEqual(model.bootstrapAuthority, authority)
    }

    func testOfferPublicationFollowsAtomicSaveAndPrecedesEnvelopeTransfer() async {
        for failSave in [false, true] {
            let original = PhoneWatchSetupRecord(pending: request(includeOffer: false))
            let store = BootstrapAuthorityStore(original)
            store.failSave = failSave
            let offer = offer
            var changes: [(WatchBootstrapAuthority?, PhoneWatchSetupRecord?)] = []
            var sent = 0
            let model = PhoneWatchModel(storage: store, clientFactory: { endpoint in
                MatchHTTPClient(endpoint: endpoint, transport: { request in
                    (try JSONEncoder().encode(offer), HTTPURLResponse(url: request.url!, statusCode: 201,
                        httpVersion: nil, headerFields: nil)!)
                })
            }, onBootstrapAuthorityChanged: { changes.append(($0, store.value)) }, sendEnvelope: { envelope in
                sent += 1
                XCTAssertEqual(store.value?.pending?.offer, envelope.offer)
                XCTAssertEqual(changes.last?.0, self.authority)
            })
            model.resume(); model.receive(WatchCompanionNotice(deviceId: device, phase: .unpaired))
            await model.connect(using: request().connection)
            if failSave {
                XCTAssertEqual(store.value, original)
                XCTAssertNil(model.bootstrapAuthority)
                XCTAssertTrue(changes.allSatisfy { $0.0 == nil })
                XCTAssertEqual(sent, 0)
            } else {
                XCTAssertEqual(model.bootstrapAuthority, authority)
                XCTAssertEqual(changes.last?.1?.pending?.offer, offer)
                XCTAssertEqual(sent, 1)
            }
        }
    }

    func testFailedConfirmationRetainsCommittedBootstrapOfferUntilSuccessfulRetry() {
        let old = WatchRelayScope(endpoint: scope.endpoint, gameId: "old-game", watchDeviceId: device,
            pairingId: "50000000-0000-4000-8000-000000000005")
        let original = PhoneWatchSetupRecord(pending: request(), relayBinding: old)
        let store = BootstrapAuthorityStore(original)
        var changes: [(WatchBootstrapAuthority?, PhoneWatchSetupRecord?)] = []
        let model = owner(store) { changes.append(($0, store.value)) }
        model.restoreRelayAssociation()
        XCTAssertEqual(model.relayBinding, old)
        XCTAssertEqual(model.bootstrapAuthority, authority)
        store.failSave = true; model.receive(pairedNotice)
        XCTAssertEqual(store.value, original)
        XCTAssertNil(model.relayBinding, "Unsaved confirmation cannot activate scoring authority")
        XCTAssertEqual(model.bootstrapAuthority, authority, "A previously committed offer still permits exact bootstrap recovery")
        XCTAssertEqual(changes.count, 1)
        store.failSave = false; model.receive(pairedNotice)
        XCTAssertNil(model.bootstrapAuthority)
        XCTAssertEqual(model.relayBinding, scope)
        XCTAssertNil(changes.last!.0)
        XCTAssertNil(changes.last!.1?.pending, "Authority removal follows the durable confirmation")
    }

    func testPeerChangeInvalidatesBeforeStorageEvenWhenSavingFails() {
        for failSave in [false, true] {
            let original = PhoneWatchSetupRecord(pending: request())
            let store = BootstrapAuthorityStore(original)
            var changes: [WatchBootstrapAuthority?] = []
            let model = owner(store) { changes.append($0) }
            model.restoreRelayAssociation()
            store.beforeSave = { _ in XCTAssertNil(model.bootstrapAuthority) }
            store.failSave = failSave
            model.peerChanged()
            XCTAssertNil(model.bootstrapAuthority)
            XCTAssertNil(changes.last!)
            model.resume(); model.receive(pairedNotice)
            XCTAssertNil(model.bootstrapAuthority)
            if failSave { XCTAssertEqual(store.value, original) }
            else {
                XCTAssertTrue(store.value?.requiresNewRequest == true)
                let restored = owner(store); restored.restoreRelayAssociation()
                XCTAssertNil(restored.bootstrapAuthority)
            }
        }
    }

    func testPeerChangeBeforeRestoreNeverPublishesOldPendingAuthority() {
        let store = BootstrapAuthorityStore(PhoneWatchSetupRecord(pending: request()))
        store.failSave = true
        var changes: [WatchBootstrapAuthority?] = []
        let model = owner(store) { changes.append($0) }
        model.peerChanged(); model.restoreRelayAssociation()
        XCTAssertNil(model.bootstrapAuthority)
        XCTAssertTrue(changes.allSatisfy { $0 == nil })
    }

    func testResetRemovesPendingAuthorityOnlyAfterSuccessfulSave() {
        let old = WatchRelayScope(endpoint: scope.endpoint, gameId: "old-game", watchDeviceId: device,
            pairingId: "50000000-0000-4000-8000-000000000005")
        let store = BootstrapAuthorityStore(PhoneWatchSetupRecord(pending: request(), relayBinding: old))
        let model = owner(store); model.resume()
        store.failSave = true; model.resetRequest()
        XCTAssertEqual(model.bootstrapAuthority, authority)
        store.failSave = false; model.resetRequest()
        XCTAssertNil(model.bootstrapAuthority)
        XCTAssertNil(store.value?.pending)
        XCTAssertEqual(model.relayBinding, old)
    }

    func testUnorderedNoticesDoNotChangeSavedBootstrapAuthority() {
        let store = BootstrapAuthorityStore(PhoneWatchSetupRecord(pending: request()))
        var changes: [WatchBootstrapAuthority?] = []
        let model = owner(store) { changes.append($0) }
        model.restoreRelayAssociation()
        let other = "60000000-0000-4000-8000-000000000006"
        for notice in [WatchCompanionNotice(deviceId: other, phase: .unpaired),
            WatchCompanionNotice(deviceId: device, phase: .paired, gameId: "other-game", pairingId: pairing),
            WatchCompanionNotice(deviceId: device, phase: .pending, gameId: scope.gameId, pairingId: pairing)] {
            model.receive(notice)
            XCTAssertEqual(model.bootstrapAuthority, authority)
        }
        XCTAssertEqual(changes, [authority])
        XCTAssertTrue(store.saves.isEmpty)
    }
}

private final class BootstrapAuthorityStore: PhoneWatchRequestStorage {
    var value: PhoneWatchSetupRecord?
    var failLoad = false, failSave = false
    var saves: [PhoneWatchSetupRecord] = []
    var beforeSave: ((PhoneWatchSetupRecord) -> Void)?
    init(_ value: PhoneWatchSetupRecord? = nil) { self.value = value }
    func load() throws -> PhoneWatchSetupRecord? {
        if failLoad { throw CocoaError(.fileReadUnknown) }
        return value
    }
    func save(_ value: PhoneWatchSetupRecord) throws {
        beforeSave?(value)
        if failSave { throw CocoaError(.fileWriteUnknown) }
        self.value = value; saves.append(value)
    }
}

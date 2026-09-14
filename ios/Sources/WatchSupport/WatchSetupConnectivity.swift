import Foundation
import ScorebugCore
import SwiftUI
@preconcurrency import WatchConnectivity

/// One replacement setup/identity context per direction. No scoring command relay.
@MainActor final class WatchSetupConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var latestEnvelope: WatchPairingEnvelope?
    var noticeHandler: (WatchCompanionNotice) -> Void = { _ in }
    var peerChangedHandler: () -> Void = {}
    private var outgoing: (String, Data)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState == .activated { activated(session) }
        else { session.activate() }
    }
    func sendNotice(_ notice: WatchCompanionNotice) throws {
        try publish(key: WatchCompanionCodec.noticeKey, data: WatchCompanionCodec.encodeNotice(notice))
    }
    func sendEnvelope(_ envelope: WatchPairingEnvelope) throws {
        try publish(key: WatchCompanionCodec.pairingKey, data: WatchCompanionCodec.encodeEnvelope(envelope))
    }
    private func publish(key: String, data: Data) throws {
        outgoing = (key, data)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { throw ConnectivityFailure.unavailable }
        try WCSession.default.updateApplicationContext([key: data])
    }
    private func activated(_ session: WCSession) {
        receive(notice: session.receivedApplicationContext[WatchCompanionCodec.noticeKey] as? Data,
                envelope: session.receivedApplicationContext[WatchCompanionCodec.pairingKey] as? Data)
        if let (key, data) = outgoing { try? session.updateApplicationContext([key: data]) }
    }
    private func receive(notice: Data?, envelope: Data?) {
        #if os(iOS)
        if let notice, let decoded = try? WatchCompanionCodec.decodeNotice(notice) { noticeHandler(decoded) }
        #elseif os(watchOS)
        if let envelope, let decoded = try? WatchCompanionCodec.decodeEnvelope(envelope) { latestEnvelope = decoded }
        #endif
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in self?.activated(session) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Copy only bounded immutable Data across the delegate/actor boundary.
        let notice = applicationContext[WatchCompanionCodec.noticeKey] as? Data
        let envelope = applicationContext[WatchCompanionCodec.pairingKey] as? Data
        guard (notice?.count ?? 0) <= WatchCompanionCodec.maximumBytes,
              (envelope?.count ?? 0) <= WatchCompanionCodec.maximumBytes else { return }
        Task { @MainActor [weak self] in self?.receive(notice: notice, envelope: envelope) }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.outgoing = nil; self?.peerChangedHandler() }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.outgoing = nil; self?.peerChangedHandler(); session.activate()
        }
    }
    #endif
    private enum ConnectivityFailure: Error { case unavailable }
}

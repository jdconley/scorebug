import Foundation
import ScorebugCore
import SwiftUI
@preconcurrency import WatchConnectivity

/// Setup application context and immediate scoring share one native delegate.
/// Message admission is reserved before dispatching work onto MainActor.
@MainActor final class WatchSetupConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var latestEnvelope: WatchPairingEnvelope?
    var noticeHandler: (WatchCompanionNotice) -> Void = { _ in }
    var peerChangedHandler: () -> Void = {}
    var scoringRequestHandler: (Data) async -> Data = { _ in Data() }
    private var outgoing: (String, Data)?
    private var scoringTransport: WatchRelayMessageTransport?
    private nonisolated let messageGate = WatchRelaySessionGate()

    var canRelayScoring: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func scoringRelayClient(for paired: WatchPairedSetup) throws -> WatchRelayScoringClient {
        let scope = WatchRelayScope(endpoint: try ScoringEndpoint(paired.endpoint).canonicalAddress,
            gameId: paired.credential.gameId, watchDeviceId: paired.credential.deviceId, pairingId: paired.pairingId)
        try WatchRelayCodec.validateScope(scope)
        return WatchRelayScoringClient(scope: scope, send: { [weak self] data in
            guard let self else { throw WatchRelayFailure.unavailable }
            return try await self.sendScoring(data)
        })
    }

    private func sendScoring(_ data: Data) async throws -> Data {
        if scoringTransport == nil {
            scoringTransport = WatchRelayMessageTransport(timeout: 2,
                isReachable: { [weak self] in self?.canRelayScoring == true },
                send: { [weak self] data, callback in
                    guard self?.canRelayScoring == true else { throw WatchRelayFailure.unavailable }
                    WCSession.default.sendMessageData(data,
                        replyHandler: { callback(.success($0)) },
                        errorHandler: { _ in callback(.failure(.unavailable)) })
                })
        }
        guard let scoringTransport else { throw WatchRelayFailure.unavailable }
        return try await scoringTransport.send(data)
    }

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
        let epoch = messageGate.currentEpoch
        Task { @MainActor [weak self] in
            guard let self, self.messageGate.isCurrentEpoch(epoch) else { return }
            self.activated(session)
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Copy only bounded immutable Data across the delegate/actor boundary.
        let notice = applicationContext[WatchCompanionCodec.noticeKey] as? Data
        let envelope = applicationContext[WatchCompanionCodec.pairingKey] as? Data
        guard (notice?.count ?? 0) <= WatchCompanionCodec.maximumBytes,
              (envelope?.count ?? 0) <= WatchCompanionCodec.maximumBytes else { return }
        let epoch = messageGate.currentEpoch
        Task { @MainActor [weak self] in
            guard let self, self.messageGate.isCurrentEpoch(epoch) else { return }
            self.receive(notice: notice, envelope: envelope)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        #if os(iOS)
        let reply = WatchRelayReplyOnce(replyHandler)
        guard !messageData.isEmpty, messageData.count <= WatchRelayCodec.maximumRequestBytes else {
            reply.send(Data()); return
        }
        let gate = messageGate
        guard let token = gate.admit() else {
            reply.send(Self.failureReply(.busy, for: messageData)); return
        }
        Task { @MainActor [weak self] in
            defer { gate.release(token) }
            guard let self, gate.isCurrent(token) else {
                reply.send(Self.failureReply(.cancelled, for: messageData)); return
            }
            let result = await self.scoringRequestHandler(messageData)
            // The delegate can invalidate this epoch before its actor task runs.
            // Do not return stale HTTP success while that actor invalidation waits.
            reply.send(gate.isCurrent(token) ? result : Self.failureReply(.cancelled, for: messageData))
        }
        #else
        // The Watch accepts setup context; HTTP forwarding belongs to the phone.
        replyHandler(Data())
        #endif
    }

    private nonisolated static func failureReply(_ failure: WatchRelayFailure, for data: Data) -> Data {
        guard let request = try? WatchRelayCodec.decodeRequest(data) else { return Data() }
        return (try? WatchRelayCodec.encodeReply(WatchRelayReply(request: request, result: .failure(failure)), for: request)) ?? Data()
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let transition = messageGate.invalidatePeer()
        Task { @MainActor [weak self] in self?.peerChanged(transition) }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        let transition = messageGate.invalidatePeer()
        Task { @MainActor [weak self] in
            guard let self, self.messageGate.isCurrentEpoch(transition) else { return }
            self.peerChanged(transition); session.activate()
        }
    }
    private func peerChanged(_ transition: UUID) {
        guard messageGate.isCurrentEpoch(transition) else { return }
        outgoing = nil
        scoringTransport?.invalidatePeer()
        peerChangedHandler()
        messageGate.completePeerChange(transition)
        // Activation may have completed while actor cleanup was queued.
        if WCSession.default.activationState == .activated { activated(WCSession.default) }
    }
    #endif
    private enum ConnectivityFailure: Error { case unavailable }
}

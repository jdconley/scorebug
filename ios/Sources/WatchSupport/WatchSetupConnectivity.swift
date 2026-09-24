import Foundation
import ScorebugCore
import SwiftUI
#if DEBUG
import OSLog
#endif
@preconcurrency import WatchConnectivity

/// Setup application context and immediate scoring share one native delegate.
/// Message admission is reserved before dispatching work onto MainActor.
@MainActor final class WatchSetupConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var latestEnvelope: WatchPairingEnvelope?
    var noticeHandler: (WatchCompanionNotice) -> Void = { _ in }
    var peerChangedHandler: () -> Void = {}
    var scoringRequestHandler: (Data) async -> Data = { _ in Data() }
    var bootstrapRequestHandler: (Data) async -> Data = { _ in Data() }
    private var outgoing: (String, Data)?
    private var relayTransport: WatchRelayMessageTransport?
    private nonisolated let messageGate = WatchRelaySessionGate()

    #if DEBUG
    private nonisolated let diagnosticsEnabled = ProcessInfo.processInfo.environment["SCOREBUG_WATCH_CONNECTIVITY_DIAGNOSTICS"] == "1"
    private nonisolated let diagnostic = WatchConnectivityDiagnostic(enabled: true)
    private nonisolated let diagnosticLogger = Logger(subsystem: "live.scorebug.connectivity", category: "diagnostic")
    #endif

    private nonisolated func observe(_ event: WatchConnectivityDiagnostic.Event,
                                    session: WCSession, kind: WatchConnectivityDiagnostic.Kind = .none,
                                    activation: WCSessionActivationState? = nil, error: Error? = nil) {
        #if DEBUG
        guard diagnosticsEnabled else { return }
        let state = activation ?? session.activationState
        var snapshot = WatchConnectivityDiagnostic.State(activation: state.rawValue)
        if state == .activated {
            snapshot.reachable = session.isReachable
            #if os(iOS)
            snapshot.paired = session.isPaired
            snapshot.installed = session.isWatchAppInstalled
            #elseif os(watchOS)
            snapshot.installed = session.isCompanionAppInstalled
            #endif
        }
        if let error = error as NSError? {
            if error.domain == WCErrorDomain { snapshot.errorCode = error.code }
            else { snapshot.otherError = true }
        }
        if let row = diagnostic.record(event, kind: kind, state: snapshot) {
            diagnosticLogger.info("\(row, privacy: .public)")
        }
        #endif
    }

    var canRelayRequests: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func scoringRelayClient(for paired: WatchPairedSetup) throws -> WatchRelayScoringClient {
        let scope = WatchRelayScope(endpoint: try ScoringEndpoint(paired.endpoint).canonicalAddress,
            gameId: paired.credential.gameId, watchDeviceId: paired.credential.deviceId, pairingId: paired.pairingId)
        try WatchRelayCodec.validateScope(scope)
        return WatchRelayScoringClient(scope: scope, send: { [weak self] data in
            guard let self else { throw WatchRelayFailure.unavailable }
            return try await self.sendRelay(data)
        })
    }

    func bootstrapRelayClient() -> WatchBootstrapRelayClient {
        WatchBootstrapRelayClient(send: { [weak self] data in
            guard let self else { throw WatchRelayFailure.unavailable }
            return try await self.sendRelay(data)
        })
    }

    private func sendRelay(_ data: Data) async throws -> Data {
        if relayTransport == nil {
            relayTransport = WatchRelayMessageTransport(timeout: 2, allowsBootstrap: true,
                isReachable: { [weak self] in self?.canRelayRequests == true },
                send: { [weak self] data, callback in
                    guard self?.canRelayRequests == true else { throw WatchRelayFailure.unavailable }
                    WCSession.default.sendMessageData(data,
                        replyHandler: { callback(.success($0)) },
                        errorHandler: { _ in callback(.failure(.unavailable)) })
                })
        }
        guard let relayTransport else { throw WatchRelayFailure.unavailable }
        return try await relayTransport.send(data)
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        observe(.activateRequested, session: session)
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
        guard WCSession.isSupported() else { throw ConnectivityFailure.unavailable }
        try updateContext(key: key, data: data, session: WCSession.default)
    }
    private func updateContext(key: String, data: Data, session: WCSession) throws {
        let kind: WatchConnectivityDiagnostic.Kind = key == WatchCompanionCodec.noticeKey ? .notice : key == WatchCompanionCodec.pairingKey ? .envelope : .unknown
        observe(.publishAttempt, session: session, kind: kind)
        do {
            guard session.activationState == .activated else { throw ConnectivityFailure.unavailable }
            try session.updateApplicationContext([key: data])
            observe(.publishAccepted, session: session, kind: kind)
        } catch {
            observe(.publishRejected, session: session, kind: kind, error: error)
            throw error
        }
    }
    private func activated(_ session: WCSession) {
        receive(notice: session.receivedApplicationContext[WatchCompanionCodec.noticeKey] as? Data,
                envelope: session.receivedApplicationContext[WatchCompanionCodec.pairingKey] as? Data)
        if let (key, data) = outgoing { try? updateContext(key: key, data: data, session: session) }
    }
    private func receive(notice: Data?, envelope: Data?) {
        #if os(iOS)
        if let notice, let decoded = try? WatchCompanionCodec.decodeNotice(notice) { observe(.noticeDecoded, session: WCSession.default, kind: .notice); noticeHandler(decoded) }
        #elseif os(watchOS)
        if let envelope, let decoded = try? WatchCompanionCodec.decodeEnvelope(envelope) { observe(.envelopeDecoded, session: WCSession.default, kind: .envelope); latestEnvelope = decoded }
        #endif
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let epoch = messageGate.currentEpoch
        observe(.activationCompleted, session: session, activation: activationState, error: error)
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.messageGate.isCurrentEpoch(epoch) else { return }
            self.activated(session)
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let epoch = messageGate.currentEpoch
        observe(.contextReceived, session: session)
        // Copy only bounded immutable Data across the delegate/actor boundary.
        let notice = applicationContext[WatchCompanionCodec.noticeKey] as? Data
        let envelope = applicationContext[WatchCompanionCodec.pairingKey] as? Data
        guard (notice?.count ?? 0) <= WatchCompanionCodec.maximumBytes,
              (envelope?.count ?? 0) <= WatchCompanionCodec.maximumBytes else { return }
        Task { @MainActor [weak self] in
            guard let self, self.messageGate.isCurrentEpoch(epoch) else { return }
            self.receive(notice: notice, envelope: envelope)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        #if os(iOS)
        let reply = WatchRelayReplyOnce(replyHandler)
        guard let request = try? WatchRelayInboundRequest(validating: messageData) else {
            reply.send(Data()); return
        }
        let gate = messageGate
        guard let token = gate.admit() else {
            reply.send(request.failureReply(.busy)); return
        }
        Task { @MainActor [weak self] in
            defer { gate.release(token) }
            guard let self, gate.isCurrent(token) else {
                reply.send(request.failureReply(.cancelled)); return
            }
            let result: Data
            switch request {
            case .scoring: result = await self.scoringRequestHandler(messageData)
            case .bootstrap: result = await self.bootstrapRequestHandler(messageData)
            }
            // The delegate can invalidate this epoch before its actor task runs.
            // Do not return stale HTTP success while that actor invalidation waits.
            reply.send(gate.isCurrent(token) ? result : request.failureReply(.cancelled))
        }
        #else
        // The Watch accepts setup context; HTTP forwarding belongs to the phone.
        replyHandler(Data())
        #endif
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let transition = messageGate.invalidatePeer()
        observe(.peerInactive, session: session)
        Task { @MainActor [weak self] in self?.peerChanged(transition) }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        let transition = messageGate.invalidatePeer()
        observe(.peerDeactivated, session: session)
        Task { @MainActor [weak self] in
            guard let self, self.messageGate.isCurrentEpoch(transition) else { return }
            self.peerChanged(transition); session.activate()
        }
    }
    private func peerChanged(_ transition: UUID) {
        guard messageGate.isCurrentEpoch(transition) else { return }
        outgoing = nil
        relayTransport?.invalidatePeer()
        peerChangedHandler()
        messageGate.completePeerChange(transition)
        // Activation may have completed while actor cleanup was queued.
        if WCSession.default.activationState == .activated { activated(WCSession.default) }
    }
    #endif
    private enum ConnectivityFailure: Error { case unavailable }
}

import Foundation
import ScorebugCore
import SwiftUI
@preconcurrency import WatchConnectivity

/// Mirrors the open match to the paired Apple Watch and runs its taps through
/// this phone's scoreboard. No Watch setup, pairing codes or server credentials:
/// whenever this phone is filming or scoring a match, the Watch can score it.
///
/// State goes out as application context (delivered whenever the Watch app next
/// runs) and, while the Watch is reachable, as an immediate message. Intents come
/// back as messages with a reply carrying the fresh state.
@MainActor final class PhoneWatchLink: NSObject, ObservableObject {
    @Published private(set) var isWatchConnected = false
    private weak var board: ScoreboardModel?
    private var lastSent: WatchRemote.State??
    private var activated = false

    func activate() {
        guard WCSession.isSupported(), !activated else { return }
        activated = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The scoreboard on screen, or nil when no match is open.
    func attach(_ board: ScoreboardModel?) {
        self.board = board
        push(board?.watchState)
    }

    func push(_ state: WatchRemote.State?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        if let lastSent, lastSent == state { return }
        lastSent = .some(state)
        guard let message = try? WatchRemote.message(WatchRemote.Envelope(state: state, sentAt: Date().timeIntervalSince1970)) else { return }
        try? session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    private func refreshConnection() {
        let session = WCSession.default
        isWatchConnected = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled && session.isReachable
    }

    fileprivate func handle(_ message: [String: Any]) -> [String: Any] {
        if let intent = WatchRemote.decode(WatchRemote.Intent.self, from: message) {
            board?.handle(intent)
        }
        let envelope = WatchRemote.Envelope(state: board?.watchState, sentAt: Date().timeIntervalSince1970)
        return (try? WatchRemote.message(envelope)) ?? [:]
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.refreshConnection()
            self.lastSent = nil
            self.push(self.board?.watchState)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another Watch: start a session for it.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshConnection()
            if session.isReachable { self.lastSent = nil; self.push(self.board?.watchState) }
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshConnection() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let payload = UncheckedMessage(value: message)
        let reply = UncheckedReply(send: replyHandler)
        Task { @MainActor in reply.send(self.handle(payload.value)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let payload = UncheckedMessage(value: message)
        Task { @MainActor in _ = self.handle(payload.value) }
    }
}

/// WatchConnectivity hands over plain property-list dictionaries; they are only read on the main actor.
struct UncheckedMessage: @unchecked Sendable { let value: [String: Any] }
struct UncheckedReply: @unchecked Sendable { let send: ([String: Any]) -> Void }

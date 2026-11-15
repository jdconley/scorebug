import Foundation
import ScorebugCore
import SwiftUI
import WatchKit
@preconcurrency import WatchConnectivity

/// The Watch side of the phone link. Holds no server setup: it shows whatever match
/// the paired iPhone has open and sends taps back for the phone to score.
@MainActor final class WatchLink: NSObject, ObservableObject {
    enum Connection: Equatable { case starting, reachable, phoneAway }

    @Published private(set) var state: WatchRemote.State?
    @Published private(set) var connection: Connection = .starting
    /// A tap is on its way to the phone.
    @Published private(set) var sending = false
    private var newest: Double = 0

    func activate() {
        guard WCSession.isSupported() else { connection = .phoneAway; return }
        WCSession.default.delegate = self
        if WCSession.default.activationState == .activated { refresh() } else { WCSession.default.activate() }
    }

    /// Ask the phone for the current match (on launch and when it comes back in range).
    func refresh() {
        let session = WCSession.default
        apply(session.receivedApplicationContext)
        connection = session.isReachable ? .reachable : .phoneAway
        if session.isReachable { send(.hello, haptic: nil) }
    }

    func send(_ intent: WatchRemote.Intent, haptic: WKHapticType? = .click) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable,
              let message = try? WatchRemote.message(intent) else {
            connection = .phoneAway
            WKInterfaceDevice.current().play(.failure)
            return
        }
        if let haptic { WKInterfaceDevice.current().play(haptic) }
        sending = intent != .hello
        session.sendMessage(message, replyHandler: { reply in
            let payload = UncheckedMessage(value: reply)
            Task { @MainActor in self.sending = false; self.apply(payload.value) }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.sending = false
                self.connection = WCSession.default.isReachable ? .reachable : .phoneAway
                if intent != .hello { WKInterfaceDevice.current().play(.failure) }
            }
        })
    }

    fileprivate func apply(_ message: [String: Any]) {
        guard let envelope = WatchRemote.decode(WatchRemote.Envelope.self, from: message),
              envelope.state.map({ $0.version == WatchRemote.version }) ?? true,
              envelope.sentAt >= newest else { return }
        newest = envelope.sentAt
        state = envelope.state
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let payload = UncheckedMessage(value: context)
        Task { @MainActor in self.apply(payload.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let payload = UncheckedMessage(value: message)
        Task { @MainActor in self.apply(payload.value); self.connection = .reachable }
    }
}

struct UncheckedMessage: @unchecked Sendable { let value: [String: Any] }

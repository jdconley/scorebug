import Foundation

/// Closed, payload-free diagnostic fields. No user or peer-provided text is accepted.
final class WatchConnectivityDiagnostic: @unchecked Sendable {
    enum Event: String { case activateRequested, activationCompleted, publishAttempt, publishAccepted, publishRejected, contextReceived, noticeDecoded, envelopeDecoded, peerInactive, peerDeactivated }
    enum Kind: String { case none, notice, envelope, unknown }
    struct State {
        let activation: Int
        var reachable: Bool? = nil
        var paired: Bool? = nil
        var installed: Bool? = nil
        var errorCode: Int? = nil
        var otherError = false
    }
    private let enabled: Bool
    private let lock = NSLock()
    private var sequence = 0
    init(enabled: Bool) { self.enabled = enabled }
    func record(_ event: Event, kind: Kind = .none, state: State) -> String? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard sequence < 129 else { return nil }
        sequence += 1
        if sequence == 129 { return "v=1 seq=129 event=overflow" }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "unknown" }
        let error = state.otherError ? "other" : state.errorCode.map(String.init) ?? "none"
        return "v=1 seq=\(sequence) event=\(event.rawValue) kind=\(kind.rawValue) activation=\(state.activation) reachable=\(flag(state.reachable)) paired=\(flag(state.paired)) installed=\(flag(state.installed)) error=\(error)"
    }
}

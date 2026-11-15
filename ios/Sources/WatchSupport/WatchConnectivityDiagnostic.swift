import Foundation

/// Closed, payload-free diagnostic fields. No user or peer-provided text is accepted.
final class WatchConnectivityDiagnostic: @unchecked Sendable {
    enum Event: String { case probeStarted, probeReply, probeUnexpectedReply, probeFailed, probeTimedOut, probeReceived, activateRequested, activationCompleted, publishAttempt, publishAccepted, publishRejected, contextReceived, noticeDecoded, envelopeDecoded, peerInactive, peerDeactivated }
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

/// One lifetime attempt; no transport payloads are retained by this gate.
final class WatchConnectivityProbeGate: @unchecked Sendable {
    enum Outcome { case reply, unexpectedReply, failed, timedOut }
    static let payload = Data([0])
    private let enabled: Bool
    private let lock = NSLock()
    private var attempted = false
    private var interval: (start: TimeInterval, deadline: TimeInterval)?
    init(enabled: Bool) { self.enabled = enabled }
    func begin(eligible: Bool, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = now + 2
        guard enabled, eligible, !attempted, now.isFinite, now >= 0,
              deadline.isFinite, deadline > now else { return false }
        attempted = true
        interval = (now, deadline)
        return true
    }
    func finish(_ result: Outcome, now: TimeInterval) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        guard let interval else { return nil }
        self.interval = nil
        guard now.isFinite, now >= interval.start, now < interval.deadline else { return .timedOut }
        return result
    }
}

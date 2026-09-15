import Foundation
import ScorebugCore

/// Admission is reserved on the native delegate thread, before creating actor
/// work. Peer invalidation changes the epoch but holds capacity until work joins.
final class WatchRelaySessionGate: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let epoch: UUID
    }
    private let lock = NSLock()
    private var epoch = UUID()
    private var active: UUID?
    private var accepting = true

    var currentEpoch: UUID { lock.lock(); defer { lock.unlock() }; return epoch }
    func isCurrentEpoch(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return epoch == value
    }
    func admit() -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard accepting, active == nil else { return nil }
        let id = UUID(); active = id
        return Token(id: id, epoch: epoch)
    }
    func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == token.id && epoch == token.epoch
    }
    @discardableResult func invalidatePeer() -> UUID {
        lock.lock(); defer { lock.unlock() }
        accepting = false; epoch = UUID()
        return epoch
    }
    /// Call only after actor-owned binding invalidation for this exact transition.
    func completePeerChange(_ transition: UUID) {
        lock.lock(); defer { lock.unlock() }
        if epoch == transition { accepting = true }
    }
    func release(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        if active == token.id { active = nil }
    }
}

/// WC reply blocks are callable from delegate/background threads. Transfer that
/// platform callback through one locked terminal slot; invoke outside the lock.
final class WatchRelayReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data) -> Void)?
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    func send(_ data: Data) {
        lock.lock()
        let callback = reply; reply = nil
        lock.unlock()
        callback?(data.count <= WatchRelayCodec.maximumReplyBytes ? data : Data())
    }
}

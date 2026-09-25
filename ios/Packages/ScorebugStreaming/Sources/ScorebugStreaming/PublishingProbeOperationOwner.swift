import Foundation

/// Cleanup ownership is separate from validated probe authority. A rejected raw
/// allocation still belongs to the operation that returned it. Only scalar IDs
/// and one joined cleanup task are retained; no live snapshot is ever adopted.
final class PublishingProbeOperationOwner: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let id: UUID
        let generation: UInt64
        init(_ value: PublishingBandwidthProbeSnapshot) {
            id = value.id; generation = value.publishingGeneration
        }
        init(id: UUID, generation: UInt64) { self.id = id; self.generation = generation }
    }
    typealias Retirement = @Sendable (UUID, UInt64) async throws -> Void
    typealias Cancellation = @Sendable (UUID, UInt64) async -> Void
    private let predecessor: Identity?
    private let lock = NSLock()
    private var returned: Identity?
    private var accepted = false
    private var cleanup: Task<Void, Error>?

    init(predecessor: PublishingBandwidthProbeSnapshot?) {
        self.predecessor = predecessor.map(Identity.init)
    }
    func capture(_ value: PublishingBandwidthProbeSnapshot) {
        lock.withLock { returned = Identity(value) }
    }
    func accept() { lock.withLock { accepted = true } }
    func matches(id: UUID, generation: UInt64) -> Bool {
        let requested = Identity(id: id, generation: generation)
        return lock.withLock { returned == requested || (!accepted && predecessor == requested) }
    }
    var target: Identity? { lock.withLock { returned ?? predecessor } }

    /// Called only once the operation has finished allocating. This leaf task
    /// calls the lower layer, never its owning bridge's retirement/shutdown.
    func join(retire: Retirement?, cancel: @escaping Cancellation) -> Task<Void, Error> {
        lock.withLock {
            if let cleanup { return cleanup }
            let target = returned ?? predecessor
            let task = Task {
                guard let target else { return }
                guard let retire else {
                    // Legacy test adapters can revoke, but cannot claim a join.
                    await cancel(target.id, target.generation)
                    throw PublishingBandwidthProbeError.disabled
                }
                try await retire(target.id, target.generation)
            }
            cleanup = task
            return task
        }
    }
}

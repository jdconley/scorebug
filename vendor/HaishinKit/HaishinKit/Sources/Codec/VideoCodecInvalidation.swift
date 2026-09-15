import Foundation

/// Notifications may arrive outside the stream actor. They only replace this
/// scalar revision; codec/session mutation stays on the owning stream actor.
final class VideoCodecInvalidation: @unchecked Sendable {
    struct Snapshot {
        let revision: UUID
        let pending: Bool
    }
    private let lock = NSLock()
    private var revision = UUID()
    private var installedRevision: UUID?

    var snapshot: Snapshot {
        lock.withLock { Snapshot(revision: revision, pending: installedRevision != revision) }
    }
    func invalidate() { lock.withLock { revision = UUID() } }
    func installed(_ revision: UUID) {
        // Installing a session cannot consume an invalidation that arrived while
        // it was being created. Such a request remains pending for the next input.
        lock.withLock { installedRevision = revision }
    }
    func isCurrent(_ expected: UUID) -> Bool {
        lock.withLock { revision == expected && installedRevision == expected }
    }
}

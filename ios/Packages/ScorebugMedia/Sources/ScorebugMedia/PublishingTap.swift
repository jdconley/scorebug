import Foundation

/// Synchronous fan-out from one running recording to the current publishing
/// attempt. Reuse across reconnects, with a fresh tap for each CaptureRecording.
/// A tap retains its attached session, but never starts/stops it. The lifecycle
/// caller must detach and stop the old session when replacing it.
public final class PublishingTap: @unchecked Sendable {
    private let lock = NSLock()
    private var session: PublishingSession?
    private var closed = false
    public init() {}

    /// Replaces the attachment. False means the recording has closed this tap.
    @discardableResult public func attach(_ session: PublishingSession) -> Bool {
        var previous: PublishingSession?
        let attached = lock.withLock {
            guard !closed else { return false }
            previous = self.session
            self.session = session
            return true
        }
        withExtendedLifetime(previous) {}
        return attached
    }
    /// Identity guards old asynchronous teardown from clearing a newer attempt.
    public func detach(_ session: PublishingSession) {
        var previous: PublishingSession?
        lock.withLock {
            if self.session === session { previous = self.session; self.session = nil }
        }
        withExtendedLifetime(previous) {}
    }
    /// Only short bounded mailbox admission occurs here. No disk/network work or
    /// task is created, and publication rejection never fails the archive.
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool {
        lock.withLock { session?.offer(sample) ?? false }
    }
    // A recording permanently closes its own tap, including late attachments.
    func close() {
        let previous = lock.withLock { closed = true; let old = session; session = nil; return old }
        withExtendedLifetime(previous) {}
    }
}

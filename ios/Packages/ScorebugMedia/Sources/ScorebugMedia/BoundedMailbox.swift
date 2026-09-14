import Foundation

/// A bounded FIFO connecting synchronous producers to one asynchronous consumer.
///
/// Only queued elements count against the limits. One delivered element may also be
/// retained by the consumer; callers must budget for that element and provide an
/// accurate retained-byte estimate for every offer. This type does not infer media
/// formats, timestamps, or whether a rejected archive sample ends a recording.
/// There is no task or asynchronous stream allocated per offer.
public final class BoundedMailbox<Element: Sendable>: @unchecked Sendable {
    public enum OverflowPolicy: Sendable {
        /// Preserve queued work. The caller must handle rejection explicitly.
        case rejectNew
        /// Discard oldest queued work until the new element fits.
        case dropOldest
    }

    public enum MailboxError: Error, Equatable, Sendable {
        case invalidLimits
        case concurrentConsumer
    }

    public enum RejectionReason: Equatable, Sendable {
        case invalidBytes
        case oversize
        case full
        case finished
        case cancelled
    }

    public struct Admission: Equatable, Sendable {
        public let acceptedCount: Int
        public let rejectedCount: Int
        public let droppedCount: Int
        public let rejectionReason: RejectionReason?
        #if DEBUG
        public internal(set) var rejectionStatistics: Statistics? = nil
        #endif
    }

    /// Counts describe elements, and cumulative counters saturate at `Int.max`.
    /// `droppedCount` includes both overflow evictions and cancellation discards.
    public struct Statistics: Equatable, Sendable {
        public let currentItems: Int
        public let currentBytes: Int
        public let peakItems: Int
        public let peakBytes: Int
        public let acceptedCount: Int
        public let rejectedCount: Int
        public let droppedCount: Int
        public let hasPendingConsumer: Bool
    }

    public let maxItems: Int
    public let maxBytes: Int
    public let overflowPolicy: OverflowPolicy

    private struct Entry {
        let element: Element
        let bytes: Int
    }

    // All mutable state, including the cancellation token, is protected by lock.
    // The token records cancellation even if it precedes continuation registration.
    private final class Waiter: @unchecked Sendable {
        var cancelled = false
        var continuation: CheckedContinuation<Element?, any Error>?
    }

    private enum State { case open, finishing, cancelled }
    private let lock = NSLock()
    private var state = State.open
    private var queue: [Entry] = []
    private var queuedBytes = 0
    private var peakItems = 0
    private var peakBytes = 0
    private var acceptedCount = 0
    private var rejectedCount = 0
    private var droppedCount = 0
    private var waiter: Waiter?

    public init(maxItems: Int, maxBytes: Int, overflowPolicy: OverflowPolicy) throws {
        guard maxItems > 0, maxBytes > 0 else { throw MailboxError.invalidLimits }
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.overflowPolicy = overflowPolicy
    }

    public var statistics: Statistics {
        lock.withLock { statisticsLocked() }
    }

    /// Immediately admits or rejects the element; it never waits for a consumer.
    /// Invalid or oversized offers never evict existing elements, even with dropOldest.
    @discardableResult
    public func offer(_ element: Element, bytes: Int) -> Admission {
        var continuation: CheckedContinuation<Element?, any Error>?
        // Release evicted objects outside the lock; generic element deinitializers
        // may themselves interact with the mailbox.
        var evicted: [Entry] = []
        let admission = lock.withLock {
            guard state == .open else {
                return reject(state == .cancelled ? .cancelled : .finished)
            }
            guard bytes > 0 else { return reject(.invalidBytes) }
            guard bytes <= maxBytes else { return reject(.oversize) }

            if let pending = waiter {
                continuation = pending.continuation
                pending.continuation = nil
                waiter = nil
            } else {
                // Subtract before comparing so even Int.max budgets cannot overflow.
                if queue.count >= maxItems || queuedBytes > maxBytes - bytes {
                    guard overflowPolicy == .dropOldest else { return reject(.full) }
                    while queue.count >= maxItems || queuedBytes > maxBytes - bytes {
                        let removed = queue.removeFirst()
                        queuedBytes -= removed.bytes
                        evicted.append(removed)
                    }
                }
                queue.append(Entry(element: element, bytes: bytes))
                queuedBytes += bytes
                peakItems = max(peakItems, queue.count)
                peakBytes = max(peakBytes, queuedBytes)
            }
            acceptedCount = Self.saturatingAdd(acceptedCount, 1)
            droppedCount = Self.saturatingAdd(droppedCount, evicted.count)
            return Admission(acceptedCount: 1, rejectedCount: 0,
                             droppedCount: evicted.count, rejectionReason: nil)
        }
        continuation?.resume(returning: element)
        withExtendedLifetime(evicted) {}
        return admission
    }

    /// Waits for one element, or returns nil after finish drains / cancel discards.
    /// Only one pending next() is supported; a second pending call throws
    /// MailboxError.concurrentConsumer. Sequential calls may come from different tasks.
    /// Cancelling the waiting task throws CancellationError without closing the mailbox.
    /// If delivery wins the cancellation race, the delivered element is returned.
    public func next() async throws -> Element? {
        let token = Waiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Element?, any Error>? = lock.withLock {
                    if token.cancelled || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard waiter == nil else { return .failure(MailboxError.concurrentConsumer) }
                    if !queue.isEmpty {
                        let entry = queue.removeFirst()
                        queuedBytes -= entry.bytes
                        return .success(entry.element)
                    }
                    guard state == .open else { return .success(nil) }
                    token.continuation = continuation
                    waiter = token
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.cancelWait(token)
        }
    }

    /// Stops admission and lets the consumer drain existing queued elements.
    /// Repeated finish calls have no effect, including after cancel.
    public func finish() {
        let continuation = lock.withLock {
            guard state == .open else { return nil as CheckedContinuation<Element?, any Error>? }
            state = .finishing
            return takeWaiter()
        }
        continuation?.resume(returning: nil)
    }

    /// Permanently closes the mailbox, discards the queue, and ends a pending wait
    /// with nil. Task cancellation is separate and throws CancellationError.
    public func cancel() {
        var discarded: [Entry] = []
        let continuation = lock.withLock {
            state = .cancelled
            discarded = queue
            queue = []
            queuedBytes = 0
            droppedCount = Self.saturatingAdd(droppedCount, discarded.count)
            return takeWaiter()
        }
        continuation?.resume(returning: nil)
        withExtendedLifetime(discarded) {}
    }

    private func cancelWait(_ token: Waiter) {
        let continuation = lock.withLock {
            token.cancelled = true
            guard waiter === token else { return nil as CheckedContinuation<Element?, any Error>? }
            return takeWaiter()
        }
        continuation?.resume(throwing: CancellationError())
    }

    // Helpers below are only called while holding lock.
    private func takeWaiter() -> CheckedContinuation<Element?, any Error>? {
        let continuation = waiter?.continuation
        waiter?.continuation = nil
        waiter = nil
        return continuation
    }

    private func reject(_ reason: RejectionReason) -> Admission {
        rejectedCount = Self.saturatingAdd(rejectedCount, 1)
        #if DEBUG
        var admission = Admission(acceptedCount: 0, rejectedCount: 1, droppedCount: 0, rejectionReason: reason)
        admission.rejectionStatistics = statisticsLocked()
        return admission
        #else
        return Admission(acceptedCount: 0, rejectedCount: 1, droppedCount: 0, rejectionReason: reason)
        #endif
    }

    private func statisticsLocked() -> Statistics {
        Statistics(currentItems: queue.count, currentBytes: queuedBytes,
                   peakItems: peakItems, peakBytes: peakBytes,
                   acceptedCount: acceptedCount, rejectedCount: rejectedCount,
                   droppedCount: droppedCount, hasPendingConsumer: waiter != nil)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

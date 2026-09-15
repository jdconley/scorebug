import CoreMedia
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

    public struct Snapshot: Sendable {
        public let statistics: Statistics
        public let ingressObservation: LiveIngressObservationSnapshot?
    }

    /// Depth and observation are captured in one transaction even while a consumer
    /// dequeues. Observations measure only this mailbox, not its in-flight element.
    public var snapshot: Snapshot {
        lock.withLock {
            if let time = observationTimeLocked() { ingress?.poll(at: time) }
            return Snapshot(statistics: statisticsLocked(), ingressObservation: ingress?.snapshot)
        }
    }
    public let hasIngressObservation: Bool

    // Scalar test clock only; no injected callback executes under the mailbox lock.
    func setObservationTimeForTesting(_ time: Double?) {
        lock.withLock { observationTimeOverride = time }
    }

    public let maxItems: Int
    public let maxBytes: Int
    public let overflowPolicy: OverflowPolicy

    private struct Entry {
        let element: Element
        let bytes: Int
        let observation: LiveIngressSampleMetadata?
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
    private var ingress: LiveIngressObservationAccumulator?
    private var observationTimeOverride: Double?

    public init(maxItems: Int, maxBytes: Int, overflowPolicy: OverflowPolicy,
                ingressObservation: LiveIngressObservationConfiguration? = nil) throws {
        guard maxItems > 0, maxBytes > 0 else { throw MailboxError.invalidLimits }
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.overflowPolicy = overflowPolicy
        if let configuration = ingressObservation,
           configuration.initialPhase == .startup || configuration.initialPhase == .admitting {
            ingress = try? LiveIngressObservationAccumulator(scope: configuration.scope,
                monotonicAnchor: configuration.monotonicAnchor, maxItems: maxItems, maxBytes: maxBytes,
                windowDuration: configuration.windowDuration, completedWindowLimit: configuration.completedWindowLimit)
            ingress?.updateOccupancy(items: 0, bytes: 0, phase: configuration.initialPhase,
                                     at: configuration.monotonicAnchor)
        }
        hasIngressObservation = ingress != nil
    }

    public var statistics: Statistics {
        lock.withLock { statisticsLocked() }
    }

    /// Immediately admits or rejects the element; it never waits for a consumer.
    /// Invalid or oversized offers never evict existing elements, even with dropOldest.
    @discardableResult
    public func offer(_ element: Element, bytes: Int, observation: LiveIngressSampleMetadata? = nil) -> Admission {
        var continuation: CheckedContinuation<Element?, any Error>?
        // Release evicted objects outside the lock; generic element deinitializers
        // may themselves interact with the mailbox.
        var evicted: [Entry] = []
        let admission = lock.withLock {
            let time = observationTimeLocked()
            if let time { ingress?.poll(at: time) }
            defer { if let time { ingress?.updateOccupancy(items: queue.count, bytes: queuedBytes, at: time) } }
            guard state == .open else {
                return reject(state == .cancelled ? .cancelled : .finished, observation: observation, at: time)
            }
            guard bytes > 0 else { return reject(.invalidBytes, observation: observation, at: time) }
            guard bytes <= maxBytes else { return reject(.oversize, observation: observation, at: time) }

            if let pending = waiter {
                continuation = pending.continuation
                pending.continuation = nil
                waiter = nil
                recordLocked(.dequeued, observation, at: time)
            } else {
                // Subtract before comparing so even Int.max budgets cannot overflow.
                if queue.count >= maxItems || queuedBytes > maxBytes - bytes {
                    guard overflowPolicy == .dropOldest else { return reject(.full, observation: observation, at: time) }
                    while queue.count >= maxItems || queuedBytes > maxBytes - bytes {
                        let removed = queue.removeFirst()
                        queuedBytes -= removed.bytes
                        evicted.append(removed)
                        recordLocked(.overflowEvicted, removed.observation, at: time)
                    }
                }
                queue.append(Entry(element: element, bytes: bytes, observation: hasIngressObservation ? observation : nil))
                queuedBytes += bytes
                peakItems = max(peakItems, queue.count)
                peakBytes = max(peakBytes, queuedBytes)
            }
            acceptedCount = Self.saturatingAdd(acceptedCount, 1)
            droppedCount = Self.saturatingAdd(droppedCount, evicted.count)
            recordLocked(.admitted, observation, at: time)
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
                    let time = observationTimeLocked()
                    if let time { ingress?.poll(at: time) }
                    defer {
                        if let time {
                            ingress?.updateOccupancy(items: queue.count, bytes: queuedBytes, at: time)
                            if state == .finishing, queue.isEmpty { ingress?.close(at: time) }
                        }
                    }
                    if token.cancelled || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard waiter == nil else { return .failure(MailboxError.concurrentConsumer) }
                    if !queue.isEmpty {
                        let entry = queue.removeFirst()
                        queuedBytes -= entry.bytes
                        recordLocked(.dequeued, entry.observation, at: time)
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
            if let time = observationTimeLocked() {
                ingress?.updateOccupancy(items: queue.count, bytes: queuedBytes, phase: .draining, at: time)
                if queue.isEmpty { ingress?.close(at: time) }
            }
            return takeWaiter()
        }
        continuation?.resume(returning: nil)
    }

    /// Permanently closes the mailbox, discards the queue, and ends a pending wait
    /// with nil. Task cancellation is separate and throws CancellationError.
    public func cancel() {
        var discarded: [Entry] = []
        let continuation = lock.withLock {
            let time = observationTimeLocked()
            if let time { ingress?.poll(at: time) }
            state = .cancelled
            discarded = queue
            if time != nil {
                for entry in discarded { recordLocked(.cancellationDiscarded, entry.observation, at: time) }
            }
            queue = []
            queuedBytes = 0
            droppedCount = Self.saturatingAdd(droppedCount, discarded.count)
            if let time {
                ingress?.updateOccupancy(items: 0, bytes: 0, at: time)
                ingress?.close(at: time)
            }
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
    private func observationTimeLocked() -> Double? {
        guard hasIngressObservation else { return nil }
        return observationTimeOverride ?? ProcessInfo.processInfo.systemUptime
    }

    private func recordLocked(_ disposition: LiveIngressDisposition, _ metadata: LiveIngressSampleMetadata?, at time: Double?) {
        guard let time else { return }
        ingress?.observe(disposition, sample: metadata ?? .init(kind: .unknown, sourcePTS: .invalid), at: time)
    }

    /// The publishing owner calls this under its own readiness lock, before any
    /// consumer or producer can observe a publishing state. No callbacks occur.
    func beginObservedAdmission() {
        lock.withLock {
            guard state == .open, let time = observationTimeLocked() else { return }
            ingress?.updateOccupancy(items: queue.count, bytes: queuedBytes, phase: .admitting, at: time)
        }
    }

    private func takeWaiter() -> CheckedContinuation<Element?, any Error>? {
        let continuation = waiter?.continuation
        waiter?.continuation = nil
        waiter = nil
        return continuation
    }

    private func reject(_ reason: RejectionReason, observation: LiveIngressSampleMetadata?, at time: Double?) -> Admission {
        rejectedCount = Self.saturatingAdd(rejectedCount, 1)
        if let time {
            let measured: LiveIngressRejectionReason
            switch reason {
            case .invalidBytes: measured = .invalidBytes
            case .oversize: measured = .oversize
            case .full: measured = .full
            case .finished: measured = .finished
            case .cancelled: measured = .cancelled
            }
            recordLocked(.rejected(measured), observation, at: time)
        }
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

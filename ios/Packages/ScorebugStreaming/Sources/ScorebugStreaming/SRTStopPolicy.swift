import Foundation

/// A bounded drain allowance for Cloudflare Stream's SRT ingest.
/// An empty SRT send queue means no outstanding sender-buffer data; packets may
/// also have been dropped. It does not acknowledge transport receipt or consumption,
/// so this is not an end-to-end delivery acknowledgment.
public struct SRTStopPolicy: Sendable {
    public let totalBudget: Duration
    public let downstreamDrainAllowance: Duration

    // Allows the supported peer recovery window plus encoder finish
    // and downstream drain. A shorter peer still exits as soon as its allowance ends.
    public init(totalBudget: Duration = .seconds(6), downstreamDrainAllowance: Duration = .milliseconds(500)) {
        self.totalBudget = max(.zero, totalBudget)
        self.downstreamDrainAllowance = max(.zero, downstreamDrainAllowance)
    }

    public enum Outcome: Sendable, Equatable {
        /// Send queue was empty and the negotiated peer delay plus deployment
        /// allowance elapsed while observed health remained good. Not delivery confirmation.
        case allowanceElapsed
        case deadlineExceeded
        case cancelled
        case failed
        case statisticsUnavailable
        case notPublishing
    }

    struct Clock: Sendable {
        let now: @Sendable () -> Duration
        let sleep: @Sendable (Duration) async throws -> Void
        static var continuous: Self {
            let origin = ContinuousClock.now
            return .init(now: { origin.duration(to: .now) }, sleep: { try await Task.sleep(for: $0) })
        }
    }
    struct Snapshot: Sendable {
        let healthy: Bool
        let unacknowledgedPackets: Int
        let peerLatencyMilliseconds: Int
    }
    struct Operations: Sendable {
        let isPublishing: @Sendable () async -> Bool
        let finish: @Sendable (Duration) async -> Void
        let snapshot: @Sendable () async -> Snapshot?
        let close: @Sendable () async -> Void
    }

    func run(clock: Clock = .continuous, operations: Operations) async -> Outcome {
        let deadline = clock.now() + totalBudget
        let cancellation = StopCancellation(close: operations.close)
        let result = await withTaskCancellationHandler {
            await drain(deadline: deadline, clock: clock, operations: operations)
        } onCancel: {
            // SDK finish owns its own task. Wake it by closing on cancellation,
            // without waiting in the synchronous cancellation handler.
            cancellation.request()
        }
        // Close the request gate and join any existing cleanup. Even a delayed
        // cancellation callback cannot create work after this join.
        await cancellation.join()
        // Always close again: a reusable SDK startup may have completed late.
        await operations.close()
        return Task.isCancelled ? .cancelled : result
    }

    private func drain(deadline: Duration, clock: Clock, operations: Operations) async -> Outcome {
        if Task.isCancelled { return .cancelled }
        guard await operations.isPublishing() else { return .notPublishing }
        let remaining = deadline - clock.now()
        guard remaining > .zero else { return .deadlineExceeded }
        await operations.finish(remaining)
        var emptySince: Duration?
        while true {
            if Task.isCancelled { return .cancelled }
            guard clock.now() < deadline else { return .deadlineExceeded }
            guard let snapshot = await operations.snapshot() else { return .statisticsUnavailable }
            if Task.isCancelled { return .cancelled }
            guard snapshot.healthy else { return .failed }
            guard snapshot.unacknowledgedPackets >= 0, snapshot.unacknowledgedPackets <= Int32.max,
                  snapshot.peerLatencyMilliseconds >= 0, snapshot.peerLatencyMilliseconds <= Int32.max else {
                return .statisticsUnavailable
            }
            let now = clock.now()
            guard now < deadline else { return .deadlineExceeded }
            var sleepFor = min(.milliseconds(20), deadline - now)
            if snapshot.unacknowledgedPackets == 0 {
                if emptySince == nil { emptySince = now }
                let allowanceEnd = emptySince! + .milliseconds(snapshot.peerLatencyMilliseconds) + downstreamDrainAllowance
                if now >= allowanceEnd { return .allowanceElapsed }
                sleepFor = min(sleepFor, allowanceEnd - now)
            } else {
                emptySince = nil
            }
            do { try await clock.sleep(sleepFor) }
            catch { return .cancelled }
        }
    }
}

/// At most one cancellation cleanup task per stop, never one per media sample.
final class StopCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let close: @Sendable () async -> Void
    private var task: Task<Void, Never>?
    private var closed = false
    init(close: @escaping @Sendable () async -> Void) { self.close = close }
    func request() {
        lock.withLock {
            guard !closed else { return }
            if task == nil { task = Task { await close() } }
        }
    }
    func join() async {
        let pending = lock.withLock {
            closed = true
            return task
        }
        await pending?.value
    }
}

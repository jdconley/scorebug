@preconcurrency import AVFoundation
import Foundation

/// Invoked on the session's single worker, except cancel(), which must be safe
/// concurrently and must unblock a pending finish(). Append must return promptly;
/// false retains ownership with the session and requests retry of the same sample.
/// Cancellation must preserve committed segments for recovery from their directory.
public protocol RecordingArchiveSink: Sendable {
    func start(at timestamp: CMTime) throws
    func append(_ sample: CapturedMediaSample) throws -> Bool
    func finish() async throws -> RecoveredArchive
    func cancel()
}

public struct SegmentedArchiveSink: RecordingArchiveSink {
    public let writer: SegmentedArchiveWriter
    public init(writer: SegmentedArchiveWriter) { self.writer = writer }
    public func start(at timestamp: CMTime) throws { try writer.start(at: timestamp) }
    public func append(_ sample: CapturedMediaSample) throws -> Bool {
        try writer.append(sample.sampleBuffer, isVideo: sample.kind == .video)
    }
    public func finish() async throws -> RecoveredArchive { try await writer.finish() }
    public func cancel() { writer.cancel() }
}

public enum RecordingSessionState: Sendable { case prepared, starting, recording, stopping, finished, failed }
public enum RecordingSessionError: Error, Equatable, Sendable {
    case invalidState, invalidTimestamp, invalidRetryPolicy, overflow, backpressureTimedOut, sinkFailed, cancelled
    case captureFailed(String)
}

public struct RecordingSessionSnapshot: Sendable {
    public let state: RecordingSessionState
    public let failure: RecordingSessionError?
    public let writtenSamples: Int
    public let queue: BoundedMailbox<CapturedMediaSample>.Statistics
}

/// One offline recording, independent of match state and publishing. The callback
/// path uses short locks and bounded FIFO admission, without tasks per sample or
/// writer calls. Queue limits exclude one in-flight sample of at most maxBytes;
/// encoder/internal allocations and samples retained by other branches are separate.
///
/// start/stop waiter cancellation does not cancel recording: stop always joins the
/// same worker and drains accepted samples. Use cancel() to explicitly abandon
/// pending samples and fail. Releasing this owner also cancels, so an idle worker
/// cannot keep its session alive indefinitely. Keep this owner through stop().
public final class RecordingSession: Sendable {
    private let core: RecordingCore

    public convenience init(sink: any RecordingArchiveSink, maxItems: Int = 24,
                            maxBytes: Int = 24 * 1024 * 1024,
                            backpressureLimit: Duration = .seconds(2),
                            retryInterval: Duration = .milliseconds(2)) throws {
        try self.init(sink: sink, maxItems: maxItems, maxBytes: maxBytes,
                      backpressureLimit: backpressureLimit, retryInterval: retryInterval,
                      retryClock: .continuous)
    }

    init(sink: any RecordingArchiveSink, maxItems: Int = 24, maxBytes: Int = 24 * 1024 * 1024,
         backpressureLimit: Duration = .seconds(2), retryInterval: Duration = .milliseconds(2),
         retryClock: RecordingRetryClock) throws {
        guard backpressureLimit > .zero, retryInterval > .zero else {
            throw RecordingSessionError.invalidRetryPolicy
        }
        core = try RecordingCore(sink: sink, maxItems: maxItems, maxBytes: maxBytes,
                                 limit: backpressureLimit, interval: retryInterval, clock: retryClock)
    }

    deinit { core.cancel() }
    public var snapshot: RecordingSessionSnapshot { core.snapshot }

    /// Both tracks must use this explicit, shared source timestamp origin. Offers
    /// are rejected until startup succeeds; this instance can only start once.
    public func start(at timestamp: CMTime) async throws { try await core.start(at: timestamp) }

    /// Synchronous, non-waiting admission for AVCapture delegates. A full/oversized
    /// queue latches recording failure; stopping/failed/unstarted sessions reject.
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool { core.offer(sample) }

    /// Report capture interruption, didDrop, or malformed media; recording can no
    /// longer claim completeness. Use a constant, non-sensitive reason string.
    public func failCapture(reason: String) { core.fail(.captureFailed(reason)) }
    public func stop() async throws -> RecoveredArchive { try await core.stop() }
    public func cancel() { core.cancel() }
}

struct RecordingRetryClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void
    static var continuous: Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: { origin.duration(to: clock.now) }, sleep: { try await Task.sleep(for: $0) })
    }
}

private final class RecordingCore: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: any RecordingArchiveSink
    private let mailbox: BoundedMailbox<CapturedMediaSample>
    private let limit: Duration
    private let interval: Duration
    private let clock: RecordingRetryClock
    private var state = RecordingSessionState.prepared
    private var failure: RecordingSessionError?
    private var writtenSamples = 0
    private var task: Task<RecoveredArchive, Error>?
    private var sinkCancelled = false
    private var failureCancellationScheduled = false

    init(sink: any RecordingArchiveSink, maxItems: Int, maxBytes: Int,
         limit: Duration, interval: Duration, clock: RecordingRetryClock) throws {
        self.sink = sink; self.limit = limit; self.interval = interval; self.clock = clock
        mailbox = try BoundedMailbox(maxItems: maxItems, maxBytes: maxBytes, overflowPolicy: .rejectNew)
    }

    var snapshot: RecordingSessionSnapshot {
        lock.withLock {
            RecordingSessionSnapshot(state: state, failure: failure,
                                     writtenSamples: writtenSamples, queue: mailbox.statistics)
        }
    }

    func start(at timestamp: CMTime) async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            lock.withLock {
                guard state == .prepared else { ready.resume(throwing: RecordingSessionError.invalidState); return }
                guard timestamp.isNumeric, timestamp.seconds.isFinite else {
                    ready.resume(throwing: RecordingSessionError.invalidTimestamp); return
                }
                state = .starting
                // The worker retains only this core, never the public session owner.
                task = Task.detached { try await self.run(at: timestamp, ready: ready) }
            }
        }
    }

    func offer(_ sample: CapturedMediaSample) -> Bool {
        let accepted = lock.withLock {
            guard state == .recording else { return false }
            if mailbox.offer(sample, bytes: sample.retainedByteCount).acceptedCount == 1 { return true }
            failure = .overflow
            state = .failed
            return false
        }
        if !accepted, lock.withLock({ failure != nil }) {
            mailbox.cancel()
            scheduleFailureCancellation()
        }
        return accepted
    }

    func fail(_ error: RecordingSessionError) {
        let changed = lock.withLock {
            guard state != .finished, failure == nil else { return false }
            failure = error; state = .failed
            return true
        }
        if changed {
            mailbox.cancel()
            scheduleFailureCancellation()
        }
    }

    func cancel() {
        fail(.cancelled)
    }

    // At most one teardown dispatch per failed session, never one task per
    // sample. Task.cancel invokes cancellation handlers synchronously, so it
    // must run off the AVCapture callback even after releasing ingress locks.
    private func scheduleFailureCancellation() {
        let pending = lock.withLock {
            guard !failureCancellationScheduled, let task else { return nil as Task<RecoveredArchive, Error>? }
            failureCancellationScheduled = true
            return task
        }
        if let pending { DispatchQueue.global(qos: .utility).async { pending.cancel() } }
    }

    func stop() async throws -> RecoveredArchive {
        let pending = lock.withLock {
            guard let task else { return nil as Task<RecoveredArchive, Error>? }
            if state == .recording || state == .starting { state = .stopping }
            mailbox.finish()
            return task
        }
        guard let pending else { throw lock.withLock { failure ?? .invalidState } }
        return try await pending.value
    }

    private func checkFailure() throws {
        if let error = lock.withLock({ failure }) { throw error }
        try Task.checkCancellation()
    }

    private func run(at timestamp: CMTime, ready: CheckedContinuation<Void, Error>) async throws -> RecoveredArchive {
        try await withTaskCancellationHandler {
            var started = false
            do {
                try checkFailure()
                try sink.start(at: timestamp)
                try lock.withLock {
                    if let failure { throw failure }
                    if state == .starting { state = .recording }
                }
                started = true
                ready.resume()
                while let sample = try await mailbox.next() {
                    try checkFailure()
                    let deadline = clock.now() + limit
                    while try !sink.append(sample) {
                        try checkFailure()
                        let remaining = deadline - clock.now()
                        guard remaining > .zero else { throw RecordingSessionError.backpressureTimedOut }
                        try await clock.sleep(min(interval, remaining))
                        try checkFailure()
                        // A scheduler may resume this worker after the requested
                        // sleep deadline. Never attempt a late retry, even if the
                        // sink has become ready in the meantime.
                        guard clock.now() < deadline else { throw RecordingSessionError.backpressureTimedOut }
                    }
                    lock.withLock { writtenSamples += 1 }
                }
                try checkFailure()
                let archive = try await sink.finish()
                try lock.withLock {
                    if let failure { throw failure }
                    state = .finished
                }
                return archive
            } catch {
                fail(error as? RecordingSessionError ?? (error is CancellationError ? .cancelled : .sinkFailed))
                cancelSinkOnce()
                let latched = lock.withLock { failure! }
                if !started { ready.resume(throwing: latched) }
                throw latched
            }
        } onCancel: {
            self.cancelSinkOnce()
        }
    }

    private func cancelSinkOnce() {
        let shouldCancel = lock.withLock {
            guard !sinkCancelled else { return false }
            sinkCancelled = true
            return true
        }
        if shouldCancel { sink.cancel() }
    }
}

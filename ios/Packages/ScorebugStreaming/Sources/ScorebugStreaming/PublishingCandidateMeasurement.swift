import CoreMedia
import Foundation
import ScorebugMedia

/// A bounded same-scene measurement of a proposed publishing recipe.
public final class PublishingCandidateMeasurement: Sendable {
    public enum Reason: String, Sendable {
        case completed, cancelled, inputRejected, deadline, pressure, ownerChanged
        case publisherStopped, startupFailed, incomplete, encoderFailed
    }
    public struct Result: Sendable {
        public let id: UUID
        public let scope: VideoFrameObservationScope
        public let profile: PublishingVideoProfile
        public let reason: Reason
        public let startedAt: Double?
        public let endedAt: Double
        public let acceptedInputCount: Int
        public let firstInputPTS: CMTime?
        public let lastInputPTS: CMTime?
        public let encoding: PublishingCandidateEncoder.Result?
    }
    struct Operations: Sendable {
        let id: UUID
        let start: @Sendable () async throws -> Void
        let offer: @Sendable (CMSampleBuffer) -> Bool
        let finish: @Sendable () async -> PublishingCandidateEncoder.Result?
        let cancel: @Sendable () async -> PublishingCandidateEncoder.Result?
        var rawClosed: @Sendable (Reason) -> Void = { _ in }
        var requiresTransport: Bool = false
    }
    public let id: UUID
    public let scope: VideoFrameObservationScope
    public let profile: PublishingVideoProfile
    private let state: MeasurementState
    private let terminal: Task<Result, Never>
    public convenience init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
                            transport: PublishingCandidateTransport? = nil,
                            publishingGeneration: UInt64? = nil) throws {
        let encoder = try PublishingCandidateEncoder(scope: scope, profile: profile, transport: transport)
        self.init(scope: scope, profile: profile, operations: .init(id: encoder.id,
            start: {
                if let publishingGeneration {
                    guard transport?.arm(publishingGeneration: publishingGeneration) == true else {
                        throw MeasurementError.invalidGeneration
                    }
                }
                try await encoder.start()
            }, offer: { encoder.offer($0) },
            finish: { await encoder.finish() }, cancel: { await encoder.cancel() },
            rawClosed: { reason in
                if reason == .completed { transport?.closeRawWindow() } else { transport?.cancel() }
            }, requiresTransport: transport != nil))
    }
    init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile, operations: Operations,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         deadlineWait: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(5)) }) {
        id = operations.id; self.scope = scope; self.profile = profile
        let state = MeasurementState(id: operations.id, scope: scope, profile: profile,
            operations: operations, now: now, deadlineWait: deadlineWait)
        self.state = state
        terminal = Task {
            for await _ in state.closedSignal {}
            await state.joinStartupAndDeadline()
            let encoding: PublishingCandidateEncoder.Result?
            if state.shouldFinish { encoding = await operations.finish() }
            else { encoding = await operations.cancel() }
            return state.complete(encoding)
        }
    }
    deinit { state.cancel(.cancelled) }

    public func start() async throws {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let startup = try state.start()
                try await startup.value
                try Task.checkCancellation()
                try state.checkReady()
            } catch {
                if Task.isCancelled { state.cancel(.cancelled) }
                if state.isClosed { _ = await terminal.value }
                throw error
            }
        } onCancel: { state.cancel(.cancelled) }
    }

    /// Audio and offers outside the active window are ignored. Video is passed
    /// directly to the encoder's bounded ingress; no additional raw queue exists.
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool {
        guard sample.kind == .video else { return false }
        return state.offer(sample.sampleBuffer)
    }

    /// Revokes raw admission synchronously. Native cleanup remains joined by result().
    public func cancel(reason: Reason = .cancelled) { state.cancel(reason) }

    /// Waits for the automatic window/deadline or cancellation, including native
    /// completion. A native call already entered has no promised hard timeout.
    public func result() async -> Result {
        state.closeIfNotStarted()
        return await withTaskCancellationHandler { await terminal.value } onCancel: { state.cancel(.cancelled) }
    }
}

private enum MeasurementError: Error { case alreadyStarted, closed, invalidClock, invalidGeneration }

/// Only a short synchronous SDK offer occurs under this lock. The fixed startup,
/// deadline and terminal tasks retain this state, never the public owner.
private final class MeasurementState: @unchecked Sendable {
    typealias Reason = PublishingCandidateMeasurement.Reason
    typealias Result = PublishingCandidateMeasurement.Result
    private let lock = NSLock()
    private let id: UUID
    private let scope: VideoFrameObservationScope
    private let profile: PublishingVideoProfile
    private let operations: PublishingCandidateMeasurement.Operations
    private let now: @Sendable () -> Double
    private let deadlineWait: @Sendable () async -> Void
    let closedSignal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var startup: Task<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var rawReady = false
    private var startedAt: Double?
    private var reason: Reason?
    private var count = 0
    private var firstPTS: CMTime?, lastPTS: CMTime?
    private var result: Result?

    init(id: UUID, scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
         operations: PublishingCandidateMeasurement.Operations,
         now: @escaping @Sendable () -> Double, deadlineWait: @escaping @Sendable () async -> Void) {
        self.id = id; self.scope = scope; self.profile = profile
        self.operations = operations; self.now = now; self.deadlineWait = deadlineWait
        (closedSignal, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    }
    var isClosed: Bool { lock.withLock { reason != nil } }
    var shouldFinish: Bool { lock.withLock { reason == .completed } }

    func start() throws -> Task<Void, Error> {
        try lock.withLock {
            guard startup == nil, reason == nil else { throw MeasurementError.alreadyStarted }
            // Startup and opening AAC belong to this same bounded measurement.
            // Establish its clock before the operation can arm the transport.
            let at = now()
            guard at.isFinite, at >= 0 else {
                close(.startupFailed)
                throw MeasurementError.invalidClock
            }
            startedAt = at
            deadline = Task { [self] in
                await deadlineWait()
                if !Task.isCancelled { lock.withLock { if reason == nil { close(.deadline) } } }
            }
            let task = Task { [self] in
                do {
                    try await operations.start()
                    try Task.checkCancellation()
                    try ready()
                } catch {
                    lock.withLock { close(.startupFailed) }
                    throw error
                }
            }
            startup = task
            return task
        }
    }
    private func ready() throws {
        try lock.withLock {
            guard reason == nil else { throw MeasurementError.closed }
            guard withinDeadline() else { close(.deadline); throw MeasurementError.closed }
            rawReady = true
        }
    }
    func checkReady() throws {
        try lock.withLock { guard reason == nil else { throw MeasurementError.closed } }
    }
    /// Called under the lock; the first failure wins, but cancellation may revoke
    /// a completed input window until its joined result has been committed.
    private func close(_ next: Reason) {
        guard result == nil else { return }
        if reason == nil || reason == .completed { reason = next }
        operations.rawClosed(reason ?? next)
        continuation.finish()
    }
    func cancel(_ reason: Reason) {
        lock.withLock {
            close(reason == .completed ? .cancelled : reason)
            if result == nil { startup?.cancel() }
        }
    }
    func closeIfNotStarted() {
        lock.withLock { if startup == nil { close(.incomplete) } }
    }
    private func withinDeadline() -> Bool {
        guard let startedAt else { return false }
        let at = now()
        return at.isFinite && at >= startedAt && at - startedAt < 5
    }
    func offer(_ sample: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard rawReady, reason == nil else { return false }
            guard withinDeadline() else { close(.deadline); return false }
            let pts = sample.presentationTimeStamp
            guard pts.isNumeric, pts.timescale > 0, pts.epoch == 0, pts.value >= 0,
                  lastPTS.map({ CMTimeCompare($0, pts) < 0 }) ?? true else {
                close(.inputRejected); return false
            }
            let span = firstPTS.map { CMTimeSubtract(pts, $0) } ?? .zero
            guard span.isNumeric, CMTimeCompare(span, CMTime(value: 17, timescale: 4)) <= 0,
                  operations.offer(sample) else { close(.inputRejected); return false }
            count += 1; firstPTS = firstPTS ?? pts; lastPTS = pts
            // SDK admission is synchronous, but may cross the owner deadline.
            // Recheck before automatic close so a delayed timer cannot be beaten.
            if !withinDeadline() { close(.deadline) }
            else if CMTimeCompare(span, CMTime(value: 4, timescale: 1)) >= 0 {
                close(count >= 97 ? .completed : .incomplete)
            } else if count == 121 { close(.incomplete) }
            return true
        }
    }
    func joinStartupAndDeadline() async {
        let tasks = lock.withLock { (startup, deadline) }
        _ = try? await tasks.0?.value
        tasks.1?.cancel()
        await tasks.1?.value
    }
    func complete(_ encoding: PublishingCandidateEncoder.Result?) -> Result {
        lock.withLock {
            if let result { return result }
            var finalReason = reason ?? .incomplete
            if finalReason == .completed {
                let native = encoding?.encoding
                let matches = encoding?.scope == scope && encoding?.profile == profile
                    && native?.id == id && native?.outcome == .completed
                    && native?.acceptedInputCount == count && native?.outputCount == count
                    && native?.frames.count == count && count >= 97 && count <= 121
                    && native?.frames.first.map({ CMTimeCompare($0.sourcePTS, firstPTS ?? .invalid) == 0 }) == true
                    && native?.frames.last.map({ CMTimeCompare($0.sourcePTS, lastPTS ?? .invalid) == 0 }) == true
                if !matches { finalReason = .encoderFailed }
                if operations.requiresTransport {
                    let transport = encoding?.transport
                    let mux = transport?.mux
                    let inputs = mux?.inputs.filter { $0.media == .video } ?? []
                    let frames = native?.frames ?? []
                    let matchesTransport = transport?.outcome == .completed
                        && transport?.scope == scope && transport?.profile == profile && transport?.id == id
                        && transport?.rawInputCount == count
                        && transport?.firstRawPTS.map({ CMTimeCompare($0, firstPTS ?? .invalid) == 0 }) == true
                        && transport?.lastRawPTS.map({ CMTimeCompare($0, lastPTS ?? .invalid) == 0 }) == true
                        && mux?.outcome == .completed && mux?.videoInputCount == count
                        && mux?.audioInputCount == transport?.audio.count
                        && inputs.count == frames.count && inputs.count == count
                        && zip(inputs, frames).allSatisfy { input, frame in
                            CMTimeCompare(input.sourcePTS, frame.sourcePTS) == 0
                                && input.byteCount == frame.byteCount && input.isSync == frame.isSync
                        }
                    if !matchesTransport { finalReason = .encoderFailed }
                }
            }
            let at = now()
            if !at.isFinite || at < (startedAt ?? 0) {
                if finalReason == .completed { finalReason = .encoderFailed }
            }
            let completed = Result(id: id, scope: scope, profile: profile, reason: finalReason,
                startedAt: startedAt, endedAt: at.isFinite ? max(at, startedAt ?? 0) : startedAt ?? 0,
                acceptedInputCount: count, firstInputPTS: firstPTS, lastInputPTS: lastPTS, encoding: encoding)
            result = completed
            startup = nil; deadline = nil
            return completed
        }
    }
}

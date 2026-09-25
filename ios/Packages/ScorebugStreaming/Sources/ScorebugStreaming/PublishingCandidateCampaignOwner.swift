import Foundation
import ScorebugMedia

/// Repeated, separately owned candidate measurements under one publication.
/// Retirement joins the old pair before another pair can occupy the slot.
public actor PublishingCandidateCampaignOwner {
    public struct Handle: Sendable, Equatable {
        public let id: UUID
        public let scope: VideoFrameObservationScope
        public let profile: PublishingVideoProfile
        public let publishingGeneration: UInt64
    }

    public enum OwnerError: Error, Equatable { case busy, closed, invalidGeneration, staleIdentity }

    /// Each invocation owns a new single-use measurement and its paired transport.
    struct Operations: Sendable {
        let id: UUID
        let start: @Sendable () async throws -> Void
        let offer: @Sendable (CapturedMediaSample) -> Bool
        let observeAudio: @Sendable (SRTPublisher.CompressedAudioFrame) -> Void
        let cancel: @Sendable (PublishingCandidateMeasurement.Reason) -> Void
        let result: @Sendable () async -> PublishingCandidateMeasurement.Result
    }
    typealias Factory = @Sendable (VideoFrameObservationScope, PublishingVideoProfile, UInt64) throws -> Operations

    private let factory: Factory
    private nonisolated let router = CandidateCampaignRouter()
    private var current: CandidateCampaignEntry?
    private var retiredID: UUID?
    private var closed = false

    public init() { factory = Self.makeOperations }
    init(factory: @escaping Factory) { self.factory = factory }
    deinit { router.cancelCurrent(reason: .publisherStopped) }

    public func begin(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
                      publishingGeneration: UInt64) async throws -> Handle {
        try Task.checkCancellation()
        guard !closed else { throw OwnerError.closed }
        guard publishingGeneration > 0 else { throw OwnerError.invalidGeneration }
        guard current == nil else { throw OwnerError.busy }
        let operations = try factory(scope, profile, publishingGeneration)
        let handle = Handle(id: operations.id, scope: scope, profile: profile,
                            publishingGeneration: publishingGeneration)
        // Reserve before any suspension, including the startup and terminal tasks.
        let entry = CandidateCampaignEntry(handle: handle, operations: operations)
        current = entry
        router.install(entry)
        return try await withTaskCancellationHandler {
            do {
                guard handle.id != retiredID else {
                    entry.cancel(reason: .ownerChanged)
                    throw OwnerError.staleIdentity
                }
                guard entry.permitStartup() else { throw OwnerError.closed }
                try await entry.startup.value
                try Task.checkCancellation()
                guard entry.activate() else { throw OwnerError.closed }
                return handle
            } catch {
                entry.cancel(reason: Task.isCancelled ? .cancelled : .startupFailed)
                _ = await entry.terminal.value
                clear(entry)
                throw error
            }
        } onCancel: {
            entry.cancel(reason: .cancelled)
        }
    }

    /// Direct bounded admission; this method never starts an asynchronous task.
    @discardableResult
    public nonisolated func offer(_ sample: CapturedMediaSample, id: UUID) -> Bool {
        guard let entry = router.entry(id: id), entry.isRouting else { return false }
        return entry.operations.offer(sample)
    }

    /// Retains routing through raw closure so the paired transport can select its
    /// bounded following AAC packet. Terminal completion or revocation closes it.
    public nonisolated func observeAudio(_ frame: SRTPublisher.CompressedAudioFrame) {
        guard let entry = router.entry(), entry.isAudioRouting else { return }
        entry.operations.observeAudio(frame)
    }

    /// Withdraws synchronous routing and native raw admission for this exact pair.
    public nonisolated func cancel(id: UUID, reason: PublishingCandidateMeasurement.Reason) {
        router.entry(id: id)?.cancel(reason: reason)
    }

    public func result(id: UUID) async -> PublishingCandidateMeasurement.Result? {
        guard let entry = current, entry.handle.id == id else { return nil }
        let result = await entry.terminal.value
        // A waiter that resumes after retirement cannot replay old evidence into
        // a later attempt, even if both attempts share the publication scope.
        guard current === entry else { return nil }
        return result
    }

    public func retire(id: UUID, reason: PublishingCandidateMeasurement.Reason) async {
        guard let entry = current, entry.handle.id == id else { return }
        entry.cancel(reason: reason)
        _ = await entry.terminal.value
        clear(entry)
    }

    public func stop() async {
        closed = true
        guard let entry = current else { return }
        entry.cancel(reason: .publisherStopped)
        _ = await entry.terminal.value
        clear(entry)
    }

    private func clear(_ entry: CandidateCampaignEntry) {
        guard current === entry else { return }
        retiredID = entry.handle.id
        router.remove(entry)
        current = nil
    }

    private nonisolated static func makeOperations(scope: VideoFrameObservationScope,
                                                   profile: PublishingVideoProfile,
                                                   publishingGeneration: UInt64) throws -> Operations {
        let transport = PublishingCandidateTransport(scope: scope, profile: profile)
        let measurement = try PublishingCandidateMeasurement(scope: scope, profile: profile, transport: transport,
            publishingGeneration: publishingGeneration)
        return Operations(id: measurement.id, start: {
            try await measurement.start()
        }, offer: { measurement.offer($0) }, observeAudio: { transport.observeAudio($0) },
        cancel: { reason in measurement.cancel(reason: reason); transport.cancel() },
        result: { await measurement.result() })
    }
}

/// The pointer lock never calls media operations. A captured old entry remains
/// bound to its old single-use pair, whose cancellation rejects late callbacks.
private final class CandidateCampaignRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CandidateCampaignEntry?
    func install(_ entry: CandidateCampaignEntry) { lock.withLock { current = entry } }
    func entry(id: UUID? = nil) -> CandidateCampaignEntry? {
        lock.withLock {
            guard let current, id == nil || current.handle.id == id else { return nil }
            return current
        }
    }
    func remove(_ entry: CandidateCampaignEntry) {
        lock.withLock { if current === entry { current = nil } }
    }
    func cancelCurrent(reason: PublishingCandidateMeasurement.Reason) { entry()?.cancel(reason: reason) }
}

/// Constant control-path state: one startup and one shared terminal task. Neither
/// task retains the actor; per-frame routes retain only this exact entry.
private final class CandidateCampaignEntry: Sendable {
    let handle: PublishingCandidateCampaignOwner.Handle
    let operations: PublishingCandidateCampaignOwner.Operations
    let startup: Task<Void, Error>
    let terminal: Task<PublishingCandidateMeasurement.Result, Never>
    private let state: CandidateCampaignEntryState
    private let startupPermit: AsyncStream<Void>.Continuation

    init(handle: PublishingCandidateCampaignOwner.Handle, operations: PublishingCandidateCampaignOwner.Operations) {
        self.handle = handle
        self.operations = operations
        let state = CandidateCampaignEntryState(operations: operations)
        self.state = state
        let (permitted, permit) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        startupPermit = permit
        let startup = Task {
            // The owner installs and validates this exact entry before native
            // arming can begin. Cancellation also ends this bounded wait.
            for await _ in permitted {}
            try Task.checkCancellation()
            try await operations.start()
            try Task.checkCancellation()
        }
        self.startup = startup
        state.install(startup)
        terminal = Task {
            do { try await startup.value }
            catch { state.cancel(reason: .startupFailed) }
            let result = await operations.result()
            state.finish()
            return result
        }
    }
    var isRouting: Bool { state.isRouting }
    var isAudioRouting: Bool { state.isAudioRouting }
    func permitStartup() -> Bool {
        guard state.beginAudioRouting() else { return false }
        startupPermit.finish()
        return true
    }
    func activate() -> Bool { state.activate() }
    func cancel(reason: PublishingCandidateMeasurement.Reason) { state.cancel(reason: reason) }
}

private final class CandidateCampaignEntryState: @unchecked Sendable {
    private let lock = NSLock()
    private let operations: PublishingCandidateCampaignOwner.Operations
    private var startup: Task<Void, Error>?
    private var ready = false, audioReady = false, revoked = false, finished = false

    init(operations: PublishingCandidateCampaignOwner.Operations) { self.operations = operations }
    func install(_ task: Task<Void, Error>) {
        let cancelled = lock.withLock { startup = task; return revoked }
        if cancelled { task.cancel() }
    }
    var isRouting: Bool { lock.withLock { ready && !revoked && !finished } }
    var isAudioRouting: Bool { lock.withLock { audioReady && !revoked && !finished } }
    func beginAudioRouting() -> Bool {
        lock.withLock {
            guard !audioReady, !revoked, !finished else { return false }
            audioReady = true
            return true
        }
    }
    func activate() -> Bool {
        lock.withLock {
            guard audioReady, !revoked, !finished else { return false }
            ready = true
            return true
        }
    }
    func cancel(reason: PublishingCandidateMeasurement.Reason) {
        let action = lock.withLock { () -> (Bool, Task<Void, Error>?) in
            guard !revoked else { return (false, nil) }
            revoked = true
            return (true, startup)
        }
        guard action.0 else { return }
        action.1?.cancel()
        operations.cancel(reason == .completed ? .cancelled : reason)
    }
    func finish() { lock.withLock { finished = true; startup = nil } }
}

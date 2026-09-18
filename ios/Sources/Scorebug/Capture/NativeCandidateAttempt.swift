#if DEBUG
import Foundation
import ScorebugMedia
import ScorebugStreaming

/// One native attempt owns its begin task even before the campaign owner returns
/// an id. Cancellation and retirement always join that exact task and owner.
final class NativeCandidateAttempt: @unchecked Sendable {
    struct Operations: Sendable {
        let begin: @Sendable () async throws -> UUID
        let offer: @Sendable (CapturedMediaSample, UUID) -> Bool
        let cancel: @Sendable (UUID, PublishingCandidateMeasurement.Reason) -> Void
        let result: @Sendable (UUID) async -> PublishingCandidateMeasurement.Result?
        let retire: @Sendable (UUID, PublishingCandidateMeasurement.Reason) async -> Void
    }
    private let operations: Operations
    private let lock = NSLock()
    private var startup: Task<UUID, Error>?
    private var retirement: Task<Void, Never>?
    private var handle: UUID?
    private var cancellation: PublishingCandidateMeasurement.Reason?
    private var cancellationSent = false

    init(operations: Operations) { self.operations = operations }
    convenience init(owner: PublishingCandidateCampaignOwner, publisher: any MediaPublisher,
                     scope: VideoFrameObservationScope, liveProfile: PublishingVideoProfile,
                     candidate: PublishingVideoProfile) {
        self.init(operations: .init(begin: {
            guard let startup = publisher.videoStartup, startup.profile == liveProfile else {
                throw PublishingSessionError.invalidState
            }
            return try await owner.begin(scope: scope, profile: candidate,
                publishingGeneration: startup.publishingGeneration).id
        }, offer: { owner.offer($0, id: $1) }, cancel: { owner.cancel(id: $0, reason: $1) },
        result: { await owner.result(id: $0) }, retire: { await owner.retire(id: $0, reason: $1) }))
    }
    func start() async throws {
        let task = try lock.withLock {
            guard startup == nil, cancellation == nil else { throw PublishingSessionError.invalidState }
            let begin = operations.begin
            let task = Task { try await begin() }
            startup = task
            return task
        }
        do {
            let id = try await withTaskCancellationHandler { try await task.value } onCancel: { self.cancel(.cancelled) }
            try Task.checkCancellation()
            let admitted = lock.withLock { handle = id; return cancellation == nil }
            guard admitted else { throw CancellationError() }
        } catch {
            cancel(.cancelled)
            await retire()
            throw error
        }
    }
    @discardableResult func offer(_ sample: CapturedMediaSample) -> Bool {
        let id = lock.withLock { cancellation == nil ? handle : nil }
        guard let id else { return false }
        return operations.offer(sample, id)
    }
    func cancel(_ reason: PublishingCandidateMeasurement.Reason) {
        let (task, id) = lock.withLock {
            if cancellation == nil { cancellation = reason == .completed ? .cancelled : reason }
            return (startup, handle)
        }
        task?.cancel()
        if let id { sendCancellation(id) }
    }
    private func sendCancellation(_ id: UUID) {
        let reason = lock.withLock { () -> PublishingCandidateMeasurement.Reason? in
            guard !cancellationSent, let cancellation else { return nil }
            cancellationSent = true
            return cancellation
        }
        if let reason { operations.cancel(id, reason) }
    }
    func result() async -> PublishingCandidateMeasurement.Result? {
        guard let startup = lock.withLock({ startup }) else { return nil }
        return await withTaskCancellationHandler {
            guard let id = try? await startup.value else { return nil }
            return await operations.result(id)
        } onCancel: { self.cancel(.cancelled) }
    }
    func retire() async {
        cancel(.ownerChanged)
        let task = lock.withLock { () -> Task<Void, Never> in
            if let retirement { return retirement }
            let startup = startup, reason = cancellation ?? .ownerChanged
            let task = Task { [self] in
                guard let startup, let id = try? await startup.value else { return }
                sendCancellation(id)
                await operations.retire(id, reason)
            }
            retirement = task
            return task
        }
        await task.value
    }
}
#endif

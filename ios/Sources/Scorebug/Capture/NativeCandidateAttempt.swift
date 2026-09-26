import Foundation
import ScorebugMedia
import ScorebugStreaming

struct NativeCandidatePressure: Sendable {
    let observedAt: Double, sampledAt: Double
    let thermal: Int, dropped: Int, rejected: Int
    let publishing: Bool
    var valid: Bool {
        observedAt.isFinite && sampledAt.isFinite && observedAt >= sampledAt && sampledAt >= 0 &&
        observedAt - sampledAt <= 2 && (0...1).contains(thermal) && dropped >= 0 && rejected >= 0 && publishing
    }
    #if DEBUG
    var object: [String: Any] {
        ["observedAt": observedAt, "sampledAt": sampledAt, "thermal": thermal, "dropped": dropped, "rejected": rejected, "publishing": publishing]
    }
    #endif
    init(observedAt: Double, sampledAt: Double, thermal: Int, dropped: Int, rejected: Int, publishing: Bool) {
        self.observedAt = observedAt; self.sampledAt = sampledAt; self.thermal = thermal
        self.dropped = dropped; self.rejected = rejected; self.publishing = publishing
    }
    init?(_ snapshot: PublishingSessionSnapshot?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let snapshot, let sample = snapshot.thermalObservation.freshSample(at: now) else { return nil }
        self.init(observedAt: now, sampledAt: sample.sampledAt, thermal: sample.state.rawValue,
            dropped: snapshot.queue.droppedCount, rejected: snapshot.queue.rejectedCount,
            publishing: snapshot.state == .publishing && snapshot.failure == nil)
    }
}

struct NativeCandidateSnapshot: Sendable {
    let cost: PublishingCandidateCost
    let binding: PublishingProbeObservation
    let probe: PublishingProbeObservation
    let boundAt: Double
    let completedAt: Double
    let permitsCurrentCandidate: @Sendable (UUID) -> Bool
}

/// An explicitly selected bounded campaign. Holds follow each allocation; the
/// final hold preserves the existing 0.5-second settling before immutable binding. Native deadlines and budgets
/// remain authoritative, including while waiting for fresh source coverage.
struct NativeCandidateStagePlan: Sendable, Equatable {
    enum Failure: Error { case invalidPlan }
    let bitRates: [Int]
    let holds: [Double]
    var finalStage: UInt32 { UInt32(bitRates.count) }
    init(bitRates: [Int], holds: [Double]) throws {
        guard (1...32).contains(bitRates.count), holds.count == bitRates.count,
              bitRates.allSatisfy({ (1...12_000_000).contains($0) }),
              holds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              holds.last! >= 0.5, holds.reduce(0, +) < 60 else { throw Failure.invalidPlan }
        self.bitRates = bitRates; self.holds = holds
    }
    #if DEBUG
    static let laboratory = try! Self(bitRates: [500_000, 2_000_000, 12_000_000], holds: [0.8, 0.8, 0.5])
    #endif
}

/// One native attempt owns its begin task even before the campaign owner returns
/// an id. Cancellation and retirement always join that exact task and owner.
final class NativeCandidateAttempt: @unchecked Sendable {
    struct Operations: Sendable {
        let begin: @Sendable (PublishingQualitySession.CandidateMeasurementContext?) async throws -> UUID
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
    convenience init(operations: Operations, scope: VideoFrameObservationScope,
                     candidate: PublishingVideoProfile,
                     contextProvider: @escaping @Sendable () async -> PublishingQualitySession.CandidateMeasurementContext?) {
        self.init(operations: .init(begin: { _ in
            try Task.checkCancellation()
            let before = await contextProvider()
            try Task.checkCancellation()
            guard let before, Self.valid(before, scope: scope, candidate: candidate) else {
                throw PublishingSessionError.invalidState
            }
            let id = try await operations.begin(before)
            do {
                try Task.checkCancellation()
                let after = await contextProvider()
                try Task.checkCancellation()
                guard let after, Self.valid(after, scope: scope, candidate: candidate),
                      Self.sameConfiguration(before, after) else { throw PublishingSessionError.invalidState }
                return id
            } catch {
                // Failed begin cannot return its UUID to the outer attempt. Keep
                // this exact allocation owned until native retirement completes.
                let reason: PublishingCandidateMeasurement.Reason = Task.isCancelled ? .cancelled : .ownerChanged
                operations.cancel(id, reason)
                await operations.retire(id, reason)
                throw error
            }
        }, offer: operations.offer, cancel: operations.cancel, result: operations.result, retire: operations.retire))
    }
    convenience init(owner: PublishingCandidateCampaignOwner, scope: VideoFrameObservationScope,
                     candidate: PublishingVideoProfile,
                     contextProvider: @escaping @Sendable () async -> PublishingQualitySession.CandidateMeasurementContext?) {
        self.init(operations: .init(begin: { context in
            guard let context else { throw PublishingSessionError.invalidState }
            return try await owner.begin(scope: scope, profile: candidate,
                publishingGeneration: context.applied.receipt.publishingGeneration).id
        }, offer: { owner.offer($0, id: $1) }, cancel: { owner.cancel(id: $0, reason: $1) },
        result: { await owner.result(id: $0) }, retire: { await owner.retire(id: $0, reason: $1) }),
        scope: scope, candidate: candidate, contextProvider: contextProvider)
    }
    static func valid(_ context: PublishingQualitySession.CandidateMeasurementContext,
                              scope: VideoFrameObservationScope, candidate: PublishingVideoProfile) -> Bool {
        let readiness = context.readiness, applied = context.applied
        return context.scope == scope && readiness.attemptID == scope.publishingAttemptID
            && readiness.settings.profileID == candidate.rawValue && readiness.settings.videoBitrate == candidate.bitRate
            && applied.attemptID == readiness.attemptID && applied.revision == readiness.appliedRevision
            && applied.settings == readiness.baseline && applied.settings.videoBitrate == applied.receipt.configuration.bitRate
            && context.clock.publishingGeneration == applied.receipt.publishingGeneration
            && applied.acknowledgedAt.isFinite && applied.acknowledgedAt >= applied.receipt.acceptedAt
    }
    static func sameConfiguration(_ before: PublishingQualitySession.CandidateMeasurementContext,
                                          _ after: PublishingQualitySession.CandidateMeasurementContext) -> Bool {
        let old = before.readiness, new = after.readiness
        let oldApplied = before.applied, newApplied = after.applied
        let oldReceipt = oldApplied.receipt, newReceipt = newApplied.receipt
        return before.scope == after.scope && before.clock == after.clock
            && old.attemptID == new.attemptID && old.appliedRevision == new.appliedRevision
            && old.baseline == new.baseline && old.settings == new.settings && old.healthySince == new.healthySince
            && new.healthSequence >= old.healthSequence && new.healthyThrough >= old.healthyThrough
            && oldApplied.attemptID == newApplied.attemptID && oldApplied.revision == newApplied.revision
            && oldApplied.settings == newApplied.settings && oldApplied.acknowledgedAt == newApplied.acknowledgedAt
            && oldReceipt.publishingGeneration == newReceipt.publishingGeneration
            && oldReceipt.configuration == newReceipt.configuration && oldReceipt.acceptedAt == newReceipt.acceptedAt
            && oldReceipt.lastSubmittedSourcePTS == newReceipt.lastSubmittedSourcePTS
    }
    convenience init(owner: PublishingCandidateCampaignOwner, publisher: any MediaPublisher,
                     scope: VideoFrameObservationScope, liveProfile: PublishingVideoProfile,
                     candidate: PublishingVideoProfile) {
        self.init(operations: .init(begin: { _ in
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
            let task = Task { try await begin(nil) }
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

/// Capture owns the lifetime; installing once binds a provider without retaining
/// an advisory context across asynchronous native startup.
final class NativeCandidateContextReader: @unchecked Sendable {
    typealias Provider = @Sendable () async -> PublishingQualitySession.CandidateMeasurementContext?
    private let lock = NSLock()
    private var provider: Provider?
    private var closed = false
    private var revision: UInt64 = 0
    private var waiter: (id: UUID, continuation: AsyncStream<Void>.Continuation)?

    var readinessRevision: UInt64 { lock.withLock { revision } }
    var readinessWaitIsPending: Bool { lock.withLock { waiter != nil } }

    /// Notifications carry no authority. A single candidate consumer re-reads
    /// its probe and context after waking; multiple notifications coalesce.
    func signalMeasurementReadinessChanged() {
        let continuation = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard !closed else { return nil }
            revision += 1
            let continuation = waiter?.continuation
            waiter = nil
            return continuation
        }
        continuation?.finish()
    }

    /// Capture the revision before any asynchronous probe/context reads, so a
    /// change during those reads cannot be lost before waiter registration.
    func wait(after observedRevision: UInt64, timeout: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let previous = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard !closed, revision == observedRevision else { return pair.continuation }
            let previous = waiter?.continuation
            waiter = (id, pair.continuation)
            return previous
        }
        // Keep one waiter even if an overlapping consumer replaces this one.
        previous?.finish()
        defer {
            lock.withLock { if waiter?.id == id { waiter = nil } }
            pair.continuation.finish()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in pair.stream {} }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        // The task group joins both cancellation-aware children, including the
        // losing timer, before removing this waiter's final reference.
        try Task.checkCancellation()
    }

    @discardableResult func install(_ provider: @escaping Provider) -> Bool {
        lock.withLock {
            guard !closed, self.provider == nil else { return false }
            self.provider = provider
            return true
        }
    }
    func read() async -> PublishingQualitySession.CandidateMeasurementContext? {
        guard let provider = lock.withLock({ closed ? nil : provider }) else { return nil }
        let context = await provider()
        return lock.withLock { closed ? nil : context }
    }
    func close() {
        let continuation = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            closed = true; provider = nil
            let continuation = waiter?.continuation
            waiter = nil
            return continuation
        }
        continuation?.finish()
    }
}

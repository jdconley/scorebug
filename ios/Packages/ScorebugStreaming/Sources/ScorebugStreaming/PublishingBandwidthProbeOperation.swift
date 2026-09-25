import Foundation

struct PublishingOwnedProbeRequest: Sendable {
    enum Kind: Sendable { case begin, replace, restart }
    let kind: Kind
    let bitRate: Int
    let policy: PublishingBandwidthProbeSnapshot.Policy
}

/// Joined cleanup evidence. Only its issuing publisher can consume it once to
/// reserve a successor. It grants no live authority or measured capacity.
public final class PublishingBandwidthProbeRetirement: @unchecked Sendable {
    let issuer: UUID
    let operationID: UUID
    let lineageContext: PublishingBandwidthProbeContext
    /// Diagnostic projection of the actual joined terminal. It grants no live
    /// authority or continuation; only this opaque receipt can reserve a successor.
    public var terminalSnapshot: PublishingBandwidthProbeSnapshot? { terminal }
    let terminal: PublishingBandwidthProbeSnapshot?
    let lower: PublishingBandwidthProbeRetirement?
    let eligible: Bool
    let policy: PublishingBandwidthProbeSnapshot.Policy
    private let lock = NSLock()
    private var consumed = false
    var isAvailable: Bool { lock.withLock { eligible && !consumed } }
    init(issuer: UUID, operationID: UUID, lineageContext: PublishingBandwidthProbeContext,
         terminal: PublishingBandwidthProbeSnapshot?, lower: PublishingBandwidthProbeRetirement?, eligible: Bool,
         policy: PublishingBandwidthProbeSnapshot.Policy) {
        self.issuer = issuer; self.operationID = operationID; self.lineageContext = lineageContext
        self.terminal = terminal; self.lower = lower; self.eligible = eligible
        self.policy = policy
    }
    func consume() throws {
        try lock.withLock {
            guard eligible, !consumed else { throw PublishingBandwidthProbeError.obsolete }
            consumed = true
        }
    }
}

/// Starts before native allocation. Public callers cannot construct handles,
/// install snapshots, or turn cancellation into proof of joined cleanup.
public final class PublishingBandwidthProbeOperation: @unchecked Sendable {
    struct Native: Sendable {
        let validate: @Sendable (UUID) async throws -> Void
        let allocate: @Sendable (PublishingOwnedProbeRequest, PublishingBandwidthProbeSnapshot?) async throws -> PublishingBandwidthProbeSnapshot
        let renew: @Sendable (UUID, UInt64) async throws -> PublishingBandwidthProbeSnapshot
        let cancel: @Sendable (UUID, UInt64) async -> Void
        let retire: @Sendable (UUID, UInt64) async throws -> PublishingBandwidthProbeSnapshot
    }
    struct Lower: Sendable {
        let validate: @Sendable (UUID) async throws -> Void
        let allocate: @Sendable (PublishingOwnedProbeRequest, PublishingBandwidthProbeRetirement?) async throws -> PublishingBandwidthProbeOperation
    }
    enum Backend: Sendable { case native(Native), lower(Lower) }
    private enum Dispatch { case none, pending, preinstallFailure, returned, unknown }
    let id = UUID()
    private let createdAt = ProcessInfo.processInfo.systemUptime
    let issuer: UUID
    let context: PublishingBandwidthProbeContext
    private let request: PublishingOwnedProbeRequest
    private let predecessor: PublishingBandwidthProbeRetirement?
    private let backend: Backend
    private let lock = NSLock()
    private var initial: Task<PublishingBandwidthProbeSnapshot, Error>?
    private var renewal: (id: UUID, task: Task<PublishingBandwidthProbeSnapshot, Error>)?
    private var retiring: Task<PublishingBandwidthProbeRetirement, Error>?
    private var cleanup: Task<PublishingBandwidthProbeRetirement, Error>?
    private var completedReceipt: PublishingBandwidthProbeRetirement?
    private var cancellation: Task<Void, Never>?
    private var revoked = false
    private var dispatch = Dispatch.none
    private var raw: PublishingBandwidthProbeSnapshot?
    private var lineage: PublishingBandwidthProbeSnapshot?
    private var accepted: PublishingBandwidthProbeSnapshot?
    private var lower: PublishingBandwidthProbeOperation?
    private var lowerTrusted = false
    private var lineageRejected = false
    private var upperOwner: UUID?

    init(issuer: UUID, context: PublishingBandwidthProbeContext, request: PublishingOwnedProbeRequest,
         predecessor: PublishingBandwidthProbeRetirement?, backend: Backend) {
        self.issuer = issuer; self.context = context; self.request = request
        self.predecessor = predecessor; self.backend = backend
    }

    // Called synchronously by the actor factory after reserving its current slot.
    func start() {
        lock.withLock {
            precondition(initial == nil)
            initial = Task { try await self.allocate() }
        }
    }
    func owns(_ receipt: PublishingBandwidthProbeRetirement) -> Bool {
        lock.withLock { receipt.issuer == issuer && receipt.operationID == id && completedReceipt === receipt }
    }
    private func bind(to upper: UUID, context: PublishingBandwidthProbeContext?, request: PublishingOwnedProbeRequest,
                      predecessor: PublishingBandwidthProbeRetirement?, requestedAt: Double) -> Bool {
        lock.withLock {
            guard upperOwner == nil, self.context === context, issuer == context?.issuer,
                  self.request.kind == request.kind, self.request.bitRate == request.bitRate,
                  self.request.policy == request.policy, self.predecessor === predecessor,
                  createdAt >= requestedAt else { return false }
            upperOwner = upper
            return true
        }
    }
    private func checkActive() throws {
        guard !Task.isCancelled, !lock.withLock({ revoked }) else { throw PublishingBandwidthProbeError.cancelled }
    }
    private func validate() async throws {
        try checkActive()
        switch backend {
        case .native(let native): try await native.validate(id)
        case .lower(let lower): try await lower.validate(id)
        }
        try checkActive()
    }
    private func live(_ value: PublishingBandwidthProbeSnapshot) throws {
        guard value.isOwnedLive(at: ProcessInfo.processInfo.systemUptime) else { throw PublishingBandwidthProbeError.obsolete }
    }

    public func value() async throws -> PublishingBandwidthProbeSnapshot {
        guard let initial = lock.withLock({ initial }) else { throw PublishingBandwidthProbeError.busy }
        return try await withTaskCancellationHandler {
            do {
                _ = try await initial.value
                try await validate()
                guard let value = lock.withLock({ accepted }) else { throw PublishingBandwidthProbeError.obsolete }
                try live(value)
                return value
            } catch {
                // This external waiter is not the initial task. Retirement can
                // join that task and any concurrent renewal without self-await.
                _ = try? await retire()
                throw publishingProbeError(error)
            }
        } onCancel: { self.revoke() }
    }

    public func renew() async throws -> PublishingBandwidthProbeSnapshot {
        let token = UUID()
        let task: Task<PublishingBandwidthProbeSnapshot, Error> = try lock.withLock {
            guard !revoked, accepted != nil else { throw PublishingBandwidthProbeError.obsolete }
            guard renewal == nil else { throw PublishingBandwidthProbeError.busy }
            let task = Task { try await self.performRenewal() }
            renewal = (token, task)
            return task
        }
        defer { lock.withLock { if renewal?.id == token { renewal = nil } } }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try await validate(); try live(result)
                return result
            } catch {
                // The owned renewal task has completed; this wrapper is not
                // captured by retirement. Its final validation can fail too.
                _ = try? await retire()
                throw publishingProbeError(error)
            }
        } onCancel: { self.revoke() }
    }

    // Local revocation is synchronous; native/lower cancellation is nonjoining.
    func revoke() {
        lock.withLock {
            revoked = true; accepted = nil; initial?.cancel(); renewal?.task.cancel()
            guard cancellation == nil else { return }
            let raw = self.raw, lower = lowerTrusted ? self.lower : nil, backend = self.backend
            cancellation = Task.detached {
                switch backend {
                case .native(let native): if let raw { await native.cancel(raw.id, raw.publishingGeneration) }
                case .lower: await lower?.cancel()
                }
            }
        }
    }
    public func cancel() async {
        revoke()
        let cancellation = lock.withLock { self.cancellation }
        await cancellation?.value
    }

    /// The detached join is shielded from any waiter cancellation. Its leaf never
    /// calls this method or its publisher's stop, avoiding allocation self-await.
    public func retire() async throws -> PublishingBandwidthProbeRetirement {
        revoke()
        let task = lock.withLock { () -> Task<PublishingBandwidthProbeRetirement, Error> in
            if let retiring { return retiring }
            revoked = true; accepted = nil
            let initial = initial, renewal = renewal?.task
            let cancellation = cancellation
            initial?.cancel(); renewal?.cancel()
            let task = Task.detached {
                await cancellation?.value
                _ = await initial?.result
                _ = await renewal?.result
                return try await self.joinLeaf().value
            }
            retiring = task
            return task
        }
        return try await task.value
    }

    private func allocate() async throws -> PublishingBandwidthProbeSnapshot {
        do {
            try await validate()
            let requestedAt = ProcessInfo.processInfo.systemUptime
            try checkActive()
            lock.withLock { dispatch = .pending }
            let value: PublishingBandwidthProbeSnapshot
            switch backend {
            case .native(let native):
                do { value = try await native.allocate(request, predecessor?.terminal) }
                catch { lock.withLock { dispatch = .preinstallFailure }; throw error }
                // Direct pinned SDK return is the trust root, before any checks or await.
                lock.withLock { raw = value; dispatch = .returned }
            case .lower(let downstream):
                let handle: PublishingBandwidthProbeOperation
                let lowerRequest = PublishingOwnedProbeRequest(kind: predecessor?.lower == nil ? .begin : request.kind,
                    bitRate: request.bitRate, policy: request.policy)
                do { handle = try await downstream.allocate(request, predecessor?.lower) }
                catch {
                    let proven = (error as? PublishingOwnedFactoryRejection)?.matches(
                        context: context.lower, predecessor: predecessor?.lower, request: lowerRequest) == true
                    lock.withLock { dispatch = proven ? .preinstallFailure : .unknown }
                    throw error
                }
                lock.withLock { lower = handle; dispatch = .returned }
                guard handle.bind(to: id, context: context.lower, request: lowerRequest,
                    predecessor: predecessor?.lower, requestedAt: requestedAt) else {
                    throw PublishingBandwidthProbeError.obsolete
                }
                lock.withLock { lowerTrusted = true }
                try checkActive()
                value = try await handle.value()
                lock.withLock { raw = value }
            }
            guard value.isOwnedAllocation(request, predecessor: predecessor?.terminal,
                generation: context.selected.publishingGeneration, requestedAt: requestedAt,
                observedAt: ProcessInfo.processInfo.systemUptime) else {
                lock.withLock { lineageRejected = true }
                throw PublishingBandwidthProbeError.obsolete
            }
            lock.withLock { lineage = value }
            // A revoked late allocation is cleaned before entering another health read.
            try await validate(); try live(value)
            try lock.withLock {
                guard !revoked else { throw PublishingBandwidthProbeError.cancelled }
                accepted = value
            }
            return value
        } catch {
            revoke()
            // Preserve operation error independently of a retained cleanup failure.
            _ = try? await joinLeaf().value
            throw publishingProbeError(error)
        }
    }

    private func performRenewal() async throws -> PublishingBandwidthProbeSnapshot {
        do {
            try await validate()
            guard let prior = lock.withLock({ lineage }) else { throw PublishingBandwidthProbeError.obsolete }
            let value: PublishingBandwidthProbeSnapshot
            switch backend {
            case .native(let native): value = try await native.renew(prior.id, prior.publishingGeneration)
            case .lower:
                guard let lower = lock.withLock({ lower }) else { throw PublishingBandwidthProbeError.obsolete }
                value = try await lower.renew()
            }
            guard value.isOwnedProgress(of: prior, observedAt: ProcessInfo.processInfo.systemUptime) else {
                throw PublishingBandwidthProbeError.obsolete
            }
            lock.withLock { lineage = value }
            try await validate(); try live(value)
            try lock.withLock {
                guard !revoked else { throw PublishingBandwidthProbeError.cancelled }
                accepted = value
            }
            return value
        } catch {
            revoke(); _ = try? await joinLeaf().value
            throw publishingProbeError(error)
        }
    }

    private func joinLeaf() -> Task<PublishingBandwidthProbeRetirement, Error> {
        lock.withLock {
            if let cleanup { return cleanup }
            let raw = raw, lineage = lineage, lower = lower, dispatch = dispatch
            let lowerTrusted = lowerTrusted, lineageRejected = lineageRejected, cancellation = cancellation
            let task = Task.detached { () throws -> PublishingBandwidthProbeRetirement in
                await cancellation?.value
                let terminal: PublishingBandwidthProbeSnapshot?
                let lowerReceipt: PublishingBandwidthProbeRetirement?
                let eligible: Bool
                switch self.backend {
                case .native(let native):
                    lowerReceipt = nil
                    if let raw {
                        terminal = try await native.retire(raw.id, raw.publishingGeneration)
                        eligible = lineage.map { terminal!.isOwnedTerminal(of: $0,
                            observedAt: ProcessInfo.processInfo.systemUptime) } ?? false
                    } else {
                        guard dispatch == .none || dispatch == .preinstallFailure else { throw PublishingBandwidthProbeError.failed }
                        terminal = self.predecessor?.terminal; eligible = self.predecessor?.eligible ?? true
                    }
                case .lower:
                    if let lower {
                        guard lowerTrusted else { throw PublishingBandwidthProbeError.obsolete }
                        let receipt = try await lower.retire()
                        guard lower.owns(receipt) else { throw PublishingBandwidthProbeError.obsolete }
                        lowerReceipt = receipt; terminal = receipt.terminal; eligible = receipt.eligible && !lineageRejected
                    } else {
                        guard dispatch == .none || dispatch == .preinstallFailure else { throw PublishingBandwidthProbeError.failed }
                        lowerReceipt = self.predecessor?.lower; terminal = self.predecessor?.terminal
                        eligible = self.predecessor?.eligible ?? true
                    }
                }
                // A failed restart must not relabel its old campaign's configuration.
                let inherited = terminal?.id == self.predecessor?.terminal?.id && terminal != nil
                let lineageContext = inherited ? self.predecessor!.lineageContext : self.context
                let receipt = PublishingBandwidthProbeRetirement(issuer: self.issuer, operationID: self.id,
                    lineageContext: lineageContext, terminal: terminal, lower: lowerReceipt, eligible: eligible, policy: self.request.policy)
                self.lock.withLock { self.completedReceipt = receipt }
                return receipt
            }
            cleanup = task
            return task
        }
    }
}

/// Emitted only by the native adapter's synchronous pre-reservation guards.
/// A generic downstream error is never proof that no allocation occurred.
struct PublishingOwnedFactoryRejection: Error {
    let context: PublishingBandwidthProbeContext
    let predecessor: PublishingBandwidthProbeRetirement?
    let request: PublishingOwnedProbeRequest
    let reason: PublishingBandwidthProbeError
    func matches(context: PublishingBandwidthProbeContext?, predecessor: PublishingBandwidthProbeRetirement?, request: PublishingOwnedProbeRequest) -> Bool {
        self.context === context && self.predecessor === predecessor && self.request.kind == request.kind &&
            self.request.bitRate == request.bitRate && self.request.policy == request.policy
    }
}

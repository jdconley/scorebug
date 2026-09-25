import Foundation
import ScorebugMedia
import SRTHaishinKit

/// One terminal SRT attempt for PublishingSession. Configuration, connection and
/// shutdown may overlap: stopping prevents late readiness and joins one shielded
/// close task. Construct a fresh instance for a later attempt. Capture callbacks
/// feed PublishingSession's bounded mailbox, never this actor directly.
public actor SRTMediaPublisher: MediaPublisher {
    public enum PublisherError: Error, Equatable, Sendable {
        case invalidState, cancelled, startFailed, appendFailed, invalidSample, notPublishing, bitRateUpdateFailed, profileUpdateFailed
    }
    public typealias TransportMetrics = (rttMilliseconds: Double, droppedPackets: Int32, sentBytes: UInt64)
    private enum State { case prepared, starting, publishing, stopped }
    public nonisolated let videoCost: PublishingVideoCostOwner?
    private nonisolated let startupRead: @Sendable () -> PublishingVideoStartup?
    public nonisolated var videoStartup: PublishingVideoStartup? { startupRead() }
    private let operations: Operations
    private var state = State.prepared
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?
    private var probeOperation: Task<PublishingBandwidthProbeSnapshot, Error>?
    private var probeIdentity: PublishingBandwidthProbeSnapshot?
    private var probeOwner: PublishingProbeOperationOwner?
    private var probeRetirement: (owner: PublishingProbeOperationOwner, task: Task<Void, Error>)?
    private var probeRetiring = false
    private var probeCleanupFailed = false
    private var probeRevision: UInt64 = 0
    private var encoderUpdating = false
    private var profileChange: Task<PublishingVideoProfileChange, Error>?

    /// The destination is captured in an opaque operation, never in error text or
    /// a persistent/public diagnostic state. The control-plane client validates it.
    public init(url: URL, stopPolicy: SRTStopPolicy = .init(), observations: VideoFrameObservationOwner? = nil,
                encoderConfigurationObserver: (@Sendable (SRTPublisher.EncoderFrame) -> Void)? = nil,
                videoProfile: PublishingVideoProfile = .hd1080,
                compressedVideoObserver: (@Sendable (SRTPublisher.CompressedVideoFrame) -> Void)? = nil,
                compressedAudioObserver: (@Sendable (SRTPublisher.CompressedAudioFrame) -> Void)? = nil,
                muxedPacketObserver: (@Sendable (SRTPublisher.MuxedPacketFrame) -> Void)? = nil,
                didStop: (@Sendable () -> Void)? = nil, pacesEncodedVideo: Bool = false,
                allowsBandwidthProbes: Bool = false, videoCost: PublishingVideoCostOwner? = nil,
                healthObserver: (@Sendable (SRTPublisher.HealthSnapshot) -> Void)? = nil,
                transportSendObserver: (@Sendable (SRTPublisher.TransportSendObservation) -> Void)? = nil,
                encoderSubmissionObserver: (@Sendable (SRTPublisher.EncoderSubmission) -> Void)? = nil) {
        let adapter = SRTPublisher(stopPolicy: stopPolicy, observations: observations,
            encoderConfigurationObserver: encoderConfigurationObserver, videoProfile: videoProfile,
            compressedVideoObserver: compressedVideoObserver, compressedAudioObserver: compressedAudioObserver,
            muxedPacketObserver: muxedPacketObserver,
            pacesEncodedVideo: pacesEncodedVideo,
            allowsBandwidthProbes: allowsBandwidthProbes, videoCost: videoCost, healthObserver: healthObserver, transportSendObserver: transportSendObserver,
            encoderSubmissionObserver: encoderSubmissionObserver)
        self.videoCost = adapter.videoCost
        self.startupRead = { adapter.videoStartup }
        operations = Operations(configure: { try await adapter.configure() },
            start: { try await adapter.start(url) },
            append: { sample in
                switch sample.kind {
                case .video: await adapter.video(sample.sampleBuffer)
                case .audio:
                    guard let (pcm, when) = copyPCM(sample.sampleBuffer) else { throw PublisherError.invalidSample }
                    await adapter.audio(pcm, when: when)
                }
            }, isPublishing: { await adapter.isPublishing() }, stop: { await adapter.stop(); didStop?() },
            setBitRate: { try await adapter.setBitRateWithReceipt($0) }, metrics: { await adapter.metrics() },
            setProfile: { try await adapter.setVideoProfile($0) },
            transportClock: { await adapter.transportClock() }, transportStatistics: { await adapter.transportStatistics() },
            beginProbe: { try await adapter.beginBandwidthProbe(bitRate: $0) },
            renewProbe: { try await adapter.renewBandwidthProbe(id: $0, publishingGeneration: $1) },
            cancelProbe: { await adapter.cancelBandwidthProbe(id: $0, publishingGeneration: $1) },
            probeSnapshot: { await adapter.bandwidthProbeSnapshot() },
            beginStagedProbe: { try await adapter.beginBandwidthProbe(bitRate: $0, staged: true) },
            replaceProbe: { try await adapter.replaceBandwidthProbe(id: $0, publishingGeneration: $1, stage: $2, bitRate: $3) },
            restartProbe: { try await adapter.restartBandwidthProbe(id: $0, publishingGeneration: $1, stage: $2, bitRate: $3) },
            beginRepeatableProbe: { try await adapter.beginBandwidthProbe(bitRate: $0, staged: true, repeatable: true) },
            beginRecoveryProbe: { try await adapter.beginBandwidthProbe(bitRate: $0, staged: true, repeatable: $1, policy: .recoveryBudget) },
            retireProbe: { try await adapter.retireBandwidthProbe(id: $0, publishingGeneration: $1) })
    }

    struct Operations: Sendable {
        let configure: @Sendable () async throws -> Void
        let start: @Sendable () async throws -> Void
        let append: @Sendable (CapturedMediaSample) async throws -> Void
        let isPublishing: @Sendable () async -> Bool
        let stop: @Sendable () async -> Void
        let setBitRate: @Sendable (Int) async throws -> PublishingBitRateChange
        let metrics: @Sendable () async -> TransportMetrics?
        var setProfile: @Sendable (PublishingVideoProfile) async throws -> PublishingVideoProfileChange = { _ in throw PublisherError.profileUpdateFailed }
        var transportClock: @Sendable () async -> PublishingTransportClock? = { nil }
        var transportStatistics: @Sendable () async -> PublishingTransportStatistics? = { nil }
        var beginProbe: @Sendable (Int) async throws -> PublishingBandwidthProbeSnapshot = { _ in throw PublishingBandwidthProbeError.disabled }
        var renewProbe: @Sendable (UUID, UInt64) async throws -> PublishingBandwidthProbeSnapshot = { _, _ in throw PublishingBandwidthProbeError.disabled }
        var cancelProbe: @Sendable (UUID, UInt64) async -> Void = { _, _ in }
        var probeSnapshot: @Sendable () async -> PublishingBandwidthProbeSnapshot? = { nil }
        var beginStagedProbe: @Sendable (Int) async throws -> PublishingBandwidthProbeSnapshot = { _ in throw PublishingBandwidthProbeError.disabled }
        var replaceProbe: @Sendable (UUID, UInt64, UInt32, Int) async throws -> PublishingBandwidthProbeSnapshot = { _, _, _, _ in throw PublishingBandwidthProbeError.disabled }
        var restartProbe: @Sendable (UUID, UInt64, UInt32, Int) async throws -> PublishingBandwidthProbeSnapshot = { _, _, _, _ in throw PublishingBandwidthProbeError.disabled }
        var beginRepeatableProbe: @Sendable (Int) async throws -> PublishingBandwidthProbeSnapshot = { _ in throw PublishingBandwidthProbeError.disabled }
        var beginRecoveryProbe: @Sendable (Int, Bool) async throws -> PublishingBandwidthProbeSnapshot = { _, _ in throw PublishingBandwidthProbeError.disabled }
        var retireProbe: PublishingProbeOperationOwner.Retirement? = nil
    }
    init(operations: Operations) { self.operations = operations; videoCost = nil; startupRead = { nil } }

    public func start() async throws {
        guard state == .prepared else { throw PublisherError.invalidState }
        state = .starting
        let attempt = Task { try await self.performStartup() }
        startup = attempt
        do {
            try await attempt.value
            startup = nil
            try checkStarting()
            state = .publishing
        } catch {
            startup = nil
            let reason: PublisherError = state == .stopped || error is CancellationError
                ? .cancelled : (error as? PublisherError ?? .startFailed)
            await stop()
            throw reason
        }
    }

    public func append(_ sample: CapturedMediaSample) async throws {
        guard state == .publishing else { throw PublisherError.notPublishing }
        do {
            try Task.checkCancellation()
            try await operations.append(sample)
            guard state == .publishing else { throw PublisherError.cancelled }
        } catch is CancellationError { throw PublisherError.cancelled }
        catch let error as PublisherError {
            throw error
        }
        catch { throw PublisherError.appendFailed }
    }

    public var isPublishing: Bool {
        get async {
            guard state == .publishing else { return false }
            let healthy = await operations.isPublishing()
            return state == .publishing && healthy
        }
    }

    public func stop() async {
        state = .stopped
        let pending: Task<Void, Never>
        if let shutdown { pending = shutdown }
        else {
            let close = operations.stop
            let starting = startup
            let changing = profileChange
            let probing = probeOperation
            let retirement = probeRetirement?.task
            probing?.cancel()
            starting?.cancel(); changing?.cancel()
            pending = Task.detached {
                // Close first so a blocked configure/connect/readiness operation
                // can finish. The reusable SDK can reopen on a late actor hop;
                // join that operation and close again before shutdown completes.
                await close()
                if let starting { _ = await starting.result }
                if let changing { _ = await changing.result }
                if let probing { _ = await probing.result }
                if let retirement { _ = await retirement.result }
                if starting != nil || changing != nil || probing != nil { await close() }
            }
            shutdown = pending
        }
        await pending.value
    }

    public func setBitRate(_ bitsPerSecond: Int) async throws {
        _ = try await setVideoBitRate(bitsPerSecond)
    }
    public func setVideoBitRate(_ bitsPerSecond: Int) async throws -> PublishingBitRateChange {
        guard state == .publishing else { throw PublisherError.notPublishing }
        guard !Task.isCancelled else { throw PublisherError.cancelled }
        guard !encoderUpdating else { throw PublisherError.invalidState }
        encoderUpdating = true
        await invalidateBandwidthProbe()
        defer { encoderUpdating = false }
        guard state == .publishing, !Task.isCancelled else { throw PublisherError.cancelled }
        let receipt: PublishingBitRateChange
        do { receipt = try await operations.setBitRate(bitsPerSecond) }
        catch {
            if state == .stopped || Task.isCancelled {
                // A dispatched operation may already have changed native settings.
                // Join live shutdown rather than leave an abandoned change active.
                await stop()
                throw PublisherError.cancelled
            }
            throw PublisherError.bitRateUpdateFailed
        }
        guard state == .publishing else { throw PublisherError.cancelled }
        if Task.isCancelled {
            await stop()
            throw PublisherError.cancelled
        }
        return receipt
    }

    public func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        guard state == .publishing else { throw PublisherError.notPublishing }
        guard !Task.isCancelled else { throw PublisherError.cancelled }
        guard !encoderUpdating else { throw PublisherError.invalidState }
        encoderUpdating = true
        await invalidateBandwidthProbe()
        guard state == .publishing, !Task.isCancelled else { encoderUpdating = false; throw PublisherError.cancelled }
        let change = operations.setProfile
        let pending = Task { try await change(profile) }
        profileChange = pending
        defer { profileChange = nil; encoderUpdating = false }
        return try await withTaskCancellationHandler {
            do {
                let receipt = try await pending.value
                let healthy = await operations.isPublishing()
                guard state == .publishing, !Task.isCancelled else { throw PublisherError.cancelled }
                guard healthy, receipt.profile == profile else { throw PublisherError.profileUpdateFailed }
                return receipt
            } catch {
                let reason: PublisherError = state == .stopped || Task.isCancelled || error is CancellationError
                    ? .cancelled : .profileUpdateFailed
                await stop()
                throw reason
            }
        } onCancel: {
            pending.cancel()
            Task { await self.stop() }
        }
    }

    public func beginBandwidthProbe(bitRate: Int, staged: Bool = false, repeatable: Bool = false, policy: PublishingBandwidthProbeSnapshot.Policy = .localZeroLoss) async throws -> PublishingBandwidthProbeSnapshot {
        guard (!repeatable || staged), (policy == .localZeroLoss || staged) else { throw PublishingBandwidthProbeError.obsolete }
        guard state == .publishing else { throw PublishingBandwidthProbeError.notPublishing }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, probeIdentity == nil, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation { owner in try await self.performProbeOperation(revision: revision) {
            let value: PublishingBandwidthProbeSnapshot
            if policy == .recoveryBudget { value = try await self.operations.beginRecoveryProbe(bitRate, repeatable) }
            else if repeatable { value = try await self.operations.beginRepeatableProbe(bitRate) }
            else if staged { value = try await self.operations.beginStagedProbe(bitRate) }
            else { value = try await self.operations.beginProbe(bitRate) }
            owner.capture(value)
            guard value.isValidStart(staged: staged, bitRate: bitRate, repeatable: repeatable, policy: policy) else {
                throw PublishingBandwidthProbeError.obsolete
            }
            return value
        } }
    }

    public func renewBandwidthProbe(id: UUID, publishingGeneration: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        guard state == .publishing else { throw PublishingBandwidthProbeError.notPublishing }
        guard let prior = probeIdentity, prior.id == id, prior.publishingGeneration == publishingGeneration else {
            throw PublishingBandwidthProbeError.obsolete
        }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation { owner in try await self.performProbeOperation(revision: revision) {
            let value = try await self.operations.renewProbe(id, publishingGeneration)
            owner.capture(value)
            guard value.isValidRenewal(of: prior) else {
                throw PublishingBandwidthProbeError.obsolete
            }
            return value
        } }
    }

    public func replaceBandwidthProbe(id: UUID, publishingGeneration: UInt64, stage: UInt32,
                                      bitRate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        guard state == .publishing else { throw PublishingBandwidthProbeError.notPublishing }
        guard let prior = probeIdentity, prior.id == id, prior.publishingGeneration == publishingGeneration,
              prior.stage == stage else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation { owner in try await self.performProbeOperation(revision: revision) {
            let value = try await self.operations.replaceProbe(id, publishingGeneration, stage, bitRate)
            owner.capture(value)
            guard value.isValidReplacement(of: prior, bitRate: bitRate) else {
                throw PublishingBandwidthProbeError.obsolete
            }
            return value
        } }
    }

    /// Begin fresh measurements after the exact v3 native owner is terminal.
    /// Requires repeatable opt-in from the first probe and a campaign-aware receiver.
    public func restartBandwidthProbe(id: UUID, publishingGeneration: UInt64, stage: UInt32,
                                      bitRate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        guard state == .publishing else { throw PublishingBandwidthProbeError.notPublishing }
        guard let prior = probeIdentity, prior.id == id, prior.publishingGeneration == publishingGeneration,
              prior.stage == stage else { throw PublishingBandwidthProbeError.obsolete }
        guard let campaign = prior.campaign, campaign > 0, campaign < UInt32.max else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation { owner in try await self.performProbeOperation(revision: revision) {
            let requestedAt = ProcessInfo.processInfo.systemUptime
            let value = try await self.operations.restartProbe(id, publishingGeneration, stage, bitRate)
            owner.capture(value)
            guard value.isValidRestart(of: prior, bitRate: bitRate,
                    requestedAt: requestedAt, observedAt: ProcessInfo.processInfo.systemUptime) else {
                throw PublishingBandwidthProbeError.obsolete
            }
            return value
        } }
    }

    public func cancelBandwidthProbe(id: UUID, publishingGeneration: UInt64) async {
        guard let owner = probeOwner, owner.matches(id: id, generation: publishingGeneration),
              let target = owner.target else { return }
        probeRevision &+= 1
        probeOperation?.cancel()
        await operations.cancelProbe(target.id, target.generation)
    }

    /// Revoke immediately and join only work captured for this exact owner.
    /// A failed replacement receipt also recognizes its predecessor, so a caller
    /// that never received the replacement UUID can still join its cleanup.
    public func retireBandwidthProbe(id: UUID, publishingGeneration: UInt64) async throws {
        if let retirement = probeRetirement, retirement.owner.matches(id: id, generation: publishingGeneration) {
            try await retirement.task.value
            return
        }
        guard let owner = probeOwner, owner.matches(id: id, generation: publishingGeneration) else {
            throw PublishingBandwidthProbeError.obsolete
        }
        guard operations.retireProbe != nil else { throw PublishingBandwidthProbeError.disabled }
        guard !probeRetiring else { throw PublishingBandwidthProbeError.busy }
        probeRetiring = true
        probeRevision &+= 1
        let operation = probeOperation
        operation?.cancel()
        let target = owner.target
        let task = Task {
            defer {
                if self.probeRetirement?.owner === owner { self.probeRetiring = false }
            }
            if let target { await self.operations.cancelProbe(target.id, target.generation) }
            _ = await operation?.result
            try await self.joinProbeOwner(owner)
        }
        probeRetirement = (owner, task)
        try await task.value
    }

    public func bandwidthProbeSnapshot() async -> PublishingBandwidthProbeSnapshot? {
        await operations.probeSnapshot()
    }

    private func invalidateBandwidthProbe() async {
        probeRevision &+= 1
        if let target = probeOwner?.target {
            await operations.cancelProbe(target.id, target.generation)
        }
    }

    private func performProbeOperation(revision: UInt64,
        operation: @Sendable () async throws -> PublishingBandwidthProbeSnapshot) async throws -> PublishingBandwidthProbeSnapshot {
        let healthy = await operations.isPublishing()
        guard healthy, state == .publishing else { throw PublishingBandwidthProbeError.notPublishing }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeRevision == revision, !encoderUpdating else { throw PublishingBandwidthProbeError.obsolete }
        let value = try await operation()
        // An allocator can return after revocation while ignoring cancellation.
        // Retire its captured raw handle before another health read can suspend.
        guard state == .publishing, !Task.isCancelled,
              probeRevision == revision, !encoderUpdating else {
            throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
        }
        let stillHealthy = await operations.isPublishing()
        guard stillHealthy, state == .publishing,
              !Task.isCancelled, probeRevision == revision, !encoderUpdating else {
            throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
        }
        return value
    }

    private func joinProbeOwner(_ owner: PublishingProbeOperationOwner) async throws {
        do {
            try await owner.join(retire: operations.retireProbe, cancel: operations.cancelProbe).value
        } catch {
            // A real failed join remains a cleanup obligation. Never discard it
            // by admitting another probe; stop remains available to close/join.
            if probeOwner === owner, operations.retireProbe != nil { probeCleanupFailed = true }
            throw error
        }
    }

    private func runProbeOperation(_ operation: @escaping @Sendable (PublishingProbeOperationOwner) async throws -> PublishingBandwidthProbeSnapshot) async throws -> PublishingBandwidthProbeSnapshot {
        let revision = probeRevision
        let owner = PublishingProbeOperationOwner(predecessor: probeIdentity)
        probeOwner = owner
        let pending = Task {
            do { return try await operation(owner) }
            catch {
                if self.probeOwner === owner, self.probeRevision == revision { self.probeRevision &+= 1 }
                // Preserve the operation error; a retirement caller separately
                // observes any cleanup failure through the same retained task.
                _ = try? await self.joinProbeOwner(owner)
                throw error
            }
        }
        probeOperation = pending
        defer { if probeOwner === owner { probeOperation = nil } }
        return try await withTaskCancellationHandler {
            do {
                let value = try await pending.value
                guard !Task.isCancelled, state == .publishing,
                      probeRevision == revision, !encoderUpdating else {
                    _ = try? await joinProbeOwner(owner)
                    throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
                }
                probeIdentity = value
                owner.accept()
                // Keep the old public retirement inert through suspended restart,
                // and discard it only when the new allocation is accepted.
                if let prior = probeRetirement, !prior.owner.matches(id: value.id, generation: value.publishingGeneration) {
                    probeRetirement = nil
                }
                return value
            } catch { throw publishingProbeError(error) }
        } onCancel: { pending.cancel() }
    }

    public func transportClock() async -> PublishingTransportClock? {
        guard state == .publishing, !Task.isCancelled else { return nil }
        let healthy = await operations.isPublishing()
        guard state == .publishing, !Task.isCancelled, healthy else { return nil }
        let clock = await operations.transportClock()
        guard state == .publishing, !Task.isCancelled else { return nil }
        return clock
    }

    public func transportStatistics() async -> PublishingTransportStatistics? {
        guard state == .publishing, !Task.isCancelled else { return nil }
        let healthy = await operations.isPublishing()
        guard state == .publishing, !Task.isCancelled, healthy else { return nil }
        let statistics = await operations.transportStatistics()
        guard state == .publishing, !Task.isCancelled else { return nil }
        let stillHealthy = await operations.isPublishing()
        guard state == .publishing, !Task.isCancelled, stillHealthy else { return nil }
        return statistics
    }

    public func metrics() async -> TransportMetrics? {
        guard state == .publishing else { return nil }
        let metrics = await operations.metrics()
        return state == .publishing ? metrics : nil
    }

    private func performStartup() async throws {
        try checkStarting()
        try await operations.configure()
        try checkStarting()
        try await operations.start()
        try checkStarting()
        let healthy = await operations.isPublishing()
        try checkStarting()
        guard healthy else { throw PublisherError.notPublishing }
    }

    private func checkStarting() throws {
        guard state == .starting else { throw PublisherError.cancelled }
        try Task.checkCancellation()
    }
}

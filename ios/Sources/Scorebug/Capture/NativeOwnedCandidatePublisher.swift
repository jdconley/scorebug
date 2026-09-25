#if DEBUG
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Raw-input forwarding only. PublishingQualitySession owns probe allocation,
/// policy registration and retirement; this wrapper never schedules a campaign.
final class NativeOwnedCandidatePublisher: MediaPublisher, PublishingProbeObserving, @unchecked Sendable {
    static func requested(environment: [String: String]) throws -> Bool {
        guard let flag = environment["SCOREBUG_TEST_OWNED_MEASUREMENT"], !flag.isEmpty else { return false }
        guard flag == "1", environment["SCOREBUG_TEST_UPLINK_PROFILE"] == "capacity750k-retry",
              VideoObservationFixture.capacityFileUplink(environment: environment) else {
            throw VideoObservationFixture.UplinkError.invalidFixtureRoute
        }
        return true
    }
    let publisher: any MediaPublisher
    let scope: VideoFrameObservationScope
    let audit: PublishingOwnedMeasurementAudit
    let campaignOwner: PublishingCandidateCampaignOwner
    struct Probes: Sendable {
        let capture: @Sendable (PublishingBitRateChange) async throws -> PublishingBandwidthProbeContext
        let validate: @Sendable (PublishingBandwidthProbeContext) async throws -> Void
        let begin: @Sendable (PublishingBandwidthProbeContext, Int, PublishingBandwidthProbeSnapshot.Policy) async throws -> PublishingBandwidthProbeOperation
        let replace: @Sendable (PublishingBandwidthProbeRetirement, PublishingBandwidthProbeContext, Int) async throws -> PublishingBandwidthProbeOperation
        let restart: @Sendable (PublishingBandwidthProbeRetirement, PublishingBandwidthProbeContext, Int) async throws -> PublishingBandwidthProbeOperation
        init(publisher: SRTMediaPublisher) {
            capture = { try await publisher.captureOwnedProbeContext(matching: $0) }
            validate = { try await publisher.validateOwnedProbeContext($0) }
            begin = { try await publisher.beginOwnedBandwidthProbe(in: $0, bitRate: $1, policy: $2) }
            replace = { try await publisher.replaceOwnedBandwidthProbe(after: $0, in: $1, bitRate: $2) }
            restart = { try await publisher.restartOwnedBandwidthProbe(after: $0, in: $1, bitRate: $2) }
        }
        init(capture: @escaping @Sendable (PublishingBitRateChange) async throws -> PublishingBandwidthProbeContext,
             validate: @escaping @Sendable (PublishingBandwidthProbeContext) async throws -> Void,
             begin: @escaping @Sendable (PublishingBandwidthProbeContext, Int, PublishingBandwidthProbeSnapshot.Policy) async throws -> PublishingBandwidthProbeOperation,
             replace: @escaping @Sendable (PublishingBandwidthProbeRetirement, PublishingBandwidthProbeContext, Int) async throws -> PublishingBandwidthProbeOperation,
             restart: @escaping @Sendable (PublishingBandwidthProbeRetirement, PublishingBandwidthProbeContext, Int) async throws -> PublishingBandwidthProbeOperation) {
            self.capture = capture; self.validate = validate; self.begin = begin; self.replace = replace; self.restart = restart
        }
    }
    let probes: Probes?
    private let lock = NSLock()
    private var candidateReader: (@Sendable () async -> NativeCandidatePublisher.CandidateSnapshot?)?
    private var probeReader: (@Sendable () async -> PublishingProbeObservation?)?
    private var pressureReader: (@Sendable () -> NativeCandidatePublisher.Pressure?)?
    func installReaders(candidate: @escaping @Sendable () async -> NativeCandidatePublisher.CandidateSnapshot?,
        probe: @escaping @Sendable () async -> PublishingProbeObservation?,
        pressure: @escaping @Sendable () -> NativeCandidatePublisher.Pressure?) -> Bool {
        lock.withLock {
            guard !stopped, candidateReader == nil else { return false }
            candidateReader = candidate; probeReader = probe; pressureReader = pressure; return true
        }
    }
    func candidateSnapshot() async -> NativeCandidatePublisher.CandidateSnapshot? {
        await lock.withLock { stopped ? nil : candidateReader }?()
    }
    var pressure: NativeCandidatePublisher.Pressure? { lock.withLock { pressureReader }?() }
    private var candidate: NativeCandidateAttempt?
    private var stopped = false
    private var shutdown: Task<Void, Never>?
    private var mutations: [UUID: @Sendable () async -> Void] = [:]
    private let lifecycle: NativeCandidateLifecycleAudit?
    private let profileReceipt: (@Sendable (PublishingVideoProfileChange) -> Void)?
    private let joinedStop: (@Sendable () async -> Void)?

    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope,
         campaignOwner: PublishingCandidateCampaignOwner, timingProfile: StreamingTimingProfile = .strict1500, probes: Probes? = nil,
         lifecycle: NativeCandidateLifecycleAudit? = nil,
         profileReceipt: (@Sendable (PublishingVideoProfileChange) -> Void)? = nil,
         joinedStop: (@Sendable () async -> Void)? = nil) {
        self.publisher = publisher; self.scope = scope; self.campaignOwner = campaignOwner
        self.lifecycle = lifecycle; self.profileReceipt = profileReceipt; self.joinedStop = joinedStop
        self.audit = PublishingOwnedMeasurementAudit(scope: scope, timingProfile: timingProfile)
        self.probes = probes ?? (publisher as? SRTMediaPublisher).map(Probes.init)
    }
    func installCandidate(_ value: NativeCandidateAttempt) {
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            candidate = value; return true
        }
        if !accepted { value.cancel(.publisherStopped) }
    }
    func removeCandidate(_ value: NativeCandidateAttempt) {
        lock.withLock { if candidate === value { candidate = nil } }
    }
    var videoStartup: PublishingVideoStartup? { publisher.videoStartup }
    func start() async throws { try await publisher.start() }
    func append(_ sample: CapturedMediaSample) async throws {
        let selected = lock.withLock { stopped ? nil : candidate }
        try await publisher.append(sample)
        if let selected, lock.withLock({ !stopped && candidate === selected }) { selected.offer(sample) }
    }
    var isPublishing: Bool { get async { await publisher.isPublishing } }
    func transportClock() async -> PublishingTransportClock? { await publisher.transportClock() }
    func transportStatistics() async -> PublishingTransportStatistics? { await publisher.transportStatistics() }
    func probeObservation() async -> PublishingProbeObservation? {
        await lock.withLock { stopped ? nil : probeReader }?()
    }
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange {
        try await mutateBitRate(rate, expected: nil)
    }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        try await mutateProfile(profile, expected: nil)
    }
    func setVideoBitRate(_ rate: Int, expecting expected: PublishingVideoMutationExpectation) async throws -> PublishingBitRateChange {
        try await mutateBitRate(rate, expected: expected)
    }
    func setVideoProfile(_ profile: PublishingVideoProfile, expecting expected: PublishingBitRateChange) async throws -> PublishingVideoProfileChange {
        try await mutateProfile(profile, expected: expected)
    }
    private func mutateBitRate(_ rate: Int, expected: PublishingVideoMutationExpectation?) async throws -> PublishingBitRateChange {
        let id = UUID()
        let task: Task<PublishingBitRateChange, Error> = try lock.withLock {
            guard !stopped else { throw PublishingSessionError.invalidState }
            let selected = candidate
            lifecycle?.beginBitRate(id: id, target: rate, requestedAt: ProcessInfo.processInfo.systemUptime)
            let task = Task { [publisher, lifecycle] in
                do {
                    if expected == nil { selected?.cancel(.ownerChanged) }
                    let result: PublishingBitRateChange
                    if let expected { result = try await publisher.setVideoBitRate(rate, expecting: expected) }
                    else { result = try await publisher.setVideoBitRate(rate) }
                    selected?.cancel(.ownerChanged)
                    lifecycle?.finishBitRate(id: id, completedAt: ProcessInfo.processInfo.systemUptime, receipt: result, failure: nil)
                    return result
                } catch {
                    lifecycle?.finishBitRate(id: id, completedAt: ProcessInfo.processInfo.systemUptime, receipt: nil, failure: String(describing: error))
                    throw error
                }
            }
            mutations[id] = { _ = await task.result }
            return task
        }
        defer { lock.withLock { mutations[id] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func mutateProfile(_ profile: PublishingVideoProfile, expected: PublishingBitRateChange?) async throws -> PublishingVideoProfileChange {
        let witness = await candidateSnapshot(), id = UUID()
        let task: Task<PublishingVideoProfileChange, Error> = try lock.withLock {
            guard !stopped else { throw PublishingSessionError.invalidState }
            let selected = candidate
            lifecycle?.beginProfile(id: id, target: profile, requestedAt: ProcessInfo.processInfo.systemUptime,
                measurementID: witness?.cost.id, authorityPermitted: witness.map { $0.permitsCurrentCandidate($0.cost.id) } ?? false,
                binding: witness?.binding, boundAt: witness?.boundAt, candidateCompletedAt: witness?.completedAt, currentProbe: witness?.probe)
            let task = Task { [publisher, lifecycle, profileReceipt] in
                let result: Result<PublishingVideoProfileChange, Error>
                do {
                    if expected == nil { selected?.cancel(.ownerChanged) }
                    let value: PublishingVideoProfileChange
                    if let expected { value = try await publisher.setVideoProfile(profile, expecting: expected) }
                    else { value = try await publisher.setVideoProfile(profile) }
                    selected?.cancel(.ownerChanged); profileReceipt?(value); result = .success(value)
                } catch { result = .failure(error) }
                let completedAt = ProcessInfo.processInfo.systemUptime
                let readStartedAt = ProcessInfo.processInfo.systemUptime
                let terminal = await (publisher as? any PublishingProbeObserving)?.probeObservation()
                let readCompletedAt = ProcessInfo.processInfo.systemUptime
                switch result {
                case .success(let value): lifecycle?.finishProfile(id: id, completedAt: completedAt, receipt: value, failure: nil,
                    readStartedAt: readStartedAt, readCompletedAt: readCompletedAt, observation: terminal)
                case .failure(let error): lifecycle?.finishProfile(id: id, completedAt: completedAt, receipt: nil, failure: String(describing: error),
                    readStartedAt: readStartedAt, readCompletedAt: readCompletedAt, observation: terminal)
                }
                return try result.get()
            }
            mutations[id] = { _ = await task.result }
            return task
        }
        defer { lock.withLock { mutations[id] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func stop() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let shutdown { return shutdown }
            stopped = true
            candidateReader = nil; probeReader = nil; pressureReader = nil
            let selected = candidate
            candidate = nil
            selected?.cancel(.publisherStopped)
            let mutations = Array(mutations.values)
            let task = Task.detached { [publisher, campaignOwner, lifecycle, joinedStop] in
                await publisher.stop()
                await selected?.retire()
                await campaignOwner.stop()
                for join in mutations { await join() }
                await lifecycle?.closeAndExport()
                await joinedStop?()
            }
            shutdown = task
            return task
        }
        await task.value
    }
}
#endif

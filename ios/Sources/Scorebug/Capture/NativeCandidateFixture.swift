#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia
import ScorebugStreaming

/// One non-recursive route validator shared by both optional fixture parsers.
enum NativeCandidateHeadroomFixture {
    static func requested(environment: [String: String]) throws -> Bool {
        guard let flag = environment["SCOREBUG_TEST_CANDIDATE_HEADROOM"] else { return false }
        guard flag == "1", environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] == "staged",
              ["360p30", "540p30", "1080p30"].contains(environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] ?? ""),
              environment["SCOREBUG_TEST_LIVE_PROFILE"] == "240p30",
              try VideoObservationFixture.liveProfile(environment: environment) == .low240,
              ["SCOREBUG_TEST_NATIVE_QUALITY", "SCOREBUG_TEST_NATIVE_CONFIRMATION", "SCOREBUG_TEST_ADAPTIVE_PROFILES",
               "SCOREBUG_TEST_PROFILE_TRANSITIONS", "SCOREBUG_TEST_SOURCE_CADENCE_PACING",
               "SCOREBUG_TEST_UPLINK_PROXY_PORT", "SCOREBUG_TEST_DECODER_STALL"].allSatisfy({ (environment[$0] ?? "").isEmpty })
        else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
        return true
    }
}

enum NativeCandidateFixture {
    static func requested(environment: [String: String]) throws -> PublishingVideoProfile? {
        let headroom = try NativeCandidateHeadroomFixture.requested(environment: environment)
        guard let raw = environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] else { return nil }
        if headroom { return PublishingVideoProfile(rawValue: raw) }
        let live = try VideoObservationFixture.liveProfile(environment: environment)
        guard let profile = PublishingVideoProfile(rawValue: raw), profile.bitRate > live.bitRate,
              live != .hd1080, environment["SCOREBUG_TEST_LIVE_PROFILE"] == live.rawValue,
              VideoObservationFixture.requested(environment: environment),
              ["SCOREBUG_TEST_NATIVE_QUALITY", "SCOREBUG_TEST_NATIVE_CONFIRMATION", "SCOREBUG_TEST_ADAPTIVE_PROFILES",
               "SCOREBUG_TEST_PROFILE_TRANSITIONS", "SCOREBUG_TEST_SOURCE_CADENCE_PACING", "SCOREBUG_TEST_BANDWIDTH_PROBE",
               "SCOREBUG_TEST_UPLINK_PROXY_PORT", "SCOREBUG_TEST_DECODER_STALL"].allSatisfy({ (environment[$0] ?? "").isEmpty })
        else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
        return profile
    }
    static func scope(_ value: VideoFrameObservationScope) -> [String: Any] {
        ["recordingID": value.recordingID, "matchID": value.matchID, "broadcastGeneration": value.broadcastGeneration,
         "publishingAttemptID": value.publishingAttemptID.uuidString, "appliedProfileRevision": String(value.appliedProfileRevision)]
    }
    static func time(_ value: CMTime) -> [String: Any] {
        ["value": String(value.value), "timescale": value.timescale, "epoch": String(value.epoch), "flags": value.flags.rawValue]
    }
    static func data(_ value: PublishingCandidateMeasurement.Result) -> Data {
        var object: [String: Any] = ["id": value.id.uuidString, "scope": scope(value.scope), "profile": value.profile.rawValue,
            "reason": value.reason.rawValue, "startedAt": value.startedAt as Any? ?? NSNull(), "endedAt": value.endedAt,
            "acceptedInputCount": value.acceptedInputCount, "firstInputPTS": value.firstInputPTS.map(time) as Any? ?? NSNull(),
            "lastInputPTS": value.lastInputPTS.map(time) as Any? ?? NSNull(), "encoding": NSNull()]
        if let result = value.encoding {
            object["transport"] = result.transport.map(transport) as Any? ?? NSNull()
            let e = result.encoding, s = e.settings
            object["encoding"] = ["id": e.id.uuidString, "outcome": e.outcome.rawValue,
                "failure": e.failure as Any? ?? NSNull(), "nativeFailure": e.nativeFailure.map { String(describing: $0) } as Any? ?? NSNull(),
                "encoderSessionID": e.encoderSessionID?.uuidString as Any? ?? NSNull(),
                "acceptedInputCount": e.acceptedInputCount, "outputCount": e.outputCount,
                "requested": ["width": s.videoSize.width, "height": s.videoSize.height, "bitRate": s.bitRate,
                    "profileLevel": s.profileLevel, "expectedFrameRate": s.expectedFrameRate as Any? ?? NSNull(),
                    "maxKeyFrameIntervalDuration": s.maxKeyFrameIntervalDuration,
                    "allowFrameReordering": s.allowFrameReordering as Any? ?? NSNull()],
                "frames": e.frames.map { f in ["sourcePTS": time(f.sourcePTS), "outputPTS": time(f.outputPTS),
                    "encoderSessionID": f.encoderSessionID.uuidString, "submittedAt": f.submittedAt, "completedAt": f.completedAt,
                    "dequeuedAt": f.dequeuedAt, "admittedAt": f.admittedAt, "rawByteCount": f.rawByteCount, "byteCount": f.byteCount, "width": f.width, "height": f.height, "isSync": f.isSync] }]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("null".utf8)
    }

    private static func audio(_ value: PublishingCandidateTransport.AudioReceipt) -> [String: Any] {
        ["sourcePTS": time(value.sourcePTS), "publishingGeneration": String(value.publishingGeneration),
         "wasEncoded": value.wasEncoded, "valid": value.valid, "observedAt": value.observedAt,
         "consumedAt": value.consumedAt, "byteCount": value.byteCount, "sampleRate": value.sampleRate,
         "channelCount": value.channelCount, "framesPerPacket": value.framesPerPacket,
         "audioObjectType": value.audioObjectType]
    }
    private static func transport(_ value: PublishingCandidateTransport.Result) -> [String: Any] {
        var object: [String: Any] = ["scope": scope(value.scope), "profile": value.profile.rawValue,
            "id": value.id?.uuidString as Any? ?? NSNull(), "outcome": value.outcome.rawValue,
            "failure": value.failure as Any? ?? NSNull(),
            "publishingGeneration": value.publishingGeneration.map { String($0) } as Any? ?? NSNull(),
            "startedAt": value.startedAt as Any? ?? NSNull(), "closedAt": value.closedAt as Any? ?? NSNull(),
            "endedAt": value.endedAt, "rawInputCount": value.rawInputCount,
            "firstRawPTS": value.firstRawPTS.map(time) as Any? ?? NSNull(),
            "lastRawPTS": value.lastRawPTS.map(time) as Any? ?? NSNull(),
            "audio": value.audio.map(audio), "followingAudio": value.followingAudio.map(audio) as Any? ?? NSNull(),
            "maximumPendingCount": value.maximumPendingCount, "maximumPendingBytes": value.maximumPendingBytes,
            "mux": NSNull()]
        if let mux = value.mux {
            object["mux"] = ["outcome": mux.outcome.rawValue, "failure": mux.failure as Any? ?? NSNull(),
                "videoInputCount": mux.videoInputCount, "audioInputCount": mux.audioInputCount,
                "videoInputBytes": mux.videoInputBytes, "audioInputBytes": mux.audioInputBytes,
                "firstVideoPTS": mux.firstVideoPTS.map(time) as Any? ?? NSNull(),
                "lastVideoPTS": mux.lastVideoPTS.map(time) as Any? ?? NSNull(),
                "firstAudioPTS": mux.firstAudioPTS.map(time) as Any? ?? NSNull(),
                "lastAudioPTS": mux.lastAudioPTS.map(time) as Any? ?? NSNull(),
                "transportBytes": mux.transportBytes, "transportMessageCount": mux.transportMessageCount,
                "inputs": mux.inputs.map { input in ["media": input.media.rawValue, "sourcePTS": time(input.sourcePTS),
                    "decodePTS": input.decodePTS.isValid ? time(input.decodePTS) as Any : NSNull(),
                    "byteCount": input.byteCount, "isSync": input.isSync, "parameterSetBytes": input.parameterSetBytes] }]
        }
        return object
    }
}

/// A simulator opt-in observer of the existing publisher's raw input. The primary
/// append finishes first; this owner adds neither capture admission nor raw queues.
actor NativeCandidatePublisher: MediaPublisher, PublishingProbeObserving {
    struct Pressure: Sendable {
        let observedAt: Double, sampledAt: Double
        let thermal: Int, dropped: Int, rejected: Int
        let publishing: Bool
        var valid: Bool {
            observedAt.isFinite && sampledAt.isFinite && observedAt >= sampledAt && sampledAt >= 0 &&
            observedAt - sampledAt <= 2 && (0...1).contains(thermal) && dropped >= 0 && rejected >= 0 && publishing
        }
        var object: [String: Any] {
            ["observedAt": observedAt, "sampledAt": sampledAt, "thermal": thermal, "dropped": dropped, "rejected": rejected, "publishing": publishing]
        }
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
    struct Operations: Sendable {
        let start: @Sendable () async throws -> Void
        let offer: @Sendable (CapturedMediaSample) -> Bool
        let cancel: @Sendable (PublishingCandidateMeasurement.Reason) -> Void
        let result: @Sendable () async -> Data
        let export: @Sendable (Data) async -> Void
        let typedResult: @Sendable () async -> PublishingCandidateCost?
        var retire: @Sendable () async -> Void
        init(start: @escaping @Sendable () async throws -> Void,
             offer: @escaping @Sendable (CapturedMediaSample) -> Bool,
             cancel: @escaping @Sendable (PublishingCandidateMeasurement.Reason) -> Void,
             result: @escaping @Sendable () async -> Data,
             export: @escaping @Sendable (Data) async -> Void,
             typedResult: @escaping @Sendable () async -> PublishingCandidateCost? = { nil },
             retire: @escaping @Sendable () async -> Void = {}) {
            self.start = start; self.offer = offer; self.cancel = cancel
            self.result = result; self.export = export; self.typedResult = typedResult
            self.retire = retire
        }
    }
    struct CandidateSnapshot: Sendable {
        let cost: PublishingCandidateCost
        let binding: PublishingProbeObservation
        let probe: PublishingProbeObservation
        let boundAt: Double
        let completedAt: Double
        let permitsCurrentCandidate: @Sendable (UUID) -> Bool
    }
    /// Cached snapshots hold only this bounded token, never the actor or native
    /// result. Revocation is synchronous and cannot be undone by a late join.
    private final class CandidateAuthority: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UUID?
        private var revoked = false
        func activate(_ candidateID: UUID) {
            lock.withLock {
                guard !revoked, id == nil else { return }
                id = candidateID
            }
        }
        func permits(_ candidateID: UUID) -> Bool { lock.withLock { !revoked && id == candidateID } }
        func revoke() { lock.withLock { revoked = true; id = nil } }
    }
    struct Timing: Sendable {
        var delay: Duration = .seconds(20)
        var poll: Duration = .milliseconds(100)
        var maximumPolls: Int = 50
        var maximumProbeWaitPolls: Int = 250
    }
    private let publisher: any MediaPublisher
    private let scope: VideoFrameObservationScope
    private let liveProfile: PublishingVideoProfile
    private let operations: Operations
    private let timing: Timing
    private let candidateHeadroom: Bool
    private let requiresMeasurementReadiness: Bool
    private let measurementProfile: PublishingVideoProfile?
    private let measurementContext: NativeCandidateContextReader
    private var pinnedProbe: PublishingProbeObservation?, currentProbe: PublishingProbeObservation?
    private var acceptedProbeRevision = 0
    private var probeBoundAt: Double?, probeCompletedAt: Double?
    private var initialProbe: ProbeSnapshot?, finalProbe: ProbeSnapshot?
    private struct ProbeSnapshot {
        let value: PublishingProbeObservation
        let observedAt: Double
        var object: [String: Any] {
            var object = NativeBandwidthProbeSample(id: value.id, publishingGeneration: value.publishingGeneration,
                bitRate: value.bitRate, startedAt: value.startedAt, leaseDeadline: value.leaseDeadline,
                acceptedPayloadBytes: value.acceptedPayloadBytes, lastAcceptedAt: value.lastAcceptedAt,
                reason: value.reason, stage: value.stage, campaign: value.campaign).object
            object["observedAt"] = observedAt
            return object
        }
    }
    private var diagnostics: (@Sendable () -> Pressure?)?
    private var starting = false, started = false, stopped = false, sampling = false
    private var candidateOperationsStarted = false, bootstrapWriteUsed = false, bootstrapWriteInFlight = false
    private var invalidReason: String?
    private var publisherStartedAt: Double?
    private var baseline: Pressure?, finalPressure: Pressure?
    private var polls = 0, maximumThermal = -1
    private var frozenMeasurementExport: Data?
    private var measurement: Data?
    private var candidateCost: PublishingCandidateCost?
    private let candidateAuthority = CandidateAuthority()
    private var work: Task<Void, Never>?, shutdown: Task<Void, Never>?
    private var primaryStartup: Task<Void, Error>?
    private let lifecycle: NativeCandidateLifecycleAudit?
    private let profileReceipt: (@Sendable (PublishingVideoProfileChange) -> Void)?
    private let joinedStop: (@Sendable () async -> Void)?
    private let candidateStop: (@Sendable () async -> Void)?
    private var completedCandidateID: UUID?
    private var profileWrites: [UUID: Task<PublishingVideoProfileChange, Error>] = [:]
    private var bitRateWrites: [UUID: Task<PublishingBitRateChange, Error>] = [:]

    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope, liveProfile: PublishingVideoProfile,
         candidate: PublishingVideoProfile, campaignOwner: PublishingCandidateCampaignOwner, candidateHeadroom: Bool = false, requiresMeasurementReadiness: Bool = false, lifecycle: NativeCandidateLifecycleAudit? = nil,
         profileReceipt: (@Sendable (PublishingVideoProfileChange) -> Void)? = nil,
         joinedStop: (@Sendable () async -> Void)? = nil) {
        let reader = NativeCandidateContextReader()
        self.measurementContext = reader
        let attempt = requiresMeasurementReadiness
            ? NativeCandidateAttempt(owner: campaignOwner, scope: scope, candidate: candidate,
                contextProvider: { await reader.read() })
            : NativeCandidateAttempt(owner: campaignOwner, publisher: publisher,
                scope: scope, liveProfile: liveProfile, candidate: candidate)
        self.requiresMeasurementReadiness = requiresMeasurementReadiness
        self.measurementProfile = candidate
        self.publisher = publisher; self.scope = scope; self.liveProfile = liveProfile; timing = Timing()
        self.candidateHeadroom = candidateHeadroom
        self.lifecycle = lifecycle; self.profileReceipt = profileReceipt; self.joinedStop = joinedStop
        candidateStop = { await campaignOwner.stop() }
        operations = .init(start: { try await attempt.start() },
            offer: { attempt.offer($0) }, cancel: { attempt.cancel($0) },
            result: { await attempt.result().map(NativeCandidateFixture.data) ?? Data("null".utf8) },
            export: { await Self.persist($0) },
            typedResult: { await attempt.result().flatMap(PublishingCandidateCost.init) },
            retire: { await attempt.retire() })
    }
    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope, liveProfile: PublishingVideoProfile,
         operations: Operations, timing: Timing, candidateHeadroom: Bool = false, requiresMeasurementReadiness: Bool = false, measurementProfile: PublishingVideoProfile? = nil, lifecycle: NativeCandidateLifecycleAudit? = nil,
         profileReceipt: (@Sendable (PublishingVideoProfileChange) -> Void)? = nil,
         joinedStop: (@Sendable () async -> Void)? = nil) {
        self.publisher = publisher; self.scope = scope; self.liveProfile = liveProfile
        self.operations = operations; self.timing = timing; self.candidateHeadroom = candidateHeadroom
        self.requiresMeasurementReadiness = requiresMeasurementReadiness; self.measurementProfile = measurementProfile
        self.measurementContext = NativeCandidateContextReader()
        self.lifecycle = lifecycle; self.profileReceipt = profileReceipt; self.joinedStop = joinedStop
        candidateStop = nil
    }
    nonisolated var videoStartup: PublishingVideoStartup? { publisher.videoStartup }
    func setDiagnostics(_ read: @escaping @Sendable () -> Pressure?) { diagnostics = read }
    @discardableResult func setMeasurementContextProvider(_ read: @escaping @Sendable () async -> PublishingQualitySession.CandidateMeasurementContext?) -> Bool {
        guard requiresMeasurementReadiness, !stopped else { return false }
        return measurementContext.install(read)
    }
    func start() async throws {
        guard !starting, !started, !stopped else { throw PublishingSessionError.invalidState }
        starting = true
        defer { starting = false }
        let primary = publisher
        let startup = Task { try await primary.start() }
        primaryStartup = startup
        try await startup.value
        guard !stopped, !Task.isCancelled else {
            if !stopped { await stop() }
            throw CancellationError()
        }
        started = true; publisherStartedAt = ProcessInfo.processInfo.systemUptime
        work = Task { await run() }
    }
    func append(_ sample: CapturedMediaSample) async throws {
        let wasSampling = sampling
        do { try await publisher.append(sample) }
        catch { revoke(.pressure); throw error }
        guard wasSampling, sampling, !stopped, sample.kind == .video else { return }
        guard await refreshProbe(requiresSampling: true), sampling, !stopped, checkPressure() else { return }
        _ = operations.offer(sample)
    }
    var isPublishing: Bool { get async {
        let healthy = await publisher.isPublishing
        if !healthy { revoke(.pressure) }
        return healthy
    } }
    func transportClock() async -> PublishingTransportClock? { await publisher.transportClock() }
    func transportStatistics() async -> PublishingTransportStatistics? { await publisher.transportStatistics() }
    func probeObservation() async -> PublishingProbeObservation? { await (publisher as? any PublishingProbeObserving)?.probeObservation() }
    func setVideoBitRate(_ value: Int) async throws -> PublishingBitRateChange {
        guard !stopped else { throw PublishingSessionError.invalidState }
        if let lifecycle, bitRateWrites.count >= 48 {
            lifecycle.rejectOverflow(); throw PublishingSessionError.invalidState
        }
        let id = UUID()
        lifecycle?.beginBitRate(id: id, target: value, requestedAt: ProcessInfo.processInfo.systemUptime)
        let task = Task {
            do {
                let receipt = try await performVideoBitRate(value)
                lifecycle?.finishBitRate(id: id, completedAt: ProcessInfo.processInfo.systemUptime, receipt: receipt, failure: nil)
                return receipt
            } catch {
                lifecycle?.finishBitRate(id: id, completedAt: ProcessInfo.processInfo.systemUptime, receipt: nil, failure: String(describing: error))
                throw error
            }
        }
        bitRateWrites[id] = task
        defer { bitRateWrites[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performVideoBitRate(_ value: Int) async throws -> PublishingBitRateChange {
        guard !stopped else { throw PublishingSessionError.invalidState }
        // One verified bootstrap write may precede candidate ownership. Reserve
        // it before awaiting native work so concurrent calls cannot share it.
        guard candidateHeadroom, started, !stopped, invalidReason == nil,
              !candidateOperationsStarted, !bootstrapWriteUsed, value == liveProfile.bitRate,
              let startup = publisher.videoStartup, startup.profile == liveProfile else {
            revoke(.ownerChanged)
            return try await publisher.setVideoBitRate(value)
        }
        bootstrapWriteUsed = true; bootstrapWriteInFlight = true
        defer { bootstrapWriteInFlight = false }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        do {
            let receipt = try await publisher.setVideoBitRate(value)
            guard !stopped, invalidReason == nil, !candidateOperationsStarted,
                  publisher.videoStartup == startup,
                  receipt.publishingGeneration == startup.publishingGeneration,
                  receipt.configuration.encoderSessionID == startup.encoderSessionID,
                  receipt.configuration.bitRate == value,
                  receipt.acceptedAt >= requestedAt, receipt.acceptedAt <= ProcessInfo.processInfo.systemUptime
            else { revoke(.ownerChanged); return receipt }
            return receipt
        } catch {
            revoke(.ownerChanged)
            throw error
        }
    }
    func setVideoProfile(_ value: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        guard !stopped else { throw PublishingSessionError.invalidState }
        if let lifecycle, profileWrites.count >= 16 {
            lifecycle.rejectOverflow(); throw PublishingSessionError.invalidState
        }
        let id = UUID()
        lifecycle?.beginProfile(id: id, target: value, requestedAt: ProcessInfo.processInfo.systemUptime,
            measurementID: completedCandidateID,
            authorityPermitted: candidateCost.map { candidateAuthority.permits($0.id) } ?? false,
            binding: pinnedProbe, boundAt: probeBoundAt, candidateCompletedAt: probeCompletedAt, currentProbe: currentProbe)
        // Capture the permission actually held at dispatch before synchronously
        // retiring it. No actor await may separate these two operations.
        revoke(.ownerChanged)
        let task = Task {
            let result: Result<PublishingVideoProfileChange, Error>
            do {
                guard !stopped else { throw PublishingSessionError.invalidState }
                result = .success(try await publisher.setVideoProfile(value))
            }
            catch { result = .failure(error) }
            let completedAt = ProcessInfo.processInfo.systemUptime
            if case let .success(receipt) = result { profileReceipt?(receipt) }
            if let lifecycle {
                let readStartedAt = ProcessInfo.processInfo.systemUptime
                let observation = await probeObservation()
                let readCompletedAt = ProcessInfo.processInfo.systemUptime
                switch result {
                case let .success(receipt):
                    lifecycle.finishProfile(id: id, completedAt: completedAt, receipt: receipt, failure: nil,
                        readStartedAt: readStartedAt, readCompletedAt: readCompletedAt, observation: observation)
                case let .failure(error):
                    lifecycle.finishProfile(id: id, completedAt: completedAt, receipt: nil, failure: String(describing: error),
                        readStartedAt: readStartedAt, readCompletedAt: readCompletedAt, observation: observation)
                }
            }
            return try result.get()
        }
        profileWrites[id] = task
        defer { profileWrites[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func revoke(_ reason: PublishingCandidateMeasurement.Reason) {
        candidateAuthority.revoke()
        sampling = false
        candidateCost = nil
        // A normal stop after the joined measurement is not an ownership change.
        if reason != .publisherStopped || measurement == nil { invalidReason = invalidReason ?? reason.rawValue }
        operations.cancel(reason)
    }
    func stop() async {
        stopped = true; measurementContext.close(); revoke(.publisherStopped); work?.cancel()
        if let shutdown { await shutdown.value; return }
        let pending = work, startup = primaryStartup
        let profiles = Array(profileWrites.values), bitRates = Array(bitRateWrites.values)
        let task = Task {
            await publisher.stop()
            _ = try? await startup?.value
            for write in profiles { _ = try? await write.value }
            for write in bitRates { _ = try? await write.value }
            await pending?.value
            if measurement == nil { measurement = await operations.result() }
            await operations.retire()
            await candidateStop?()
            // Measured mode exports the diagnostic frozen at measurement join;
            // later application retirement belongs only to lifecycle evidence.
            if lifecycle != nil, frozenMeasurementExport == nil { frozenMeasurementExport = try? exportData() }
            let data = lifecycle == nil ? try? exportData() : frozenMeasurementExport
            if let data, data.count <= 256 * 1024 { await operations.export(data) }
            await joinedStop?()
            await lifecycle?.closeAndExport()
        }
        shutdown = task
        await task.value
    }
    func waitForMeasurement() async { await work?.value }
    /// Runtime evidence stays typed and bounded. Native ownership and pressure
    /// are read again after join without rewriting the closed diagnostic sample.
    func candidateSnapshot() async -> CandidateSnapshot? {
        guard candidateHeadroom, measurement != nil, !stopped, invalidReason == nil,
              !bootstrapWriteInFlight, let cost = candidateCost,
              candidateAuthority.permits(cost.id),
              let binding = pinnedProbe, let boundAt = probeBoundAt, let completedAt = probeCompletedAt,
              cost.scope == scope, cost.publishingGeneration == binding.publishingGeneration,
              cost.startedAt >= boundAt, cost.endedAt <= completedAt,
              publisher.videoStartup?.profile == liveProfile,
              publisher.videoStartup?.publishingGeneration == cost.publishingGeneration,
              await refreshProbe(recordDiagnostic: false), checkPressure(recordDiagnostic: false),
              !stopped, invalidReason == nil, candidateCost?.id == cost.id, !bootstrapWriteInFlight,
              let probe = currentProbe else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard completedAt <= now, now - cost.endedAt <= 2 else { return nil }
        let authority = candidateAuthority
        return .init(cost: cost, binding: binding, probe: probe, boundAt: boundAt, completedAt: completedAt,
            permitsCurrentCandidate: { authority.permits($0) })
    }
    private func checkPressure(recordDiagnostic: Bool = true) -> Bool {
        guard let value = diagnostics?(), value.valid, let baseline,
              value.observedAt >= baseline.observedAt, value.dropped == baseline.dropped,
              value.rejected == baseline.rejected else { revoke(.pressure); return false }
        if recordDiagnostic { finalPressure = value; maximumThermal = max(maximumThermal, value.thermal) }
        return true
    }
    private func checkProbeAuthority() -> Bool {
        guard candidateHeadroom else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard let pinnedProbe, let currentProbe,
              pinnedProbe.permitsCurrentOwner?(pinnedProbe.id, pinnedProbe.publishingGeneration, pinnedProbe.stage) == true,
              currentProbe.isActive(at: now) else { revoke(.ownerChanged); return false }
        return true
    }
    private func waitForFinalProbe() async throws {
        guard candidateHeadroom else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        for _ in 0..<timing.maximumProbeWaitPolls {
            try Task.checkCancellation()
            guard !stopped, invalidReason == nil else { throw CancellationError() }
            let value = await probeObservation()
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard !stopped, invalidReason == nil, now < deadline else { break }
            if let value, value.stage == 3, value.bitRate == 12_000_000,
               publisher.videoStartup?.publishingGeneration == value.publishingGeneration,
               value.isActive(at: now), now - value.startedAt >= 0.5 {
                if requiresMeasurementReadiness {
                    let context = await measurementContext.read()
                    try Task.checkCancellation()
                    guard !stopped, invalidReason == nil else { throw CancellationError() }
                    guard let context, let measurementProfile,
                          context.scope == scope,
                          context.readiness.settings.profileID == measurementProfile.rawValue,
                          context.readiness.settings.videoBitrate == measurementProfile.bitRate,
                          context.applied.receipt.publishingGeneration == value.publishingGeneration else {
                        try await Task.sleep(for: timing.poll)
                        continue
                    }
                }
                // Readiness can suspend. It cannot renew the earlier probe lease
                // or restore authority that was revoked during that suspension.
                let boundAt = ProcessInfo.processInfo.systemUptime
                guard boundAt < deadline, value.isActive(at: boundAt) else {
                    try await Task.sleep(for: timing.poll)
                    continue
                }
                pinnedProbe = value; currentProbe = value; probeBoundAt = boundAt
                initialProbe = .init(value: value, observedAt: boundAt)
                return
            }
            try await Task.sleep(for: timing.poll)
        }
        revoke(.deadline)
        throw CancellationError()
    }
    private func refreshProbe(requiresSampling: Bool = false, recordDiagnostic: Bool = true) async -> Bool {
        guard candidateHeadroom else { return true }
        for _ in 0..<3 {
            let revision = acceptedProbeRevision
            let value = await probeObservation()
            // The native read can suspend past measurement completion or stop. A late
            // raw-input read must neither reopen admission nor replace joined evidence.
            guard !requiresSampling || (sampling && !stopped) else { return false }
            guard !stopped, invalidReason == nil else { revoke(.ownerChanged); return false }
            // An overlapping monitor or append may have accepted a newer snapshot.
            // Re-read native state rather than compare an older response with it or
            // give cached evidence a new observation time. Retries stay bounded.
            if acceptedProbeRevision != revision { continue }
            let now = ProcessInfo.processInfo.systemUptime
            if recordDiagnostic, let value { finalProbe = .init(value: value, observedAt: now) }
            guard let pinnedProbe, let value,
                  value.id == pinnedProbe.id, value.publishingGeneration == pinnedProbe.publishingGeneration,
                  value.stage == pinnedProbe.stage, value.campaign == pinnedProbe.campaign, value.bitRate == pinnedProbe.bitRate,
                  value.startedAt == pinnedProbe.startedAt, value.isActive(at: now),
                  value.acceptedPayloadBytes >= (currentProbe?.acceptedPayloadBytes ?? 0),
                  value.leaseDeadline >= (currentProbe?.leaseDeadline ?? 0) else {
                revoke(.ownerChanged); return false
            }
            currentProbe = value
            acceptedProbeRevision += 1
            return checkProbeAuthority()
        }
        revoke(.deadline)
        return false
    }
    private func monitor() async {
        for _ in 0..<timing.maximumPolls {
            do { try await Task.sleep(for: timing.poll); try Task.checkCancellation() } catch { return }
            guard sampling, !stopped else { return }
            polls += 1
            guard await refreshProbe(), checkPressure() else { return }
        }
        if sampling { revoke(.deadline) }
    }
    private func run() async {
        defer {
            if lifecycle != nil, measurement != nil { frozenMeasurementExport = try? exportData() }
        }
        do {
            guard !requiresMeasurementReadiness || (candidateHeadroom && measurementProfile != nil),
                  timing.delay >= .zero, timing.poll > .zero, (1...50).contains(timing.maximumPolls),
                  (1...250).contains(timing.maximumProbeWaitPolls) else { throw PublishingSessionError.invalidState }
            try await Task.sleep(for: timing.delay)
            try Task.checkCancellation()
            try await waitForFinalProbe()
            guard !stopped, invalidReason == nil, let value = diagnostics?(), value.valid else { revoke(.pressure); throw CancellationError() }
            baseline = value; finalPressure = value; maximumThermal = value.thermal
            candidateOperationsStarted = true
            try await operations.start()
            try Task.checkCancellation()
            guard !stopped, invalidReason == nil, await refreshProbe(), checkPressure() else { throw CancellationError() }
            sampling = true
            let monitor = Task { await self.monitor() }
            let result = await operations.result()
            sampling = false
            monitor.cancel(); await monitor.value
            let cost = await operations.typedResult()
            if !stopped {
                _ = await refreshProbe()
                _ = checkPressure()
                if candidateHeadroom { probeCompletedAt = ProcessInfo.processInfo.systemUptime }
            }
            measurement = result
            completedCandidateID = cost?.id
            if !stopped, invalidReason == nil, let cost,
               cost.scope == scope, cost.publishingGeneration == pinnedProbe?.publishingGeneration,
               let boundAt = probeBoundAt, let completedAt = probeCompletedAt,
               boundAt <= cost.startedAt, cost.endedAt <= completedAt {
                candidateCost = cost
                candidateAuthority.activate(cost.id)
            }
        } catch {
            revoke(Task.isCancelled || stopped ? .publisherStopped : .startupFailed)
            measurement = await operations.result()
        }
    }
    private func exportData() throws -> Data {
        var object: [String: Any] = ["formatVersion": 3, "isClosed": true,
            "resourceLimits": ["rawQueueCount": 4, "unresolvedInputCount": 16,
                "unresolvedRawBytes": 64 * 1024 * 1024, "rawBytesPerInput": 16 * 1024 * 1024],
            "scope": NativeCandidateFixture.scope(scope), "liveProfile": liveProfile.rawValue,
            "publisherStartedAt": publisherStartedAt as Any? ?? NSNull(), "closedAt": ProcessInfo.processInfo.systemUptime,
            "invalidReason": invalidReason as Any? ?? NSNull(), "pressureBaseline": baseline?.object as Any? ?? NSNull(),
            "pressureFinal": finalPressure?.object as Any? ?? NSNull(), "pressurePolls": polls, "maximumThermal": maximumThermal,
            "measurement": try measurement.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()]
        if candidateHeadroom {
            object["probeBinding"] = ["boundAt": probeBoundAt as Any? ?? NSNull(),
                "completedAt": probeCompletedAt as Any? ?? NSNull(),
                "initial": initialProbe?.object as Any? ?? NSNull(), "final": finalProbe?.object as Any? ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private static func persist(_ data: Data) async {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("native-candidate-measurement.json"), options: .atomic)
        }.value
    }
}
#endif

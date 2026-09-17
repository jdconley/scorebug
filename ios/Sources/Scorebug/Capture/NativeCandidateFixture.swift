#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia
import ScorebugStreaming

enum NativeCandidateFixture {
    static func requested(environment: [String: String]) throws -> PublishingVideoProfile? {
        guard let raw = environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] else { return nil }
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
    }
    struct Timing: Sendable {
        var delay: Duration = .seconds(20)
        var poll: Duration = .milliseconds(100)
        var maximumPolls: Int = 50
    }
    private let publisher: any MediaPublisher
    private let scope: VideoFrameObservationScope
    private let liveProfile: PublishingVideoProfile
    private let operations: Operations
    private let timing: Timing
    private var diagnostics: (@Sendable () -> Pressure?)?
    private var starting = false, started = false, stopped = false, sampling = false
    private var invalidReason: String?
    private var publisherStartedAt: Double?
    private var baseline: Pressure?, finalPressure: Pressure?
    private var polls = 0, maximumThermal = -1
    private var measurement: Data?
    private var work: Task<Void, Never>?, shutdown: Task<Void, Never>?
    private var primaryStartup: Task<Void, Error>?

    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope, liveProfile: PublishingVideoProfile,
         candidate: PublishingVideoProfile, transport: PublishingCandidateTransport) throws {
        let owner = try PublishingCandidateMeasurement(scope: scope, profile: candidate, transport: transport)
        self.publisher = publisher; self.scope = scope; self.liveProfile = liveProfile; timing = Timing()
        operations = .init(start: {
            guard let startup = publisher.videoStartup, startup.profile == liveProfile,
                  transport.arm(publishingGeneration: startup.publishingGeneration) else {
                throw PublishingSessionError.invalidState
            }
            try await owner.start()
        }, offer: { owner.offer($0) }, cancel: { owner.cancel(reason: $0) },
            result: { NativeCandidateFixture.data(await owner.result()) }, export: { await Self.persist($0) })
    }
    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope, liveProfile: PublishingVideoProfile,
         operations: Operations, timing: Timing) {
        self.publisher = publisher; self.scope = scope; self.liveProfile = liveProfile
        self.operations = operations; self.timing = timing
    }
    nonisolated var videoStartup: PublishingVideoStartup? { publisher.videoStartup }
    func setDiagnostics(_ read: @escaping @Sendable () -> Pressure?) { diagnostics = read }
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
        if wasSampling, sampling, !stopped, sample.kind == .video, checkPressure() { _ = operations.offer(sample) }
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
        revoke(.ownerChanged); return try await publisher.setVideoBitRate(value)
    }
    func setVideoProfile(_ value: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        revoke(.ownerChanged); return try await publisher.setVideoProfile(value)
    }
    private func revoke(_ reason: PublishingCandidateMeasurement.Reason) {
        sampling = false
        // A normal stop after the joined measurement is not an ownership change.
        if reason != .publisherStopped || measurement == nil { invalidReason = invalidReason ?? reason.rawValue }
        operations.cancel(reason)
    }
    func stop() async {
        stopped = true; revoke(.publisherStopped); work?.cancel()
        if let shutdown { await shutdown.value; return }
        let pending = work, startup = primaryStartup
        let task = Task {
            await publisher.stop()
            _ = try? await startup?.value
            await pending?.value
            if measurement == nil { measurement = await operations.result() }
            if let data = try? exportData(), data.count <= 256 * 1024 { await operations.export(data) }
        }
        shutdown = task
        await task.value
    }
    func waitForMeasurement() async { await work?.value }
    private func checkPressure() -> Bool {
        guard let value = diagnostics?(), value.valid, let baseline,
              value.observedAt >= baseline.observedAt, value.dropped == baseline.dropped,
              value.rejected == baseline.rejected else { revoke(.pressure); return false }
        finalPressure = value; maximumThermal = max(maximumThermal, value.thermal)
        return true
    }
    private func monitor() async {
        for _ in 0..<timing.maximumPolls {
            do { try await Task.sleep(for: timing.poll); try Task.checkCancellation() } catch { return }
            guard sampling, !stopped else { return }
            polls += 1
            guard checkPressure() else { return }
        }
        if sampling { revoke(.deadline) }
    }
    private func run() async {
        do {
            guard timing.delay >= .zero, timing.poll > .zero, (1...50).contains(timing.maximumPolls) else { throw PublishingSessionError.invalidState }
            try await Task.sleep(for: timing.delay)
            try Task.checkCancellation()
            guard !stopped, invalidReason == nil, let value = diagnostics?(), value.valid else { revoke(.pressure); throw CancellationError() }
            baseline = value; finalPressure = value; maximumThermal = value.thermal
            try await operations.start()
            try Task.checkCancellation()
            guard !stopped, invalidReason == nil, checkPressure() else { throw CancellationError() }
            sampling = true
            let monitor = Task { await self.monitor() }
            let result = await operations.result()
            sampling = false
            monitor.cancel(); await monitor.value
            if !stopped { _ = checkPressure() }
            measurement = result
        } catch {
            revoke(Task.isCancelled || stopped ? .publisherStopped : .startupFailed)
            measurement = await operations.result()
        }
    }
    private func exportData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 3, "isClosed": true,
            "resourceLimits": ["rawQueueCount": 4, "unresolvedInputCount": 16,
                "unresolvedRawBytes": 64 * 1024 * 1024, "rawBytesPerInput": 16 * 1024 * 1024],
            "scope": NativeCandidateFixture.scope(scope), "liveProfile": liveProfile.rawValue,
            "publisherStartedAt": publisherStartedAt as Any? ?? NSNull(), "closedAt": ProcessInfo.processInfo.systemUptime,
            "invalidReason": invalidReason as Any? ?? NSNull(), "pressureBaseline": baseline?.object as Any? ?? NSNull(),
            "pressureFinal": finalPressure?.object as Any? ?? NSNull(), "pressurePolls": polls, "maximumThermal": maximumThermal,
            "measurement": try measurement.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()], options: [.sortedKeys])
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

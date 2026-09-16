#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia
import ScorebugStreaming

/// Bounded scalar evidence for one explicit simulator experiment. It owns no media.
final class NativeProfileTransitionEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: VideoFrameObservationScope
    private struct Phase {
        let width: Int32, height: Int32, first: CMTime
        var last: CMTime, frames: Int, maximumSourceGap: Double
        let firstObservedAt: Double
        var lastObservedAt: Double, maximumObservationGap: Double
    }
    private struct EncoderSession {
        let id: UUID, first: CMTime, firstCompletedAt: Double
        var last: CMTime, frames: Int, lastCompletedAt: Double
        var maximumCompletionGap: Double, maximumEncodeLatency: Double
    }
    private var encoderSessions: [EncoderSession] = []
    private var encoderFrames = 0
    private var phases: [Phase] = []
    private var receipts: [PublishingVideoProfileChange] = []
    private var frames = 0
    private var generation: UInt64?
    private var invalid = false, closed = false
    init(scope: VideoFrameObservationScope) { self.scope = scope }
    func observe(_ frame: SRTPublisher.CompressedVideoFrame) {
        record(generation: frame.publishingGeneration, pts: frame.sourcePTS, width: frame.width,
               height: frame.height, valid: frame.valid && frame.wasEncoded && frame.codec == kCMVideoCodecType_H264)
    }
    func record(generation: UInt64, pts: CMTime, width: Int32, height: Int32, valid: Bool, observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard !closed, frames < 25_000 else { invalid = true; return }
            frames += 1
            guard valid, generation > 0, pts.isNumeric, pts.timescale > 0, pts.epoch == 0,
                  pts >= .zero, width > 0, height > 0, observedAt.isFinite, (0...1e12).contains(observedAt) else { invalid = true; return }
            if let prior = self.generation, prior != generation { invalid = true; return }
            self.generation = generation
            if let last = phases.last {
                guard pts > last.last, observedAt >= last.lastObservedAt else { invalid = true; return }
                if last.width == width && last.height == height {
                    phases[phases.count - 1].frames += 1
                    phases[phases.count - 1].maximumSourceGap = max(last.maximumSourceGap, CMTimeSubtract(pts, last.last).seconds)
                    phases[phases.count - 1].maximumObservationGap = max(last.maximumObservationGap, observedAt - last.lastObservedAt)
                    phases[phases.count - 1].lastObservedAt = observedAt
                    phases[phases.count - 1].last = pts
                    return
                }
            }
            guard phases.count < 3 else { invalid = true; return }
            phases.append(.init(width: width, height: height, first: pts, last: pts, frames: 1, maximumSourceGap: 0, firstObservedAt: observedAt, lastObservedAt: observedAt, maximumObservationGap: 0))
        }
    }
    func observeEncoder(_ frame: SRTPublisher.EncoderFrame) {
        recordEncoder(id: frame.encoderSessionID, pts: frame.sourcePTS,
            submittedAt: frame.submittedAt, completedAt: frame.completedAt)
    }
    func recordEncoder(id: UUID, pts: CMTime, submittedAt: Double, completedAt: Double) {
        lock.withLock {
            guard !closed, encoderFrames < 25_000, pts.isNumeric, pts.timescale > 0, pts.epoch == 0, pts >= .zero,
                  submittedAt.isFinite, completedAt.isFinite, (0...1e12).contains(submittedAt),
                  completedAt >= submittedAt, completedAt <= 1e12 else { invalid = true; return }
            encoderFrames += 1
            if let prior = encoderSessions.last {
                guard pts > prior.last, completedAt >= prior.lastCompletedAt else { invalid = true; return }
                if prior.id == id {
                    let n = encoderSessions.count - 1
                    encoderSessions[n].frames += 1; encoderSessions[n].last = pts
                    encoderSessions[n].maximumCompletionGap = max(prior.maximumCompletionGap, completedAt - prior.lastCompletedAt)
                    encoderSessions[n].lastCompletedAt = completedAt
                    encoderSessions[n].maximumEncodeLatency = max(prior.maximumEncodeLatency, completedAt - submittedAt)
                    return
                }
            }
            guard encoderSessions.count < 3, !encoderSessions.contains(where: { $0.id == id }) else { invalid = true; return }
            encoderSessions.append(.init(id: id, first: pts, firstCompletedAt: completedAt, last: pts, frames: 1,
                lastCompletedAt: completedAt, maximumCompletionGap: 0, maximumEncodeLatency: completedAt - submittedAt))
        }
    }
    func receipt(_ value: PublishingVideoProfileChange) {
        lock.withLock {
            guard !closed, receipts.count < 2 else { invalid = true; return }
            receipts.append(value)
        }
    }
    func fail() { lock.withLock { invalid = true } }
    func close() { lock.withLock { closed = true } }
    func data() throws -> Data {
        let object: [String: Any] = lock.withLock {
            ["formatVersion": 2, "isClosed": closed, "invalid": invalid, "frames": frames,
             "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                "broadcastGeneration": scope.broadcastGeneration, "publishingAttemptID": scope.publishingAttemptID.uuidString,
                "appliedProfileRevision": String(scope.appliedProfileRevision)],
             "publishingGeneration": generation.map(String.init) as Any? ?? NSNull(),
             "phases": phases.map { ["width": $0.width, "height": $0.height, "frames": $0.frames,
                "firstSourcePTS": Self.time($0.first), "lastSourcePTS": Self.time($0.last),
                "maximumSourceGapSeconds": $0.maximumSourceGap, "firstObservedAt": $0.firstObservedAt,
                "lastObservedAt": $0.lastObservedAt, "maximumObservationGapSeconds": $0.maximumObservationGap] as [String: Any] },
             "encoderSessions": encoderSessions.map { ["encoderSessionID": $0.id.uuidString, "frames": $0.frames,
                "firstSourcePTS": Self.time($0.first), "lastSourcePTS": Self.time($0.last),
                "firstCompletedAt": $0.firstCompletedAt, "lastCompletedAt": $0.lastCompletedAt,
                "maximumCompletionGapSeconds": $0.maximumCompletionGap, "maximumEncodeLatencySeconds": $0.maximumEncodeLatency] as [String: Any] },
             "receipts": receipts.map { ["profile": $0.profile.rawValue,
                "publishingGeneration": String($0.publishingGeneration),
                "previousEncoderSessionID": $0.previousEncoderSessionID.uuidString,
                "encoderSessionID": $0.encoderSessionID.uuidString,
                "lastOldSourcePTS": Self.time($0.lastOldSourcePTS), "firstNewSourcePTS": Self.time($0.firstNewSourcePTS),
                "width": $0.width, "height": $0.height, "rawVideoFramesDropped": String($0.rawVideoFramesDropped),
                "acknowledgedAt": $0.acknowledgedAt] as [String: Any] }]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private static func time(_ pts: CMTime) -> [String: Any] {
        ["value": String(pts.value), "timescale": pts.timescale, "epoch": String(pts.epoch), "flags": pts.flags.rawValue]
    }
    static func requested(environment: [String: String]) throws -> Bool {
        guard let flag = environment["SCOREBUG_TEST_PROFILE_TRANSITIONS"], !flag.isEmpty else { return false }
        guard flag == "1", VideoObservationFixture.requested(environment: environment),
              environment["SCOREBUG_TEST_MOTION_FIXTURE"] == "blocks16",
              (environment["SCOREBUG_TEST_LIVE_PROFILE"] ?? "").isEmpty,
              (environment["SCOREBUG_TEST_NATIVE_QUALITY"] ?? "").isEmpty,
              (environment["SCOREBUG_TEST_NATIVE_CONFIRMATION"] ?? "").isEmpty,
              (environment["SCOREBUG_TEST_UPLINK_PROXY_PORT"] ?? "").isEmpty,
              (environment["SCOREBUG_TEST_UPLINK_PROFILE"] ?? "").isEmpty,
              let raw = environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"], let hold = Int(raw),
              String(hold) == raw, (90...600).contains(hold) else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
        return true
    }
    static func persist(_ data: Data) async {
        await Task.detached(priority: .utility) {
            do {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Scorebug/QA", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("native-profile-transitions.json"), options: .atomic)
            } catch { /* Missing evidence fails qualification, never recording. */ }
        }.value
    }
}
/// This wrapper adds observation ownership only; PublishingSession still owns admission.
final class NativeProfileTransitionPublisher: MediaPublisher, Sendable {
    let evidence: NativeProfileTransitionEvidence
    private let publisher: any MediaPublisher
    init(url: URL, observations: VideoFrameObservationOwner) {
        let evidence = NativeProfileTransitionEvidence(scope: observations.snapshot.scope)
        self.evidence = evidence
        publisher = SRTMediaPublisher(url: url, observations: observations,
            encoderConfigurationObserver: { evidence.observeEncoder($0) },
            compressedVideoObserver: { evidence.observe($0) })
    }
    func start() async throws { try await publisher.start() }
    func append(_ sample: CapturedMediaSample) async throws { try await publisher.append(sample) }
    var isPublishing: Bool { get async { await publisher.isPublishing } }
    func stop() async { await publisher.stop() }
    func transportClock() async -> PublishingTransportClock? { await publisher.transportClock() }
    func transportStatistics() async -> PublishingTransportStatistics? { await publisher.transportStatistics() }
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange { try await publisher.setVideoBitRate(rate) }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        try await publisher.setVideoProfile(profile)
    }
}

/// Fixed experimental schedule: down after 20 seconds, up 40 seconds later.
/// This is deliberately separate from the production quality controller.
@MainActor final class NativeProfileTransitionDriver {
    private let session: PublishingSession
    private let evidence: NativeProfileTransitionEvidence
    private let export: (Data) async -> Void
    private var work: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    init(session: PublishingSession, evidence: NativeProfileTransitionEvidence,
         waits: [Duration] = [.seconds(20), .seconds(40)],
         export: @escaping (Data) async -> Void = NativeProfileTransitionEvidence.persist) {
        self.session = session; self.evidence = evidence; self.export = export
        work = Task {
            guard waits.count == 2, waits.allSatisfy({ $0 >= .zero }) else { evidence.fail(); return }
            do {
                for (wait, profile) in zip(waits, [PublishingVideoProfile.sd540, .hd1080]) {
                    try await Task.sleep(for: wait)
                    try Task.checkCancellation()
                    let receipt = try await session.setVideoProfile(profile)
                    try Task.checkCancellation()
                    evidence.receipt(receipt)
                }
            } catch {
                if !Task.isCancelled { evidence.fail() }
            }
        }
    }
    func cancel() { work?.cancel() }
    func stop() async {
        if let shutdown { await shutdown.value; return }
        cancel()
        let pending = work
        let finish = Task {
            await session.stop()
            await pending?.value
            evidence.close()
            if let data = try? evidence.data() { await export(data) }
        }
        shutdown = finish
        await finish.value
    }
    func waitForSchedule() async { await work?.value }
}
#endif

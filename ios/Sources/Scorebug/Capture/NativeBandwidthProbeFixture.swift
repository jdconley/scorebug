#if DEBUG
import Foundation
import ScorebugMedia
import ScorebugStreaming

struct NativeBandwidthProbeSample: Sendable {
    let id: UUID
    let publishingGeneration: UInt64
    let bitRate: Int
    let startedAt: Double
    let leaseDeadline: Double
    let acceptedPayloadBytes: UInt64
    let lastAcceptedAt: Double?
    var reason: String?
    var object: [String: Any] {
        ["id": id.uuidString, "publishingGeneration": String(publishingGeneration), "bitRate": bitRate,
         "startedAt": startedAt, "leaseDeadline": leaseDeadline, "acceptedPayloadBytes": String(acceptedPayloadBytes),
         "lastAcceptedAt": lastAcceptedAt as Any? ?? NSNull(), "reason": reason as Any? ?? NSNull()]
    }
}
extension NativeBandwidthProbeSample {
    init(_ value: PublishingBandwidthProbeSnapshot) {
        self.init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: value.acceptedPayloadBytes,
            lastAcceptedAt: value.lastAcceptedAt, reason: value.reason?.rawValue)
    }
}

/// DEBUG-only optional traffic owner. PublishingSession still owns media admission;
/// recording never waits for this task. Shutdown joins work before exporting proof.
actor NativeBandwidthProbePublisher: MediaPublisher {
    enum Mode: String, Sendable { case renew, expire }
    struct Timing: Sendable {
        var delay: Duration = .seconds(20)
        var poll: Duration = .milliseconds(100)
        var maximumPolls: Int = 600
    }
    struct Operations: Sendable {
        let clock: @Sendable () async -> PublishingTransportClock?
        let begin: @Sendable () async throws -> NativeBandwidthProbeSample
        let renew: @Sendable (UUID, UInt64) async throws -> NativeBandwidthProbeSample
        let cancel: @Sendable (UUID, UInt64) async -> Void
        let snapshot: @Sendable () async -> NativeBandwidthProbeSample?
        let export: @Sendable (Data) async -> Void
    }
    private let publisher: any MediaPublisher
    private let scope: VideoFrameObservationScope
    private let mode: Mode
    private let operations: Operations
    private let timing: Timing
    private var starting = false, started = false, stopped = false, closed = false, invalid = false
    private var result = "notStarted"
    private var generation: UInt64?
    private var handle: NativeBandwidthProbeSample?
    private struct Event {
        let phase: String, at: Double, sample: NativeBandwidthProbeSample
        var object: [String: Any] { ["phase": phase, "observedAt": at, "sample": sample.object] }
    }
    private var events: [Event] = []
    private var work: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    init(publisher: SRTMediaPublisher, scope: VideoFrameObservationScope, mode: Mode) {
        self.publisher = publisher; self.scope = scope; self.mode = mode; timing = Timing()
        operations = .init(clock: { await publisher.transportClock() },
            begin: { NativeBandwidthProbeSample(try await publisher.beginBandwidthProbe(bitRate: 1_000_000)) },
            renew: { NativeBandwidthProbeSample(try await publisher.renewBandwidthProbe(id: $0, publishingGeneration: $1)) },
            cancel: { await publisher.cancelBandwidthProbe(id: $0, publishingGeneration: $1) },
            snapshot: { await publisher.bandwidthProbeSnapshot().map(NativeBandwidthProbeSample.init) },
            export: { await Self.persist($0) })
    }
    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope, mode: Mode,
         operations: Operations, timing: Timing) {
        self.publisher = publisher; self.scope = scope; self.mode = mode
        self.operations = operations; self.timing = timing
    }
    func start() async throws {
        guard !starting, !started, !stopped else { throw FixtureError.lifecycle }
        starting = true
        defer { starting = false }
        try await publisher.start()
        guard !stopped, !Task.isCancelled else { await publisher.stop(); throw CancellationError() }
        started = true
        work = Task { await run() }
    }
    func append(_ sample: CapturedMediaSample) async throws { try await publisher.append(sample) }
    var isPublishing: Bool { get async { await publisher.isPublishing } }
    func transportClock() async -> PublishingTransportClock? { await publisher.transportClock() }
    func transportStatistics() async -> PublishingTransportStatistics? { await publisher.transportStatistics() }
    func setVideoBitRate(_ rate: Int) async throws -> PublishingBitRateChange { try await publisher.setVideoBitRate(rate) }
    func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange { try await publisher.setVideoProfile(profile) }

    func stop() async {
        stopped = true
        work?.cancel()
        if let shutdown { await shutdown.value; return }
        let pending = work
        let finish = Task {
            await publisher.stop() // Release any native operation blocked during admission.
            await pending?.value
            if let value = await operations.snapshot() { _ = record(value, phase: "final") }
            closed = true
            if let data = try? data() { await operations.export(data) }
        }
        shutdown = finish
        await finish.value
    }
    func waitForProbe() async { await work?.value }

    private func run() async {
        do {
            guard timing.delay >= .zero, timing.poll >= .zero, (1...600).contains(timing.maximumPolls) else {
                throw FixtureError.invalidEvidence
            }
            try await Task.sleep(for: timing.delay)
            try Task.checkCancellation()
            let readinessDeadline = ProcessInfo.processInfo.systemUptime + 10
            for _ in 0..<100 {
                if let clock = await operations.clock() { generation = clock.publishingGeneration; break }
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < readinessDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard generation != nil else { result = "clockUnavailable"; return }
            let value = try await operations.begin()
            handle = value
            guard record(value, phase: "began") else { throw FixtureError.invalidEvidence }
            try Task.checkCancellation()
            result = "completed"
            if value.reason == nil {
                for _ in 0..<timing.maximumPolls {
                    try await Task.sleep(for: timing.poll)
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - value.startedAt < 50 else { break }
                    let next: NativeBandwidthProbeSample?
                    if mode == .renew { next = try await operations.renew(value.id, value.publishingGeneration) }
                    else { next = await operations.snapshot() }
                    try Task.checkCancellation()
                    guard let next, record(next, phase: mode == .renew ? "renewed" : "observed") else {
                        throw FixtureError.invalidEvidence
                    }
                    if next.reason != nil { result = "withdrawn"; break }
                }
            } else { result = "withdrawn" }
        } catch {
            if Task.isCancelled || error is CancellationError { result = "cancelled" }
            else if error is FixtureError { invalid = true; result = "invalidEvidence" }
            else { result = "operationFailed" }
        }
        if let handle { await operations.cancel(handle.id, handle.publishingGeneration) }
    }

    @discardableResult private func record(_ value: NativeBandwidthProbeSample, phase: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard !closed, events.count < 602, now.isFinite, value.startedAt.isFinite,
              value.startedAt >= 0, value.startedAt <= now, value.leaseDeadline.isFinite,
              value.leaseDeadline > value.startedAt, value.leaseDeadline <= value.startedAt + 60.3,
              value.publishingGeneration == generation, value.bitRate == 1_000_000,
              value.acceptedPayloadBytes <= 16 * 1024 * 1024, value.acceptedPayloadBytes % 1316 == 0,
              (value.acceptedPayloadBytes == 0) == (value.lastAcceptedAt == nil),
              value.lastAcceptedAt.map({ $0.isFinite && $0 >= value.startedAt && $0 <= now }) ?? true else {
            invalid = true; return false
        }
        if let prior = events.last {
            guard value.id == prior.sample.id, value.startedAt == prior.sample.startedAt,
                  value.acceptedPayloadBytes >= prior.sample.acceptedPayloadBytes,
                  value.leaseDeadline >= prior.sample.leaseDeadline, now >= prior.at,
                  prior.sample.reason == nil || (value.reason == prior.sample.reason && value.acceptedPayloadBytes == prior.sample.acceptedPayloadBytes) else {
                invalid = true; return false
            }
        }
        events.append(.init(phase: phase, at: now, sample: value))
        return true
    }
    private func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "isClosed": closed, "invalid": invalid,
            "mode": mode.rawValue, "result": result,
            "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                "broadcastGeneration": scope.broadcastGeneration, "publishingAttemptID": scope.publishingAttemptID.uuidString,
                "appliedProfileRevision": String(scope.appliedProfileRevision)],
            "publishingGeneration": generation.map(String.init) as Any? ?? NSNull(),
            "events": events.map(\.object)], options: [.sortedKeys])
    }
    static func requested(environment: [String: String]) throws -> Mode? {
        guard let flag = environment["SCOREBUG_TEST_BANDWIDTH_PROBE"], !flag.isEmpty else { return nil }
        guard let mode = Mode(rawValue: flag), try VideoObservationFixture.liveProfile(environment: environment) == .sd540,
              ["SCOREBUG_TEST_NATIVE_QUALITY", "SCOREBUG_TEST_NATIVE_CONFIRMATION", "SCOREBUG_TEST_ADAPTIVE_PROFILES",
               "SCOREBUG_TEST_PROFILE_TRANSITIONS", "SCOREBUG_TEST_SOURCE_CADENCE_PACING"].allSatisfy({ (environment[$0] ?? "").isEmpty }) else {
            throw VideoObservationFixture.UplinkError.invalidFixtureRoute
        }
        return mode
    }
    private static func persist(_ data: Data) async {
        await Task.detached(priority: .utility) {
            do {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Scorebug/QA", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("native-bandwidth-probe.json"), options: .atomic)
            } catch { /* Missing evidence fails qualification; it never owns recording. */ }
        }.value
    }
    private enum FixtureError: Error { case lifecycle, invalidEvidence }
}
#endif

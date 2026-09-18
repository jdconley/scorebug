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
    var stage: Int? = nil
    var campaign: UInt32? = nil
    var permitsCurrentOwner: (@Sendable (UUID, UInt64, Int?) -> Bool)? = nil
    var campaignStartedAt: Double? = nil
    var totalAcceptedPayloadBytes: UInt64? = nil
    var object: [String: Any] {
        var object: [String: Any] = ["id": id.uuidString, "publishingGeneration": String(publishingGeneration), "bitRate": bitRate,
         "startedAt": startedAt, "leaseDeadline": leaseDeadline, "acceptedPayloadBytes": String(acceptedPayloadBytes),
         "lastAcceptedAt": lastAcceptedAt as Any? ?? NSNull(), "reason": reason as Any? ?? NSNull()]
        if let stage { object["stage"] = stage }
        if let campaign { object["campaign"] = String(campaign) }
        if let campaignStartedAt { object["campaignStartedAt"] = campaignStartedAt }
        if let totalAcceptedPayloadBytes { object["totalAcceptedPayloadBytes"] = String(totalAcceptedPayloadBytes) }
        return object
    }
}
extension NativeBandwidthProbeSample {
    init(_ value: PublishingBandwidthProbeSnapshot) {
        self.init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: value.acceptedPayloadBytes,
            lastAcceptedAt: value.lastAcceptedAt, reason: value.reason?.rawValue,
            stage: value.stage.flatMap(Int.init(exactly:)), campaign: value.campaign, permitsCurrentOwner: PublishingProbeObservation(value).permitsCurrentOwner,
            campaignStartedAt: value.campaignStartedAt, totalAcceptedPayloadBytes: value.totalAcceptedPayloadBytes)
    }
}

/// DEBUG-only optional traffic owner. PublishingSession still owns media admission;
/// recording never waits for this task. Shutdown joins work before exporting proof.
actor NativeBandwidthProbePublisher: MediaPublisher, PublishingProbeObserving {
    enum Mode: String, Sendable { case renew, expire, staged }
    struct Timing: Sendable {
        var delay: Duration = .seconds(20)
        var poll: Duration = .milliseconds(100)
        var maximumPolls: Int = 600
        var stagePolls: Int = 80
        var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    }
    struct Operations: Sendable {
        let clock: @Sendable () async -> PublishingTransportClock?
        let begin: @Sendable () async throws -> NativeBandwidthProbeSample
        let renew: @Sendable (UUID, UInt64) async throws -> NativeBandwidthProbeSample
        let cancel: @Sendable (UUID, UInt64) async -> Void
        let snapshot: @Sendable () async -> NativeBandwidthProbeSample?
        let export: @Sendable (Data) async -> Void
        var beginStaged: @Sendable () async throws -> NativeBandwidthProbeSample = { throw PublishingBandwidthProbeError.disabled }
        var replace: @Sendable (UUID, UInt64, Int, Int) async throws -> NativeBandwidthProbeSample = { _,_,_,_ in throw PublishingBandwidthProbeError.disabled }
    }
    private let publisher: any MediaPublisher
    private let scope: VideoFrameObservationScope
    private let mode: Mode
    private let operations: Operations
    private let timing: Timing
    private let candidateHeadroom: Bool
    private var starting = false, started = false, stopped = false, closed = false, invalid = false
    private var result = "notStarted"
    private var generation: UInt64?
    private var handle: NativeBandwidthProbeSample?
    private struct Event {
        let phase: String, at: Double, sample: NativeBandwidthProbeSample
        let retirementRequestedAt: Double?
        var object: [String: Any] {
            var object: [String: Any] = ["phase": phase, "observedAt": at, "sample": sample.object]
            if let retirementRequestedAt { object["retirementRequestedAt"] = retirementRequestedAt }
            return object
        }
    }
    private var events: [Event] = []
    private var work: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    init(publisher: SRTMediaPublisher, scope: VideoFrameObservationScope, mode: Mode, candidateHeadroom: Bool = false) {
        self.publisher = publisher; self.scope = scope; self.mode = mode; timing = Timing()
        self.candidateHeadroom = candidateHeadroom
        operations = .init(clock: { await publisher.transportClock() },
            begin: { NativeBandwidthProbeSample(try await publisher.beginBandwidthProbe(bitRate: 1_000_000)) },
            renew: { NativeBandwidthProbeSample(try await publisher.renewBandwidthProbe(id: $0, publishingGeneration: $1)) },
            cancel: { await publisher.cancelBandwidthProbe(id: $0, publishingGeneration: $1) },
            snapshot: { await publisher.bandwidthProbeSnapshot().map(NativeBandwidthProbeSample.init) },
            export: { await Self.persist($0) },
            beginStaged: { NativeBandwidthProbeSample(try await publisher.beginBandwidthProbe(bitRate: 500_000, staged: true)) },
            replace: { id, generation, stage, rate in
                guard let ordinal = UInt32(exactly: stage) else { throw PublishingBandwidthProbeError.obsolete }
                return NativeBandwidthProbeSample(try await publisher.replaceBandwidthProbe(id: id,
                    publishingGeneration: generation, stage: ordinal, bitRate: rate))
            })
    }
    init(publisher: any MediaPublisher, scope: VideoFrameObservationScope, mode: Mode,
         operations: Operations, timing: Timing, candidateHeadroom: Bool = false) {
        self.publisher = publisher; self.scope = scope; self.mode = mode
        self.operations = operations; self.timing = timing; self.candidateHeadroom = candidateHeadroom
    }
    nonisolated var videoStartup: PublishingVideoStartup? { publisher.videoStartup }
    func start() async throws {
        guard !starting, !started, !stopped else { throw FixtureError.lifecycle }
        starting = true
        defer { starting = false }
        try await publisher.start()
        guard !stopped, !Task.isCancelled else { await publisher.stop(); throw CancellationError() }
        started = true
        work = Task { await run() }
    }
    func probeObservation() async -> PublishingProbeObservation? {
        guard let value = await operations.snapshot() else { return nil }
        return .init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline, acceptedPayloadBytes: value.acceptedPayloadBytes,
            lastAcceptedAt: value.lastAcceptedAt, reason: value.reason, stage: value.stage, campaign: value.campaign,
            permitsCurrentOwner: value.permitsCurrentOwner)
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
            else if mode == .staged, handle != nil || !events.isEmpty {
                invalid = true
                if result == "completed" || result == "withdrawn" { result = "invalidEvidence" }
            }
            closed = true
            if let data = try? data(), !candidateHeadroom || data.count <= 256 * 1024 { await operations.export(data) }
        }
        shutdown = finish
        await finish.value
    }
    func waitForProbe() async { await work?.value }

    private func run() async {
        do {
            guard timing.delay >= .zero, timing.poll >= .zero, (1...600).contains(timing.maximumPolls),
                  !candidateHeadroom || mode == .staged,
                  mode != .staged || ((1...200).contains(timing.stagePolls) && timing.stagePolls * 3 <= timing.maximumPolls) else {
                throw FixtureError.invalidEvidence
            }
            try await Task.sleep(for: timing.delay)
            try Task.checkCancellation()
            let readinessDeadline = timing.now() + 10
            for _ in 0..<100 {
                if let clock = await operations.clock() { generation = clock.publishingGeneration; break }
                try Task.checkCancellation()
                guard timing.now() < readinessDeadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard generation != nil else { result = "clockUnavailable"; return }
            if mode == .staged { try await runStaged() }
            else {
                let value = try await operations.begin()
                handle = value
                guard record(value, phase: "began") else { throw FixtureError.invalidEvidence }
                try Task.checkCancellation()
                result = "completed"
                if value.reason == nil {
                    for _ in 0..<timing.maximumPolls {
                        try await Task.sleep(for: timing.poll)
                        try Task.checkCancellation()
                        guard timing.now() - value.startedAt < 50 else { break }
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
            }
        } catch {
            if Task.isCancelled || error is CancellationError { result = "cancelled" }
            else if error is FixtureError { invalid = true; result = "invalidEvidence" }
            else { result = "operationFailed" }
        }
        if let handle, mode != .staged || handle.reason == nil {
            await operations.cancel(handle.id, handle.publishingGeneration)
        }
    }

    private var stagedBitRates: [Int] { candidateHeadroom ? [500_000, 2_000_000, 12_000_000] : [500_000, 1_000_000, 2_000_000] }
    private func runStaged() async throws {
        var current = try await operations.beginStaged()
        handle = current
        try Task.checkCancellation()
        guard record(current, phase: "began") else { throw FixtureError.invalidEvidence }
        result = "completed"
        for (index, _) in stagedBitRates.enumerated() {
            if current.reason != nil { result = "withdrawn"; return }
            let stageDeadline = current.startedAt + 8
            for _ in 0..<timing.stagePolls {
                if candidateHeadroom, timing.now() >= stageDeadline { break }
                try await Task.sleep(for: timing.poll)
                try Task.checkCancellation()
                if candidateHeadroom, timing.now() >= stageDeadline { break }
                let renewed = try await operations.renew(current.id, current.publishingGeneration)
                handle = renewed
                try Task.checkCancellation()
                guard record(renewed, phase: "renewed") else { throw FixtureError.invalidEvidence }
                current = renewed
                if renewed.reason != nil { result = "withdrawn"; return }
            }
            let retirementRequestedAt = timing.now()
            await operations.cancel(current.id, current.publishingGeneration)
            try Task.checkCancellation()
            guard let retired = await operations.snapshot() else { throw FixtureError.invalidEvidence }
            handle = retired
            try Task.checkCancellation()
            guard retired.reason != nil,
                  record(retired, phase: "retired", retirementRequestedAt: retirementRequestedAt) else {
                throw FixtureError.invalidEvidence
            }
            if retired.reason != "cancelled" { result = "withdrawn"; return }
            if index == stagedBitRates.count - 1 { return }
            guard let stage = retired.stage else { throw FixtureError.invalidEvidence }
            let replacement = try await operations.replace(retired.id, retired.publishingGeneration, stage,
                stagedBitRates[index + 1])
            handle = replacement
            try Task.checkCancellation()
            guard record(replacement, phase: "replaced") else { throw FixtureError.invalidEvidence }
            current = replacement
        }
    }

    @discardableResult private func record(_ value: NativeBandwidthProbeSample, phase: String,
                                           retirementRequestedAt: Double? = nil) -> Bool {
        let now = timing.now()
        guard !closed, events.count < (mode == .staged ? 607 : 602), now.isFinite, value.startedAt.isFinite,
              value.startedAt >= 0, value.startedAt <= now, value.leaseDeadline.isFinite,
              value.leaseDeadline > value.startedAt, value.leaseDeadline <= value.startedAt + 60.3,
              value.publishingGeneration == generation,
              value.acceptedPayloadBytes <= 16 * 1024 * 1024, value.acceptedPayloadBytes % 1316 == 0,
              (value.acceptedPayloadBytes == 0) == (value.lastAcceptedAt == nil),
              value.lastAcceptedAt.map({ $0.isFinite && $0 >= value.startedAt && $0 <= now }) ?? true else {
            invalid = true; return false
        }
        if mode == .staged {
            guard let stage = value.stage, (1...3).contains(stage), value.bitRate == stagedBitRates[stage - 1],
                  let origin = value.campaignStartedAt, origin.isFinite, origin >= 0, origin <= value.startedAt,
                  value.startedAt - origin < 60, value.leaseDeadline <= origin + 60.3,
                  let total = value.totalAcceptedPayloadBytes, total <= 16 * 1024 * 1024,
                  total % 1316 == 0, total >= value.acceptedPayloadBytes,
                  value.lastAcceptedAt.map({ $0 <= value.leaseDeadline && $0 < origin + 60 }) ?? true else {
                invalid = true; return false
            }
            if phase == "retired" {
                guard let retirementRequestedAt, retirementRequestedAt.isFinite,
                      retirementRequestedAt >= (events.last?.at ?? value.startedAt), retirementRequestedAt <= now,
                      value.reason != nil else { invalid = true; return false }
            } else if retirementRequestedAt != nil { invalid = true; return false }
        } else if value.bitRate != 1_000_000 || value.stage != nil || value.campaignStartedAt != nil || value.totalAcceptedPayloadBytes != nil {
            invalid = true; return false
        }
        if let prior = events.last {
            guard now >= prior.at else { invalid = true; return false }
            if mode == .staged, value.stage != prior.sample.stage {
                guard (phase == "replaced" || (phase == "final" && result == "cancelled")),
                      value.stage == prior.sample.stage.map({ $0 + 1 }), value.id != prior.sample.id,
                      prior.sample.reason == "cancelled", value.startedAt >= prior.at,
                      value.campaignStartedAt == prior.sample.campaignStartedAt,
                      value.acceptedPayloadBytes == 0,
                      value.totalAcceptedPayloadBytes == prior.sample.totalAcceptedPayloadBytes else {
                    invalid = true; return false
                }
            } else {
                guard phase != "replaced", value.id == prior.sample.id, value.startedAt == prior.sample.startedAt,
                      value.acceptedPayloadBytes >= prior.sample.acceptedPayloadBytes,
                      value.leaseDeadline >= prior.sample.leaseDeadline,
                      prior.sample.reason == nil || (value.reason == prior.sample.reason && value.acceptedPayloadBytes == prior.sample.acceptedPayloadBytes),
                      prior.sample.lastAcceptedAt.map({ old in value.lastAcceptedAt.map { $0 >= old } ?? false }) ?? true else {
                    invalid = true; return false
                }
                if mode == .staged {
                    guard value.campaignStartedAt == prior.sample.campaignStartedAt,
                          let total = value.totalAcceptedPayloadBytes, let oldTotal = prior.sample.totalAcceptedPayloadBytes,
                          total >= oldTotal, total - oldTotal == value.acceptedPayloadBytes - prior.sample.acceptedPayloadBytes else {
                        invalid = true; return false
                    }
                }
            }
        } else if phase != "began" || (mode == .staged && (value.stage != 1 || value.campaignStartedAt != value.startedAt || value.totalAcceptedPayloadBytes != 0)) {
            invalid = true; return false
        }
        events.append(.init(phase: phase, at: now, sample: value, retirementRequestedAt: retirementRequestedAt))
        return true
    }
    private func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": mode == .staged ? 2 : 1, "isClosed": closed, "invalid": invalid,
            "mode": mode.rawValue, "result": result,
            "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                "broadcastGeneration": scope.broadcastGeneration, "publishingAttemptID": scope.publishingAttemptID.uuidString,
                "appliedProfileRevision": String(scope.appliedProfileRevision)],
            "publishingGeneration": generation.map(String.init) as Any? ?? NSNull(),
            "events": events.map(\.object)], options: [.sortedKeys])
    }
    static func requested(environment: [String: String]) throws -> Mode? {
        if try NativeCandidateHeadroomFixture.requested(environment: environment) { return .staged }
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

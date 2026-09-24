#if DEBUG
import Foundation

/// Advisory scalar evidence only. The bounded prefix grants no authority and is
/// serialized once, after the publisher has joined work and retired its owner.
final class NativeCandidateWaitTrace: @unchecked Sendable {
    enum Kind: String, Codable, Sendable {
        case campaignStarted, poll, operationStarted, operationReturned, operationFailed
        case postStartContext, measurementJoined
        // Measurement-path completion, not a retirement receipt: the admission
        // wait and ownership retirement may follow. Export joins all teardown.
        case campaignEnded
    }
    enum Outcome: String, Codable, Sendable {
        case probeUnavailable, probeRejectedOrNotReady, contextUnavailable, contextMismatch
        case leaseExpiredAfterAwait, probeRejectedAfterAwait, deadline, bound, matched
        case cancelled, completed, startupFailed, pressure, ownerChanged, publisherStopped
    }
    struct Probe: Codable, Sendable {
        let id: UUID
        let publishingGeneration: UInt64
        let stage: Int?
        let campaign: UInt32?
        let bitRate: Int
        let startedAt: Double
        let leaseDeadline: Double
        init(_ value: PublishingProbeObservation) {
            id = value.id; publishingGeneration = value.publishingGeneration
            stage = value.stage; campaign = value.campaign; bitRate = value.bitRate
            startedAt = value.startedAt; leaseDeadline = value.leaseDeadline
        }
    }
    struct Context: Codable, Sendable {
        let appliedRevision: UInt64
        let readinessAppliedRevision: UInt64
        let healthyThrough: Double
        let validUntil: Double
        init(_ value: PublishingQualitySession.CandidateMeasurementContext) {
            appliedRevision = value.applied.revision
            readinessAppliedRevision = value.readiness.appliedRevision
            healthyThrough = value.readiness.healthyThrough; validUntil = value.readiness.validUntil
        }
    }
    struct Event: Codable, Sendable {
        let kind: Kind
        let campaign: UInt32
        var at: Double
        var outcome: Outcome?
        var queryStartedAt: Double?
        var probeReturnedAt: Double?
        var probe: Probe?
        var contextReadStartedAt: Double?
        var contextReadReturnedAt: Double?
        var context: Context?
        var operationStarted: Bool?
        var valid: Bool {
            let times = [at, queryStartedAt, probeReturnedAt, contextReadStartedAt,
                contextReadReturnedAt, probe?.startedAt, probe?.leaseDeadline,
                context?.healthyThrough, context?.validUntil].compactMap { $0 }
            return (1...2).contains(campaign) && times.allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }
    private struct Export: Encodable {
        let formatVersion = 1
        let isClosed = true
        let eventLimit = 4096
        let byteLimit = 4 * 1024 * 1024
        let attemptID: UUID
        let events: [Event]
        let overflow: Bool
        let invalid: Bool
        let omittedEventCount: UInt64
    }
    private let lock = NSLock()
    private let attemptID: UUID
    private let export: @Sendable (Data) async -> Void
    private var events: [Event] = []
    private var closed = false, overflow = false, invalid = false
    private var omitted: UInt64 = 0
    init(attemptID: UUID, export: @escaping @Sendable (Data) async -> Void = { await NativeCandidateWaitTrace.persist($0) }) {
        self.attemptID = attemptID; self.export = export
    }
    private func omit() { if omitted < UInt64.max { omitted += 1 } }
    func record(_ event: Event) {
        lock.withLock {
            guard !closed else { return }
            guard events.count < 4096 else { overflow = true; invalid = true; omit(); return }
            // Once an event is omitted, retain only the original ordered prefix.
            guard omitted == 0, event.valid else { invalid = true; omit(); return }
            events.append(event)
        }
    }
    func closeAndExport() async {
        let data: Data? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // The scalar schema is small enough for all 4,096 events; enforce a
            // final byte ceiling as well, preserving the prefix on any overflow.
            while true {
                let object = Export(attemptID: attemptID, events: events, overflow: overflow,
                    invalid: invalid, omittedEventCount: omitted)
                if let data = try? encoder.encode(object), data.count <= 4 * 1024 * 1024 { return data }
                guard !events.isEmpty else { return nil }
                events.removeLast(); overflow = true; invalid = true; omit()
            }
        }
        if let data { await export(data) }
    }
    private static func persist(_ data: Data) async {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("native-candidate-wait.json"), options: .atomic)
        }.value
    }
}
#endif

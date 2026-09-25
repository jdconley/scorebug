#if DEBUG
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Bounded observations of actual calls and returned handles. No event or scalar
/// can authorize allocation, settlement, or native mutation.
final class PublishingOwnedMeasurementAudit: @unchecked Sendable {
    static let maximumAttempts = 16
    static let maximumEvents = 4096
    private let timingProfile: StreamingTimingProfile
    private let scope: VideoFrameObservationScope
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var closed = false, overflow = false
    private var closedAt: Double?
    init(scope: VideoFrameObservationScope, timingProfile: StreamingTimingProfile = .strict1500) { self.scope = scope; self.timingProfile = timingProfile }
    func record(_ kind: String, owner: UUID, registeredAt: Double, revision: UInt64, fields: [String: Any] = [:]) {
        lock.withLock {
            guard !closed, events.count < Self.maximumEvents else { overflow = true; return }
            var row = fields
            row["ordinal"] = String(events.count + 1)
            row["kind"] = kind; row["at"] = ProcessInfo.processInfo.systemUptime
            row["ownerID"] = owner.uuidString.lowercased(); row["coreRegisteredAt"] = registeredAt
            row["appliedRevision"] = String(revision)
            events.append(row)
        }
    }
    func close() { lock.withLock { if !closed { closed = true; closedAt = ProcessInfo.processInfo.systemUptime } } }
    func data() throws -> Data {
        try lock.withLock {
            var fields: [String: Any] = ["formatVersion": 1, "isClosed": closed, "closedAt": closedAt as Any? ?? NSNull(), "overflow": overflow,
                "scope": NativeCandidateFixture.scope(scope), "maximumAttempts": Self.maximumAttempts,
                "maximumEvents": Self.maximumEvents, "events": events]
            fields["timingContract"] = timingProfile.evidence
            return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
    }
    static func snapshot(_ value: PublishingBandwidthProbeSnapshot) -> [String: Any] {
        var result = NativeBandwidthProbeSample(value).object
        result["policy"] = value.policy.rawValue
        return result
    }
    static func diagnostic(_ value: QualityController.CandidateMeasurementDiagnostic) -> [String: Any] {
        ["consecutiveFailures": value.consecutiveFailures, "healthyNotBefore": value.healthyNotBefore,
         "requiredHealthyDuration": value.requiredHealthyDuration, "failureEpisodeActive": value.failureEpisodeActive,
         "recoveryStart": value.recoveryStart as Any? ?? NSNull(),
         "strongHealthSequence": value.strongHealthSequence.map(String.init) as Any? ?? NSNull(),
         "strongHealthStart": value.strongHealthStart as Any? ?? NSNull(), "strongHealthEnd": value.strongHealthEnd as Any? ?? NSNull()]
    }
    static func receipt(_ value: PublishingBitRateChange) -> [String: Any] {
        ["publishingGeneration": String(value.publishingGeneration), "configurationID": value.configuration.id.uuidString.lowercased(),
         "encoderSessionID": value.configuration.encoderSessionID.uuidString.lowercased(), "bitRate": value.configuration.bitRate,
         "acceptedAt": value.acceptedAt,
         "lastSubmittedSourcePTS": value.lastSubmittedSourcePTS.map {
            ["value": String($0.value), "timescale": $0.timescale, "epoch": String($0.epoch), "flags": $0.flags.rawValue] as [String: Any]
         } as Any? ?? NSNull()]
    }
    func persist() async {
        guard let data = try? data() else { return }
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("owned-measurement-lifecycle.json"), options: .atomic)
        }.value
    }
}
#endif

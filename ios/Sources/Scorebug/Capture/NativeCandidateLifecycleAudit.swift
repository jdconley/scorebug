#if DEBUG
import Foundation
import ScorebugMedia
import ScorebugStreaming

/// Bounded scalar history, separate from the closed candidate measurement. It
/// grants no authority and failures here never interrupt recording or publishing.
final class NativeCandidateLifecycleAudit: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: VideoFrameObservationScope
    private let export: @Sendable (Data) async -> Void
    private var profiles: [[String: Any]] = [], bitRates: [[String: Any]] = []
    private var closed = false, overflow = false, invalid = false
    private var closedAt: Double?
    private var latestProfileRequest: UUID?
    private var pendingProfiles = Set<UUID>()

    init(scope: VideoFrameObservationScope,
         export: @escaping @Sendable (Data) async -> Void = { await NativeCandidateLifecycleAudit.persist($0) }) {
        self.scope = scope; self.export = export
    }
    func rejectOverflow() { lock.withLock { overflow = true; invalid = true } }
    func beginProfile(id: UUID, target: PublishingVideoProfile, requestedAt: Double,
                      measurementID: UUID?, authorityPermitted: Bool,
                      binding: PublishingProbeObservation?, boundAt: Double?, candidateCompletedAt: Double?,
                      currentProbe: PublishingProbeObservation?) {
        lock.withLock {
            guard !closed, profiles.count < 16 else { overflow = true; invalid = true; return }
            if !pendingProfiles.isEmpty { invalid = true }
            pendingProfiles.insert(id)
            // Preserve each rate request's dispatch-time association, but never
            // claim it is unambiguous if a profile starts while that write waits.
            for index in bitRates.indices where bitRates[index]["outcome"] as? String == "pending" {
                bitRates[index]["profileLinkUnambiguous"] = false
                invalid = true
            }
            profiles.append(["requestID": id.uuidString, "requestedAt": requestedAt,
                "targetProfile": target.rawValue, "candidateMeasurementID": measurementID?.uuidString as Any? ?? NSNull(),
                "authorityPermitted": authorityPermitted,
                "probeBinding": ["boundAt": boundAt as Any? ?? NSNull(),
                    "candidateCompletedAt": candidateCompletedAt as Any? ?? NSNull(),
                    "observation": binding.map(Self.probe) as Any? ?? NSNull()],
                "probeAuthorityPermitted": binding.map { $0.permitsCurrentOwner?($0.id, $0.publishingGeneration, $0.stage, $0.policy) == true } ?? false,
                "currentProbe": currentProbe.map(Self.probe) as Any? ?? NSNull(),
                "currentProbeActive": currentProbe?.isActive(at: requestedAt) ?? false,
                "outcome": "pending", "completedAt": NSNull(), "receipt": NSNull(),
                "failure": NSNull(), "terminalProbeRead": NSNull()])
        }
    }
    func finishProfile(id: UUID, completedAt: Double, receipt: PublishingVideoProfileChange?, failure: String?,
                       readStartedAt: Double, readCompletedAt: Double, observation: PublishingProbeObservation?) {
        lock.withLock {
            guard !closed, let index = profiles.firstIndex(where: { $0["requestID"] as? String == id.uuidString }) else { return }
            pendingProfiles.remove(id)
            profiles[index]["completedAt"] = completedAt
            profiles[index]["outcome"] = receipt == nil ? "failed" : "completed"
            profiles[index]["receipt"] = receipt.map(Self.profileReceipt) as Any? ?? NSNull()
            profiles[index]["failure"] = failure.map { String($0.prefix(512)) } as Any? ?? NSNull()
            profiles[index]["terminalProbeRead"] = ["startedAt": readStartedAt, "completedAt": readCompletedAt,
                "observation": observation.map(Self.probe) as Any? ?? NSNull()]
            if let receipt {
                latestProfileRequest = id
                if receipt.profile.rawValue != profiles[index]["targetProfile"] as? String ||
                    receipt.acknowledgedAt < (profiles[index]["requestedAt"] as? Double ?? .infinity) ||
                    receipt.acknowledgedAt > completedAt { invalid = true }
            } else { invalid = true }
            if observation == nil || readStartedAt < completedAt || readCompletedAt < readStartedAt { invalid = true }
        }
    }
    func beginBitRate(id: UUID, target: Int, requestedAt: Double) {
        lock.withLock {
            guard !closed, bitRates.count < 48 else { overflow = true; invalid = true; return }
            let unambiguous = pendingProfiles.isEmpty
            if !unambiguous { invalid = true }
            bitRates.append(["requestID": id.uuidString, "requestedAt": requestedAt, "targetBitRate": target,
                "profileRequestID": unambiguous ? (latestProfileRequest?.uuidString as Any? ?? NSNull()) : NSNull(),
                "profileLinkUnambiguous": unambiguous, "completedAt": NSNull(),
                "outcome": "pending", "receipt": NSNull(), "failure": NSNull()])
        }
    }
    func finishBitRate(id: UUID, completedAt: Double, receipt: PublishingBitRateChange?, failure: String?) {
        lock.withLock {
            guard !closed, let index = bitRates.firstIndex(where: { $0["requestID"] as? String == id.uuidString }) else { return }
            bitRates[index]["completedAt"] = completedAt
            bitRates[index]["outcome"] = receipt == nil ? "failed" : "completed"
            bitRates[index]["receipt"] = receipt.map(Self.bitRateReceipt) as Any? ?? NSNull()
            bitRates[index]["failure"] = failure.map { String($0.prefix(512)) } as Any? ?? NSNull()
            if let receipt {
                if receipt.configuration.bitRate != bitRates[index]["targetBitRate"] as? Int ||
                    receipt.acceptedAt < (bitRates[index]["requestedAt"] as? Double ?? .infinity) ||
                    receipt.acceptedAt > completedAt { invalid = true }
            } else { invalid = true }
        }
    }
    /// Called only after the publisher has joined every owned native operation.
    func closeAndExport() async {
        let data: Data? = lock.withLock {
            guard !closed else { return nil }
            closed = true; closedAt = ProcessInfo.processInfo.systemUptime
            if profiles.contains(where: { $0["outcome"] as? String == "pending" }) ||
                bitRates.contains(where: { $0["outcome"] as? String == "pending" }) { invalid = true }
            let object: [String: Any] = ["formatVersion": 1, "isClosed": closed, "closedAt": closedAt as Any? ?? NSNull(),
                "scope": NativeCandidateFixture.scope(scope), "invalid": invalid, "overflow": overflow,
                "profileRequestLimit": 16, "bitRateRequestLimit": 48,
                "profileRequests": profiles, "bitRateRequests": bitRates]
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        if let data, data.count <= 256 * 1024 { await export(data) }
    }
    private static func probe(_ value: PublishingProbeObservation) -> [String: Any] {
        NativeBandwidthProbeSample(id: value.id, publishingGeneration: value.publishingGeneration,
            bitRate: value.bitRate, startedAt: value.startedAt, leaseDeadline: value.leaseDeadline,
            acceptedPayloadBytes: value.acceptedPayloadBytes, lastAcceptedAt: value.lastAcceptedAt,
            reason: value.reason, stage: value.stage, campaign: value.campaign,
                policy: value.policy, recoveryObservation: value.recoveryObservation).object
    }
    private static func profileReceipt(_ value: PublishingVideoProfileChange) -> [String: Any] {
        ["profile": value.profile.rawValue, "publishingGeneration": String(value.publishingGeneration),
         "previousEncoderSessionID": value.previousEncoderSessionID.uuidString, "encoderSessionID": value.encoderSessionID.uuidString,
         "lastOldSourcePTS": NativeCandidateFixture.time(value.lastOldSourcePTS), "firstNewSourcePTS": NativeCandidateFixture.time(value.firstNewSourcePTS),
         "width": value.width, "height": value.height, "rawVideoFramesDropped": String(value.rawVideoFramesDropped),
         "acknowledgedAt": value.acknowledgedAt]
    }
    private static func bitRateReceipt(_ value: PublishingBitRateChange) -> [String: Any] {
        ["publishingGeneration": String(value.publishingGeneration), "configurationID": value.configuration.id.uuidString,
         "encoderSessionID": value.configuration.encoderSessionID.uuidString, "bitRate": value.configuration.bitRate,
         "acceptedAt": value.acceptedAt, "lastSubmittedSourcePTS": value.lastSubmittedSourcePTS.map(NativeCandidateFixture.time) as Any? ?? NSNull()]
    }
    private static func persist(_ data: Data) async {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("native-candidate-lifecycle.json"), options: .atomic)
        }.value
    }
}
#endif

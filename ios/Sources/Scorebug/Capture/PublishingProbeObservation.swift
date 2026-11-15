import Foundation
import ScorebugStreaming
import SRTHaishinKit

/// Optional read of the existing publisher-owned probe. Never starts or renews
/// traffic; reads must remain bounded and cooperate with publisher teardown.
protocol PublishingProbeObserving: Sendable {
    func probeObservation() async -> PublishingProbeObservation?
}
struct PublishingProbeObservation: Sendable {
    typealias Policy = PublishingBandwidthProbeSnapshot.Policy
    typealias RecoveryObservation = PublishingBandwidthProbeSnapshot.RecoveryObservation
    var budget: PublishingBandwidthProbeSnapshot.Budget = .standard
    var policy: Policy = .localZeroLoss
    var recoveryObservation: RecoveryObservation? = nil
    var id: UUID
    var publishingGeneration: UInt64
    var bitRate: Int
    var startedAt: Double
    var leaseDeadline: Double
    var acceptedPayloadBytes: UInt64
    var lastAcceptedAt: Double?
    var reason: String?
    var stage: Int?
    var campaign: UInt32?
    var permitsCurrentOwner: (@Sendable (UUID, UInt64, Int?, Policy) -> Bool)?
    func isActive(at now: Double) -> Bool {
        if policy == .recoveryBudget {
            guard stage != nil, let recoveryObservation, recoveryObservation.isValid,
                  recoveryObservation.checkedAt >= startedAt, recoveryObservation.checkedAt <= now else { return false }
        } else if recoveryObservation != nil { return false }
        let maximumBitRate = stage == nil ? 2_000_000 : budget.maximumBitRate
        guard budget == .standard || campaign != nil, campaign.map({ $0 > 0 && stage != nil }) ?? true,
              stage.map({ (1...32).contains($0) }) ?? true,
              permitsCurrentOwner?(id, publishingGeneration, stage, policy) == true else { return false }
        guard reason == nil, publishingGeneration > 0, (1...maximumBitRate).contains(bitRate),
              now.isFinite, startedAt.isFinite, startedAt >= 0, now >= startedAt, now - startedAt < 60,
              leaseDeadline.isFinite, leaseDeadline > now, leaseDeadline <= startedAt + 60.3,
              acceptedPayloadBytes <= budget.maximumPayloadBytes, acceptedPayloadBytes % 1316 == 0,
              (acceptedPayloadBytes == 0) == (lastAcceptedAt == nil) else { return false }
        return lastAcceptedAt.map { $0.isFinite && $0 >= startedAt && $0 <= now && $0 < leaseDeadline } ?? true
    }
    init(_ sample: PublishingBandwidthProbeSnapshot) {
        self.init(id: sample.id, publishingGeneration: sample.publishingGeneration, bitRate: sample.bitRate,
            startedAt: sample.startedAt, leaseDeadline: sample.leaseDeadline, acceptedPayloadBytes: sample.acceptedPayloadBytes,
            lastAcceptedAt: sample.lastAcceptedAt, reason: sample.reason?.rawValue,
            stage: sample.stage.flatMap(Int.init(exactly:)), campaign: sample.campaign, permitsCurrentOwner: { id, generation, stage, policy in
                sample.authority?.permits(id: id, generation: generation,
                    stage: stage.flatMap(UInt32.init(exactly:)), policy: policy) == true
            }, policy: sample.policy, recoveryObservation: sample.recoveryObservation, budget: sample.budget)
    }
    init(id: UUID, publishingGeneration: UInt64, bitRate: Int, startedAt: Double, leaseDeadline: Double,
         acceptedPayloadBytes: UInt64, lastAcceptedAt: Double?, reason: String?, stage: Int? = nil, campaign: UInt32? = nil,
         permitsCurrentOwner: (@Sendable (UUID, UInt64, Int?, Policy) -> Bool)? = nil,
         policy: Policy = .localZeroLoss, recoveryObservation: RecoveryObservation? = nil, budget: PublishingBandwidthProbeSnapshot.Budget = .standard) {
        self.budget = budget; self.policy = policy; self.recoveryObservation = recoveryObservation
        self.id = id; self.publishingGeneration = publishingGeneration; self.bitRate = bitRate
        self.startedAt = startedAt; self.leaseDeadline = leaseDeadline; self.acceptedPayloadBytes = acceptedPayloadBytes
        self.lastAcceptedAt = lastAcceptedAt; self.reason = reason
        self.stage = stage; self.campaign = campaign; self.permitsCurrentOwner = permitsCurrentOwner
    }
}
extension SRTMediaPublisher: PublishingProbeObserving {
    func probeObservation() async -> PublishingProbeObservation? { await bandwidthProbeSnapshot().map(PublishingProbeObservation.init) }
}

struct PublishingProbeReadTiming: Sendable {
    let requestStartedAt: Double
    let responseReceivedAt: Double
    let nativeReadStartedAt: Double
    let nativeReadFinishedAt: Double
    let evaluatedAt: Double
}

extension SRTBandwidthProbeRecoveryObservation {
    var auditObject: [String: Any] {
        ["checkedAt": checkedAt, "sampledAt": sampledAt,
         "elapsedMilliseconds": String(elapsedMilliseconds), "sentBytes": String(sentBytes),
         "retransmittedBytes": String(retransmittedBytes), "droppedPackets": droppedPackets,
         "rttMilliseconds": rttMilliseconds, "senderBufferMilliseconds": senderBufferMilliseconds,
         "senderDeliveryDelayMilliseconds": senderDeliveryDelayMilliseconds]
    }
}

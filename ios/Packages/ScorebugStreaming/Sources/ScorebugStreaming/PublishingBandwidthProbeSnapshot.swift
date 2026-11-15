import Foundation
import SRTHaishinKit

public enum PublishingBandwidthProbeError: Error, Equatable, Sendable {
    case disabled, notPublishing, busy, obsolete, cancelled, failed
}

/// Local native acceptance only; this is not receiver delivery or usable capacity.
public struct PublishingBandwidthProbeSnapshot: Equatable, Sendable {
    public typealias RecoveryObservation = SRTBandwidthProbeRecoveryObservation
    public typealias Budget = SRTBandwidthProbeBudget
    public typealias Policy = SRTBandwidthProbePolicy
    public typealias Reason = SRTBandwidthProbeSnapshot.Reason
    public typealias Authority = SRTBandwidthProbeAuthority
    public let id: UUID
    public let publishingGeneration: UInt64
    public let bitRate: Int
    public let startedAt: Double
    public let leaseDeadline: Double
    public let acceptedPayloadBytes: UInt64
    public let lastAcceptedAt: Double?
    public let reason: Reason?
    public internal(set) var budget: Budget = .standard
    public internal(set) var stage: UInt32? = nil
    public internal(set) var campaign: UInt32? = nil
    public internal(set) var authority: Authority? = nil
    public internal(set) var campaignStartedAt: Double? = nil
    public internal(set) var totalAcceptedPayloadBytes: UInt64? = nil
    public internal(set) var policy: Policy = .localZeroLoss
    public internal(set) var recoveryObservation: RecoveryObservation? = nil
}

extension PublishingBandwidthProbeSnapshot {
    init(_ value: SRTBandwidthProbeSnapshot) {
        self.init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline,
            acceptedPayloadBytes: value.acceptedPayloadBytes, lastAcceptedAt: value.lastAcceptedAt, reason: value.reason,
            budget: value.budget, stage: value.stage, campaign: value.campaign, authority: value.authority, campaignStartedAt: value.campaignStartedAt,
            totalAcceptedPayloadBytes: value.totalAcceptedPayloadBytes, policy: value.policy, recoveryObservation: value.recoveryObservation)
    }

    func isValidStart(staged: Bool, bitRate: Int, repeatable: Bool = false, policy: Policy = .localZeroLoss) -> Bool {
        guard self.policy == policy, policy == .localZeroLoss || staged,
              self.bitRate == bitRate, !repeatable || staged,
              campaign == (repeatable ? UInt32(1) : nil) else { return false }
        if !staged { return stage == nil && campaignStartedAt == nil && totalAcceptedPayloadBytes == nil }
        return stage == 1 && hasValidCampaignAccounting && campaignStartedAt == startedAt
            && acceptedPayloadBytes == 0 && totalAcceptedPayloadBytes == 0
    }

    func isValidRenewal(of prior: Self) -> Bool {
        guard budget == prior.budget, policy == prior.policy, id == prior.id, publishingGeneration == prior.publishingGeneration,
              bitRate == prior.bitRate, startedAt == prior.startedAt, stage == prior.stage, campaign == prior.campaign,
              campaignStartedAt == prior.campaignStartedAt,
              acceptedPayloadBytes >= prior.acceptedPayloadBytes else { return false }
        if stage == nil { return campaign == nil && campaignStartedAt == nil && totalAcceptedPayloadBytes == nil }
        guard hasValidCampaignAccounting, prior.hasValidCampaignAccounting,
              let total = totalAcceptedPayloadBytes, let previousTotal = prior.totalAcceptedPayloadBytes,
              total >= previousTotal else { return false }
        return total - previousTotal == acceptedPayloadBytes - prior.acceptedPayloadBytes
    }

    func isValidReplacement(of prior: Self, bitRate: Int) -> Bool {
        guard budget == prior.budget, policy == prior.policy, let previousStage = prior.stage, previousStage < 32,
              stage == previousStage + 1, campaign == prior.campaign, id != prior.id,
              publishingGeneration == prior.publishingGeneration, self.bitRate == bitRate,
              campaignStartedAt == prior.campaignStartedAt, startedAt >= prior.startedAt,
              acceptedPayloadBytes == 0, hasValidCampaignAccounting, prior.hasValidCampaignAccounting,
              let total = totalAcceptedPayloadBytes, let previousTotal = prior.totalAcceptedPayloadBytes else { return false }
        // The native owner may accept more payload after our last acknowledgement,
        // before replacement retires it. That final carry cannot move backwards.
        return total >= previousTotal && total <= budget.maximumPayloadBytes - 1316
    }

    /// A new campaign must carry neither the old traffic budget nor stale time.
    func isValidRestart(of prior: Self, bitRate: Int, requestedAt: Double, observedAt: Double) -> Bool {
        guard budget == prior.budget, policy == prior.policy, (1...budget.maximumBitRate).contains(bitRate), prior.hasValidCampaignAccounting, id != prior.id,
              let previousCampaign = prior.campaign, previousCampaign > 0, previousCampaign < UInt32.max,
              campaign == previousCampaign + 1,
              publishingGeneration == prior.publishingGeneration,
              self.bitRate == bitRate, stage == 1, hasValidCampaignAccounting, campaignStartedAt == startedAt,
              acceptedPayloadBytes == 0, totalAcceptedPayloadBytes == 0, reason == nil, lastAcceptedAt == nil,
              requestedAt.isFinite, observedAt.isFinite, requestedAt >= 0, observedAt >= requestedAt,
              startedAt > prior.startedAt, startedAt >= requestedAt, startedAt <= observedAt,
              leaseDeadline > startedAt, leaseDeadline <= startedAt + 0.3 else { return false }
        return true
    }

    private var hasValidCampaignAccounting: Bool {
        guard budget == .standard || campaign != nil, campaign == nil || campaign! > 0, publishingGeneration > 0, let stage, (1...32).contains(stage), let campaignStartedAt,
              campaignStartedAt.isFinite, campaignStartedAt >= 0, startedAt.isFinite,
              campaignStartedAt <= startedAt, startedAt - campaignStartedAt < 60,
              leaseDeadline.isFinite, leaseDeadline >= startedAt,
              let totalAcceptedPayloadBytes else { return false }
        return totalAcceptedPayloadBytes >= acceptedPayloadBytes && totalAcceptedPayloadBytes <= budget.maximumPayloadBytes
            && totalAcceptedPayloadBytes % 1316 == 0 && acceptedPayloadBytes % 1316 == 0
    }
}

func publishingProbeError(_ error: any Error) -> PublishingBandwidthProbeError {
    if let rejection = error as? PublishingOwnedFactoryRejection { return rejection.reason }
    if let error = error as? PublishingBandwidthProbeError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? SRTBandwidthProbeError {
        switch error {
        case .disabled: return .disabled
        case .notPublishing: return .notPublishing
        case .alreadyStarted: return .busy
        case .obsolete: return .obsolete
        default: return .failed
        }
    }
    return .failed
}

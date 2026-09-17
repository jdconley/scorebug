import Foundation
import SRTHaishinKit

public enum PublishingBandwidthProbeError: Error, Equatable, Sendable {
    case disabled, notPublishing, busy, obsolete, cancelled, failed
}

/// Local native acceptance only; this is not receiver delivery or usable capacity.
public struct PublishingBandwidthProbeSnapshot: Equatable, Sendable {
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
    public internal(set) var stage: UInt32? = nil
    public internal(set) var authority: Authority? = nil
    public internal(set) var campaignStartedAt: Double? = nil
    public internal(set) var totalAcceptedPayloadBytes: UInt64? = nil
}

extension PublishingBandwidthProbeSnapshot {
    init(_ value: SRTBandwidthProbeSnapshot) {
        self.init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline,
            acceptedPayloadBytes: value.acceptedPayloadBytes, lastAcceptedAt: value.lastAcceptedAt, reason: value.reason,
            stage: value.stage, authority: value.authority, campaignStartedAt: value.campaignStartedAt,
            totalAcceptedPayloadBytes: value.totalAcceptedPayloadBytes)
    }

    func isValidStart(staged: Bool, bitRate: Int) -> Bool {
        guard self.bitRate == bitRate else { return false }
        if !staged { return stage == nil && campaignStartedAt == nil && totalAcceptedPayloadBytes == nil }
        return stage == 1 && hasValidCampaignAccounting && campaignStartedAt == startedAt
            && acceptedPayloadBytes == 0 && totalAcceptedPayloadBytes == 0
    }

    func isValidRenewal(of prior: Self) -> Bool {
        guard id == prior.id, publishingGeneration == prior.publishingGeneration,
              bitRate == prior.bitRate, startedAt == prior.startedAt, stage == prior.stage,
              campaignStartedAt == prior.campaignStartedAt,
              acceptedPayloadBytes >= prior.acceptedPayloadBytes else { return false }
        if stage == nil { return campaignStartedAt == nil && totalAcceptedPayloadBytes == nil }
        guard hasValidCampaignAccounting, prior.hasValidCampaignAccounting,
              let total = totalAcceptedPayloadBytes, let previousTotal = prior.totalAcceptedPayloadBytes,
              total >= previousTotal else { return false }
        return total - previousTotal == acceptedPayloadBytes - prior.acceptedPayloadBytes
    }

    func isValidReplacement(of prior: Self, bitRate: Int) -> Bool {
        guard let previousStage = prior.stage, previousStage < 32,
              stage == previousStage + 1, id != prior.id,
              publishingGeneration == prior.publishingGeneration, self.bitRate == bitRate,
              campaignStartedAt == prior.campaignStartedAt, startedAt >= prior.startedAt,
              acceptedPayloadBytes == 0, hasValidCampaignAccounting, prior.hasValidCampaignAccounting,
              let total = totalAcceptedPayloadBytes, let previousTotal = prior.totalAcceptedPayloadBytes else { return false }
        // The native owner may accept more payload after our last acknowledgement,
        // before replacement retires it. That final carry cannot move backwards.
        return total >= previousTotal && total <= 16 * 1024 * 1024 - 1316
    }

    private var hasValidCampaignAccounting: Bool {
        guard publishingGeneration > 0, let stage, (1...32).contains(stage), let campaignStartedAt,
              campaignStartedAt.isFinite, campaignStartedAt >= 0, startedAt.isFinite,
              campaignStartedAt <= startedAt, startedAt - campaignStartedAt < 60,
              leaseDeadline.isFinite, leaseDeadline >= startedAt,
              let totalAcceptedPayloadBytes else { return false }
        return totalAcceptedPayloadBytes >= acceptedPayloadBytes && totalAcceptedPayloadBytes <= 16 * 1024 * 1024
            && totalAcceptedPayloadBytes % 1316 == 0 && acceptedPayloadBytes % 1316 == 0
    }
}

func publishingProbeError(_ error: any Error) -> PublishingBandwidthProbeError {
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

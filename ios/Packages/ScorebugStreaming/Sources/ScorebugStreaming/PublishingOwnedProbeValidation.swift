import Foundation

/// Called only inside a publisher's non-suspending reservation turn, before
/// consuming the receipt or replacing its current operation slot.
func validateOwnedReservation(current: PublishingBandwidthProbeOperation?, issuer: UUID,
    context: PublishingBandwidthProbeContext, receipt: PublishingBandwidthProbeRetirement?, request: PublishingOwnedProbeRequest, budget: PublishingBandwidthProbeSnapshot.Budget = .standard) throws {
    guard request.budget == budget, (1...budget.maximumBitRate).contains(request.bitRate) else { throw PublishingBandwidthProbeError.obsolete }
    guard let receipt else {
        guard request.kind == .begin, current == nil else { throw PublishingBandwidthProbeError.busy }
        return
    }
    guard request.kind != .begin, receipt.issuer == issuer, receipt.isAvailable,
          current?.owns(receipt) == true,
          receipt.lineageContext.selected.publishingGeneration == context.selected.publishingGeneration else {
        throw PublishingBandwidthProbeError.obsolete
    }
    if request.kind == .replace {
        guard let terminal = receipt.terminal, let stage = terminal.stage, stage < 32,
              receipt.lineageContext.issuer == context.issuer, receipt.lineageContext.epoch == context.epoch,
              receipt.lineageContext.matches(context.selected) else { throw PublishingBandwidthProbeError.obsolete }
    } else if let terminal = receipt.terminal {
        guard let campaign = terminal.campaign, campaign < UInt32.max else { throw PublishingBandwidthProbeError.obsolete }
    }
}

extension PublishingBandwidthProbeSnapshot {
    private var ownedShape: Bool {
        guard budget == .standard || campaign != nil, publishingGeneration > 0, (1...budget.maximumBitRate).contains(bitRate),
              let stage, (1...32).contains(stage), let campaign, campaign > 0,
              let origin = campaignStartedAt, origin.isFinite, origin >= 0,
              startedAt.isFinite, startedAt >= origin, startedAt - origin < 60,
              leaseDeadline.isFinite, leaseDeadline >= startedAt,
              let total = totalAcceptedPayloadBytes, total >= acceptedPayloadBytes,
              total <= budget.maximumPayloadBytes, total % 1316 == 0, acceptedPayloadBytes % 1316 == 0,
              authority != nil else { return false }
        if acceptedPayloadBytes == 0 { return lastAcceptedAt == nil }
        guard let lastAcceptedAt else { return false }
        return lastAcceptedAt.isFinite && lastAcceptedAt >= startedAt
    }

    func isOwnedLive(at now: Double) -> Bool {
        ownedShape && reason == nil && now.isFinite && now >= startedAt &&
        now < leaseDeadline && leaseDeadline <= now + 0.300001 &&
        (lastAcceptedAt.map { $0 <= now } ?? true) &&
        authority?.permits(id: id, generation: publishingGeneration, stage: stage, policy: policy) == true
    }

    func isOwnedAllocation(_ request: PublishingOwnedProbeRequest, predecessor: Self?, generation: UInt64,
                           requestedAt: Double, observedAt: Double) -> Bool {
        guard ownedShape, budget == request.budget, publishingGeneration == generation, bitRate == request.bitRate, policy == request.policy,
              requestedAt.isFinite, requestedAt >= 0, observedAt.isFinite, observedAt >= requestedAt,
              startedAt >= requestedAt, startedAt <= observedAt,
              leaseDeadline > startedAt, leaseDeadline <= startedAt + 0.300001, reason == nil,
              acceptedPayloadBytes == 0, lastAcceptedAt == nil else { return false }
        guard let predecessor else {
            return request.kind != .replace && stage == 1 && campaign == 1 &&
                campaignStartedAt == startedAt && totalAcceptedPayloadBytes == 0
        }
        guard id != predecessor.id, publishingGeneration == predecessor.publishingGeneration,
              budget == predecessor.budget, policy == predecessor.policy else { return false }
        switch request.kind {
        case .begin: return false
        case .replace:
            guard let previousStage = predecessor.stage, previousStage < 32 else { return false }
            return stage == previousStage + 1 && campaign == predecessor.campaign &&
                campaignStartedAt == predecessor.campaignStartedAt && startedAt >= predecessor.startedAt &&
                totalAcceptedPayloadBytes == predecessor.totalAcceptedPayloadBytes
        case .restart:
            guard let previousCampaign = predecessor.campaign, previousCampaign < UInt32.max else { return false }
            return stage == 1 && campaign == previousCampaign + 1 && startedAt > predecessor.startedAt &&
                campaignStartedAt == startedAt && totalAcceptedPayloadBytes == 0
        }
    }

    func isOwnedProgress(of prior: Self, observedAt: Double) -> Bool {
        guard budget == prior.budget, ownedShape, prior.ownedShape, observedAt.isFinite, observedAt >= startedAt,
              id == prior.id, publishingGeneration == prior.publishingGeneration,
              stage == prior.stage, campaign == prior.campaign, campaignStartedAt == prior.campaignStartedAt,
              policy == prior.policy, bitRate == prior.bitRate, startedAt == prior.startedAt,
              authority === prior.authority, leaseDeadline >= prior.leaseDeadline,
              leaseDeadline <= observedAt + 0.300001,
              leaseDeadline <= campaignStartedAt! + 60.300001,
              acceptedPayloadBytes >= prior.acceptedPayloadBytes,
              let total = totalAcceptedPayloadBytes, let oldTotal = prior.totalAcceptedPayloadBytes,
              total >= oldTotal, total - oldTotal == acceptedPayloadBytes - prior.acceptedPayloadBytes,
              prior.reason == nil || reason == prior.reason,
              lastAcceptedAt.map({ $0 <= observedAt }) ?? true else { return false }
        if acceptedPayloadBytes == prior.acceptedPayloadBytes { return lastAcceptedAt == prior.lastAcceptedAt }
        return lastAcceptedAt.map { $0 >= (prior.lastAcceptedAt ?? startedAt) } ?? false
    }

    func isOwnedTerminal(of prior: Self, observedAt: Double) -> Bool {
        isOwnedProgress(of: prior, observedAt: observedAt) && reason != nil &&
        authority?.permits(id: id, generation: publishingGeneration, stage: stage, policy: policy) == false
    }
}

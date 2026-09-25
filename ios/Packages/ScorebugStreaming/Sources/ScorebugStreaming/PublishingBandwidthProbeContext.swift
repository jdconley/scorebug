import CoreMedia
import Foundation
import ScorebugMedia
import SRTHaishinKit

/// Opaque point-in-time configuration selection. It carries no measured capacity,
/// delivery health, or permission to allocate a probe after another suspension.
public final class PublishingBandwidthProbeContext: Sendable {
    // Construction and inspection are confined to the trusted adapter module.
    let issuer: UUID
    let epoch: UUID
    let selected: PublishingBitRateChange
    let lower: PublishingBandwidthProbeContext?

    init(issuer: UUID, epoch: UUID, selected: PublishingBitRateChange,
         lower: PublishingBandwidthProbeContext? = nil) {
        self.issuer = issuer; self.epoch = epoch; self.selected = selected; self.lower = lower
    }

    func matches(_ receipt: PublishingBitRateChange) -> Bool {
        selected.publishingGeneration == receipt.publishingGeneration &&
        selected.configuration == receipt.configuration && selected.acceptedAt == receipt.acceptedAt &&
        Self.samePTS(selected.lastSubmittedSourcePTS, receipt.lastSubmittedSourcePTS)
    }

    func matches(_ receipt: SRTStream.VideoBitRateReceipt) -> Bool {
        selected.publishingGeneration == receipt.publishingGeneration &&
        selected.configuration.id == receipt.change.configuration.id &&
        selected.configuration.encoderSessionID == receipt.change.configuration.encoderSessionID &&
        selected.configuration.bitRate == receipt.change.configuration.bitRate &&
        selected.acceptedAt == receipt.change.acceptedAt &&
        Self.samePTS(selected.lastSubmittedSourcePTS, receipt.change.lastSubmittedSourcePTS)
    }

    private static func samePTS(_ lhs: CMTime?, _ rhs: CMTime?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.value == rhs.value && lhs.timescale == rhs.timescale &&
                lhs.flags == rhs.flags && lhs.epoch == rhs.epoch
        default: return false
        }
    }
}

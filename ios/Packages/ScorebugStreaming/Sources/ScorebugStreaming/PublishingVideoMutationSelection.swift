import CoreMedia
import HaishinKit
import ScorebugMedia
import SRTHaishinKit

extension PublishingBitRateChange {
    var nativeExpectation: VideoBitRateExpectation {
        .init(configurationID: configuration.id, encoderSessionID: configuration.encoderSessionID,
            bitRate: configuration.bitRate, acceptedAt: acceptedAt, lastSubmittedSourcePTS: lastSubmittedSourcePTS)
    }
    func matchesNative(_ actual: SRTStream.VideoBitRateReceipt) -> Bool {
        publishingGeneration == actual.publishingGeneration &&
        configuration.id == actual.change.configuration.id &&
        configuration.encoderSessionID == actual.change.configuration.encoderSessionID &&
        configuration.bitRate == actual.change.configuration.bitRate &&
        acceptedAt.bitPattern == actual.change.acceptedAt.bitPattern &&
        exactMutationPTS(lastSubmittedSourcePTS, actual.change.lastSubmittedSourcePTS)
    }
}

/// Bounded actual native-to-Media issuance record. An arbitrary Media receipt
/// cannot reconstruct the native continuation, even with the same encoder UUID.
struct PublishingVideoReplacementMapping: Sendable {
    let native: SRTStream.VideoReplacementReceipt
    let media: PublishingVideoProfileChange
    func matches(_ value: PublishingVideoProfileChange) -> Bool {
        media.profile == value.profile && media.publishingGeneration == value.publishingGeneration &&
        media.previousEncoderSessionID == value.previousEncoderSessionID && media.encoderSessionID == value.encoderSessionID &&
        exactMutationPTS(media.lastOldSourcePTS, value.lastOldSourcePTS) && exactMutationPTS(media.firstNewSourcePTS, value.firstNewSourcePTS) &&
        media.width == value.width && media.height == value.height && media.rawVideoFramesDropped == value.rawVideoFramesDropped &&
        media.acknowledgedAt.bitPattern == value.acknowledgedAt.bitPattern
    }
}

private func exactMutationPTS(_ lhs: CMTime?, _ rhs: CMTime?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (lhs?, rhs?): lhs.value == rhs.value && lhs.timescale == rhs.timescale && lhs.flags == rhs.flags && lhs.epoch == rhs.epoch
    default: false
    }
}

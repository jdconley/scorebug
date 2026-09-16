import Foundation
import SRTHaishinKit

public enum PublishingBandwidthProbeError: Error, Equatable, Sendable {
    case disabled, notPublishing, busy, obsolete, cancelled, failed
}

/// Local native acceptance only; this is not receiver delivery or usable capacity.
public struct PublishingBandwidthProbeSnapshot: Equatable, Sendable {
    public typealias Reason = SRTBandwidthProbeSnapshot.Reason
    public let id: UUID
    public let publishingGeneration: UInt64
    public let bitRate: Int
    public let startedAt: Double
    public let leaseDeadline: Double
    public let acceptedPayloadBytes: UInt64
    public let lastAcceptedAt: Double?
    public let reason: Reason?
}

extension PublishingBandwidthProbeSnapshot {
    init(_ value: SRTBandwidthProbeSnapshot) {
        self.init(id: value.id, publishingGeneration: value.publishingGeneration, bitRate: value.bitRate,
            startedAt: value.startedAt, leaseDeadline: value.leaseDeadline,
            acceptedPayloadBytes: value.acceptedPayloadBytes, lastAcceptedAt: value.lastAcceptedAt, reason: value.reason)
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

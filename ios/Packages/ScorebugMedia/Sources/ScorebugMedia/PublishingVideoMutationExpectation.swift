import Foundation

/// Selects one exact native configuration. This value is not a mutation permit;
/// guarded publishers compare it again at native admission.
public enum PublishingVideoMutationExpectation: Sendable {
    case verified(PublishingBitRateChange)
    case replacement(PublishingVideoProfileChange)
}

/// A guarded operation rejected before any encoder effect. Only the explicit
/// guarded route may interpret these errors as safe to continue publication.
public enum PublishingVideoMutationAdmissionError: Error, Equatable, Sendable {
    case stale
    case unavailable
}

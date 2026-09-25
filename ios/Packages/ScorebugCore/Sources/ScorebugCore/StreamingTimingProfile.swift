import Foundation

/// Immutable experimental capture-to-decoder contracts. Selecting these values
/// never authorizes a route: the fixture boundary must validate the entire owned
/// capacity diagnostic. Production and omitted selectors retain strict timing.
public enum StreamingTimingProfile: String, CaseIterable, Sendable {
    case strict1500 = "strict1500-v1"
    case broadcastReliability2000 = "broadcast-reliability2000-v1"
    case broadcastReliability3000 = "broadcast-reliability3000-v1"

    public var decoderBudgetMs: Int {
        switch self { case .strict1500: 1500; case .broadcastReliability2000: 2000; case .broadcastReliability3000: 3000 }
    }
    public var maximumCaptureWindowEvaluationAgeMs: Int { decoderBudgetMs + 500 }
    public var decoderBudget: Double { Double(decoderBudgetMs) / 1000 }
    /// The extra 500ms is experimental evaluation allowance, not industry guidance.
    public var maximumCaptureWindowEvaluationAge: Double { Double(maximumCaptureWindowEvaluationAgeMs) / 1000 }
    public var maximumCompletedDecoderWindowReportAgeMs: Int { 2000 }
    public var maximumCadenceDeliveryReportAgeMs: Int { 250 }
    public var decoderStallThresholdMs: Int { 1000 }

    /// Historical artifacts must remain unchanged and reject new metadata.
    public var evidence: [String: Any]? {
        guard self != .strict1500 else { return nil }
        return ["formatVersion": 1, "profileId": rawValue, "decoderBudgetMs": decoderBudgetMs,
                "maximumCaptureWindowEvaluationAgeMs": maximumCaptureWindowEvaluationAgeMs,
                "maximumCompletedDecoderWindowReportAgeMs": maximumCompletedDecoderWindowReportAgeMs,
                "maximumCadenceDeliveryReportAgeMs": maximumCadenceDeliveryReportAgeMs,
                "decoderStallThresholdMs": decoderStallThresholdMs, "scope": "owned-capacity-diagnostic"]
    }
}

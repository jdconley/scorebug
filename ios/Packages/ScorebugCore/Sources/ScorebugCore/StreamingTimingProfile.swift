import Foundation

/// Immutable capture-to-decoder contracts. The app's production factory selects
/// broadcastReliability3000; strict1500 remains the default for explicit legacy
/// construction and fixture benchmarks. Selecting a value never authorizes a route.
public enum StreamingTimingProfile: String, CaseIterable, Sendable {
    case strict1500 = "strict1500-v1"
    case broadcastReliability2000 = "broadcast-reliability2000-v1"
    case broadcastReliability3000 = "broadcast-reliability3000-v1"

    /// Explicit buffered scheduling experiments; not the production selection.
    case broadcastReliability6000 = "broadcast-reliability6000-v1"

    public var decoderBudgetMs: Int {
        switch self { case .strict1500: 1500; case .broadcastReliability2000: 2000; case .broadcastReliability3000: 3000; case .broadcastReliability6000: 6000 }
    }
    public var maximumCaptureWindowEvaluationAgeMs: Int { decoderBudgetMs + 500 }
    public var decoderBudget: Double { Double(decoderBudgetMs) / 1000 }
    /// The extra 500ms is experimental evaluation allowance, not industry guidance.
    public var maximumCaptureWindowEvaluationAge: Double { Double(maximumCaptureWindowEvaluationAgeMs) / 1000 }
    public var maximumCompletedDecoderWindowReportAgeMs: Int { 2000 }
    public var maximumCadenceDeliveryReportAgeMs: Int { 250 }
    public var decoderStallThresholdMs: Int { 1000 }

    /// Historical fixture artifacts retain their original diagnostic scope.
    /// Ordinary production diagnostics report the profile and budgets separately.
    public var evidence: [String: Any]? {
        guard self != .strict1500 else { return nil }
        return ["formatVersion": 1, "profileId": rawValue, "decoderBudgetMs": decoderBudgetMs,
                "maximumCaptureWindowEvaluationAgeMs": maximumCaptureWindowEvaluationAgeMs,
                "maximumCompletedDecoderWindowReportAgeMs": maximumCompletedDecoderWindowReportAgeMs,
                "maximumCadenceDeliveryReportAgeMs": maximumCadenceDeliveryReportAgeMs,
                "decoderStallThresholdMs": decoderStallThresholdMs, "scope": "owned-capacity-diagnostic"]
    }
}

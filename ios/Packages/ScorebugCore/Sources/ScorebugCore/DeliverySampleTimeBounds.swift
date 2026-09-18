/// A request bracket in the same monotonic clock domain as native capture times.
public struct DeliveryRequestTiming: Sendable, Equatable {
    public let startedAt: Double
    public let receivedAt: Double

    public init?(startedAt: Double, receivedAt: Double) {
        guard let bounds = DeliverySampleTimeBounds(lower: startedAt, upper: receivedAt) else { return nil }
        self.startedAt = bounds.lower
        self.receivedAt = bounds.upper
    }
}

/// An immutable interval containing the worker sample in the native capture clock.
public struct DeliverySampleTimeBounds: Sendable, Equatable {
    public let lower: Double
    public let upper: Double

    public init?(lower: Double, upper: Double) {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper <= 1e12, lower <= upper else { return nil }
        self.lower = lower
        self.upper = upper
    }
}

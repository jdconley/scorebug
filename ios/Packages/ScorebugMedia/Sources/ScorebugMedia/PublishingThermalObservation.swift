import Foundation

/// Raw OS-reported state, not a measurement of temperature or media performance.
public enum PublishingThermalState: Int, Equatable, Sendable {
    case unknown = -1, nominal, fair, serious, critical
    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}
public struct PublishingThermalSample: Equatable, Sendable {
    public let state: PublishingThermalState
    public let sampledAt: Double
    public init(state: PublishingThermalState, sampledAt: Double) {
        self.state = state; self.sampledAt = sampledAt
    }
}
public struct PublishingThermalInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let enclosingStart: Double
    public let enclosingEnd: Double
    public let sampleCount: Int
    public let enclosingMaximumState: PublishingThermalState
}
public struct PublishingThermalSnapshot: Equatable, Sendable {
    public let samples: [PublishingThermalSample]
    public let isQuarantined: Bool
    public let isClosed: Bool
    /// An OS reading at one instant; neither temperature nor continuous coverage.
    public func freshSample(at uptime: Double, maximumAge: Double = 2) -> PublishingThermalSample? {
        guard !isClosed, !isQuarantined, let last = samples.last,
              uptime.isFinite, (0...1e12).contains(uptime), maximumAge.isFinite, maximumAge >= 0,
              uptime >= last.sampledAt, uptime - last.sampledAt <= maximumAge else { return nil }
        return last
    }
    /// Historical maximum across enclosing actual samples, including both bounds.
    /// Polling cannot exclude an unobserved state change between collections.
    public func interval(from start: Double, to end: Double) -> PublishingThermalInterval? {
        guard !isQuarantined, start.isFinite, end.isFinite, start >= 0, end > start, end <= 1e12,
              let left = samples.lastIndex(where: { $0.sampledAt <= start }),
              let right = samples.firstIndex(where: { $0.sampledAt >= end }), left < right else { return nil }
        let enclosed = samples[left...right]
        let state: PublishingThermalState = enclosed.contains(where: { $0.state == .unknown })
            ? .unknown : enclosed.max(by: { $0.state.rawValue < $1.state.rawValue })!.state
        return .init(start: start, end: end, enclosingStart: samples[left].sampledAt,
            enclosingEnd: samples[right].sampledAt, sampleCount: enclosed.count, enclosingMaximumState: state)
    }
}
public struct PublishingThermalTracker: Sendable {
    // This is sampled off the capture path, with an absolute 160-scalar bound.
    // Matches transport retention for aged source windows at 100ms cadence.
    private var samples: [PublishingThermalSample] = []
    private var quarantined = false, closed = false
    public init() {}
    public var snapshot: PublishingThermalSnapshot {
        .init(samples: samples, isQuarantined: quarantined, isClosed: closed)
    }
    public mutating func observe(_ sample: PublishingThermalSample) {
        guard !closed, !quarantined else { return }
        guard sample.sampledAt.isFinite, (0...1e12).contains(sample.sampledAt) else {
            quarantined = true; samples.removeAll(keepingCapacity: true); return
        }
        if let last = samples.last {
            if sample == last { return }
            guard sample.sampledAt > last.sampledAt else {
                quarantined = true; samples.removeAll(keepingCapacity: true); return
            }
            if sample.sampledAt - last.sampledAt > 2 { samples.removeAll(keepingCapacity: true) }
        }
        if samples.count == 160 { samples.removeFirst() }
        samples.append(sample)
    }
    public mutating func close() { closed = true }
}

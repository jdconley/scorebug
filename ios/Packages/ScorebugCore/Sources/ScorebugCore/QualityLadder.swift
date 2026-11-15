import Foundation

/// Pure live-stream quality policy. The caller feeds periodic SRT sender
/// statistics and the device thermal state; the ladder answers which rung the
/// stream encoder should use. It never touches capture or the local recording.
///
/// Rules:
/// - Start at 720p (capped by `maximum`).
/// - Step down one rung after `pressureDuration` of continuous sender pressure
///   (send buffer backed up, retransmit ratio high, or sender drops).
/// - Step up one rung after `headroomDuration` of continuous headroom, never
///   within `upgradeHoldoff` of a step down, and never while thermally serious.
/// - Thermal `.serious`/`.critical`: step down one rung on entry; cap at 720p
///   while serious and 540p while critical.
/// - Disconnect: resume one rung below the last stable rung.
public struct QualityLadder: Sendable, Equatable {
    public enum Rung: Int, CaseIterable, Comparable, Sendable {
        case p360, p540, p720, p1080
        public static func < (lhs: Rung, rhs: Rung) -> Bool { lhs.rawValue < rhs.rawValue }
        public var width: Int { switch self { case .p360: 640; case .p540: 960; case .p720: 1280; case .p1080: 1920 } }
        public var height: Int { switch self { case .p360: 360; case .p540: 540; case .p720: 720; case .p1080: 1080 } }
        /// H.264 video bits per second at 30 fps; AAC audio is separate.
        public var videoBitRate: Int {
            switch self { case .p360: 800_000; case .p540: 1_600_000; case .p720: 3_000_000; case .p1080: 6_000_000 }
        }
        /// User-facing label, e.g. "720p".
        public var label: String { "\(height)p" }
        public var below: Rung { Rung(rawValue: max(rawValue - 1, 0))! }
        public var above: Rung { Rung(rawValue: min(rawValue + 1, Rung.allCases.count - 1))! }
        /// Largest rung that fits within a recording of the given height.
        public static func fitting(height: Int) -> Rung {
            allCases.last(where: { $0.height <= height }) ?? .p360
        }
    }

    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        public static func < (lhs: Thermal, rhs: Thermal) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One read of cumulative SRT sender counters.
    public struct Sample: Equatable, Sendable {
        /// Monotonic seconds.
        public var time: Double
        /// Timespan of unacknowledged data in the SRT send buffer.
        public var senderBufferMilliseconds: Int
        public var sentPackets: Int64
        public var retransmittedPackets: Int64
        public var droppedPackets: Int64
        public init(time: Double, senderBufferMilliseconds: Int, sentPackets: Int64,
                    retransmittedPackets: Int64, droppedPackets: Int64) {
            self.time = time; self.senderBufferMilliseconds = senderBufferMilliseconds
            self.sentPackets = sentPackets; self.retransmittedPackets = retransmittedPackets
            self.droppedPackets = droppedPackets
        }
    }

    public struct Configuration: Equatable, Sendable {
        public var start: Rung = .p720
        public var pressureDuration: Double = 3
        public var headroomDuration: Double = 20
        public var upgradeHoldoff: Double = 30
        /// A rung counts as stable after this long without pressure.
        public var stableDuration: Double = 5
        public var pressureBufferMilliseconds = 800
        public var headroomBufferMilliseconds = 300
        public var pressureRetransmitRatio = 0.10
        public var headroomRetransmitRatio = 0.02
        /// Intervals with fewer sent packets carry no retransmit-ratio signal.
        public var minimumPacketsForRatio: Int64 = 20
        public init() {}
    }

    public enum Condition: Equatable, Sendable { case pressure, neutral, headroom }

    public let maximum: Rung
    public let configuration: Configuration
    public private(set) var current: Rung
    public private(set) var lastStable: Rung
    private var previous: Sample?
    private var pressureSince: Double?
    private var headroomSince: Double?
    private var calmSince: Double?
    private var lastStepDownAt: Double?
    private var thermal: Thermal = .nominal

    public init(maximum: Rung = .p1080, configuration: Configuration = .init()) {
        self.maximum = maximum
        self.configuration = configuration
        let start = min(configuration.start, maximum)
        current = start
        lastStable = start
    }

    /// Highest rung currently allowed by the recording size and thermal state.
    public var cap: Rung {
        switch thermal {
        case .nominal, .fair: maximum
        case .serious: min(maximum, .p720)
        case .critical: min(maximum, .p540)
        }
    }

    /// Classifies the interval ending at `sample`. Pure; exposed for tests.
    public func condition(of sample: Sample, after previous: Sample?) -> Condition {
        var ratio = 0.0
        var dropped = false
        if let previous {
            let sent = sample.sentPackets - previous.sentPackets
            let retransmitted = max(0, sample.retransmittedPackets - previous.retransmittedPackets)
            if sent >= configuration.minimumPacketsForRatio { ratio = Double(retransmitted) / Double(sent) }
            dropped = sample.droppedPackets > previous.droppedPackets
        }
        if dropped || sample.senderBufferMilliseconds >= configuration.pressureBufferMilliseconds ||
            ratio >= configuration.pressureRetransmitRatio { return .pressure }
        if previous != nil, sample.senderBufferMilliseconds <= configuration.headroomBufferMilliseconds,
           ratio <= configuration.headroomRetransmitRatio { return .headroom }
        return .neutral
    }

    /// Feeds one statistics read. Returns the new rung when it changed.
    @discardableResult
    public mutating func observe(_ sample: Sample, thermal newThermal: Thermal) -> Rung? {
        let before = current
        let now = sample.time
        // Thermal applies on every call, even when the stats sample is a repeat.
        let worsened = newThermal >= .serious && newThermal > thermal
        thermal = newThermal
        if worsened { stepDown(at: max(now, previous?.time ?? now)) }
        if current > cap { current = cap; markStepDown(at: max(now, previous?.time ?? now)) }
        let changed: Rung? = current == before ? nil : current

        if let previous, now <= previous.time { return changed }
        if let previous, sample.sentPackets < previous.sentPackets || sample.retransmittedPackets < previous.retransmittedPackets
            || sample.droppedPackets < previous.droppedPackets {
            // Counters reset (new connection): start a fresh interval.
            self.previous = sample
            return changed
        }

        let condition = self.condition(of: sample, after: previous)
        previous = sample
        switch condition {
        case .pressure:
            headroomSince = nil; calmSince = nil
            let since = pressureSince ?? now
            pressureSince = since
            if now - since >= configuration.pressureDuration { stepDown(at: now) }
        case .neutral, .headroom:
            pressureSince = nil
            let calm = calmSince ?? now
            calmSince = calm
            if now - calm >= configuration.stableDuration { lastStable = current }
            if condition == .headroom {
                let since = headroomSince ?? now
                headroomSince = since
                if now - since >= configuration.headroomDuration, canStepUp(at: now) {
                    current = current.above
                    headroomSince = nil; calmSince = nil
                }
            } else {
                headroomSince = nil
            }
        }
        return current == before ? nil : current
    }

    /// The stream disconnected. Returns the rung to reconnect with: one below
    /// the last stable rung. Repeated failures keep walking down.
    @discardableResult
    public mutating func connectionLost(at time: Double) -> Rung {
        let resume = min(lastStable.below, cap)
        current = resume
        lastStable = resume
        previous = nil
        pressureSince = nil; headroomSince = nil; calmSince = nil
        lastStepDownAt = time
        return resume
    }

    private func canStepUp(at now: Double) -> Bool {
        guard current < cap, thermal < .serious else { return false }
        if let lastStepDownAt, now - lastStepDownAt < configuration.upgradeHoldoff { return false }
        return true
    }

    private mutating func stepDown(at now: Double) {
        if current > .p360 { current = current.below }
        markStepDown(at: now)
    }

    private mutating func markStepDown(at now: Double) {
        lastStepDownAt = now
        pressureSince = nil; headroomSince = nil; calmSince = nil
        if lastStable > current { lastStable = current }
    }
}

/// Reconnect delays: 1, 2, 4, 8, then 10 seconds.
public enum StreamReconnectBackoff {
    public static func delay(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        return min(10, pow(2, Double(min(failures, 5) - 1)))
    }
}

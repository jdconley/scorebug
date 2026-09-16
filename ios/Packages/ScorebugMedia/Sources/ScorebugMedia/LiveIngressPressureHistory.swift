import Foundation

/// Scalar state effective from `at` until the next transition. No media is retained.
public struct LiveIngressPressureState: Equatable, Sendable {
    public let at: Double
    public let itemFraction: Double
    public let byteFraction: Double
    public let phase: LiveIngressPhase
}
public struct LiveIngressPressureInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let itemSeconds: Double
    public let byteSeconds: Double
    public let maxPressureSeconds: Double
    public var meanItemOccupancy: Double { itemSeconds / (end - start) }
    public var meanByteOccupancy: Double { byteSeconds / (end - start) }
    public var meanMaxPressure: Double { maxPressureSeconds / (end - start) }
}
public struct LiveIngressPressureSnapshot: Sendable {
    public let states: [LiveIngressPressureState]
    public let coveredThrough: Double
    public let omittedStates: UInt64
    public let isQuarantined: Bool
    public let isClosed: Bool
    /// Historical [start,end) integration, not a claim of present health/freshness.
    public func interval(from start: Double, to end: Double) -> LiveIngressPressureInterval? {
        guard !isQuarantined, start.isFinite, end.isFinite, start >= 0, end > start,
              end <= coveredThrough, let first = states.first, start >= first.at else { return nil }
        var itemArea = 0.0, byteArea = 0.0, maxArea = 0.0
        for index in states.indices {
            let state = states[index]
            if state.at >= end { break }
            let next = index + 1 < states.count ? states[index + 1].at : coveredThrough
            let duration = min(next, end) - max(state.at, start)
            guard duration > 0 else { continue }
            guard state.phase == .admitting else { return nil }
            itemArea += state.itemFraction * duration
            byteArea += state.byteFraction * duration
            maxArea += max(state.itemFraction, state.byteFraction) * duration
        }
        let duration = end - start
        return .init(start: start, end: end, itemSeconds: min(duration, itemArea),
            byteSeconds: min(duration, byteArea), maxPressureSeconds: min(duration, maxArea))
    }
}
struct LiveIngressPressureHistory: Sendable {
    private var storage: [LiveIngressPressureState?]
    private var head = 0, count = 1
    private var coveredThrough: Double
    private var omitted: UInt64 = 0
    private var quarantined = false, closed = false
    init(start: Double, capacity: Int = 4096) {
        precondition(capacity > 0 && capacity <= 4096)
        storage = Array(repeating: nil, count: capacity)
        storage[0] = .init(at: start, itemFraction: 0, byteFraction: 0, phase: .startup)
        coveredThrough = start
        quarantined = !Self.legalClock(start)
    }
    var snapshot: LiveIngressPressureSnapshot {
        .init(states: (0..<count).map { storage[(head + $0) % storage.count]! },
            coveredThrough: coveredThrough, omittedStates: omitted,
            isQuarantined: quarantined, isClosed: closed)
    }
    mutating func advance(to time: Double) {
        guard !closed, !quarantined else { return }
        guard Self.legalClock(time), time >= coveredThrough else { quarantined = true; return }
        coveredThrough = time
    }
    mutating func record(itemFraction: Double, byteFraction: Double, phase: LiveIngressPhase, at time: Double) {
        guard !closed, !quarantined else { return }
        advance(to: time)
        guard !quarantined else { return }
        guard itemFraction.isFinite, byteFraction.isFinite,
              (0...1).contains(itemFraction), (0...1).contains(byteFraction) else { quarantined = true; return }
        let lastIndex = (head + count - 1) % storage.count
        let last = storage[lastIndex]!
        let value = LiveIngressPressureState(at: time, itemFraction: itemFraction, byteFraction: byteFraction, phase: phase)
        if last.at == time { storage[lastIndex] = value; return }
        if last.itemFraction == itemFraction, last.byteFraction == byteFraction, last.phase == phase { return }
        if count == storage.count {
            storage[head] = value; head = (head + 1) % storage.count
            if omitted < .max { omitted += 1 }
        } else {
            storage[(head + count) % storage.count] = value; count += 1
        }
    }
    mutating func quarantine() { if !closed { quarantined = true } }
    mutating func close() { closed = true }
    private static func legalClock(_ time: Double) -> Bool { time.isFinite && (0...1e12).contains(time) }
}

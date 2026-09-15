import CoreMedia
import Foundation

public enum LiveIngressSampleKind: String, CaseIterable, Hashable, Sendable { case audio, video, unknown }
public enum LiveIngressPhase: String, CaseIterable, Hashable, Sendable { case startup, admitting, draining, closed }
public enum LiveIngressRejectionReason: String, CaseIterable, Hashable, Sendable {
    case invalidBytes, oversize, full, finished, cancelled
}
public enum LiveIngressDisposition: Hashable, Sendable {
    case admitted, dequeued, overflowEvicted, cancellationDiscarded
    case rejected(LiveIngressRejectionReason)
}
/// Scalar metadata only: never owns a sample buffer or its payload.
public struct LiveIngressSampleMetadata: Sendable {
    public let kind: LiveIngressSampleKind
    public let sourcePTS: CMTime
    public init(kind: LiveIngressSampleKind, sourcePTS: CMTime) { self.kind = kind; self.sourcePTS = sourcePTS }
}
public enum LiveIngressObservationError: Error, Equatable { case invalidConfiguration }
public struct LiveIngressInvalidity: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let invalidMonotonicClock = Self(rawValue: 1 << 0)
    public static let counterOverflow = Self(rawValue: 1 << 1)
    public static let invalidPTS = Self(rawValue: 1 << 2)
    public static let epochDiscontinuity = Self(rawValue: 1 << 3)
    public static let invalidOccupancy = Self(rawValue: 1 << 4)
}
/// Counts are elements (audio buffers), not frames or PCM samples. PTS extrema
/// describe observations, never continuity or an expected-frame denominator.
public struct LiveIngressDispositionSummary: Sendable {
    public fileprivate(set) var count: UInt64 = 0
    public fileprivate(set) var invalidPTSCount: UInt64 = 0
    public fileprivate(set) var firstSourcePTS: CMTime?
    public fileprivate(set) var lastSourcePTS: CMTime?
    /// Extrema are quarantined after an epoch change; first/last remain literal.
    public fileprivate(set) var minimumSourcePTS: CMTime?
    public fileprivate(set) var maximumSourcePTS: CMTime?
    public fileprivate(set) var invalidity: LiveIngressInvalidity = []
}
public typealias LiveIngressDispositions = [LiveIngressDisposition: [LiveIngressSampleKind: LiveIngressDispositionSummary]]

/// Normalized queue occupancy integrated over time. The maximum is taken at each
/// instant, before integration. Unknown time is explicit and prevents a mean.
public struct LiveIngressOccupancy: Sendable {
    public fileprivate(set) var knownDuration: Double = 0
    public fileprivate(set) var unknownDuration: Double = 0
    public fileprivate(set) var itemSeconds: Double = 0
    public fileprivate(set) var byteSeconds: Double = 0
    public fileprivate(set) var maxPressureSeconds: Double = 0
    public fileprivate(set) var peakItems: Int = 0
    public fileprivate(set) var peakBytes: Int = 0
    public var meanItemOccupancy: Double? { mean(itemSeconds) }
    public var meanByteOccupancy: Double? { mean(byteSeconds) }
    public var meanMaxPressure: Double? { mean(maxPressureSeconds) }
    private func mean(_ area: Double) -> Double? {
        guard unknownDuration == 0, knownDuration > 0 else { return nil }
        return min(1, max(0, area / knownDuration))
    }
}
public struct LiveIngressObservationWindow: Sendable {
    public fileprivate(set) var monotonicStart: Double
    public fileprivate(set) var monotonicEnd: Double
    public fileprivate(set) var scheduledMonotonicEnd: Double
    public fileprivate(set) var coveredWindowCount: UInt64 = 1
    /// Coalesced intervals may be occupied and never qualify as individual windows.
    public fileprivate(set) var isCoalesced = false
    public fileprivate(set) var isPartial = true
    public fileprivate(set) var isClosed = false
    public fileprivate(set) var occupancy = LiveIngressOccupancy()
    /// Known duration only: no phase is inferred across a clock-invalid gap.
    public fileprivate(set) var occupancyByPhase: [LiveIngressPhase: LiveIngressOccupancy] = [:]
    public fileprivate(set) var dispositions: LiveIngressDispositions = [:]
}
public struct LiveIngressObservationSnapshot: Sendable {
    public let scope: VideoFrameObservationScope
    public let monotonicAnchor: Double
    public let windowDuration: Double
    public let maxItems: Int
    public let maxBytes: Int
    public let phase: LiveIngressPhase
    public let currentItems: Int
    public let currentBytes: Int
    public let current: LiveIngressObservationWindow
    public let completed: [LiveIngressObservationWindow]
    public let totalOccupancy: LiveIngressOccupancy
    public let totalDispositions: LiveIngressDispositions
    public let omittedCompletedWindowCount: UInt64
    public let omittedThroughMonotonicTime: Double?
    public let rejectedClockOperationCount: UInt64
    public let unassignedDispositionCount: UInt64
    public let invalidity: LiveIngressInvalidity
    public let isClosed: Bool
}

/// Pure scalar state; the caller serializes it and supplies mutation-time uptime.
/// Observe dispositions individually, then replace depth at the SAME sampled time.
/// Only queued media is measured; direct handoff and in-flight/downstream buffering
/// are outside occupancy. No callbacks, locks, tasks, or media are retained here.
public struct LiveIngressObservationAccumulator: Sendable {
    private let scope: VideoFrameObservationScope
    private let anchor: Double
    private let duration: Double
    private let maxItems: Int
    private let maxBytes: Int
    private let historyLimit: Int
    private let counterLimit: UInt64
    private var index: UInt64 = 0
    private var lastClock: Double
    private var clockKnown = true
    private var depthValid = true
    private var items = 0, bytes = 0
    private var phase: LiveIngressPhase = .startup
    private var current: LiveIngressObservationWindow
    private var completed: [LiveIngressObservationWindow] = []
    private var totals = LiveIngressOccupancy()
    private var dispositions: LiveIngressDispositions = [:]
    private var omitted: UInt64 = 0, rejectedClocks: UInt64 = 0, unassigned: UInt64 = 0
    private var omittedThrough: Double?
    private var invalidity: LiveIngressInvalidity = []
    private var closed = false

    public init(scope: VideoFrameObservationScope, monotonicAnchor: Double, maxItems: Int, maxBytes: Int,
                windowDuration: Double = 5, completedWindowLimit: Int = 8) throws {
        try self.init(scope: scope, monotonicAnchor: monotonicAnchor, maxItems: maxItems, maxBytes: maxBytes,
            windowDuration: windowDuration, completedWindowLimit: completedWindowLimit, counterLimit: .max)
    }
    init(scope: VideoFrameObservationScope, monotonicAnchor: Double, maxItems: Int, maxBytes: Int,
         windowDuration: Double, completedWindowLimit: Int, counterLimit: UInt64) throws {
        guard Self.legalClock(monotonicAnchor), windowDuration.isFinite,
              (1.0 / 1024...86400).contains(windowDuration), (1...128).contains(completedWindowLimit),
              maxItems > 0, maxBytes > 0, counterLimit > 0 else {
            throw LiveIngressObservationError.invalidConfiguration
        }
        self.scope = scope; anchor = monotonicAnchor; duration = windowDuration
        self.maxItems = maxItems; self.maxBytes = maxBytes; historyLimit = completedWindowLimit
        self.counterLimit = counterLimit; lastClock = monotonicAnchor
        current = LiveIngressObservationWindow(monotonicStart: monotonicAnchor, monotonicEnd: monotonicAnchor,
            scheduledMonotonicEnd: monotonicAnchor + windowDuration)
    }
    public var snapshot: LiveIngressObservationSnapshot {
        LiveIngressObservationSnapshot(scope: scope, monotonicAnchor: anchor, windowDuration: duration,
            maxItems: maxItems, maxBytes: maxBytes, phase: phase, currentItems: items, currentBytes: bytes,
            current: current, completed: completed, totalOccupancy: totals, totalDispositions: dispositions,
            omittedCompletedWindowCount: omitted, omittedThroughMonotonicTime: omittedThrough,
            rejectedClockOperationCount: rejectedClocks, unassignedDispositionCount: unassigned,
            invalidity: invalidity, isClosed: closed)
    }
    /// Always retains the supplied actual depth, even when its timestamp is bad.
    /// The next trusted operation reestablishes timing only for future intervals.
    /// Passing phase.closed is a terminal close alias: supplied depth is ignored.
    /// Count cancellation discards or dequeues first, as with close(at:).
    public mutating func updateOccupancy(items: Int, bytes: Int, phase: LiveIngressPhase? = nil, at time: Double) {
        guard !closed else { return }
        if phase == .closed { _ = close(at: time); return }
        let timed = advance(to: time)
        self.items = items; self.bytes = bytes
        depthValid = (0...maxItems).contains(items) && (0...maxBytes).contains(bytes)
            && (items == 0) == (bytes == 0) && bytes >= items
        if !depthValid { invalidity.insert(.invalidOccupancy) }
        if let phase { self.phase = phase }
        if depthValid {
            totals.peak(items: items, bytes: bytes)
            if timed {
                current.occupancy.peak(items: items, bytes: bytes)
                current.occupancyByPhase[self.phase, default: LiveIngressOccupancy()].peak(items: items, bytes: bytes)
            }
        }
    }

    /// Bad clock events still count globally, but are never assigned to a guessed
    /// window. Rational PTS validity is independent of observation clock validity.
    public mutating func observe(_ disposition: LiveIngressDisposition, sample: LiveIngressSampleMetadata, at time: Double) {
        guard !closed else { return }
        let timed = advance(to: time)
        var total = dispositions[disposition]?[sample.kind] ?? LiveIngressDispositionSummary()
        let referenceEpoch = total.firstSourcePTS?.epoch
        let discontinuous = total.invalidity.contains(.epochDiscontinuity)
        total.observe(sample.sourcePTS, referenceEpoch: referenceEpoch, discontinuous: discontinuous, limit: counterLimit)
        dispositions[disposition, default: [:]][sample.kind] = total
        invalidity.formUnion(total.invalidity)
        if timed {
            var local = current.dispositions[disposition]?[sample.kind] ?? LiveIngressDispositionSummary()
            local.observe(sample.sourcePTS, referenceEpoch: referenceEpoch, discontinuous: discontinuous, limit: counterLimit)
            current.dispositions[disposition, default: [:]][sample.kind] = local
            invalidity.formUnion(local.invalidity)
        } else { var count = unassigned; increment(&count); unassigned = count }
    }

    @discardableResult public mutating func poll(at time: Double) -> LiveIngressObservationSnapshot {
        if !closed { _ = advance(to: time) }
        return snapshot
    }

    /// Invoke at terminal queue cancellation AFTER counting queued discards. Later
    /// reads/operations cannot extend the duration through publisher shutdown.
    /// All post-close offers/rejections are outside this frozen observation;
    /// lifetime mailbox statistics remain a separate accounting boundary.
    /// Invalid close freezes at the last trusted timestamp with sticky invalidity.
    @discardableResult public mutating func close(at time: Double) -> LiveIngressObservationSnapshot {
        guard !closed else { return snapshot }
        _ = advance(to: time)
        closed = true; phase = .closed; current.isClosed = true
        items = 0; bytes = 0
        return snapshot
    }

    private static func legalClock(_ time: Double) -> Bool { time.isFinite && (0...1e12).contains(time) }
    private func boundary(_ value: UInt64) -> Double { anchor + Double(value) * duration }
    private mutating func increment(_ value: inout UInt64, by amount: UInt64 = 1) {
        if amount > counterLimit - value { value = counterLimit; invalidity.insert(.counterOverflow) }
        else { value += amount }
    }
    private mutating func appendCompleted(_ window: LiveIngressObservationWindow) {
        if completed.count == historyLimit {
            let removed = completed.removeFirst()
            // Local avoids overlapping mutable access to this struct.
            var count = omitted; increment(&count, by: removed.coveredWindowCount); omitted = count
            omittedThrough = removed.monotonicEnd
        }
        completed.append(window)
    }
    private mutating func integrateCurrent(until time: Double) {
        let elapsed = max(0, time - current.monotonicEnd)
        let known = clockKnown && depthValid
        current.occupancy.integrate(elapsed, items: items, bytes: bytes, maxItems: maxItems, maxBytes: maxBytes, known: known)
        totals.integrate(elapsed, items: items, bytes: bytes, maxItems: maxItems, maxBytes: maxBytes, known: known)
        if known {
            current.occupancyByPhase[phase, default: LiveIngressOccupancy()].integrate(elapsed,
                items: items, bytes: bytes, maxItems: maxItems, maxBytes: maxBytes, known: true)
        }
        current.monotonicEnd = time
    }

    /// Like video observations, legal clocks are 0...1e12, windows are anchored
    /// half-open intervals, and gap work is constant: prior window + one coalesced
    /// interval + current partial. Unlike empty video gaps, occupied gaps retain
    /// the exact unchanged normalized depth and phase for their whole duration.
    private mutating func advance(to time: Double) -> Bool {
        guard Self.legalClock(time), time >= lastClock else {
            invalidity.insert(.invalidMonotonicClock); clockKnown = false
            var count = rejectedClocks; increment(&count); rejectedClocks = count
            return false
        }
        var next = UInt64(((time - anchor) / duration).rounded(.down))
        if next > 0, time < boundary(next) { next -= 1 }
        if time >= boundary(next + 1) { next += 1 }
        if next > index {
            integrateCurrent(until: current.scheduledMonotonicEnd)
            current.isPartial = false; appendCompleted(current)
            if next - index > 1 {
                current = LiveIngressObservationWindow(monotonicStart: boundary(index + 1),
                    monotonicEnd: boundary(index + 1), scheduledMonotonicEnd: boundary(next))
                current.isCoalesced = true; current.coveredWindowCount = next - index - 1
                integrateCurrent(until: boundary(next))
                current.isPartial = false; appendCompleted(current)
            }
            index = next
            current = LiveIngressObservationWindow(monotonicStart: boundary(next), monotonicEnd: boundary(next),
                scheduledMonotonicEnd: boundary(next + 1))
        }
        integrateCurrent(until: time)
        lastClock = time; clockKnown = true
        return true
    }
}

private extension LiveIngressOccupancy {
    mutating func peak(items: Int, bytes: Int) {
        peakItems = max(peakItems, items); peakBytes = max(peakBytes, bytes)
    }
    mutating func integrate(_ elapsed: Double, items: Int, bytes: Int, maxItems: Int, maxBytes: Int, known: Bool) {
        // At an exact boundary the old depth belongs to the preceding interval.
        // updateOccupancy records the new instantaneous peak after the transition.
        guard elapsed > 0 else { return }
        // At most 1e12 legal elapsed seconds, normalized ratios in 0...1.
        // Clamping also absorbs rounding at the extreme legal clock boundary.
        guard known else { unknownDuration = min(1e12, unknownDuration + elapsed); return }
        knownDuration = min(1e12, knownDuration + elapsed)
        let itemRatio = min(1, max(0, Double(items) / Double(maxItems)))
        let byteRatio = min(1, max(0, Double(bytes) / Double(maxBytes)))
        itemSeconds = min(knownDuration, itemSeconds + itemRatio * elapsed)
        byteSeconds = min(knownDuration, byteSeconds + byteRatio * elapsed)
        maxPressureSeconds = min(knownDuration, maxPressureSeconds + max(itemRatio, byteRatio) * elapsed)
        peak(items: items, bytes: bytes)
    }
}
private extension LiveIngressDispositionSummary {
    mutating func observe(_ pts: CMTime, referenceEpoch: Int64?, discontinuous: Bool, limit: UInt64) {
        if count == limit { invalidity.insert(.counterOverflow) } else { count += 1 }
        guard pts.isNumeric, pts.timescale > 0 else {
            if invalidPTSCount == limit { invalidity.insert(.counterOverflow) } else { invalidPTSCount += 1 }
            invalidity.insert(.invalidPTS); return
        }
        if firstSourcePTS == nil { firstSourcePTS = pts }
        lastSourcePTS = pts
        if discontinuous || referenceEpoch.map({ $0 != pts.epoch }) == true {
            invalidity.insert(.epochDiscontinuity); return
        }
        if minimumSourcePTS.map({ CMTimeCompare(pts, $0) < 0 }) ?? true { minimumSourcePTS = pts }
        if maximumSourcePTS.map({ CMTimeCompare(pts, $0) > 0 }) ?? true { maximumSourcePTS = pts }
    }
}

import CoreMedia
import Foundation

/// Local identity only. No worker attempt or remote delivery identity is inferred.
public struct VideoFrameObservationScope: Equatable, Sendable {
    public let recordingID: String
    public let matchID: String
    public let broadcastGeneration: Int
    public let publishingAttemptID: UUID
    public let appliedProfileRevision: UInt64

    public init(recordingID: String, matchID: String, broadcastGeneration: Int,
                publishingAttemptID: UUID, appliedProfileRevision: UInt64) {
        self.recordingID = recordingID
        self.matchID = matchID
        self.broadcastGeneration = broadcastGeneration
        self.publishingAttemptID = publishingAttemptID
        self.appliedProfileRevision = appliedProfileRevision
    }
}

public enum VideoFrameObservationStage: Sendable { case captureVideo, encodedVideo }
public enum VideoFrameObservationError: Error, Equatable { case invalidConfiguration }

public struct VideoFrameObservationInvalidity: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let invalidSourcePTS = Self(rawValue: 1 << 0)
    public static let epochDiscontinuity = Self(rawValue: 1 << 1)
    public static let invalidMonotonicClock = Self(rawValue: 1 << 2)
    public static let counterOverflow = Self(rawValue: 1 << 3)
}

/// Timestamp progression is evidence of source-PTS freshness only, never image
/// content uniqueness, encoder capacity, source loss, or transport receipt.
public struct VideoFrameObservationAggregate: Sendable {
    public fileprivate(set) var callbackCount: UInt64 = 0
    /// Includes the first numeric PTS (zero is valid), then strictly advancing PTS.
    public fileprivate(set) var advancingSourcePTSCount: UInt64 = 0
    public fileprivate(set) var duplicateSourcePTSCount: UInt64 = 0
    public fileprivate(set) var reorderedSourcePTSCount: UInt64 = 0
    public fileprivate(set) var invalidSourcePTSCount: UInt64 = 0
    /// Numeric callbacks quarantined after any epoch mismatch. This includes all
    /// later numeric callbacks, even a return to the original epoch.
    public fileprivate(set) var discontinuousSourcePTSCount: UInt64 = 0
    /// First and last numeric PTS observed in this interval, including reorders
    /// and discontinuities. Their rational representation and epoch are retained.
    public fileprivate(set) var firstSourcePTS: CMTime?
    public fileprivate(set) var lastSourcePTS: CMTime?
    /// Continuity fields survive window rotation, including empty gap intervals.
    public fileprivate(set) var highWaterSourcePTS: CMTime?
    public fileprivate(set) var firstObservationTime: Double?
    public fileprivate(set) var lastObservationTime: Double?
    /// Malformed PTS evidence is local to this interval. Epoch discontinuity and
    /// counter overflow persist through rotation. The snapshot also retains every
    /// observed invalidity as owner-level evidence, even after history eviction.
    public fileprivate(set) var invalidity: VideoFrameObservationInvalidity = []

    fileprivate func nextWindow() -> Self {
        var next = Self()
        next.highWaterSourcePTS = highWaterSourcePTS
        next.firstObservationTime = firstObservationTime
        next.lastObservationTime = lastObservationTime
        next.invalidity = invalidity.intersection([.epochDiscontinuity, .counterOverflow])
        return next
    }

    private mutating func increment(_ field: WritableKeyPath<Self, UInt64>, limit: UInt64) {
        if self[keyPath: field] == limit { invalidity.insert(.counterOverflow) }
        else { self[keyPath: field] += 1 }
    }

    fileprivate mutating func observe(_ pts: CMTime, at time: Double, counterLimit: UInt64) {
        increment(\.callbackCount, limit: counterLimit)
        if firstObservationTime == nil { firstObservationTime = time }
        lastObservationTime = time
        guard pts.isNumeric, pts.timescale > 0 else {
            increment(\.invalidSourcePTSCount, limit: counterLimit)
            invalidity.insert(.invalidSourcePTS)
            return
        }
        if firstSourcePTS == nil { firstSourcePTS = pts }
        lastSourcePTS = pts
        if invalidity.contains(.epochDiscontinuity)
            || highWaterSourcePTS.map({ $0.epoch != pts.epoch }) == true {
            invalidity.insert(.epochDiscontinuity)
            increment(\.discontinuousSourcePTSCount, limit: counterLimit)
            return
        }
        guard let highWaterSourcePTS else {
            self.highWaterSourcePTS = pts
            increment(\.advancingSourcePTSCount, limit: counterLimit)
            return
        }
        let comparison = CMTimeCompare(pts, highWaterSourcePTS)
        if comparison > 0 {
            self.highWaterSourcePTS = pts
            increment(\.advancingSourcePTSCount, limit: counterLimit)
        } else if comparison == 0 {
            increment(\.duplicateSourcePTSCount, limit: counterLimit)
        } else {
            increment(\.reorderedSourcePTSCount, limit: counterLimit)
        }
    }
}

public struct VideoFrameObservationWindow: Sendable {
    public fileprivate(set) var monotonicStart: Double
    /// Completed intervals retain their entire duration. For a partial interval,
    /// this is the last trusted operation time, not the last callback time.
    public fileprivate(set) var monotonicEnd: Double
    public fileprivate(set) var scheduledMonotonicEnd: Double
    public fileprivate(set) var coveredWindowCount: UInt64 = 1
    public fileprivate(set) var isCoalescedEmptyGap = false
    public fileprivate(set) var isPartial = true
    public fileprivate(set) var isClosed = false
    public fileprivate(set) var captureVideo = VideoFrameObservationAggregate()
    public fileprivate(set) var encodedVideo = VideoFrameObservationAggregate()
}

public struct VideoFrameObservationSnapshot: Sendable {
    public let scope: VideoFrameObservationScope
    public let monotonicAnchor: Double
    public let windowDuration: Double
    public let current: VideoFrameObservationWindow
    /// Bounded chronological history; gaps may cover multiple empty intervals.
    public let completed: [VideoFrameObservationWindow]
    /// Counts underlying intervals evicted from history, not merely array entries.
    public let omittedCompletedWindowCount: UInt64
    public let omittedThroughMonotonicTime: Double?
    public let rejectedClockOperationCount: UInt64
    /// Sticky for this owner, including rejected clock operations and any overflow.
    public let invalidity: VideoFrameObservationInvalidity
    public let isClosed: Bool
}

/// Pure scalar accumulator. Callers must serialize access or use the owner below.
///
/// Windows are fixed half-open intervals anchored at creation. A callback rotates
/// BEFORE being counted; a poll advances the clock without adding a callback. A
/// poll must not run ahead of callbacks whose supplied observation times precede
/// it: those late operations are rejected, never reassigned to a newer interval.
/// Equal monotonic times are allowed. Each callback supplies its own clock value.
///
/// Legal clock values are finite seconds in 0...1e12; duration is 1/1024...86400
/// seconds, history limit 1...128. These bounds keep index arithmetic representable
/// and avoid windows below clock precision. Out-of-range, reversed, or nonfinite
/// clocks reject the operation and sticky-invalidate the owner, preserving PTS.
///
/// Rotating over any gap emits at most two completed records: the prior interval
/// and one coalesced empty gap. Work and retained memory are bounded by the fixed
/// history limit, independent of elapsed time. The anchor, persistent first/last
/// observations, and eviction count/time retain startup and omitted-gap evidence.
/// Counts saturate at UInt64.max; saturation invalidates rather than wrapping.
public struct VideoFrameObservationAccumulator: Sendable {
    private let scope: VideoFrameObservationScope
    private let anchor: Double
    private let duration: Double
    private let historyLimit: Int
    private let counterLimit: UInt64
    private var windowIndex: UInt64 = 0
    private var lastClock: Double
    private var current: VideoFrameObservationWindow
    private var completed: [VideoFrameObservationWindow] = []
    private var omittedCount: UInt64 = 0
    private var omittedThrough: Double?
    private var rejectedClocks: UInt64 = 0
    private var invalidity: VideoFrameObservationInvalidity = []
    private var closed = false

    public init(scope: VideoFrameObservationScope, monotonicAnchor: Double,
                windowDuration: Double = 5, completedWindowLimit: Int = 8) throws {
        try self.init(scope: scope, monotonicAnchor: monotonicAnchor,
                      windowDuration: windowDuration, completedWindowLimit: completedWindowLimit,
                      counterLimit: .max)
    }

    // Internal bounded counter ceiling lets tests reach overflow without 2^64 calls.
    init(scope: VideoFrameObservationScope, monotonicAnchor: Double,
         windowDuration: Double, completedWindowLimit: Int, counterLimit: UInt64) throws {
        guard Self.legalClock(monotonicAnchor), windowDuration.isFinite,
              (1.0 / 1024...86400).contains(windowDuration),
              (1...128).contains(completedWindowLimit), counterLimit > 0
        else { throw VideoFrameObservationError.invalidConfiguration }
        self.scope = scope
        anchor = monotonicAnchor
        duration = windowDuration
        historyLimit = completedWindowLimit
        self.counterLimit = counterLimit
        lastClock = monotonicAnchor
        current = VideoFrameObservationWindow(monotonicStart: monotonicAnchor,
            monotonicEnd: monotonicAnchor, scheduledMonotonicEnd: monotonicAnchor + windowDuration)
    }

    public var snapshot: VideoFrameObservationSnapshot {
        VideoFrameObservationSnapshot(scope: scope, monotonicAnchor: anchor, windowDuration: duration,
            current: current, completed: completed, omittedCompletedWindowCount: omittedCount,
            omittedThroughMonotonicTime: omittedThrough, rejectedClockOperationCount: rejectedClocks,
            invalidity: invalidity, isClosed: closed)
    }

    /// False means closed or a rejected clock; no source PTS was consumed.
    @discardableResult
    public mutating func observe(_ stage: VideoFrameObservationStage, sourcePTS: CMTime, at time: Double) -> Bool {
        guard !closed, advance(to: time) else { return false }
        switch stage {
        case .captureVideo:
            current.captureVideo.observe(sourcePTS, at: time, counterLimit: counterLimit)
            invalidity.formUnion(current.captureVideo.invalidity)
        case .encodedVideo:
            current.encodedVideo.observe(sourcePTS, at: time, counterLimit: counterLimit)
            invalidity.formUnion(current.encodedVideo.invalidity)
        }
        return true
    }

    @discardableResult
    public mutating func poll(at time: Double) -> VideoFrameObservationSnapshot {
        if !closed { _ = advance(to: time) }
        return snapshot
    }

    /// Caller-controlled terminal operation: invoke AFTER any desired encoder
    /// drain. There is no automatic shutdown on a poll or owner deinitialization.
    /// The final partial interval stays in `current`; reads are non-consuming so
    /// later diagnostics may read it repeatedly. Late callbacks/polls/close calls
    /// cannot mutate anything. Invalid close time freezes at the last trusted time
    /// and records the clock rejection before closing. At an exact boundary the
    /// preceding full interval is completed and the final partial has zero length.
    @discardableResult
    public mutating func close(at time: Double) -> VideoFrameObservationSnapshot {
        guard !closed else { return snapshot }
        _ = advance(to: time)
        closed = true
        current.isClosed = true
        return snapshot
    }

    private static func legalClock(_ time: Double) -> Bool {
        time.isFinite && (0...1e12).contains(time)
    }

    private mutating func addSaturating(_ amount: UInt64, to value: inout UInt64) {
        if amount > counterLimit - value {
            value = counterLimit
            invalidity.insert(.counterOverflow)
        } else { value += amount }
    }

    private mutating func appendCompleted(_ window: VideoFrameObservationWindow) {
        if completed.count == historyLimit {
            let removed = completed.removeFirst()
            // Locals avoid overlapping access to the mutable accumulator.
            var count = omittedCount
            addSaturating(removed.coveredWindowCount, to: &count)
            omittedCount = count
            omittedThrough = removed.monotonicEnd
        }
        completed.append(window)
    }

    private func boundary(_ index: UInt64) -> Double { anchor + Double(index) * duration }

    private mutating func advance(to time: Double) -> Bool {
        guard Self.legalClock(time), time >= lastClock else {
            invalidity.insert(.invalidMonotonicClock)
            var count = rejectedClocks
            addSaturating(1, to: &count)
            rejectedClocks = count
            return false
        }
        // Quotient rounding at a represented boundary may be one index off.
        // Correct against the actual anchored boundaries, without a gap-sized loop.
        var index = UInt64(((time - anchor) / duration).rounded(.down))
        if index > 0, time < boundary(index) { index -= 1 }
        if time >= boundary(index + 1) { index += 1 }
        if index > windowIndex {
            current.monotonicEnd = current.scheduledMonotonicEnd
            current.isPartial = false
            appendCompleted(current)
            let capture = current.captureVideo.nextWindow()
            let encoded = current.encodedVideo.nextWindow()
            if index - windowIndex > 1 {
                var gap = VideoFrameObservationWindow(monotonicStart: boundary(windowIndex + 1),
                    monotonicEnd: boundary(index), scheduledMonotonicEnd: boundary(index))
                gap.coveredWindowCount = index - windowIndex - 1
                gap.isCoalescedEmptyGap = true
                gap.isPartial = false
                gap.captureVideo = capture
                gap.encodedVideo = encoded
                appendCompleted(gap)
            }
            windowIndex = index
            current = VideoFrameObservationWindow(monotonicStart: boundary(index),
                monotonicEnd: time, scheduledMonotonicEnd: boundary(index + 1))
            current.captureVideo = capture
            current.encodedVideo = encoded
        }
        lastClock = time
        current.monotonicEnd = time
        return true
    }
}

/// One synchronous owner per immutable publishing attempt/profile scope. Retained
/// callbacks reference this exact owner, so closing/replacing an owner cannot
/// redirect old observations to a new scope. Capture and encoder share its anchor,
/// but their counts do not establish a loss percentage. NSLock protects only scalar
/// state: no external callbacks, sample buffers, tasks, I/O, or media retention.
/// Observation time is sampled from system uptime INSIDE the lock at scalar
/// admission, not caller entry, so concurrent callbacks and polling cannot produce
/// false clock reversals by acquiring this lock out of order. Each callback uses
/// its own admission time. The pure accumulator accepts explicit times for tests.
public final class VideoFrameObservationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator: VideoFrameObservationAccumulator

    public init(scope: VideoFrameObservationScope,
                windowDuration: Double = 5, completedWindowLimit: Int = 8) throws {
        accumulator = try VideoFrameObservationAccumulator(scope: scope,
            monotonicAnchor: ProcessInfo.processInfo.systemUptime,
            windowDuration: windowDuration, completedWindowLimit: completedWindowLimit)
    }
    public var snapshot: VideoFrameObservationSnapshot { lock.withLock { accumulator.snapshot } }
    @discardableResult
    public func observe(_ stage: VideoFrameObservationStage, sourcePTS: CMTime) -> Bool {
        lock.withLock {
            accumulator.observe(stage, sourcePTS: sourcePTS, at: ProcessInfo.processInfo.systemUptime)
        }
    }
    @discardableResult
    public func poll() -> VideoFrameObservationSnapshot {
        lock.withLock { accumulator.poll(at: ProcessInfo.processInfo.systemUptime) }
    }
    /// Call only after the desired encoder drain; the final snapshot is retained.
    @discardableResult
    public func close() -> VideoFrameObservationSnapshot {
        lock.withLock { accumulator.close(at: ProcessInfo.processInfo.systemUptime) }
    }
}

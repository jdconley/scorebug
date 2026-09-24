import Foundation
import ScorebugCore

/// A scheduling prerequisite only. Core still supplies fresh source readiness,
/// and the session separately checks the current receipt and revocable owners.
/// Completed historical delivery is never promoted into Core health credit.
final class PublishingCandidateRecoveryCoverage: @unchecked Sendable {
    private struct Source {
        let start: Double, end: Double
        let sequence: UInt64
    }
    private struct Lane { let start: Double; var end: Double }
    private let lock = NSLock()
    private var sources: [Source] = []
    private var lanes: [Int: Lane] = [:]
    private var resumedAt: Double?
    private var invalid = false

    /// Also callable synchronously by the driver's input classifier, before
    /// actor scheduling can expose a positive row from a mixed/invalid batch.
    func invalidate() { lock.withLock { clear() } }
    private func clear() { sources = []; lanes = [:]; resumedAt = nil; invalid = false }
    private func finite(_ time: Double) -> Bool { time.isFinite && (0...1e12).contains(time) }
    func resume(at now: Double) {
        lock.withLock {
            guard !invalid else { return }
            guard finite(now) else { invalid = true; return }
            if resumedAt == nil { resumedAt = now }
        }
    }
    func recordSource(start: Double, end: Double, sequence: UInt64) {
        lock.withLock {
            guard !invalid else { return }
            guard finite(start), finite(end), end > start, sequence > 0,
                  sources.last.map({ sequence > $0.sequence }) ?? true,
                  sources.count < 256 else { invalid = true; return }
            if let previous = sources.last, previous.end != start { clear() }
            sources.append(.init(start: start, end: end, sequence: sequence))
        }
    }
    func recordDelivery(start: Double, end: Double, result: DeliveryDeadlineResult) {
        lock.withLock {
            guard !invalid else { return }
            let duration = end - start
            guard finite(start), finite(end), [1.0, 2.0].contains(duration), result.duration == duration,
                  (1...240).contains(result.expectedFrames),
                  [result.onTimeFrames, result.lateFrames, result.missingFrames, result.uncertainFrames]
                    .allSatisfy({ (0...240).contains($0) }),
                  result.onTimeFrames + result.lateFrames + result.missingFrames + result.uncertainFrames == result.expectedFrames
            else { invalid = true; return }
            guard result.uncertainFrames == 0, result.lateFrames == 0, result.missingFrames == 0,
                  Double(result.onTimeFrames) / duration >= 30 else { clear(); return }
            let lane = Int(duration)
            if var previous = lanes[lane] {
                guard previous.end == start else { clear(); return }
                previous.end = end; lanes[lane] = previous
            } else { lanes[lane] = .init(start: start, end: end) }
        }
    }
    func permits(healthySince: Double, healthyThrough: Double, healthSequence: UInt64) -> Bool {
        lock.withLock {
            guard !invalid, let resumedAt, let one = lanes[1], let two = lanes[2],
                  finite(healthySince), finite(healthyThrough), healthySince < healthyThrough else { return false }
            let lower = max(max(healthySince, resumedAt), max(one.start, two.start))
            let upper = min(healthyThrough, min(one.end, two.end))
            // Select whole original source windows within Core's current strong
            // segment. Reusing this earliest completed prefix does not require
            // delivery to catch each newer (short-lived) source readiness tail.
            var start: Double?, end: Double?
            for window in sources where window.start >= lower && window.end <= upper && window.sequence <= healthSequence {
                if let end, window.start != end { return false }
                if start == nil { start = window.start }
                end = window.end
                if window.end - start! >= 10 { return true }
            }
            return false
        }
    }
}

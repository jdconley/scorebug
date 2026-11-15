import Foundation

/// Pure conservative clock-interval arithmetic, not a control-plane authenticator
/// or a source/configuration matcher. Caller-owned scope/freshness and complete
/// native source windows are prerequisites. No quality controller consumes this yet.
public enum DeliveryDeadlineClassifier {
    public enum Failure: Error, Equatable { case invalidEvidence, incompleteCoverage, impossibleArrival }
    private static let maximum: Int64 = 9_007_199_254_740_991
    public static func classify(timeline: DecoderDeliverySnapshot, expectedScopeID: String,
                                frames: [DeliveryDeadlineFrame], windowStart: Double, windowEnd: Double,
                                evaluatedAt: Double, sampleAgeUpperBound: Double,
                                maximumSampleAge: Double, latencyBudget: Double,
                                sampleTimeBounds: DeliverySampleTimeBounds? = nil) throws -> DeliveryDeadlineResult {
        func finite(_ n: Double) -> Bool { n.isFinite && (0...1e12).contains(n) }
        func age(_ n: Double) -> Bool { n.isFinite && n >= 0 && n <= Double(maximum) }
        func pts(_ n: Int64) -> Bool { (-maximum...maximum).contains(n) }
        guard timeline.formatVersion == 1, timeline.scopeID == expectedScopeID,
              WorkerPublication.isCanonicalUUID(expectedScopeID), timeline.invalidReason == nil, !timeline.ended,
              age(timeline.coverageAgeMs), (0...maximum).contains(timeline.lastOrdinal),
              timeline.arrivals.count == Int(min(timeline.lastOrdinal, 256)),
              finite(windowStart), finite(windowEnd), [1.0, 2.0].contains(windowEnd - windowStart),
              finite(evaluatedAt), evaluatedAt >= windowEnd,
              maximumSampleAge.isFinite, maximumSampleAge > 0, maximumSampleAge <= 5,
              sampleAgeUpperBound.isFinite, sampleAgeUpperBound >= 0,
              sampleAgeUpperBound <= maximumSampleAge, sampleAgeUpperBound <= evaluatedAt,
              latencyBudget.isFinite, latencyBudget > 0, latencyBudget <= 10,
              !frames.isEmpty, frames.count <= 240 else { throw Failure.invalidEvidence }
        if let sampleTimeBounds {
            guard sampleTimeBounds.upper <= evaluatedAt,
                  evaluatedAt - sampleTimeBounds.lower <= maximumSampleAge else { throw Failure.invalidEvidence }
        }
        var previousCapture: Double?, sourceIDs = Set<Int64>()
        for frame in frames {
            guard pts(frame.pts), finite(frame.capturedAt), frame.capturedAt >= windowStart,
                  frame.capturedAt < windowEnd, previousCapture.map({ frame.capturedAt > $0 }) ?? true,
                  sourceIDs.insert(frame.pts).inserted else { throw Failure.invalidEvidence }
            previousCapture = frame.capturedAt
        }
        let sampleLower = sampleTimeBounds?.lower ?? evaluatedAt - sampleAgeUpperBound
        let sampleUpper = sampleTimeBounds?.upper ?? evaluatedAt
        guard sampleUpper - timeline.coverageAgeMs / 1000 < frames[0].capturedAt,
              sampleLower > frames.last!.capturedAt + latencyBudget else { throw Failure.incompleteCoverage }
        var firstArrivals: [Int64: Double] = [:]
        var previousAge = timeline.coverageAgeMs
        let firstOrdinal = timeline.lastOrdinal - Int64(timeline.arrivals.count) + 1
        for (index, arrival) in timeline.arrivals.enumerated() {
            guard arrival.ordinal == firstOrdinal + Int64(index), pts(arrival.pts),
                  age(arrival.ageMs), arrival.ageMs <= previousAge else { throw Failure.invalidEvidence }
            previousAge = arrival.ageMs
            if firstArrivals[arrival.pts] == nil { firstArrivals[arrival.pts] = arrival.ageMs / 1000 }
        }
        var onTime = 0, late = 0, missing = 0, uncertain = 0
        for frame in frames {
            guard let arrivalAge = firstArrivals[frame.pts] else { missing += 1; continue }
            let upper = sampleUpper - arrivalAge
            let lower = sampleTimeBounds.map { $0.lower - arrivalAge } ?? upper - sampleAgeUpperBound
            guard upper >= frame.capturedAt else { throw Failure.impossibleArrival }
            let deadline = frame.capturedAt + latencyBudget
            if upper <= deadline { onTime += 1 }
            else if lower > deadline { late += 1 }
            else { uncertain += 1 }
        }
        return .init(expectedFrames: frames.count, onTimeFrames: onTime, lateFrames: late,
            missingFrames: missing, uncertainFrames: uncertain, duration: windowEnd - windowStart)
    }
}

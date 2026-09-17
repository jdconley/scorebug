import Foundation

public struct DecoderCadenceWindow: Codable, Equatable, Sendable {
    public var sequence: Int64
    public var durationMs: Int
    public var ageMs: Double
    public var firstPTS: Int64?
    public var lastPTS: Int64?
    public var freshFrames: Int64
    public var duplicateFrames: Int64
    public var reorderedFrames: Int64
    public var valid: Bool
    private enum CodingKeys: String, CodingKey { case sequence, durationMs, ageMs, firstPTS, lastPTS, freshFrames, duplicateFrames, reorderedFrames, valid }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sequence, forKey: .sequence); try c.encode(durationMs, forKey: .durationMs); try c.encode(ageMs, forKey: .ageMs)
        try c.encode(firstPTS, forKey: .firstPTS); try c.encode(lastPTS, forKey: .lastPTS)
        try c.encode(freshFrames, forKey: .freshFrames); try c.encode(duplicateFrames, forKey: .duplicateFrames)
        try c.encode(reorderedFrames, forKey: .reorderedFrames); try c.encode(valid, forKey: .valid)
    }
}
public struct DecoderCadenceProgress: Codable, Equatable, Sendable {
    public var lastFreshPTS: Int64
    public var ageMs: Double
    public var stalled: Bool
}
public struct DecoderCadenceSnapshot: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var scopeID: String
    public var oneSecond: DecoderCadenceWindow?
    public var twoSeconds: DecoderCadenceWindow?
    public var progress: DecoderCadenceProgress?
    public var invalidReason: DecodedVideoInvalidReason?
    public var ended: Bool

    private enum CodingKeys: String, CodingKey { case formatVersion, scopeID, oneSecond, twoSeconds, progress, invalidReason, ended }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion); try c.encode(scopeID, forKey: .scopeID)
        try c.encode(oneSecond, forKey: .oneSecond); try c.encode(twoSeconds, forKey: .twoSeconds)
        try c.encode(progress, forKey: .progress); try c.encode(invalidReason, forKey: .invalidReason); try c.encode(ended, forKey: .ended)
    }
}

/// Fresh worker decoder-arrival evidence for the expected publication. This does
/// not establish source loss, on-time delivery, headroom, or viewer output.
public struct WorkerDecoderCadenceFreshness: Sendable {
    public enum Window: Sendable { case oneSecond, twoSeconds }
    /// Local consumption identity for one received response. Copies retain it;
    /// this is not a worker epoch or a server authenticity claim.
    public let receiptID: UUID
    public let gameId: String
    public let generation: Int
    public let workerId: String
    public let workerEpoch: String
    public let attempt: Int
    public let publication: WorkerPublication
    public let snapshot: DecoderCadenceSnapshot
    private static let maximum: Int64 = 9_007_199_254_740_991
    private static let maximumAge: Duration = .milliseconds(maximum)
    private let receivedAt: ContinuousClock.Instant
    private let ageAtReceipt: Duration
    private let statusFreshness: WorkerStatusFreshness

    public init?(response: WorkerMediaStatusResponse, expectedPublishingAttemptID: UUID,
                 receivedAt: ContinuousClock.Instant, requestDuration: Duration) {
        let status = response.status
        guard requestDuration >= .zero, status.state == .producingOutput,
              let publication = status.validatedPublication,
              publication.publishingAttemptId == expectedPublishingAttemptID.uuidString.lowercased(),
              let observation = status.observation, let workerId = status.workerId, let workerEpoch = status.workerEpoch,
              observation.decodedVideo?.clock == "mpegts-pts-90k-v1",
              let snapshot = observation.decoderCadence, Self.valid(snapshot),
              let serverAge = status.decoderCadenceAgeUpperBoundMs,
              serverAge.isFinite, serverAge >= 0, serverAge <= Double(Self.maximum), serverAge.rounded(.down) == serverAge else { return nil }
        let base = Duration.milliseconds(Int64(serverAge))
        guard requestDuration <= Self.maximumAge - base else { return nil }
        let freshness = WorkerStatusFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration)
        guard freshness.isFresh(at: receivedAt) else { return nil }
        self.receiptID = UUID()
        self.gameId = status.gameId; self.generation = status.generation; self.workerId = workerId; self.workerEpoch = workerEpoch
        self.attempt = observation.attempt; self.publication = publication; self.snapshot = snapshot
        self.receivedAt = receivedAt; self.ageAtReceipt = base + requestDuration; self.statusFreshness = freshness
    }
    public func sampleAgeUpperBound(at instant: ContinuousClock.Instant = .now) -> Duration? {
        guard instant >= receivedAt, statusFreshness.isFresh(at: instant) else { return nil }
        let residence = receivedAt.duration(to: instant)
        guard residence <= Self.maximumAge - ageAtReceipt else { return nil }
        return ageAtReceipt + residence
    }
    public func windowAgeUpperBound(_ window: Window, at instant: ContinuousClock.Instant = .now) -> Duration? {
        let value = window == .oneSecond ? snapshot.oneSecond : snapshot.twoSeconds
        guard let value, let sampleAge = sampleAgeUpperBound(at: instant) else { return nil }
        let age = Duration.milliseconds(Int64(value.ageMs.rounded(.up)))
        guard sampleAge <= Self.maximumAge - age else { return nil }
        return age + sampleAge
    }
    /// Never turns missing reports into a new stall. The worker must have observed
    /// it, and the caller supplies its independently qualified report-age budget.
    public func observedStall(maximumSampleAge: Duration, at instant: ContinuousClock.Instant = .now) -> Bool? {
        guard maximumSampleAge >= .zero, let age = sampleAgeUpperBound(at: instant), age <= maximumSampleAge else { return nil }
        return snapshot.progress?.stalled
    }
    private static func valid(_ snapshot: DecoderCadenceSnapshot) -> Bool {
        guard snapshot.formatVersion == 1, WorkerPublication.isCanonicalUUID(snapshot.scopeID),
              snapshot.invalidReason == nil, !snapshot.ended, let progress = snapshot.progress,
              safe(progress.lastFreshPTS), age(progress.ageMs), progress.stalled == (progress.ageMs >= 1000) else { return false }
        for (window, duration) in [(snapshot.oneSecond, 1000), (snapshot.twoSeconds, 2000)] {
            guard let w = window else { continue }
            guard w.valid, w.sequence > 0, w.sequence <= maximum / Int64(duration), w.durationMs == duration, age(w.ageMs) else { return false }
            var count: Int64 = 0
            for n in [w.freshFrames, w.duplicateFrames, w.reorderedFrames] {
                guard n >= 0, n <= maximum - count else { return false }; count += n
            }
            if w.freshFrames == 0 {
                guard w.firstPTS == nil, w.lastPTS == nil else { return false }
            } else {
                guard let first = w.firstPTS, let last = w.lastPTS, safe(first), safe(last),
                      (w.freshFrames == 1 ? first == last : first < last), last <= progress.lastFreshPTS else { return false }
            }
        }
        if let two = snapshot.twoSeconds {
            guard let one = snapshot.oneSecond,
                  one.sequence == two.sequence * 2 || one.sequence == two.sequence * 2 + 1 else { return false }
            let oneTime = Double(one.sequence * 1000) + one.ageMs, twoTime = Double(two.sequence * 2000) + two.ageMs
            guard abs(oneTime - twoTime) <= 0.001 else { return false }
        } else if let one = snapshot.oneSecond, one.sequence != 1 { return false }
        return true
    }
    private static func safe(_ n: Int64) -> Bool { n >= -maximum && n <= maximum }
    private static func age(_ n: Double) -> Bool { n.isFinite && n >= 0 && n <= Double(maximum) }
}

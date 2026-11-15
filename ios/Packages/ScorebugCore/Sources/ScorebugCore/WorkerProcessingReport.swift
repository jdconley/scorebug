import Foundation

public struct WorkerObservedDuration: Codable, Equatable, Sendable {
    public var meanMs: Double
    public var maximumMs: Double
    public init(meanMs: Double, maximumMs: Double) { self.meanMs = meanMs; self.maximumMs = maximumMs }
}
public struct WorkerProcessingInterval: Codable, Equatable, Sendable {
    public var sourceStartExclusive: Int64
    public var sourceEndInclusive: Int64
    public var decodedFrames: Int64
    public var submittedFrames: Int64
    public var completedFrames: Int64
    public var pendingFrames: Int64
    public var omittedBeforeEncoderFrames: Int64
    public var intentionalFrameCapOmissions: Int64?
    public var filterDuration: WorkerObservedDuration?
    public var processingDuration: WorkerObservedDuration?
    public init(sourceStartExclusive: Int64, sourceEndInclusive: Int64, decodedFrames: Int64, submittedFrames: Int64,
                completedFrames: Int64, pendingFrames: Int64, omittedBeforeEncoderFrames: Int64,
                filterDuration: WorkerObservedDuration?, processingDuration: WorkerObservedDuration?, intentionalFrameCapOmissions: Int64? = nil) {
        self.sourceStartExclusive = sourceStartExclusive; self.sourceEndInclusive = sourceEndInclusive
        self.decodedFrames = decodedFrames; self.submittedFrames = submittedFrames; self.completedFrames = completedFrames
        self.pendingFrames = pendingFrames; self.omittedBeforeEncoderFrames = omittedBeforeEncoderFrames
        self.intentionalFrameCapOmissions = intentionalFrameCapOmissions
        self.filterDuration = filterDuration; self.processingDuration = processingDuration
    }
    private enum CodingKeys: String, CodingKey { case sourceStartExclusive, sourceEndInclusive, decodedFrames, submittedFrames, completedFrames, pendingFrames, omittedBeforeEncoderFrames, filterDuration, processingDuration, intentionalFrameCapOmissions }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceStartExclusive, forKey: .sourceStartExclusive); try c.encode(sourceEndInclusive, forKey: .sourceEndInclusive)
        try c.encode(decodedFrames, forKey: .decodedFrames); try c.encode(submittedFrames, forKey: .submittedFrames)
        try c.encode(completedFrames, forKey: .completedFrames); try c.encode(pendingFrames, forKey: .pendingFrames)
        try c.encode(omittedBeforeEncoderFrames, forKey: .omittedBeforeEncoderFrames)
        try c.encodeIfPresent(intentionalFrameCapOmissions, forKey: .intentionalFrameCapOmissions)
        try c.encode(filterDuration, forKey: .filterDuration); try c.encode(processingDuration, forKey: .processingDuration)
    }
}
/// Untrusted optional wire metadata. Validate through WorkerProcessingEvidence before use.
public struct WorkerProcessingReport: Codable, Equatable, Sendable {
    public var scopeID: String
    public var encoder: String
    public var previousSequence: Int64
    public var sequence: Int64
    public var firstPTS: Int64
    public var interval: WorkerProcessingInterval
    public init(scopeID: String, encoder: String, previousSequence: Int64, sequence: Int64, firstPTS: Int64, interval: WorkerProcessingInterval) {
        self.scopeID = scopeID; self.encoder = encoder; self.previousSequence = previousSequence
        self.sequence = sequence; self.firstPTS = firstPTS; self.interval = interval
    }
}
/// Source-correlated worker processing, not pressure classification or viewer receipt.
public struct WorkerProcessingEvidence: Sendable {
    public let report: WorkerProcessingReport
    public let publication: WorkerPublication
    public let workerEpoch: String
    public let freshness: WorkerDecodedVideoFreshness
    public init?(response: WorkerMediaStatusResponse, receivedAt: ContinuousClock.Instant, requestDuration: Duration) {
        guard let report = response.status.observation?.processing,
              let decoded = response.status.observation?.decodedVideo,
              report.matches(decoded), let publication = response.status.validatedPublication,
              let epoch = response.status.workerEpoch,
              let freshness = WorkerDecodedVideoFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration) else { return nil }
        self.report = report; self.publication = publication; self.workerEpoch = epoch; self.freshness = freshness
    }
}

private extension WorkerProcessingReport {
    func matches(_ decoded: DecodedVideoSnapshot) -> Bool {
        let maximum: Int64 = 9_007_199_254_740_991
        guard WorkerPublication.isCanonicalUUID(scopeID), ["software", "videotoolbox", "nvenc"].contains(encoder),
              sequence >= 2, sequence <= maximum, previousSequence == sequence - 1,
              decoded.usesTransportClock, !decoded.ended, decoded.invalidReason == nil,
              let window = decoded.completed, window.valid, window.sequence == sequence,
              window.freshFrames > 0, window.duplicateFrames == 0, window.reorderedFrames == 0,
              window.firstPTS == firstPTS, window.lastPTS == interval.sourceEndInclusive,
              window.freshFrames == interval.decodedFrames else { return false }
        for pts in [firstPTS, interval.sourceStartExclusive, interval.sourceEndInclusive] {
            guard pts >= -maximum, pts <= maximum else { return false }
        }
        guard interval.sourceStartExclusive < firstPTS, firstPTS <= interval.sourceEndInclusive else { return false }
        for count in [interval.decodedFrames, interval.submittedFrames, interval.completedFrames,
                      interval.pendingFrames, interval.omittedBeforeEncoderFrames] {
            guard count >= 0, count <= maximum else { return false }
        }
        guard interval.submittedFrames <= interval.decodedFrames, interval.completedFrames <= interval.submittedFrames,
              interval.pendingFrames == interval.submittedFrames - interval.completedFrames,
              interval.omittedBeforeEncoderFrames == interval.decodedFrames - interval.submittedFrames else { return false }
        if let intentional = interval.intentionalFrameCapOmissions {
            guard intentional >= 0, intentional <= interval.omittedBeforeEncoderFrames else { return false }
        }
        for duration in [interval.filterDuration, interval.processingDuration].compactMap({ $0 }) {
            guard duration.meanMs.isFinite, duration.maximumMs.isFinite, duration.meanMs >= 0,
                  duration.meanMs <= duration.maximumMs, duration.maximumMs <= Double(maximum) else { return false }
        }
        guard interval.submittedFrames > 0 || (interval.filterDuration == nil && interval.processingDuration == nil),
              interval.pendingFrames == 0 || interval.processingDuration == nil else { return false }
        return true
    }
}

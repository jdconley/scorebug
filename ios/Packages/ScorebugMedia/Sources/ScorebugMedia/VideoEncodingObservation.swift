import Foundation

/// Verified settings at native submission, not achieved frame size or capacity.
public struct VideoEncodingConfiguration: Equatable, Sendable {
    public let id: UUID
    public let encoderSessionID: UUID
    public let bitRate: Int
    public init?(id: UUID, encoderSessionID: UUID, bitRate: Int) {
        guard bitRate > 0, bitRate <= Int32.max else { return nil }
        self.id = id; self.encoderSessionID = encoderSessionID; self.bitRate = bitRate
    }
}
/// Immutable scalar completion evidence. No media or mutable encoder is retained.
public struct VideoEncodingObservation: Equatable, Sendable {
    public let encoderSessionID: UUID
    public let configuration: VideoEncodingConfiguration?
    public let submittedAt: Double
    public let completedAt: Double
    public init?(encoderSessionID: UUID, configuration: VideoEncodingConfiguration?, submittedAt: Double, completedAt: Double) {
        guard submittedAt.isFinite, completedAt.isFinite, submittedAt >= 0,
              completedAt >= submittedAt,
              configuration.map({ $0.encoderSessionID == encoderSessionID }) ?? true else { return nil }
        self.encoderSessionID = encoderSessionID; self.configuration = configuration
        self.submittedAt = submittedAt; self.completedAt = completedAt
    }
}
/// Coverage of every included native frame, independent of receiver freshness.
public enum VideoEncodingCoverage: Equatable, Sendable {
    case unavailable, unverified, mixed
    case verified(VideoEncodingConfiguration)
}

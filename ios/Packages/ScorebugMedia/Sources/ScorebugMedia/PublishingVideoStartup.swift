import CoreMedia
import Foundation

/// Historical first native frame at the pre-mux boundary. This is neither a
/// bitrate-achievement measurement nor proof that a receiver displayed the frame.
public struct PublishingVideoStartup: Equatable, Sendable {
    public let profile: PublishingVideoProfile
    public let width: Int
    public let height: Int
    public let publishingGeneration: UInt64
    public let encoderSessionID: UUID
    public let firstSourcePTS: CMTime
    public let submittedAt: Double
    public let completedAt: Double
    public let observedAt: Double
    public init?(profile: PublishingVideoProfile, width: Int, height: Int,
                 publishingGeneration: UInt64, encoderSessionID: UUID, firstSourcePTS: CMTime,
                 submittedAt: Double, completedAt: Double, observedAt: Double) {
        guard width == profile.width, height == profile.height, publishingGeneration > 0,
              firstSourcePTS.isNumeric, firstSourcePTS.timescale > 0, firstSourcePTS.epoch == 0,
              firstSourcePTS.value >= 0, firstSourcePTS.seconds <= 1e12,
              [submittedAt, completedAt, observedAt].allSatisfy({ $0.isFinite && (0...1e12).contains($0) }),
              submittedAt <= completedAt, completedAt <= observedAt else { return nil }
        self.profile = profile; self.width = width; self.height = height
        self.publishingGeneration = publishingGeneration; self.encoderSessionID = encoderSessionID
        self.firstSourcePTS = firstSourcePTS; self.submittedAt = submittedAt
        self.completedAt = completedAt; self.observedAt = observedAt
    }
}

import CoreMedia
import Foundation

/// Historical verified native write, not a promise of current health or rate convergence.
public struct PublishingBitRateChange: Sendable {
    public let publishingGeneration: UInt64
    public let configuration: VideoEncodingConfiguration
    public let acceptedAt: Double
    public let lastSubmittedSourcePTS: CMTime?
    public init?(publishingGeneration: UInt64, configuration: VideoEncodingConfiguration,
                 acceptedAt: Double, lastSubmittedSourcePTS: CMTime?) {
        guard publishingGeneration > 0, acceptedAt.isFinite, (0...1e12).contains(acceptedAt),
              lastSubmittedSourcePTS.map({ $0.isNumeric && $0.timescale > 0 && $0.epoch == 0 }) ?? true else { return nil }
        self.publishingGeneration = publishingGeneration; self.configuration = configuration
        self.acceptedAt = acceptedAt; self.lastSubmittedSourcePTS = lastSubmittedSourcePTS
    }
}

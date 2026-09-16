import CoreMedia
import Foundation

/// Immutable live encoder choice. It never configures the local archive.
public enum PublishingVideoProfile: String, Sendable, CaseIterable {
    case hd1080 = "1080p30"
    case sd540 = "540p30"
    public var width: Int { self == .hd1080 ? 1920 : 960 }
    public var height: Int { self == .hd1080 ? 1080 : 540 }
    public var bitRate: Int { self == .hd1080 ? 6_000_000 : 1_500_000 }
}

/// Historical pre-mux format evidence, not achieved bitrate or receiver delivery.
public struct PublishingVideoProfileChange: Sendable {
    public let profile: PublishingVideoProfile
    public let publishingGeneration: UInt64
    public let previousEncoderSessionID: UUID
    public let encoderSessionID: UUID
    public let lastOldSourcePTS: CMTime
    public let firstNewSourcePTS: CMTime
    public let width: Int
    public let height: Int
    public let rawVideoFramesDropped: UInt64
    public let acknowledgedAt: Double
    public init?(profile: PublishingVideoProfile, publishingGeneration: UInt64,
                 previousEncoderSessionID: UUID, encoderSessionID: UUID,
                 lastOldSourcePTS: CMTime, firstNewSourcePTS: CMTime,
                 width: Int, height: Int, rawVideoFramesDropped: UInt64, acknowledgedAt: Double) {
        let times = [lastOldSourcePTS, firstNewSourcePTS]
        guard publishingGeneration > 0, previousEncoderSessionID != encoderSessionID,
              width == profile.width, height == profile.height,
              times.allSatisfy({ $0.isNumeric && $0.timescale > 0 && $0.epoch == 0 && $0 >= .zero }),
              CMTimeCompare(lastOldSourcePTS, firstNewSourcePTS) < 0,
              acknowledgedAt.isFinite, (0...1e12).contains(acknowledgedAt) else { return nil }
        self.profile = profile; self.publishingGeneration = publishingGeneration
        self.previousEncoderSessionID = previousEncoderSessionID; self.encoderSessionID = encoderSessionID
        self.lastOldSourcePTS = lastOldSourcePTS; self.firstNewSourcePTS = firstNewSourcePTS
        self.width = width; self.height = height; self.rawVideoFramesDropped = rawVideoFramesDropped
        self.acknowledgedAt = acknowledgedAt
    }
}

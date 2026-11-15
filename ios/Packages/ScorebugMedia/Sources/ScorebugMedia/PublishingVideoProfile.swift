import CoreMedia
import Foundation

/// Immutable live encoder choice. It never configures the local archive.
public enum PublishingVideoProfile: String, Sendable, CaseIterable {
    /// Normal app connections start at the lowest implemented live profile.
    /// Capture/archive settings are independently owned.
    public static let minimumStartup = PublishingVideoProfile.low240
    /// Explicit high-resolution recipe; not part of the automatic app ladder.
    case uhd2160 = "2160p30"
    case hd1080 = "1080p30"
    case hd720 = "720p30"
    case sd540 = "540p30"
    case low360 = "360p30"
    case low240 = "240p30"
    public var width: Int {
        switch self { case .uhd2160: 3840; case .hd1080: 1920; case .hd720: 1280; case .sd540: 960; case .low360: 640; case .low240: 426 }
    }
    public var height: Int {
        switch self { case .uhd2160: 2160; case .hd1080: 1080; case .hd720: 720; case .sd540: 540; case .low360: 360; case .low240: 240 }
    }
    public var bitRate: Int {
        switch self { case .uhd2160: 24_000_000; case .hd1080: 6_000_000; case .hd720: 3_000_000; case .sd540: 1_500_000; case .low360: 600_000; case .low240: 350_000 }
    }
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

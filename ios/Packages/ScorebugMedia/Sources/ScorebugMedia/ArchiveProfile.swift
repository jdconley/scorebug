import Foundation

/// The immutable H.264/AAC encoding configuration for one recording part.
public struct ArchiveProfile: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let videoBitRate: Int
    public let audioSampleRate: Double
    public let audioChannels: Int
    public let audioBitRate: Int
    public let segmentDuration: Double

    public init(width: Int = 1920, height: Int = 1080, framesPerSecond: Int = 30,
                videoBitRate: Int = 12_000_000, audioSampleRate: Double = 48_000,
                audioChannels: Int = 1, audioBitRate: Int = 128_000, segmentDuration: Double = 2) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.videoBitRate = videoBitRate
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.audioBitRate = audioBitRate
        self.segmentDuration = segmentDuration
    }

    public func validate() throws {
        guard (320...7680).contains(width), (240...4320).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2),
              (1...120).contains(framesPerSecond), (100_000...100_000_000).contains(videoBitRate),
              audioSampleRate.isFinite, (8_000...192_000).contains(audioSampleRate),
              (1...2).contains(audioChannels), (16_000...512_000).contains(audioBitRate),
              segmentDuration.isFinite, (1...3).contains(segmentDuration) else {
            throw ArchiveStoreError.invalidProfile
        }
    }
}

import ScorebugMedia

/// Explicit file-driven qualification recipes, independent of the app's adaptive ladder.
public struct DualOutputConfiguration: Sendable {
    public enum ConfigurationError: Error { case unsupportedProfile }
    public let liveProfile: PublishingVideoProfile
    public let archiveProfile: ArchiveProfile
    public let liveQueueMaxBytes: Int
    public let archiveQueueMaxBytes: Int
    public let changedBitRate: Int

    public init(profileID: String = "1080p30") throws {
        let scale: Int
        switch profileID {
        case "1080p30": liveProfile = .hd1080; scale = 1
        case "2160p30": liveProfile = .uhd2160; scale = 4
        default: throw ConfigurationError.unsupportedProfile
        }
        archiveProfile = ArchiveProfile(width: liveProfile.width, height: liveProfile.height,
            videoBitRate: scale == 4 ? 24_000_000 : 12_000_000)
        // Preserve approximately the same raw NV12 frame capacity at either size.
        // These bounds exclude in-flight samples and internal encoder allocations.
        liveQueueMaxBytes = scale * 12 * 1024 * 1024
        archiveQueueMaxBytes = scale * 24 * 1024 * 1024
        changedBitRate = scale * 2_000_000
    }
}

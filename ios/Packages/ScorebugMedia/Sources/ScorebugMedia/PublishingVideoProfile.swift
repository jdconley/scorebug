import Foundation

/// Live stream encoder rung (30 fps H.264). Never configures the local recording.
public enum PublishingVideoProfile: String, Sendable, CaseIterable {
    case hd1080 = "1080p30"
    case hd720 = "720p30"
    case sd540 = "540p30"
    case low360 = "360p30"
    public var width: Int {
        switch self { case .hd1080: 1920; case .hd720: 1280; case .sd540: 960; case .low360: 640 }
    }
    public var height: Int {
        switch self { case .hd1080: 1080; case .hd720: 720; case .sd540: 540; case .low360: 360 }
    }
    public var bitRate: Int {
        switch self { case .hd1080: 6_000_000; case .hd720: 3_000_000; case .sd540: 1_600_000; case .low360: 800_000 }
    }
}

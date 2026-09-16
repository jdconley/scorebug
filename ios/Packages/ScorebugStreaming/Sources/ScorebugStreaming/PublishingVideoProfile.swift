import Foundation
import HaishinKit
import VideoToolbox

/// Immutable live encoder choice. It never configures the local archive.
public enum PublishingVideoProfile: String, Sendable, CaseIterable {
    case hd1080 = "1080p30"
    case sd540 = "540p30"
    public var width: Int { self == .hd1080 ? 1920 : 960 }
    public var height: Int { self == .hd1080 ? 1080 : 540 }
    public var bitRate: Int { self == .hd1080 ? 6_000_000 : 1_500_000 }
    var settings: VideoCodecSettings {
        .init(videoSize: CGSize(width: width, height: height), bitRate: bitRate,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2, allowFrameReordering: false, expectedFrameRate: 30)
    }
}

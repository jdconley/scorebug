import Foundation
import HaishinKit
import VideoToolbox

import ScorebugMedia

public typealias PublishingVideoProfile = ScorebugMedia.PublishingVideoProfile

extension PublishingVideoProfile {
    var settings: VideoCodecSettings {
        .init(videoSize: CGSize(width: width, height: height), bitRate: bitRate,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2, allowFrameReordering: false, expectedFrameRate: 30)
    }
}

# ScorebugStreaming

SRT publisher for the iPhone app, built on the vendored HaishinKit/SRTHaishinKit.
`SRTStreamPublisher(url:profile:)` owns one SRT connection and stream for one
publishing attempt: it configures 30 fps H.264 + AAC at a `PublishingVideoProfile`
(360p/540p/720p/1080p), connects, appends capture samples, replaces the live encoder
profile on request, and reports SRT sender statistics (send-buffer milliseconds,
cumulative sent/retransmitted/dropped packets, RTT). Create a fresh publisher per
attempt; `stop()` is terminal and drains via `SRTStopPolicy` (6 s total budget,
500 ms downstream allowance) before closing.

The app wraps it in `ScorebugMedia.PublishingSession`, which bounds queued media
and drops the oldest samples instead of back-pressuring the recording. Quality
decisions live in `ScorebugCore.QualityLadder`; this package has no policy.

This package targets iOS 17 and macOS 13. Watch scoring uses ScorebugCore only.

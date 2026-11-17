# ScorebugStreaming

The iPhone app's SRT publisher, built on the vendored HaishinKit and SRTHaishinKit
(`vendor/HaishinKit`).

`SRTStreamPublisher(url:profile:)` owns one SRT connection for one publishing attempt. It encodes
30 fps H.264 at a `PublishingVideoProfile` (360p, 540p, 720p or 1080p) and 128 kbps AAC, connects,
appends capture samples, switches the encoder profile while live, and reports SRT sender statistics:
packets sent, retransmitted and dropped, send-buffer milliseconds, round-trip time and send rate.
`stop()` is final, so make a new publisher for each attempt. Stopping drains the send queue under
`SRTStopPolicy` (6 seconds in all, with a 500 ms downstream allowance) before it closes.

The app wraps the publisher in `ScorebugMedia.PublishingSession`, which bounds queued media and
drops the oldest samples rather than slow the recording. `ScorebugCore.QualityLadder` decides the
profile; this package has no policy. It depends on `ScorebugMedia` for the publisher protocol,
samples and profiles.

Platforms: iOS 17 and macOS 13. The Watch app doesn't use it.

```sh
swift test --package-path ios/Packages/ScorebugStreaming --scratch-path ios/.build/streaming
```

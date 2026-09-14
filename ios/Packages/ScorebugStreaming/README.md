# ScorebugStreaming

Production SRT adapter extracted from the qualified local SDK probe. It owns the
HaishinKit connection and stream, encodes 1080p30 H.264/AAC, preserves capture audio
timestamps, and exposes bitrate control and transport observations. The probe's
`SDKProbe` name forwards to this package, so local media qualification uses the
same implementation.

This package targets iOS 17 and macOS 13. Watch scoring uses ScorebugCore and does
not link capture, codec, or SRT dependencies.

Call `configure`, then `start`, feed video and copied PCM from one bounded consumer,
and call `stop` on every terminal path. The caller serializes lifecycle operations
and creates a fresh adapter for each attempt. Do not invoke asynchronous transport
work directly from camera callbacks. `isPublishing` describes local SDK health;
remote worker output needs its separate observed status.

The native Film UI uses `SRTMediaPublisher` through an independently owned
`ScorebugMedia.PublishingSession`. Capture-role reporting and durable broadcast
commands coordinate its ownership. Recording continues when publishing stops or fails.

`SRTMediaPublisher(url:stopPolicy:)` accepts an optional `SRTStopPolicy`. Its default
three-second total drain budget covers codec/transport acceptance, empty sender
buffer observation, negotiated peer latency, and a 500 ms downstream allowance.
The allowance is configurable for other relay/worker deployments. It is not a remote
delivery acknowledgment or a hard timeout on native codec calls. The lower-level
adapter exposes `lastStopOutcome`; failure and cancellation still close the transport.
See [publishing lifecycle](../../../docs/native-publishing-session.md) and
[decoded native qualification](../../../docs/native-streaming-qualification.md).

Automatic reconnection, adaptive quality, Watch UI/networking, and physical-device
qualification remain in the [portable streaming plan](../../../docs/superpowers/plans/2026-09-13-portable-streaming-and-watch.md).

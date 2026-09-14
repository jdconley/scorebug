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

The adapter's extraction does not connect publishing to the Film UI. Production
ownership, capture-role reporting, reconnection, and adaptive quality follow the
[native publishing plan](../../../docs/superpowers/plans/2026-09-14-native-publishing.md).

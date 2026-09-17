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

Experimental native bandwidth probing is opt-in at construction with
`allowsBandwidthProbes: true` on `SRTPublisher` or `SRTMediaPublisher`.
`beginBandwidthProbe(bitRate:)` returns a UUID/generation-scoped immutable snapshot;
renew and cancel require both exact values. Start, renewal and replacement are serialized as
one owned operation. Stop cancels and joins it, and settings changes invalidate
pending acknowledgments and revoke the current probe. An abandoned or failed
renewal also revokes the existing lease without stopping otherwise healthy media.
`configure()` is pre-start only; use verified bitrate/profile methods while live.

`bandwidthProbeSnapshot()` retains terminal evidence without renewing a lease.
The snapshot describes local native acceptance, not receiver delivery or capacity.
The SDK's 300 ms lease and bounded optional writes remain authoritative. There is
no automatic renewal task, production quality admission or general `MediaPublisher`
protocol change. A DEBUG fixture must explicitly own renewal and collect receiver
confirmation before this can support a quality upgrade. See
[adapter validation](../../../docs/superpowers/plans/2026-09-16-publisher-probe-adapter.md).


`PublishingBandwidthProbeSnapshot` forwards the SDK's optional stage and readonly
native authority without creating a new authority. Native cancellation/replacement,
expiry and failure revoke retained observations; consumers must check ownership as
well as age and lease after async calls. Locally fabricated snapshots without native
authority are diagnostics only. Authenticated v2 matching is implemented separately
from quality admission.

`beginBandwidthProbe(bitRate:staged: true)` starts an explicitly staged campaign.
`replaceBandwidthProbe(id:publishingGeneration:stage:bitRate:)` replaces only the
current exact staged identity. Both adapters validate the returned stage, generation,
UUID, rate and campaign accounting before acknowledging it. Renewal cannot change
stage or campaign. Rejected handles are cancelled; an optional probe failure does
not itself stop otherwise healthy media. The default start remains legacy v1.

Snapshots also forward `campaignStartedAt` and `totalAcceptedPayloadBytes` for
staged owners. These counters describe local acceptance only. SDK stage/byte/time
limits persist through replacement; they cannot be reset by adapter calls.

The app's DEBUG `staged` fixture exercises 500 kbps, 1 Mbps and 2 Mbps in sequence,
renewing each for 80 polls at 100 ms and recording its terminal snapshot before
replacement. Its bounded version-2 export includes a cancellation-request timestamp
for each retirement. Stop joins work before export. The CLI still permits only
legacy probe modes pending independent staged sender/receiver/interval verification;
these adapter and fixture tests do not qualify sustained spare capacity or automatic
quality upgrades. See the [staged publisher plan](../../../docs/superpowers/plans/2026-09-17-staged-probe-publishers.md).

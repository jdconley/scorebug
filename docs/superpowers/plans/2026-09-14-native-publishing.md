# Native publishing integration

Continue the approved portable streaming plan. Local recording remains authoritative and independent of all network operations. Native iPhone and Watch scoring remain the only scoring interfaces.

- [x] Add the native capture-only publishing access route. Bind responses to match, recording, and broadcast generation; keep credentialed URLs out of diagnostic descriptions. Test wire shape, stale responses, authorization, and transport failures. Core: 55 tests pass; watchOS build passes; spec and quality reviews approved.
- [x] Audit and bound the SDK's publishing queues. Overflow must produce an observable publishing failure rather than silently corrupt compressed media. Retain the startup media/clock fixes and upstream provenance. 57 SDK tests, five-case media conformance, final ARM64 Simulator/iPhone links, patch verification, and separate spec/quality reviews pass. See [measured scope and remaining races](../../sdk-publishing-bounds.md).
- [x] Extract the SRT adapter into `ScorebugStreaming`, with the probe forwarding to the same code. PCM clock tests and configure/bitrate/metrics/stop smoke pass.
- [x] Introduce an independently owned publishing lifecycle with bounded raw-media ingress. Test stop/start races and network failure without interrupting the archive.
- [x] Connect the native Film UI to capture-role reporting, broadcast selection, and truthful publishing status. Keep offline Record independent of API setup.
- [x] Validate the native app against the local relay/worker with complete decoded A/V, loss/timing metrics, stalled/disconnected peers, and recording/export checks. Native streaming passes iOS 17.5/18.5/26.2; final five-case stress, offline recovery regression, 37 Film model tests, unsigned iPhone Release build, and separate spec/quality reviews pass. See [qualification scope and evidence](../../native-streaming-qualification.md).

Automatic reconnection/adaptive quality, Watch UI/networking, and physical device qualification follow once this lifecycle is measured. Do not equate a bounded app mailbox with a bounded complete SDK pipeline.

Next is the [pure adaptive-quality policy](2026-09-14-adaptive-quality-policy.md),
followed by truthful runtime telemetry and impairment qualification before enabling
automatic quality changes in the app.

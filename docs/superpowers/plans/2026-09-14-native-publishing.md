# Native publishing integration

Continue the approved portable streaming plan. Local recording remains authoritative and independent of all network operations. Native iPhone and Watch scoring remain the only scoring interfaces.

- [x] Add the native capture-only publishing access route. Bind responses to match, recording, and broadcast generation; keep credentialed URLs out of diagnostic descriptions. Test wire shape, stale responses, authorization, and transport failures. Core: 55 tests pass; watchOS build passes; spec and quality reviews approved.
- [x] Audit and bound the SDK's publishing queues. Overflow must produce an observable publishing failure rather than silently corrupt compressed media. Retain the startup media/clock fixes and upstream provenance. 57 SDK tests, five-case media conformance, final ARM64 Simulator/iPhone links, patch verification, and separate spec/quality reviews pass. See [measured scope and remaining races](../../sdk-publishing-bounds.md).
- [x] Extract the SRT adapter into `ScorebugStreaming`, with the probe forwarding to the same code. PCM clock tests and configure/bitrate/metrics/stop smoke pass.
- [ ] Introduce an independently owned publishing lifecycle with bounded raw-media ingress. Test stop/start races and network failure without interrupting the archive.
- [ ] Connect the native Film UI to capture-role reporting, broadcast selection, and truthful publishing status. Keep offline Record independent of API setup.
- [ ] Validate the native app against the local relay/worker with complete decoded A/V, loss/latency metrics, stalled/disconnected peers, and recording/export checks. Re-run iPhone/Simulator builds and obtain separate spec and quality reviews.

Automatic reconnection/adaptive quality, Watch UI/networking, and physical device qualification follow once this lifecycle is measured. Do not equate a bounded app mailbox with a bounded complete SDK pipeline.

# Worker capabilities and startup preflight

A worker reports its configured encoder (`software`, `videotoolbox`, or `nvenc`), output ID, output mode, and fixed output profile. Before registering, it runs a bounded, local H.264/AAC initialization check at that output size using synthetic media. No camera, input recording, network destination or GPU purchase is involved. The check uses the same video encoder options as the real pipeline and explicitly disables VideoToolbox software fallback.

The check reports `passed`, `failed`, `timeout`, `cancelled`, or `unsupported_platform`. `passed` means the selected encoder initialized and completed the short encode. It does **not** qualify decoder capacity, overlay fonts, destination connectivity, sustainable frame rate, a maximum input profile, or full-match performance. `sustainedPerformance` is explicitly `unqualified`; existing measured adaptation and runtime pipeline status remain authoritative. Native Windows probing is unavailable; use the documented WSL2/Linux deployment path until Windows process ownership is implemented.

Capabilities belong to the current worker process session. Authenticated heartbeats renew a five-second monotonic lease, including while the worker is idle. API restart makes capabilities unknown until registration; worker replacement removes the previous session's capabilities. A stopped or disconnected worker becomes stale.

A match-authenticated client can read:

```text
GET /v1/matches/{matchId}/media/capabilities?workerId={workerId}
```

The response includes `workerId`, `state` (`unknown`, `stale`, or `fresh`), `validForMs`, `capabilities`, and `serverTime`; it is never cacheable. There are no host paths, stream keys or arbitrary FFmpeg diagnostics in this response. Worker registration adds an optional version1 capability object to `POST /v1/worker/sessions`.

Before issuing a new broadcast start, the native phone requires a fresh report, a passing encoder check, and the configured output ID. Request duration consumes the remaining lease. Failure leaves the clean recording active and asks the user to check the proxy/setup and retry. This preflight does not tear down an existing healthy stream or replace recovery of an already accepted selection.

Upgrade the API first, then workers, then native apps. The API continues accepting legacy worker reports, but a legacy worker does not advertise the capabilities required by the new native start preflight. `WORKER_PROCESSING=off` disables optional timing statistics; it does not disable the encoder startup check. Startup checks take at most10seconds; both probes are cancelled and joined during shutdown.

Local evidence: software H.264 and VideoToolbox initialize at1080p on the development Mac; NVENC correctly reports failed there. A real idle worker/API exchange expires after process shutdown. These are initialization checks, not backend throughput qualification. See [session evidence](session-logs/2026-09-28-backend-capabilities.md).

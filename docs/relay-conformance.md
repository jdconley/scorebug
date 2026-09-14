# Relay access and worker supervision progress

The first real SRT conformance test now exercises the production relay adapter
against a dedicated MediaMTX 1.21.0 container and the configured FFmpeg binary.
It runs entirely on this machine and sends no video to an external destination.

```sh
pnpm install --frozen-lockfile
pnpm test:relay
```

The runner selects `ffmpeg-full` on this Mac, or honors `FFMPEG_PATH` and
`FFPROBE_PATH`. It creates a uniquely named container with random loopback ports,
uses the repository's local ingest configuration, and removes its own container,
processes, and temporary video on completion or cancellation. It does not stop a
manually running local stack. Docker and an FFmpeg build with SRT, H.264 software
encoding, AAC, and lavfi are required.

## Measured behavior

The local run passed these checks:

- Management requires authentication; a configured path has no source readiness
  before audio/video arrives.
- Incorrect publishing credentials and using the reader credential to publish
  are rejected.
- A real 640×360, 30 fps fixture with H.264 video and AAC audio becomes observable
  on the relay. An authorized reader receives a three-second clip that passes
  stream inspection and full audio/video decode.
- A second publisher cannot replace the active publisher. Incorrect reading
  credentials and using the publisher credential to read are rejected.
- Deleting the path disconnects the publisher and a reader already producing
  frames. Reusing either revoked credential fails. Repeated deletion is harmless.
- Native capture/worker API routes return separate credentials. A forced API exit
  preserves the active publisher: readiness remains true and received bytes continue
  increasing after restart. Credentials remain stable.
- Startup removes an orphan in the installation's namespace and preserves a path
  belonging to another installation. Restarting the relay at unchanged host ports
  causes the running API to recreate the desired path, after which the fixture
  reconnects with its existing publishing credential.
- Ending the native match automatically disconnects its publisher and rejects the
  old credential. The independent recording association remains unchanged.

This is transport/access evidence at one small fixture profile. It does not measure
fresh-frame loss, gym motion quality, audio/video synchronization, a score overlay,
phone recording, ten-minute recovery performance, or sustained streaming capacity.
The received clip is a temporary relay test output, not the phone's archive.

## Access contract

`apps/control-plane/src/ingest.ts` derives a path and separate publishing/reading
capabilities from an installation secret, match, selected recording/device/worker,
output, and broadcast generation. Retries derive the same values; a new generation
derives different ones. Secrets do not appear in the public media snapshot.

The SRT encryption passphrases act as bearer capabilities. The local relay enables
only SRT for media ingest, allows publish/read on the generated path pattern, and
the adapter creates each exact path with distinct mandatory passphrases. Do not add
an unencrypted protocol or a wildcard path that bypasses those constraints. The
management API has separate credentials and is bound to loopback by local Compose.

Provisioning checks existing configuration before creating a path. An exact retry
does not patch or interrupt a publisher; a conflicting configuration is rejected.
API requests have a bounded timeout, refuse redirects, and suppress remote error
bodies and credentialed URLs. Source observations include only validated readiness,
byte counters, and codecs. The adapter uses the
[pinned MediaMTX API contract](https://github.com/bluenviron/mediamtx/blob/v1.21.0/api/openapi.yaml).

The adapter is now connected to native capture credential retrieval and automatic
match/broadcast reconciliation. Configure `RELAY_API_URL`, `RELAY_API_USERNAME`, and
`RELAY_API_PASSWORD` together; the local environment example points to the local
Compose ingest API. `INGEST_HOST` and `INGEST_PORT` are the address capture devices
and workers use for SRT, independently of the private management address. Omit all
three management settings to run scoring without a relay. Connection routes then
return HTTP 503 `relay_not_configured`.

The API inventories only paths belonging to its installation secret and reconciles
them with the current durable broadcast. It runs once at startup and one second
after each completed pass, serializing credential requests with background work.
It rechecks generation after network operations and immediately before constructing
credential responses. Stop or match end removes stale paths; API failures retain
the durable desired state for retry and return a visible error. No recording report
is changed by relay reconciliation.

Revocation is asynchronous. If the relay management API is unreachable, an existing
SRT connection can remain alive until management access recovers. The native worker
now stops output after five seconds without a validated control snapshot, and
waits for fresh control before restarting. Keep the installation secret stable: changing it creates
a different namespace, so deliberate secret rotation must also retire old paths.
Relay inventory is bounded to 1,000 configured paths; larger or malformed inventory
fails closed rather than returning a partial result.

## Worker process supervision

The worker's FFmpeg handle now settles missing-binary/spawn failures, makes stop
idempotent, and escalates SIGTERM to SIGKILL based on actual exit state. Exit clears
the escalation timer. Raw encoder output and exception messages are excluded from
logs because they can contain stream credentials.

An optional progress callback parses bounded, complete, monotonic FFmpeg output
frame/time counters. These counters do not prove delivery freshness or remote
playback. The worker entry point now consumes durable native assignments, handles
initial/current scores, and uses these counters for a ten-second output watchdog.
States are logged locally; API/native UI status reporting remains required.

Focused verification passes 14 relay adapter tests, 25 lifecycle tests, 6 route tests,
and 20 pipeline argument/process
tests. The latter use real child fixtures for ignored TERM, graceful exit, spawn
failure, progress parsing, and credential-safe logs. Harness tests also cover
partial container startup and cancellation cleanup. CI is configured to run the
real relay test on Linux; a local Mac pass is not Linux host qualification.

The complete workspace passes 169 API tests, 72 worker tests, and 12 tooling tests,
plus typecheck, production build, and formatting. Production server container
startup and the four-exit native scoring recovery test also pass with this integration.

## Native worker short media check

`pnpm test:worker software` and `pnpm test:worker videotoolbox` pass on this Mac
with FFmpeg 8.1.2. Both produce 1280×720 H.264/AAC clips at approximately 30 decoded
fps, with at least 24 distinct source frame IDs per second. A binary counter in
the source image measures freshness independently of lossy compression; an
adversarial 12fps source duplicated to 30fps is correctly recognized as only 36
fresh frames in a three-second clip. Separate real encoder checks cap 60fps at
30 while preserving a 25fps input.

Decoded images show initial HOME 0–0 AWAY and HOME 1–0 AWAY after a native scoring
command; the encoder does not restart for the point. Worker SIGKILL and
forced API exit/recovery return to the current score. The IPC guardian terminates
and reaps the encoder after worker death; it reports actual encoder exit status.
Source-loss recovery also restores the current score, with local output returning
in roughly six to seven seconds in the short runs. An API outage stops output
on the control lease while the independent synthetic publisher stays connected.
Match end stops output and revokes publishing without changing recording metadata.

Artifacts: `artifacts/qa/native-worker-{software,videotoolbox}/` contains playable
clips and inspected stills; adjacent `.log` files record the runs. All owned runtime
resources were removed. These short checks do not establish audio synchronization,
ten-minute stability, native status reporting, physical recording, or NVENC/other-host
qualification. Independently killing the guardian remains a fail-closed case requiring
host-level cleanup, not a confirmed encoder exit. The default Linux arm64 CPU image
has separate compiled-pipeline/startup/decode/stop evidence. See the
[worker runbook](../apps/home-daemon/README.md).

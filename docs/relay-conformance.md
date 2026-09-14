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

The adapter is not yet wired to native capture credential retrieval or automatic
match/broadcast reconciliation. Deletion is proven when explicitly invoked by the
test; match end does not yet automatically revoke relay access. That integration
must recheck generation after asynchronous provisioning and reconcile old paths
after control-plane or relay restarts. Relay API unavailability must remain visible.

## Worker process supervision

The worker's FFmpeg handle now settles missing-binary/spawn failures, makes stop
idempotent, and escalates SIGTERM to SIGKILL based on actual exit state. Exit clears
the escalation timer. Raw encoder output and exception messages are excluded from
logs because they can contain stream credentials.

An optional progress callback parses bounded, complete, monotonic FFmpeg output
frame/time counters. These counters do not prove delivery freshness or remote
playback. The old worker entry point still uses the legacy WebSocket lifecycle and
does not yet consume the durable match assignment or this callback for truthful
live status; that replacement remains required.

Focused verification passes 12 relay adapter tests and 20 pipeline argument/process
tests. The latter use real child fixtures for ignored TERM, graceful exit, spawn
failure, progress parsing, and credential-safe logs. Harness tests also cover
partial container startup and cancellation cleanup. CI is configured to run the
real relay test on Linux; a local Mac pass is not Linux host qualification.

# Native broadcast worker

The worker polls the durable native API for its selected match, retrieves a
generation-bound SRT read credential, and checks the assignment again before using
it. FFmpeg scales the video, burns in the current score, and publishes audio/video
to the configured RTMP(S) destination. Score changes rewrite the text file
atomically without restarting FFmpeg.

The worker waits for an observed source before starting. Changing the assignment,
ending the match, losing control access for five seconds, or losing output progress
for ten seconds stops the encoder. Shutdown waits for process exit, with a one-second
SIGTERM grace before SIGKILL. Retries are limited to three starts per match/generation
in a rolling minute. A recovered API resumes the current assignment.

A small IPC guardian owns FFmpeg and reaps it if the worker is forcibly killed.
Exit reporting preserves the encoder's actual status. If the guardian itself is
independently killed, the worker cannot confirm encoder exit and will not start a
replacement; that exceptional case still needs host-level cleanup. One worker
process per worker ID remains required; this is not a distributed fencing mechanism.

`producing_output` in local logs means FFmpeg's frame and timestamp counters have
advanced. It does not establish delivery to viewers or sustained fresh-frame rate.
Worker observations now reach the API and native scorer through an independent
reporting loop. Reports expire after five seconds without a heartbeat; the native
display also expires them locally when a network request stalls. See the
[status contract and tests](../../docs/worker-status.md). The old WebSocket client
remains unused legacy code.

## Run locally

From the repository root, start the fixtures and API using the main README, then
copy `apps/home-daemon/.env.example` to `apps/home-daemon/.env` and set the executable
and font paths for this machine. The example sends only to the local fixture.
`WORKER_ID` and `OUTPUT_ID` must match the broadcast selection. Each worker needs a
separate score directory, and one worker process should use each worker ID.

```sh
pnpm install --frozen-lockfile
node --env-file=apps/home-daemon/.env apps/home-daemon/node_modules/tsx/dist/cli.mjs apps/home-daemon/src/index.ts
```

FFmpeg needs SRT, drawtext, AAC, and the selected H.264 encoder. On this Mac,
`ffmpeg-full` provides those capabilities. `ENCODER=videotoolbox` requires native
macOS hardware encoding and explicitly disables silent software fallback.

| Profile   | Canvas      | Video bitrate target | Maximum fps |
| --------- | ----------- | -------------------- | ----------- |
| `720p30`  | 1280 × 720  | 3 Mbps               | 30          |
| `1080p30` | 1920 × 1080 | 6 Mbps               | 30          |
| `2160p30` | 3840 × 2160 | 18 Mbps              | 30          |

Profiles preserve aspect ratio with padding. A lower input frame rate stays lower;
these are manual presets, not adaptive quality or guarantees of the 24fps goal.
Audio is AAC at 128 Kbps. Capability qualification and adaptation remain planned.
If `ENCODER` is omitted, software is the default; legacy `NVENC_ENABLED=true` selects
NVENC only when an explicit encoder was not provided.

## Local validation

```sh
pnpm --filter @scorebug/home-daemon test
pnpm test:worker software
pnpm test:worker videotoolbox
# Ten-minute continuous capture, fresh-frame and A/V synchronization checks:
pnpm test:worker software --soak-seconds=600
pnpm test:worker videotoolbox --soak-seconds=600
```

The media harness owns its API, two uniquely named MediaMTX containers, and synthetic
source. It uses loopback ports and public fixture credentials, captures and decodes
short clips, checks fresh test-pattern frames and changing overlay pixels, and tests
worker SIGKILL/descendant cleanup, control-outage shutdown, source loss/recovery,
current-score restoration, and match end. Clips and images
are retained under `artifacts/qa/native-worker-<encoder>`; owned runtime resources
are removed. This is a short integration check, not the ten-minute qualification
gate, a real phone recording test, or an external broadcast test.

## Linux container

```sh
docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon .
docker run --rm --env-file apps/home-daemon/.env scorebug/home-daemon
pnpm test:worker-container scorebug/home-daemon
```

The default image uses Node 22/Debian and software encoding with a small init
process, without a CUDA runtime requirement. Its native arm64 build on this Mac
passes worker startup, actual compiled-pipeline H.264/AAC encoding with overlay,
full decoding, and graceful stop while Docker networking is disabled. That check
does not qualify network transport, GPU encoding, or other host architectures.

Use reachable container-network addresses instead of `127.0.0.1` for services
outside the container. NVENC requires a compatible NVIDIA host/driver and container
toolkit, `ENCODER=nvenc`, and `--gpus all`. An encoder listing alone does not prove
that encoding works; qualify the actual media pipeline on that host before use.

See [sustained media qualification](../../docs/media-soak.md) for measurement rules and limits.

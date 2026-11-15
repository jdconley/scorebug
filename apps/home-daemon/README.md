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
Audio is AAC at 128 Kbps. Automatic profile qualification and adaptation remain planned.
If `ENCODER` is omitted, software is the default; legacy `NVENC_ENABLED=true` selects
NVENC only when an explicit encoder was not provided.

## Output recording

`OUTPUT_MODE=rtmp` is the default. Use `OUTPUT_MODE=record` to save the overlaid
stream without RTMP, or `OUTPUT_MODE=rtmp+record` for both. Recording modes require
`OUTPUT_RECORDING_DIR`; RTMP modes require `OUTPUT_URL`. Each pipeline attempt
creates a private `attempt-*/overlay.mp4` below that directory, retaining earlier
attempts after retries. Provide a writable volume when running in a container.

Both outputs share one encode through FFmpeg's [tee muxer](https://ffmpeg.org/ffmpeg-formats.html#tee).
Either output failing stops that attempt and enters the existing bounded retry path.
Fragmented MP4 preserves completed fragments after interruption; the first complete
fragment is required before recovery is possible, and a partial tail can be lost.
There is no automatic recording rotation or deletion. These files contain the
score overlay; the phone's independent recording remains clean.

```sh
OUTPUT_MODE=rtmp+record
OUTPUT_RECORDING_DIR=/path/to/scorebug-recordings
```

See [native device testing](../../docs/device-testing.md) for the owned LAN stack,
mock YouTube recorder, and phone/Watch workflow.

## Local validation

```sh
pnpm --filter @scorebug/home-daemon test
pnpm test:worker software
pnpm test:worker videotoolbox
# Ten-minute continuous capture, fresh-frame and A/V synchronization checks:
pnpm test:worker software --soak-seconds=600
pnpm test:worker videotoolbox --soak-seconds=600
# Source-correlated processing evidence (requires FFmpeg encoder statistics):
pnpm test:worker-processing software
pnpm test:worker-processing software 60
pnpm test:worker-processing videotoolbox
pnpm test:worker-processing videotoolbox 60
# Paced 24-second source with at least two complete live processing windows:
pnpm test:worker-processing software 30 --paced
pnpm test:worker-processing videotoolbox 30 --paced
pnpm test:worker-processing software 60 --paced
```

The media harness owns its API, two uniquely named MediaMTX containers, and synthetic
source. It uses loopback ports and public fixture credentials, captures and decodes
short clips, checks fresh test-pattern frames and changing overlay pixels, and tests
worker SIGKILL/descendant cleanup, control-outage shutdown, source loss/recovery,
current-score restoration, and match end. Clips and images
are retained under `artifacts/qa/native-worker-<encoder>`; owned runtime resources
are removed. This is a short integration check, not the ten-minute qualification
gate, a real phone recording test, or an external broadcast test.

The separate `test:worker-processing <encoder> [25|30|60]` command runs a three-second
local file fixture through the actual pipeline, without containers or network output.
It compares decoder timestamps with an independent source probe, checks the exact
expected frame selection and saved output barcodes, fully decodes A/V, and independently
replays processing durations. Results and media are retained in a unique
`artifacts/qa/worker-processing-*` directory. Set `FFMPEG_PATH`, `FFPROBE_PATH` and
`FONT_PATH` for another host. Missing encoder-statistics options or unsupported hardware
fail the check. Software 25/30/60 and VideoToolbox 30/60 pass on this Mac; the accepted
`nvenc` option still needs qualification on NVIDIA hardware. This fixture establishes
source correlation, not spare capacity, sustained performance or network delivery.
Add `--paced` after an explicit source rate for a 24-second source sent through an
owned loopback HTTP endpoint. The test samples real pipeline windows, independently
checks adjacent source bounds and processing arithmetic, and requires at least two
complete current windows after acquisition. Five-second input analysis observed on
this Mac is part of startup, not fabricated steady-state processing coverage.

Worker startup defaults to `WORKER_PROCESSING=auto`. It checks the configured FFmpeg's
four encoder-statistics options with a three-second, 4 MiB bounded help query and
then enables optional timing only if available. `WORKER_PROCESSING=off` bypasses the
probe. Missing/failed/unsupported probes leave ordinary publication enabled without
these diagnostics. This is an option check, not a hardware/profile capacity test.
POSIX process-group cleanup covers configured wrappers and cancellation during startup.
Native Windows skips the optional probe until job-object ownership is implemented;
WSL follows the Linux path. None of this constitutes Windows host qualification.

`snapshotVideoEvidence()` samples decoder and processing evidence together for
negotiated `source-processing-v1` API reports. `snapshotProcessingWindow()` remains
available to direct callers. Pending work can update while its decoder window is
current; completed results freeze and invalid/ended/superseded evidence clears.
The native app attaches validated reports to matching source intervals. The native quality controller uses matching processing reports alongside its other
admission and health checks; completion alone is not a capacity estimate. See [worker status](../../docs/worker-status.md).

## Linux CPU/GPU deployment

Use Docker Engine with Compose v2 on Linux and a pinned repository revision.
The worker image is Node 22/Debian Trixie with FFmpeg, DejaVu fonts and `tini`;
software encoding needs no CUDA runtime. Trixie supplies the encoder-statistics
options used by measured adaptation; the older Bookworm image could publish but
lacked this timing capability. The image check now exercises actual encoder
timing as well as overlay/audio/video encoding and decoding. From the repository root:

```sh
WORKER_RELEASE=$(git rev-parse --short=12 HEAD)
docker build -f apps/home-daemon/Dockerfile -t "scorebug/home-daemon:$WORKER_RELEASE" .
```

Build for the target host architecture. A successful build or an encoder listing
is not runtime/media qualification. Keep the previous image tag/digest for rollback.
The worker connects to an existing native control plane and managed SRT relay;
it does not provision those services. The checked-in [VPS stack](../../infra/vps/README.md)
provides the native API, persistent database and managed relay; external-host
and public TLS/media acceptance still require testing on that destination. For native macOS use the [service runbook](../../docs/macos-worker-service.md).

Create a private deployment directory outside the checkout, with `worker.env`
mode 0600 and its parent mode 0700. Do not commit it or print `docker compose config`
in shared logs: environment values include credentials. Configure these existing
worker keys (example destinations are deliberately non-routable):

```dotenv
CONTROL_PLANE_URL=https://control.example.invalid
HOME_TOKEN=replace-with-private-worker-token
WORKER_ID=linux-worker
OUTPUT_ID=main
ENCODER=software
VIDEO_PROFILE=720p30
FFMPEG_PATH=/usr/bin/ffmpeg
FFPROBE_PATH=/usr/bin/ffprobe
FONT_PATH=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
SCORE_DIR=/state
OUTPUT_MODE=rtmp+record
OUTPUT_URL=rtmps://destination.example.invalid/live/replace-with-stream-key
OUTPUT_RECORDING_DIR=/recordings
WORKER_REPORT_INTERVAL_MS=100
LOG_LEVEL=info
```

`WORKER_ID` and `OUTPUT_ID` must match the selected broadcast. Use reachable
container-network/DNS addresses: container `127.0.0.1` means that container.
The API must advertise an SRT ingest host/port reachable by this worker; the
worker obtains its generation-bound read URL from that API. Keep relay management
private. No worker inbound port needs publishing. `rtmp` requires `OUTPUT_URL`,
`record` requires `OUTPUT_RECORDING_DIR`, and `rtmp+record` requires both. Recordings
are overlaid fragmented MP4s, separate from the phone's clean archive.

Create `compose.yml` next to the protected env file. This is a worker-only example
using the existing image/settings; no new application configuration is required:

```yaml
services:
    worker:
        image: scorebug/home-daemon:REPLACE_WITH_BUILT_REVISION
        restart: unless-stopped
        env_file: ./worker.env
        volumes:
            - ./state:/state
            - ./recordings:/recordings
        stop_grace_period: 30s
        logging:
            driver: json-file
            options:
                max-size: '10m'
                max-file: '3'
```

Create `state` and `recordings` directories inside the private deployment directory
before starting. The current image runs as root inside the container, so generated
files may be root-owned on the host; plan backup access accordingly. Only one
worker may run per worker ID. From that deployment directory:

```sh
docker compose up -d worker
docker compose ps worker
docker compose logs --tail=100 worker
# Explicit stop/restart (does not delete recordings):
docker compose stop worker
docker compose start worker
```

A running container alone is not a healthy broadcast. The worker has no HTTP
health endpoint. Check control-plane `/healthz`, current assignment/status through
the native app, advancing `producing_output`, and decoded mock output with a changed
score. Idle workers legitimately wait for an assignment/source. `control_unavailable`
or stopped/expired observations require investigation; keep logs private.

### NVIDIA option — requires host qualification

Use an NVIDIA-capable Linux host, compatible installed driver and NVIDIA Container
Toolkit configured for Docker. Set `ENCODER=nvenc` in `worker.env`; add `gpus: all`
to the worker service on a Compose version supporting it. The runtime also needs
NVIDIA video capability, for example `environment: { NVIDIA_DRIVER_CAPABILITIES:
"compute,video,utility" }` on that service. The current CPU Dockerfile is not a
qualified CUDA/NVENC image: verify its FFmpeg NVENC support, driver-library access
and actual H.264/AAC pipeline on that host before selecting it. Installing a toolkit
or passing `nvidia-smi` is insufficient. Do not use `videotoolbox` on Linux.

### Verification and operational lifecycle

Use the existing owned mock tests from the repository checkout, after installing
the repository-pinned Node/pnpm dependencies. They do not require production keys:

```sh
pnpm test:worker-container "scorebug/home-daemon:$WORKER_RELEASE"
pnpm test:relay
pnpm test:worker software --soak-seconds=12
```

The container test uses the supplied image with networking disabled and verifies
compiled-worker startup, real software encoding/overlay, decode and graceful exit.
The relay/worker tests use their own local API, containers and mock sink; the worker
test runs natively on the test host, not inside the deployment container. Together
they do not prove this deployed container's networking. Verify its assigned native
broadcast against a reachable local mock sink before external output. The local file-processing harness accepts `pnpm test:worker-processing nvenc`
on the actual NVIDIA host; the networked `test:worker` harness currently accepts
only software/VideoToolbox. Retain actual GPU media results and follow
[sustained media qualification](../../docs/media-soak.md); CPU evidence does not
transfer to GPU. Run only after active capture has ended.

For upgrade: finish/stop the broadcast, stop the worker, retain its old image
and private configuration, build/load a newly pinned image, change only the image
tag, then `docker compose up -d worker`. Check status and mock output. Roll back by
stopping the new instance and restoring the previous image tag/configuration before
starting it. Never run old and new instances with the same worker ID concurrently.
Use `docker compose down` to remove this worker deployment without deleting bind
mount data; do not add `-v` or delete unrelated resources.

Back up the private env/Compose files and completed `recordings/` after stopping;
protect secret-bearing backups. Overlay `state/` is regenerated, not the match
source of truth. Back up the separate control-plane SQLite database consistently
with SQLite, including any schema/version compatibility needed for API rollback.
The worker does not rotate/delete recordings: monitor storage and prune only owned,
completed exports under an explicit retention policy.

| Backend/runtime                               | Evidence currently recorded                                                                                      | Still required                                                    |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Native macOS software/VideoToolbox            | Local real worker/media tests and documented soaks                                                               | New host/profile and sustained device acceptance                  |
| Linux arm64 CPU image on this Mac's Docker VM | Compiled worker/timing plus120s native Mac→SRT→Linux proxy→mock RTMP/MP4; confirmed240→360, continuous saved A/V | Full ladder, sustained and actual Linux-host qualification        |
| Linux amd64 CPU                               | CI has container/relay/software-worker jobs                                                                      | Inspect a passing target-runtime result; no new pass claimed here |
| NVIDIA Linux container/native                 | Config and file-processing harness accept NVENC                                                                  | Actual driver/toolkit/image/media qualification; unqualified here |
| Windows/WSL2, remote/cloud hosts              | No transferable qualification from the Mac                                                                       | Actual host/runtime/network qualification                         |

`WORKER_REPORT_INTERVAL_MS` controls the delay between completed status reports
(default 100, integer range 100–5000). The native quality-control simulator fixture
uses 100 ms so reporting plus phone polling can fit within the existing two-second
source freshness budget. This increases control-plane request load; it does not
change decoder window duration or make old measurements fresh.

# Broadcast worker

The worker (directory name `home-daemon` is historical) turns the phone's stream into
the broadcast. It polls the control plane for its assignment, gets a per-broadcast
SRT read credential, reads the stream from the relay, and runs FFmpeg to scale the
video, burn in the score, and publish audio and video to RTMP(S). Score changes
rewrite a text file atomically, so FFmpeg keeps running.

It waits for the phone's stream before starting FFmpeg. It stops the encoder when
the assignment changes, the match ends, the control plane is unreachable for five
seconds, or output stalls for ten seconds, and retries at most three times per
broadcast per minute. A small guardian process owns FFmpeg so it is cleaned up even
if the worker is killed. Run one worker process per `WORKER_ID`.

The worker reports its status (source, encoder, output progress) to the control
plane every `WORKER_REPORT_INTERVAL_MS`, so the apps can show whether the broadcast
is live.

## Run locally

Start the dev stack and API first (see [development](../../docs/development.md)),
then:

```sh
cp apps/home-daemon/.env.example apps/home-daemon/.env   # set FFMPEG_PATH, FONT_PATH
node --env-file=apps/home-daemon/.env apps/home-daemon/node_modules/tsx/dist/cli.mjs apps/home-daemon/src/index.ts
```

FFmpeg needs SRT, drawtext, AAC and the selected H.264 encoder. On macOS use
Homebrew's `ffmpeg-full`.

## Configuration

| Variable                      | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `CONTROL_PLANE_URL`           | API base URL                                                     |
| `HOME_TOKEN`                  | Worker token, must match the control plane                       |
| `WORKER_ID`, `OUTPUT_ID`      | Must match the broadcast selected in the app                     |
| `OUTPUT_MODE`                 | `rtmp` (default), `record`, or `rtmp+record`                     |
| `OUTPUT_URL`                  | RTMP(S) destination including stream key (RTMP modes)            |
| `OUTPUT_RECORDING_DIR`        | Where to save overlaid MP4s (record modes)                       |
| `ENCODER`                     | `software` (default), `videotoolbox` (macOS) or `nvenc` (NVIDIA) |
| `VIDEO_PROFILE`               | Output size and bitrate, see below (default `1080p30`)           |
| `FFMPEG_PATH`, `FFPROBE_PATH` | Executables (default from `PATH`)                                |
| `FONT_PATH`                   | Font for the score text                                          |
| `SCORE_DIR`                   | Per-worker scratch directory for the score file                  |
| `WORKER_REPORT_INTERVAL_MS`   | Status report interval, 100–5000 ms (default 100)                |
| `LOG_LEVEL`                   | `debug`, `info`, `warn`, `error`                                 |

| Profile   | Canvas      | Video bitrate |
| --------- | ----------- | ------------- |
| `240p30`  | 426 × 240   | 350 kbps      |
| `360p30`  | 640 × 360   | 600 kbps      |
| `540p30`  | 960 × 540   | 1.5 Mbps      |
| `720p30`  | 1280 × 720  | 3 Mbps        |
| `1080p30` | 1920 × 1080 | 6 Mbps        |
| `2160p30` | 3840 × 2160 | 18 Mbps       |

Profiles keep the aspect ratio with padding and cap the frame rate at 30 fps. Audio is
AAC at 128 kbps. With a recording mode, each attempt writes
`attempt-*/overlay.mp4` (fragmented MP4) under `OUTPUT_RECORDING_DIR`; nothing is
rotated or deleted automatically. The phone's own recording stays clean.

## Linux CPU/GPU deployment

Build the image from the repository root:

```sh
docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon:$(git rev-parse --short=12 HEAD) .
```

The image is Node 22 on Debian Trixie with FFmpeg, DejaVu fonts and `tini`. Put a
`worker.env` (mode 0600) with the settings above next to this `compose.yml`, using
container paths such as `SCORE_DIR=/state` and `OUTPUT_RECORDING_DIR=/recordings`:

```yaml
services:
    worker:
        image: scorebug/home-daemon:REPLACE_WITH_TAG
        restart: unless-stopped
        env_file: ./worker.env
        volumes:
            - ./state:/state
            - ./recordings:/recordings
        stop_grace_period: 30s
```

```sh
docker compose up -d worker
docker compose logs --tail=100 worker
```

The worker needs no inbound ports. The control plane must advertise an SRT address
the worker can reach. For NVENC, use a host with the NVIDIA driver and Container
Toolkit, set `ENCODER=nvenc`, and add `gpus: all` to the service; this path has not
been tested yet. The control plane and relay are deployed with
[`infra/vps`](../../infra/vps/README.md).

## Test

```sh
pnpm --filter @scorebug/home-daemon test
pnpm test:worker-container scorebug/home-daemon:<tag>
```

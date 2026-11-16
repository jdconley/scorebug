# Broadcast worker

The worker (directory name `home-daemon` is historical) turns the phone's stream into
the broadcast. It polls the control plane for its assignment, gets a per-broadcast
SRT read credential, reads the stream from the relay, and runs FFmpeg to scale the
video, burn in a graphic scorebug, and publish audio and video to RTMP(S). Score
changes are re-rendered and fed to the running FFmpeg, so it never restarts.

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
cp apps/home-daemon/.env.example apps/home-daemon/.env   # set FFMPEG_PATH
node --env-file=apps/home-daemon/.env apps/home-daemon/node_modules/tsx/dist/cli.mjs apps/home-daemon/src/index.ts
```

FFmpeg needs SRT, AAC and the selected H.264 encoder (no `drawtext`/fonts). On macOS use
Homebrew's `ffmpeg-full`.

## Configuration

| Variable                      | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `CONTROL_PLANE_URL`           | API base URL                                                     |
| `HOME_TOKEN`                  | Worker token, must match the control plane                       |
| `WORKER_ID`, `OUTPUT_ID`      | This worker's IDs; the API sends it broadcasts for them          |
| `OUTPUT_MODE`                 | `rtmp` (default), `record`, or `rtmp+record`                     |
| `OUTPUT_URL`                  | RTMP(S) destination including stream key (RTMP modes)            |
| `OUTPUT_RECORDING_DIR`        | Where to save overlaid MP4s (record modes)                       |
| `ENCODER`                     | `software` (default), `videotoolbox` (macOS) or `nvenc` (NVIDIA) |
| `VIDEO_PROFILE`               | Output size and bitrate, see below (default `1080p30`)           |
| `FFMPEG_PATH`, `FFPROBE_PATH` | Executables (default from `PATH`)                                |
| `SCORE_DIR`                   | Per-worker scratch directory for `scorebug.json`                 |
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

## Scorebug overlay

The burned-in scoreboard is a raster graphic, configurable per match with
`scorebugStyle` (`bar` default, `lowerThird`, `setCard`): set it on
`POST /v1/matches` or change it live with the scorer command
`{ "type": "set_scorebug_style", "style": "setCard" }`. The worker serializes the
style, teams, score, best-of and completed sets to `$SCORE_DIR/scorebug.json`;
`src/scorebug/` turns that into SVG, rasterizes it with resvg and the bundled
Barlow Condensed (SIL OFL 1.1, `assets/fonts/OFL.txt`), and streams it into
FFmpeg's second input.

Compositing: FFmpeg reads the overlay as a live Matroska stream of RGBA frames on
stdin (`-f matroska -i pipe:0`, guardian fd6) and blends it with `overlay`. The
live graph keeps the camera's transport clock (`-copyts`), so a plain image or
rawvideo input (timestamps from zero) would stall `overlay`'s frame sync; the
feed instead stamps each frame from decoder telemetry (latest decoded PTS +
elapsed wall time + 250 ms lead) at 8 fps. Only one box per style is sent,
packed into a small canvas, and each is blended at its place (about a quarter of
the frame); `overlay` blends every pixel it is given, transparent or not. The
RGB to YUV matrix follows format negotiation, so it matches the camera's.
A score change shows about 0.3–0.4 s after the worker writes it, without
restarting FFmpeg or dropping frames. If the feed dies, FFmpeg sees EOF and
`eof_action=pass` keeps the video going without the graphic.

Review the styles without a stream:

```sh
pnpm --filter @scorebug/home-daemon render-scorebug ./scorebug-samples [--frame=still.png]
```

## Linux CPU/GPU deployment

Build the image from the repository root:

```sh
docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon:$(git rev-parse --short=12 HEAD) .
```

The image is Node 22 on Debian Trixie with FFmpeg and `tini` (the scorebug font is bundled). Put a
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

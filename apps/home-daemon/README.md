# Broadcast worker

The broadcast worker (package `@scorebug/home-daemon`) turns the phone's stream into
the broadcast. It polls the control plane for its assignment, reads the match video,
and runs FFmpeg to scale it, burn in the scorebug, and push audio and video to
RTMP(S). Score changes are re-rendered and fed to the running FFmpeg, so it never
restarts for a point.

The same code runs in two places:

- **Hosted (scorebug.live).** Each live match gets a Cloudflare Container built from
  this package's `Dockerfile`. The team's Durable Object starts it and sets its
  environment. The worker reads the match from Cloudflare Stream over RTMPS and
  pushes RTMPS to YouTube.
- **Self-hosted.** The worker runs as a long-lived Docker service or a plain Node
  process next to your own control plane. It reads the match over SRT from the
  MediaMTX relay. See [Self-hosting](../../docs/self-hosting.md).

In both cases the worker only makes outbound connections.

## How it works

Every 500 ms the worker asks the control plane for its assignment
(`GET /v1/worker/snapshot`, then `GET /v1/worker/connection`, with
`Authorization: Bearer $HOME_TOKEN` and `?workerId=$WORKER_ID`). It runs a broadcast
only when the match is active, the broadcast is set to running, and the broadcast is
assigned to this `WORKER_ID`. The read URL comes from the control plane and must be
`srt:` or `rtmps:`.

The output goes to the match's destination from the control plane. If the match has
none, the worker uses `OUTPUT_URL`. With neither, it logs `worker_output_missing` and
does not start.

The worker waits until the control plane reports the source ready before it starts
FFmpeg. It stops FFmpeg when:

- the assignment changes or the match ends (it lets FFmpeg drain for up to 10 seconds),
- the control plane has been unreachable for 5 seconds,
- FFmpeg has produced no new output for `OUTPUT_TIMEOUT_MS`.

It retries at most `RETRY_MAX_ATTEMPTS` times per broadcast per minute, at least one
second apart. A small guardian process owns FFmpeg, so FFmpeg is cleaned up even if
the worker is killed. Run one worker process per `WORKER_ID`.

The worker reports its state (`waiting_source`, `starting`, `producing_output`,
`retrying` and so on), FFmpeg's frame and time counters, and its output profile to
the control plane every `WORKER_REPORT_INTERVAL_MS` (`POST /v1/worker/sessions` and
`/v1/worker/observations`). The apps use this to show whether the broadcast is live.
Logs never contain media URLs or stream keys.

## Hosted match container

`apps/control-plane/src/worker/team-object.ts` starts the container with the
`standard-4` instance type and internet access. It intercepts outbound HTTP to
`api.internal` and routes it to the team's Durable Object, so the container holds no
credential: its `HOME_TOKEN` is a fixed placeholder that the intercept makes
irrelevant. Stream and YouTube are reached directly.

`apps/control-plane/src/worker/hosted-media.ts` sets this environment:

| Variable                | Hosted value                                 |
| ----------------------- | -------------------------------------------- |
| `CONTROL_PLANE_URL`     | `http://api.internal/`                       |
| `WORKER_ID`             | `match`                                      |
| `OUTPUT_ID`             | `youtube`                                    |
| `ENCODER`               | `software`                                   |
| `VIDEO_PROFILE`         | The Worker's `VIDEO_PROFILE` var (`1080p30`) |
| `SCORE_DELAY_MS`        | The Worker's `SCORE_DELAY_MS` var (`1100`)   |
| `INPUT_PROBE`           | `fast`                                       |
| `INPUT_READ_TIMEOUT_MS` | `4000`                                       |
| `OUTPUT_TIMEOUT_MS`     | `15000`                                      |
| `RETRY_MAX_ATTEMPTS`    | `6`                                          |
| `RETRY_FREE_AFTER_MS`   | `3000`                                       |
| `LOG_LEVEL`             | `info`                                       |

The YouTube destination is the match's broadcast ingest URL, sent in the assignment.
The image is built and deployed with the Worker by `wrangler deploy`
(`containers` in `apps/control-plane/wrangler.jsonc`).

## Configuration

All settings are environment variables, validated at startup by `src/config.ts`.
`.env.example` has local-fixture values.

| Variable                    | Purpose                                                                         |
| --------------------------- | ------------------------------------------------------------------------------- |
| `CONTROL_PLANE_URL`         | API base URL (`http:` or `https:`)                                              |
| `HOME_TOKEN`                | Worker bearer token, at least 16 characters; must match the control plane       |
| `WORKER_ID`, `OUTPUT_ID`    | This worker's IDs; the control plane assigns broadcasts to them                 |
| `OUTPUT_MODE`               | `rtmp` (default), `record`, or `rtmp+record`                                    |
| `OUTPUT_URL`                | Fallback RTMP(S) destination with the stream key, for matches without one       |
| `OUTPUT_RECORDING_DIR`      | Where to save overlaid MP4s; required by the record modes                       |
| `ENCODER`                   | `software` (default, libx264), `videotoolbox` (macOS) or `nvenc` (NVIDIA)       |
| `VIDEO_PROFILE`             | Output size and bitrate, see below (default `1080p30`)                          |
| `DECODER_THREADING`         | `automatic` (default) or `slice` for the input decoder                          |
| `SCORE_DELAY_MS`            | Hold each score change this long so it lines up with delayed video (default 0)  |
| `INPUT_PROBE`               | `default`, or `fast` to bound FFmpeg's input analysis                           |
| `INPUT_READ_TIMEOUT_MS`     | End an attempt when the source sends nothing for this long (default: wait)      |
| `OUTPUT_TIMEOUT_MS`         | Restart FFmpeg after this long without new output (default 10000)               |
| `RETRY_MAX_ATTEMPTS`        | FFmpeg starts per broadcast per minute (default 3)                              |
| `RETRY_FREE_AFTER_MS`       | An attempt that ran at least this long does not count against the retry limit   |
| `WORKER_REPORT_INTERVAL_MS` | Status report interval, 100–4000 ms (default 1000)                              |
| `FFMPEG_PATH`               | FFmpeg executable (default `ffmpeg` from `PATH`)                                |
| `SCORE_DIR`                 | Scratch directory for `scorebug.json` (default `/tmp/scorebug`); one per worker |
| `LOG_LEVEL`                 | `debug`, `info` (default), `warn` or `error`                                    |

| Profile   | Canvas      | Video bitrate |
| --------- | ----------- | ------------- |
| `240p30`  | 426 × 240   | 350 kbps      |
| `360p30`  | 640 × 360   | 600 kbps      |
| `540p30`  | 960 × 540   | 1.5 Mbps      |
| `720p30`  | 1280 × 720  | 3 Mbps        |
| `1080p30` | 1920 × 1080 | 6 Mbps        |
| `2160p30` | 3840 × 2160 | 18 Mbps       |

Profiles keep the source aspect ratio with padding, cap the frame rate at 30 fps and
set a keyframe every 2 seconds. Audio is AAC at 128 kbps, 44.1 kHz.

With a record mode, each attempt writes `attempt-*/overlay.mp4` (fragmented MP4)
under `OUTPUT_RECORDING_DIR`. Nothing is rotated or deleted automatically. The
phone's own recording has no scorebug.

FFmpeg needs SRT (self-hosted), RTMPS (hosted), AAC and the selected H.264 encoder.
It does not need `drawtext` or system fonts. On macOS use Homebrew's `ffmpeg-full`.

## Scorebug overlay

The burned-in scorebug is a raster graphic in one of three styles: `bar` (default),
`lowerThird` and `setCard`.

| `bar`                               | `lowerThird`                                      | `setCard`                                   |
| ----------------------------------- | ------------------------------------------------- | ------------------------------------------- |
| ![bar style](docs/scorebug/bar.png) | ![lowerThird style](docs/scorebug/lowerThird.png) | ![setCard style](docs/scorebug/setCard.png) |

The style is set per match: pass `scorebugStyle` to `POST /v1/matches`, or change it
during the match with the scorer command
`{ "type": "set_scorebug_style", "style": "setCard" }` (see [the API reference](../../docs/api.md)).

On each score change the worker writes the style, teams, score, best-of and
completed sets to `$SCORE_DIR/scorebug.json`, atomically. `src/scorebug/` turns
that into SVG and rasterizes it with resvg and the bundled Barlow Condensed font
(SIL OFL 1.1, `assets/fonts/OFL.txt`).

The overlay reaches FFmpeg as a second input: a live Matroska stream of RGBA frames
on FFmpeg's stdin, at 8 frames per second. FFmpeg keeps the camera's timestamps
(`-copyts`), so each overlay frame is stamped from the latest decoded video
timestamp plus elapsed time plus a 250 ms lead. Only one box per style is sent,
packed into a small canvas, and FFmpeg blends each box at its place with `overlay`.
A score change shows about 0.25–0.4 s after the worker writes it (plus
`SCORE_DELAY_MS`), without restarting FFmpeg or dropping frames. If the overlay feed
stops, `eof_action=pass` keeps the video going without the graphic.

Render the styles to PNG without a stream:

```sh
pnpm --filter @scorebug/home-daemon render-scorebug ./scorebug-samples [--frame=still.png]
```

It writes each style at 1080p and 720p on a transparent background, plus a 1080p
preview over a backdrop (or over `--frame`).

## Run locally

Start the local relay, mock YouTube and API first (see
[Development](../../docs/development.md)), then:

```sh
cp apps/home-daemon/.env.example apps/home-daemon/.env   # set FFMPEG_PATH
node --env-file=apps/home-daemon/.env apps/home-daemon/node_modules/tsx/dist/cli.mjs apps/home-daemon/src/index.ts
```

The example points at the local API and sends to the mock YouTube sink.
`pnpm --filter @scorebug/home-daemon dev` runs the same entry point with `tsx watch`
and reads settings from the environment.

## Docker image

Build from the repository root:

```sh
docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon:$(git rev-parse --short=12 HEAD) .
```

The image is Node 22 on Debian Trixie with Debian's FFmpeg and `tini`. It runs
`node apps/home-daemon/dist/index.js`. Self-hosted Compose stacks run it as user
`1000:1000` with all capabilities dropped:
[`infra/vps/docker-compose.yml`](../../infra/vps/docker-compose.yml) (all-in-one) and
[`infra/worker/docker-compose.yml`](../../infra/worker/docker-compose.yml) (a home
machine). Both use `ENCODER=software`.

## Test

```sh
pnpm --filter @scorebug/home-daemon test
pnpm test:worker-container scorebug/home-daemon:<tag>
```

The unit tests include FFmpeg tests that need `ffmpeg` and `ffprobe` on `PATH`
(override with `SCOREBUG_FFMPEG_PATH` and `SCOREBUG_FFPROBE_PATH`). The recording
test runs only when `SCOREBUG_RECORDING_FFMPEG` and `SCOREBUG_RECORDING_FFPROBE` are
set.

`test:worker-container` starts a built image without network access, checks that
the worker starts and reports the control plane unavailable, then runs the real
pipeline inside the image and checks that the scorebug is in the output. CI runs it
on pull requests and pushes to `main`.

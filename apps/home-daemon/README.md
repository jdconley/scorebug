# @scorebug/home-daemon

Runs on the home box. Opens a single outbound WebSocket to the control plane and:

- On `start_game`: spawns ffmpeg to pull SRT from the VPS, draw the score over it, and push RTMPS to YouTube.
- On `score_update` / `callout`: atomically rewrites `${SCORE_DIR}/score.txt` so ffmpeg's `drawtext reload=1` picks it up.
- On `end_game`: SIGTERMs ffmpeg (SIGKILL after 5s grace).
- On WS drop: exponential backoff reconnect.

The home is the **source of truth** for pipeline state. The control plane mirrors what we report.

## Develop (CPU-only, no Docker)

```sh
cp .env.example .env       # set CONTROL_PLANE_WS, HOME_TOKEN, NVENC_ENABLED=false
pnpm install
pnpm --filter @scorebug/home-daemon dev
```

You need `ffmpeg` on `$PATH` for the dev path. Any recent ffmpeg works for libx264.

## Build the Docker image

```sh
# From the repo root
docker build -f apps/home-daemon/Dockerfile -t scorebug/home-daemon .
```

## Run with NVENC (Linux or Windows WSL2)

Requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) inside the host (or inside WSL2 on Windows with Docker Desktop's WSL2 backend).

```sh
docker run --rm \
  --gpus all \
  --env-file apps/home-daemon/.env \
  scorebug/home-daemon
```

## Run without NVENC (CPU fallback)

```sh
docker run --rm \
  -e NVENC_ENABLED=false \
  --env-file apps/home-daemon/.env \
  scorebug/home-daemon
```

## Test

```sh
pnpm --filter @scorebug/home-daemon test
```

## Verifying NVENC is available inside the container

```sh
docker run --rm --gpus all scorebug/home-daemon \
  ffmpeg -hide_banner -encoders 2>&1 | grep nvenc
```

If the output is empty, the toolkit isn't passing the GPU through — fix that before running real games.

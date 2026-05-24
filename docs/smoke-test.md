# Smoke testing the pipeline without an iPhone

Walk every link in the chain before the iOS app exists. Each section is independent — skip to whichever piece you're currently blocked on.

## 1. Control plane locally

```sh
cd apps/control-plane
cp .env.example .env
# replace tokens with: openssl rand -base64 32
pnpm install
pnpm dev
```

Verify:

```sh
curl http://localhost:8787/healthz
# {"ok":true,"home":false}
```

## 2. Scoring PWA locally

```sh
pnpm --filter @scorebug/scoring dev
```

Open `http://localhost:5174` on your phone (same WiFi) or your laptop.

1. Tap the gear → enter `http://<your-laptop-ip>:8787` and the `PHONE_TOKEN` from `.env`.
2. Enter team names + a placeholder YouTube stream key (`xxxx-xxxx-xxxx-xxxx`).
3. Tap **Start Game** — you should land on the scoreboard. The top-bar reads `home ✗` until the home daemon is connected (step 5).
4. Tap the home tile a few times — the control plane log shows the score going up; `curl -H "Authorization: Bearer $PHONE_TOKEN" http://localhost:8787/games/<id>` confirms.

## 3. MediaMTX locally (so something can publish SRT)

```sh
docker compose -f docker-compose.dev.yml up
```

MediaMTX is now listening on `srt://localhost:8890`. **Note**: the `runOnReady` webhook in `infra/vps/mediamtx.yml` points at `http://127.0.0.1:8787` — that resolves inside the container to the container itself, not your host. For local smoke-testing, edit `infra/vps/mediamtx.yml` and change the URL to `http://host.docker.internal:8787`, OR run MediaMTX outside Docker.

## 4. Push a test stream into MediaMTX without an iPhone

Pick whichever tool you have. The goal: get a video into `game_<gameId>` via SRT publish so MediaMTX flips it to `live` and `runOnReady` fires.

### Option A — ffmpeg from a file

```sh
GAMEID=$(curl -sS -X POST http://localhost:8787/games/start \
  -H "Authorization: Bearer $PHONE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"homeTeam":{"name":"H","shortName":"H","color":"#1e3a8a"},
       "awayTeam":{"name":"A","shortName":"A","color":"#b91c1c"},
       "youtubeStreamKey":"xxxx-xxxx-xxxx-xxxx"}' | jq -r '.id')

PUBLISH_SECRET=$(curl -sS -H "Authorization: Bearer $PHONE_TOKEN" \
  http://localhost:8787/games/$GAMEID | jq -r '.publish.passphrase')

# Use any sample 1080p file
ffmpeg -re -stream_loop -1 -i sample.mp4 \
  -c:v libx264 -preset veryfast -tune zerolatency -b:v 6000k -g 60 \
  -c:a aac -b:a 128k -f mpegts \
  "srt://localhost:8890?streamid=publish:game_$GAMEID:$PUBLISH_SECRET&passphrase=$PUBLISH_SECRET&latency=1000000"
```

### Option B — OBS Studio

1. Settings → Stream → Custom: `srt://localhost:8890?streamid=publish:game_<gameId>:<secret>&passphrase=<secret>&latency=1000000`
2. Output → Streaming → x264, 6000 Kbps, keyframe 2s.
3. Start Streaming.

In both cases the control-plane log should print `stream_ready` and `GET /games/<id>` will return `status: live`.

## 5. Home daemon locally (CPU fallback)

```sh
cd apps/home-daemon
cp .env.example .env
# CONTROL_PLANE_WS=ws://localhost:8787/home/ws
# HOME_TOKEN must match control plane
# NVENC_ENABLED=false   <-- key for Mac/dev
pnpm install
pnpm dev
```

You need `ffmpeg` on PATH. The daemon will:

1. Connect to the control plane WS — control plane log prints `home_socket_attached`. PWA top-bar flips to `home ✓`.
2. On a `start_game` (PWA's Start Game), spawn ffmpeg, pull from MediaMTX, draw the score, and push RTMPS to `RTMP_TARGET/<streamKey>`. For smoke-testing, point `RTMP_TARGET` at a local nginx-rtmp or use ffmpeg-with-`-f null -` by editing `src/pipeline.ts` temporarily.

## 6. End-to-end on the VPS

Once locally green:

```sh
# DNS already pointed at the VPS
ssh root@<vps>
git clone https://github.com/jdconley/scorebug.git
cd scorebug/infra/vps
cp .env.example .env
$EDITOR .env     # fill in real tokens + CADDY_DOMAIN
docker compose pull
docker compose build
docker compose up -d
docker compose logs -f
```

Then point the PWA at `https://api.scorebug.live` and the home daemon at `wss://api.scorebug.live/home/ws`. Use Option A or OBS to push a test stream. When you see it on YouTube, you're ready for the iPhone.

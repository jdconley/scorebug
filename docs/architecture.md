# Architecture

This document captures the decisions locked in during the initial design conversation. If something here contradicts the code, the code is likely wrong — open an issue.

## The pipeline

```
┌────────────┐   SRT (UDP, AES,    ┌──────────┐   SRT       ┌────────────────┐  RTMPS  ┌────────────┐
│  iPhone    │   latency=1s)       │   VPS    │   pull      │   Home box     │  TCP    │  YouTube   │
│ HaishinKit │  ─────────────────► │ MediaMTX │ ──────────► │ FFmpeg + NVENC │ ──────► │   Live     │
│  H.264     │                     │          │             │  + overlay     │         │ (low-lat)  │
└────────────┘                     │  Hono    │             └────────────────┘         └────────────┘
       │                           │  control │                     ▲
       │  REST start/end/score     │  plane   │                     │ outbound WS
       └─────────────────────────► │          │ ◄───────────────────┘   wss://api/home/ws
                                   └──────────┘
                                         ▲
                                         │ REST score updates
                                   ┌────────────┐
                                   │ Scoring PWA│
                                   │ (phone/lap)│
                                   └────────────┘
```

End-to-end latency target: **5–10s glass-to-glass** (YouTube "low latency" mode).

## Three runtimes

### iPhone

- Swift, `AVFoundation`, **HaishinKit.swift** for SRT.
- `AVCaptureSession` produces `CMSampleBuffer`s. Fork on two independent serial queues:
  1. **Stream** — encode H.264 1080p @ 5–6 Mbps, ship via SRT.
  2. **Archive** — `AVAssetWriter` writing fragmented MP4 (movieFragmentInterval set for crash safety). Never re-encoded.
- Trim HaishinKit: no WebRTC, no playback, no talkback — one-way feed only.
- Configure control plane URL + auth token in Settings.

### VPS (Hetzner CPX11, Hillsboro, OR)

- docker-compose with three services:
  - **Caddy** — TLS termination, reverse proxy to control plane.
  - **control-plane** (Hono on Node 22) — REST + WebSocket to home.
  - **MediaMTX** with `network_mode: host` — SRT ingest + pull.
- ~$5/mo, always-on. ~11 GB egress per 2-hour game; included in plan's 1 TB.

### Home (always-on box w/ NVIDIA GPU)

- **home-daemon** (Node, systemd unit) — outbound WebSocket to control plane.
  - On `start_game`: spawn ffmpeg.
  - On `score_update` / `callout`: atomic-write `/tmp/score.txt` (tmp + rename) so `drawtext textfile=...:reload=1` picks it up.
  - On `end_game`: kill ffmpeg.
- **Overlay** — served locally; v1 = `drawtext`, v2 = Smelter Web View loading a Vite-built React page over GPU compositing.

## Protocol

Shared types live in `packages/protocol/src/messages.ts`. Both control plane and home daemon import from there.

### REST (control plane)

| Method | Path                       | Auth                  | Body                                  |
|--------|----------------------------|-----------------------|---------------------------------------|
| POST   | `/games/start`             | phone token           | `{ homeTeam, awayTeam, youtubeStreamKey }` |
| POST   | `/games/:id/end`           | phone token           | —                                     |
| POST   | `/games/:id/score`         | phone token           | `{ home, away, set, homeSets, awaySets }` |
| POST   | `/games/:id/callout`       | phone token           | `{ kind: 'kill'\|'dig'\|'block', player }` |
| POST   | `/internal/stream-ready`   | MediaMTX bearer       | (webhook fired by MediaMTX `runOnReady`) |
| GET    | `/home/ws`                 | home token (query)    | WebSocket upgrade                     |

### WebSocket (control plane ↔ home)

- Home initiates: `wss://api.scorebug.live/home/ws?token=…`.
- Control sends `HomeMessage`; home replies with `HomeReport`.
- Reconnect with backoff on drop; home is the source of truth for pipeline state.

## Security

- Three Bearer secrets, all rotatable, stored as env vars:
  - **phone token** — for iPhone + scoring PWA → control plane.
  - **home token** — for home daemon WS.
  - **internal token** — for MediaMTX webhook.
- Per-game **two SRT passphrases**:
  - `publish_secret` — handed to the iPhone for this game.
  - `read_secret` — handed to the home daemon for this game.
  - Leaked publish → disrupt this stream, can't exfiltrate.
  - Leaked read → can't inject content.
- Home never accepts inbound. Period.

## Stream IDs

- iPhone publishes with streamId `publish:game_<uuid>:<secret>`.
- Home pulls with streamId `read:game_<uuid>`.
- MediaMTX `paths` regex `~^game_.+$`.

## Why these choices

- **SRT, not RTMP, on the venue→VPS hop.** RTMP rides TCP, which collapses under congested 2.4 GHz / marginal cellular at gyms. SRT (UDP + ARQ) recovers within its latency window.
- **RTMPS to YouTube** because that's what YouTube speaks. TCP over 443 is fine on the home network.
- **Compositing at home, not in the cloud.** Home has NVENC + plenty of uplink. Per-game compute cost: $0.
- **MediaMTX** over SRS / nginx-rtmp. Single Go binary, active project, supports SRT and webhooks.
- **Hetzner CPX11** over AWS/GCP/DO (cheaper) and Fly suspend (rejected — eviction is unacceptable mid-game).
- **No Cloudflare Tunnel** — HTTP-only, no SRT.
- **No Tailscale** — mobile CGNAT defeats UDP hole-punching too often; DERP is shared and latency-variable.

## v2 upgrade path

Once v1 works:

- Swap `drawtext` for **Smelter** (Software Mansion). React SDK, Web View element, GPU-accelerated.
- Overlay becomes a real React page with **Rive** state-machine animations (chosen over Lottie for `kill`/`dig`/`block` callouts with player number + name).
- Persist game history to SQLite on the home box.
- Add Android client and a basic web admin UI.

## Non-goals

Multi-camera switching. Sub-second latency. Multi-tenant. Web broadcast control panel (v1). Offsite redundancy. Turbo/Nx. Game engine for overlay. WebRTC / playback in iOS.

## Open questions

- Volleyball scoring rules (rally vs side-out, set/match win conditions, 5th-set tiebreak) aren't yet in the data model — only `{home, away, set}`.
- Roster/lineup CRUD — `Player` type exists but no management UI specced.
- Where the scoring PWA is served (VPS via control plane vs static host).
- YouTube stream-key storage/rotation flow.

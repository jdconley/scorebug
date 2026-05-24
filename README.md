# Scorebug

Open-source live streaming of kids' volleyball games with a graphical scoreboard overlay, run by one parent from the stands.

One parent points a phone at the court. Another (or the same one) taps a scoreboard from the stands. The broadcast handles itself.

> Status: early scaffolding. Not yet operational.

## What it does

- iPhone captures 1080p, encodes H.264 at 5–6 Mbps, and publishes via **SRT** to a $5/mo VPS.
- The VPS runs **MediaMTX** as a relay and notifies a control plane.
- A **home machine** (already-on, with an NVIDIA GPU) pulls the SRT stream, composites a scoreboard overlay with **FFmpeg + NVENC**, and pushes **RTMPS** to YouTube Live.
- A small **PWA** lets you tap the score from your phone in the stands; updates land on the overlay within a beat.
- The iPhone keeps a full-resolution local archive (fragmented MP4, never re-encoded) for after the game.

Glass-to-glass latency target: ~5–10s.

## Why

Existing options:

- Paid SaaS: $30–100+/mo, no source access.
- OBS + manual scoreboard: needs someone at a laptop the whole game.

Scorebug aims to be free to fork, ~$5/mo to operate, and runnable by one parent.

## Architecture (v1)

```
iPhone (HaishinKit, SRT)  ──►  VPS  ──►  Home machine  ──►  YouTube Live
                              MediaMTX     FFmpeg+NVENC      RTMPS
                              Hono API     Overlay (HTML)
                                  ▲
                                  │ REST / WS
Phone PWA (scoring) ──────────────┘
```

See [docs/architecture.md](docs/architecture.md) for the full picture, including the protocol, security model, and v2 upgrade path (Smelter + Rive overlay, kill/dig/block callouts).

## Layout

```
scorebug/
├── apps/
│   ├── control-plane/   # Hono API on the VPS — game state, WS to home
│   ├── home-daemon/     # WS client on home box — spawns ffmpeg/Smelter
│   ├── overlay/         # Transparent 1920x1080 HTML scoreboard
│   └── scoring/         # PWA: big buttons, taps the score
├── packages/
│   ├── protocol/        # Shared TS types — HomeMessage, Score, etc.
│   └── eslint-config/
├── ios/                 # Native capture app (Swift, AVFoundation, HaishinKit)
├── docs/
└── Justfile             # Cross-language task runner
```

iOS lives at the top level, not in `apps/`, because Swift and pnpm workspaces don't share anything.

## Requirements

- Node 22+ and pnpm 9+ for the TS apps
- [just](https://github.com/casey/just) for task running
- Xcode 16+ for the iOS app (iOS 17+ target)
- A home box with NVIDIA GPU (NVENC) for compositing
- A small VPS for ingest + control plane (we use Hetzner CPX11 in Hillsboro)

## Quickstart

```sh
pnpm install
just --list
```

Apps and per-app run commands will be filled in as scaffolds land.

## Domain

`scorebug.live` — production.

## License

[MIT](LICENSE) © Conley Chaos LLC.

## Security

Disclosures: security@scorebug.live.

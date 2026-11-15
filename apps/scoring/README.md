# @scorebug/scoring

> Legacy prototype: the September product plan replaces this PWA with native iPhone and Apple Watch scoring. The instructions below describe the existing prototype only; browser scoring is not a planned product feature.

PWA you tap from the stands. Big buttons, no chrome, installable.

## Develop

```sh
pnpm --filter @scorebug/scoring dev
```

Open `http://localhost:5174` on the same WiFi (or your laptop). On a phone, "Add to Home Screen" to install as a PWA.

## First run

1. Tap the gear in the top-right.
2. Set **Control plane URL** (e.g. `http://localhost:8787` for dev or `https://api.scorebug.live` for prod).
3. Paste your **phone bearer token** (the value of `PHONE_TOKEN` you set in the control plane).

The token is stored in `localStorage`, unencrypted. This is a personal-scale tool; if you don't trust the device, don't paste the token.

## Workflow

1. Enter team names + short names (max 8 chars — appears on overlay).
2. Paste a fresh YouTube stream key.
3. Start the game. The phone (separately) connects to the VPS via SRT.
4. Tap the big home/away tiles to score. Undo, end set, end game, all on screen.

## Build

```sh
pnpm --filter @scorebug/scoring build
```

Static files land in `dist/`. Host them anywhere — VPS via Caddy, a static CDN, or `pnpm preview`.

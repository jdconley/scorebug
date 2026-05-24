# @scorebug/control-plane

Hono server that runs on the VPS. It:

- Issues per-game SRT publish/read secrets.
- Hands publish credentials to the iPhone via `POST /games/start`.
- Pushes `start_game`/`score_update`/`callout`/`end_game` messages to the home daemon over a WebSocket the home initiates.
- Accepts MediaMTX's `runOnReady` webhook on `/internal/stream-ready` to flip a game from `starting` → `live`.
- Holds state in-memory (single live game at a time).

## Develop

```sh
cp .env.example .env       # then edit tokens
pnpm install
pnpm --filter @scorebug/control-plane dev
```

Server listens on `http://localhost:8787`. WS upgrade is at `ws://localhost:8787/home/ws?token=$HOME_TOKEN`.

## Endpoints

| Method | Path                       | Auth     |
|--------|----------------------------|----------|
| GET    | `/healthz`                 | none     |
| POST   | `/games/start`             | phone    |
| POST   | `/games/:id/end`           | phone    |
| POST   | `/games/:id/score`         | phone    |
| POST   | `/games/:id/callout`       | phone    |
| GET    | `/games/:id`               | phone    |
| POST   | `/internal/stream-ready`   | internal |
| GET    | `/home/ws`                 | home (query `?token=`) |

## Test

```sh
pnpm --filter @scorebug/control-plane test
```

# @scorebug/control-plane

Hono API on Node 22 with SQLite storage. It holds the active match and its score,
issues device credentials, tracks recording and broadcast state, manages relay paths
and SRT credentials through the MediaMTX API, and serves the broadcast worker its
assignment.

## Develop

From the repository root, with the dev relay running (`pnpm local:up`):

```sh
pnpm dev:api
```

This uses `infra/local/.env.example` and listens on `http://127.0.0.1:18787`. To run
with your own settings, copy `.env.example` to `.env` and run
`pnpm --filter @scorebug/control-plane dev`.

## Endpoints

| Method   | Path                                 | Auth                  |
| -------- | ------------------------------------ | --------------------- |
| GET      | `/healthz`                           | none                  |
| POST     | `/v1/matches`                        | installation token    |
| GET      | `/v1/matches/active`                 | installation token    |
| POST     | `/v1/matches/:id/join`               | installation token    |
| GET      | `/v1/matches/:id`                    | match credential      |
| POST     | `/v1/matches/:id/commands`           | match credential      |
| GET      | `/v1/matches/:id/commands/:id`       | match credential      |
| GET/POST | `/v1/matches/:id/watch-pairings/...` | match credential      |
| GET/POST | `/v1/matches/:id/media/...`          | match credential      |
| GET/POST | `/v1/worker/...`                     | worker (`HOME_TOKEN`) |

## Configuration

| Variable                                                    | Purpose                                       |
| ----------------------------------------------------------- | --------------------------------------------- |
| `PHONE_TOKEN`                                               | Installation token used by the apps to set up |
| `HOME_TOKEN`                                                | Worker bearer token                           |
| `PORT`, `HOST`                                              | Listen address (default `0.0.0.0:8787`)       |
| `DATABASE_PATH`                                             | SQLite file (default `data/scorebug.sqlite`)  |
| `INGEST_HOST`, `INGEST_PORT`                                | Relay SRT address handed to the worker        |
| `INGEST_PUBLISH_HOST`, `INGEST_PUBLISH_PORT`                | Optional separate SRT address for the phone   |
| `RELAY_API_URL`, `RELAY_API_USERNAME`, `RELAY_API_PASSWORD` | MediaMTX management API                       |
| `CORS_ORIGINS`, `LOG_LEVEL`                                 | CORS origins (default `*`) and log level      |

## Test

```sh
pnpm --filter @scorebug/control-plane test
```

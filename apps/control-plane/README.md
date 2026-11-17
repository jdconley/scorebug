# @scorebug/control-plane

The Scorebug API. The package has two entry points that share the match, scoring,
media and worker code:

- **Hosted Worker** (`src/worker/`, `wrangler.jsonc`). The Cloudflare Worker behind
  `https://scorebug.live`: Google sign-in, the private beta, teams, team invites,
  YouTube channels, and the public pages. Storage is D1 (`migrations/`). Each team
  has a `TeamObject` Durable Object that holds its matches and runs the match
  container, built from `apps/home-daemon/Dockerfile`, which pulls the match from
  Cloudflare Stream and pushes it to YouTube.
- **Node server** (`src/index.ts`, `src/app.ts`). The self-hosted API on Node 22 with
  SQLite. It authenticates owner phones with setup-link device tokens, stores RTMP
  destinations, and manages relay paths and SRT credentials through the MediaMTX
  management API.

The shared code is `src/matches-store.ts`, `src/scoring.ts`, `src/media-store.ts`,
`src/worker-observations.ts` and the route modules in `src/routes/`. See
[docs/architecture.md](../../docs/architecture.md) for how the pieces fit and
[docs/api.md](../../docs/api.md) for the HTTP API.

## Develop

### Hosted Worker

```sh
cp apps/control-plane/.dev.vars.example apps/control-plane/.dev.vars   # fill in the secrets
pnpm --filter @scorebug/control-plane exec wrangler d1 migrations apply scorebug --local
pnpm --filter @scorebug/control-plane dev:worker
```

`wrangler dev` reads secrets and a localhost `PUBLIC_URL` from `.dev.vars`, and runs
D1 and the Durable Objects locally. Google sign-in needs the real
`GOOGLE_CLIENT_SECRET`. Local containers are off (`dev.enable_containers` is
`false`), so Go Live answers `container_unavailable` unless you turn them on and
have Docker running.

### Node server

From the repository root, with the dev relay running:

```sh
pnpm local:up
pnpm dev:api
```

`dev:api` uses `infra/local/.env.example` and listens on `http://127.0.0.1:18787`.
`pnpm -s dev:setup-link` prints a one-time setup link for it.

`pnpm --filter @scorebug/control-plane dev` runs the server with `tsx watch` and
reads its settings from the environment only; it does not load a `.env` file. To
use your own file, pass it to Node the way `dev:api` does:

```sh
node --env-file=apps/control-plane/.env \
  apps/control-plane/node_modules/tsx/dist/cli.mjs apps/control-plane/src/index.ts
```

`.env.example` lists the variables.

## Test

| Command                                             | Runs                                                              |
| --------------------------------------------------- | ----------------------------------------------------------------- |
| `pnpm --filter @scorebug/control-plane test`        | `test/**/*.test.ts` in Node (`vitest.config.ts`)                  |
| `pnpm --filter @scorebug/control-plane test:worker` | `test-worker/**/*.test.ts` in workerd (`vitest.worker.config.ts`) |
| `pnpm --filter @scorebug/control-plane typecheck`   | Both TypeScript configs (`tsconfig.json`, `tsconfig.worker.json`) |

The Worker tests run through `@cloudflare/vitest-plugin` with the bindings from
`wrangler.jsonc` and test values for the secrets. Each test starts from empty D1 and
Durable Object storage with the migrations applied. Google, YouTube and Stream are faked (`test-worker/fake-google.ts`,
`test-worker/fake-media.ts`). Both test scripts build `@scorebug/protocol` first.

## Configuration

### Hosted Worker

Vars, in `wrangler.jsonc`:

| Var                 | Purpose                                                                  |
| ------------------- | ------------------------------------------------------------------------ |
| `PUBLIC_URL`        | `https://scorebug.live`: OAuth callback, invite and join links           |
| `APP_AUTH_REDIRECT` | `scorebug://auth`: where sign-in and channel connections return          |
| `GOOGLE_CLIENT_ID`  | Google OAuth client                                                      |
| `CF_ACCOUNT_ID`     | Cloudflare account that owns the Stream live inputs                      |
| `LIVE_MATCH_CAP`    | Concurrent live matches across every team (default 5)                    |
| `SCORE_DELAY_MS`    | How long the match container holds score changes (Stream's intake delay) |
| `VIDEO_PROFILE`     | The match container's video profile, `1080p30` or `720p30`               |

Secrets, set with `wrangler secret put` and never committed:

| Secret                 | Purpose                                                                                                                                |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret                                                                                                             |
| `SERVER_SECRET`        | At least 32 characters. Signs OAuth state, keys code hashes and match credentials, and derives the key that seals YouTube tokens in D1 |
| `ADMIN_EMAILS`         | Comma-separated emails that may open `/admin`                                                                                          |
| `STREAM_API_TOKEN`     | Cloudflare API token with Stream:Edit on `CF_ACCOUNT_ID`                                                                               |

Rotating `SERVER_SECRET` makes stored YouTube connections unreadable; they then
show as needing a reconnect.

Bindings: `DB` (D1), `TEAM` (the `TeamObject` namespace and its container),
`ASSETS` (`public/`), and the rate limits `AUTH_LIMIT` and `REDEEM_LIMIT`. A daily
cron trigger runs the sweep in `src/worker/sweep.ts`.

### Node server

| Variable                                                    | Purpose                                                                       |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `SERVER_SECRET`                                             | Required, at least 16 characters. Keys match credentials and SRT secrets      |
| `HOME_TOKEN`                                                | Required, at least 16 characters. The worker's bearer token                   |
| `PUBLIC_URL`                                                | Base URL in setup and join links; minting links needs it                      |
| `PORT`, `HOST`                                              | Listen address (default `0.0.0.0:8787`)                                       |
| `DATABASE_PATH`                                             | SQLite file (default `data/scorebug.sqlite`)                                  |
| `RELAY_API_URL`, `RELAY_API_USERNAME`, `RELAY_API_PASSWORD` | MediaMTX management API; set all three or none                                |
| `INGEST_HOST`, `INGEST_PORT`                                | Relay SRT address (port default 8890); `INGEST_HOST` is required with a relay |
| `INGEST_PUBLISH_HOST`, `INGEST_PUBLISH_PORT`                | Separate SRT address for the phone; set both or neither                       |
| `SRT_PUBLISH_PACING`, `SRT_PUBLISH_PEER_LATENCY_MS`         | Optional SRT publisher tuning handed to the phone                             |
| `WORKER_ID`, `OUTPUT_ID`                                    | Default worker and output for broadcasts; set both or neither                 |
| `CORS_ORIGINS`                                              | Comma-separated CORS origins (default `*`)                                    |
| `LOG_LEVEL`                                                 | `debug`, `info` (default), `warn` or `error`                                  |

`src/config.ts` validates these at startup.

Admin commands run against the same database:
`node dist/cli.js setup-link | devices | revoke-device ID | destinations | seed-destination`
(`node dist/cli.js` with no command prints usage).

## Deploy

**Hosted.** `.github/workflows/deploy.yml` deploys on every push to `main` that
touches this package, `apps/home-daemon`, `packages/protocol` or the lockfile. It
runs `wrangler d1 migrations apply scorebug --remote`, then `wrangler deploy`,
which also builds and pushes the match container image. Deploys queue rather than
cancel, so a migration is never left without its code.

**Self-hosted.** `apps/control-plane/Dockerfile` builds the Node server image from
the repository root. `infra/vps/docker-compose.yml` runs it with the relay and
Caddy. See [docs/self-hosting.md](../../docs/self-hosting.md).

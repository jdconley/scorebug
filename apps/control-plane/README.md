# @scorebug/control-plane

The Scorebug API: a Cloudflare Worker behind `https://scorebug.live` (`src/worker/`,
`wrangler.jsonc`). It handles Google sign-in, teams, team invites, YouTube channels,
the public pages and the `/admin` page. Storage is D1 (`migrations/`). Each team has a
`TeamObject` Durable Object that holds its matches and runs the match container, built
from `apps/home-daemon/Dockerfile`, which pulls the match from Cloudflare Stream and
pushes it to YouTube.

The team object serves the match routes in `src/routes/` (matches, scoring commands,
media, match join codes and the container's worker API) over its own SQLite storage.
They use `src/matches-store.ts`, `src/scoring.ts`, `src/media-store.ts` and
`src/worker-observations.ts`. `src/worker/hosted-media.ts` creates the match's Stream
input and YouTube broadcast and starts and stops the container. See
[docs/architecture.md](../../docs/architecture.md) for how the pieces fit and
[docs/api.md](../../docs/api.md) for the HTTP API.

## Develop

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

## Test

| Command                                             | Runs                                                              |
| --------------------------------------------------- | ----------------------------------------------------------------- |
| `pnpm --filter @scorebug/control-plane test`        | `test/**/*.test.ts` in Node (`vitest.config.ts`)                  |
| `pnpm --filter @scorebug/control-plane test:worker` | `test-worker/**/*.test.ts` in workerd (`vitest.worker.config.ts`) |
| `pnpm --filter @scorebug/control-plane typecheck`   | Both TypeScript configs (`tsconfig.json`, `tsconfig.worker.json`) |

The Node tests cover the stores and the match routes, composed as the team object
composes them (`test/helpers.ts`), on `node:sqlite` (`test/sqlite.ts`). The Worker
tests run through `@cloudflare/vitest-plugin` with the bindings from
`wrangler.jsonc` and test values for the secrets. Each test starts from empty D1 and
Durable Object storage with the migrations applied. Google, YouTube and Stream are faked (`test-worker/fake-google.ts`,
`test-worker/fake-media.ts`). Both test scripts build `@scorebug/protocol` first.

## Configuration

Vars, in `wrangler.jsonc`:

| Var                 | Purpose                                                                  |
| ------------------- | ------------------------------------------------------------------------ |
| `PUBLIC_URL`        | `https://scorebug.live`: OAuth callback, invite and join links           |
| `APP_AUTH_REDIRECT` | `scorebug://auth`: where sign-in and channel connections return          |
| `APP_STORE_URL`     | The app's App Store page; empty shows "Coming soon" on the site          |
| `GOOGLE_CLIENT_ID`  | Google OAuth client                                                      |
| `CF_ACCOUNT_ID`     | Cloudflare account that owns the Stream live inputs                      |
| `LIVE_MATCH_CAP`    | Service-wide live cap: concurrent live matches across every team (5)     |
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

## Deploy

`.github/workflows/deploy.yml` deploys on every push to `main` that
touches this package, `apps/home-daemon`, `packages/protocol` or the lockfile. It
runs `wrangler d1 migrations apply scorebug --remote`, then `wrangler deploy`,
which also builds and pushes the match container image. Deploys queue rather than
cancel, so a migration is never left without its code.

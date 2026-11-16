# Development

## Install

- Node 22.13+ and pnpm 9.15.0 (`corepack enable` picks up the pinned version)
- Docker with Compose v2, for the relay, mock sink and container tests
- FFmpeg with SRT, drawtext, H.264 and AAC. On macOS use Homebrew's `ffmpeg-full`
  (`/opt/homebrew/opt/ffmpeg-full/bin`); the default `ffmpeg` formula lacks SRT and
  drawtext.
- For the iPhone and Watch apps: Xcode 26 and XcodeGen (`brew install xcodegen`)

```sh
pnpm install --frozen-lockfile
```

## Run the API locally

The dev stack runs the patched MediaMTX relay and a stock MediaMTX that stands in
for YouTube. All credentials in `infra/local` are public test values.

```sh
docker compose -f docker-compose.dev.yml build ingest   # first time only
pnpm local:up
pnpm dev:api
```

The API listens on `http://127.0.0.1:18787` with the settings in
`infra/local/.env.example`. Set up a phone or simulator with a one-time link from
`pnpm -s dev:setup-link`. The
relay takes SRT on `127.0.0.1:18890/udp`; the mock sink takes RTMP on
`127.0.0.1:11935`. Stop the stack with `pnpm local:down`.

To reach the API from a physical phone, run it with `HOST=0.0.0.0` and set
`INGEST_HOST` (or `INGEST_PUBLISH_HOST`/`INGEST_PUBLISH_PORT`) to the Mac's LAN
address, and publish the relay's SRT port on that interface.

## Run the worker locally

```sh
cp apps/home-daemon/.env.example apps/home-daemon/.env   # set FFMPEG_PATH, FONT_PATH
node --env-file=apps/home-daemon/.env apps/home-daemon/node_modules/tsx/dist/cli.mjs apps/home-daemon/src/index.ts
```

The example points at the local API and sends to the mock sink. When the phone
starts a broadcast, the API picks the one connected worker and the `OUTPUT_ID` it
registered (or `WORKER_ID`/`OUTPUT_ID` if the API has them set). See
[the worker README](../apps/home-daemon/README.md) for settings and deployment.

## iPhone and Watch apps

```sh
just ios-build
```

This generates the Xcode projects from `ios/Project.yml` and `ios/Scoring.yml` and
builds the Scorebug app (with the embedded Watch app) for the simulator. Open
`ios/Scorebug.xcodeproj` in Xcode to run on a simulator or device. The simulator
connects to `http://localhost:18787` by default. See [ios/README.md](../ios/README.md).

## Tests

| Command                      | What it checks                                                    | Needs             |
| ---------------------------- | ----------------------------------------------------------------- | ----------------- |
| `pnpm test`                  | Unit tests for every package, plus `scripts/test` node tests      | FFmpeg            |
| `pnpm test:scoring`          | Real API process: scoring and media state survive forced restarts | —                 |
| `pnpm test:relay`            | Real relay: SRT media, credentials and revocation                 | Docker, FFmpeg    |
| `pnpm test:local`            | The dev Compose stack starts with the expected relay config       | Docker            |
| `pnpm test:container`        | The control-plane image starts and serves HTTP                    | Docker            |
| `pnpm test:worker-container` | The worker image encodes and overlays real media                  | Docker, image tag |
| `pnpm -r typecheck`          | TypeScript                                                        | —                 |
| `pnpm format:check`          | Prettier                                                          | —                 |

`pnpm test:relay` expects the relay image `scorebug/ingest:drain-v1` (built by the
`docker compose ... build ingest` step above). `node scripts/test-vps-stack.mjs`
checks the `infra/vps` Compose stack. CI (`.github/workflows/ci.yml`) runs all of
these; `.github/workflows/native.yml` builds and tests the Apple apps.

Native tests run with Swift and Xcode:

```sh
swift test --package-path ios/Packages/ScorebugCore
```

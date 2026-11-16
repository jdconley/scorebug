# Scorebug

Live-stream a volleyball match to YouTube with a scoreboard on the video, run by one
parent in the stands.

An iPhone films the match, keeps a clean recording on the phone, and streams the
video to a small server. You keep score on that phone, on its paired Apple Watch,
or on a second phone. The server adds the score to the video and sends it to
YouTube.

## Status

The whole path works end to end on a development Mac: the iPhone and Watch apps
score a match, the phone records and streams, the worker draws the score on the
video and publishes it to a local stand-in for YouTube. It has not yet been used
with a real YouTube stream, on a remote server, or through a full match.

## How it fits together

```text
iPhone (film + record) ──SRT──▶ MediaMTX relay ──SRT──▶ worker (FFmpeg + score) ──RTMPS──▶ YouTube
iPhone scoring ──HTTPS──▶ control plane (Hono + SQLite) ◀──HTTPS── worker
Watch ◀──WatchConnectivity──▶ paired iPhone
```

See [docs/architecture.md](docs/architecture.md) for details.

## Repository layout

```text
ios/                  iPhone and Apple Watch apps (filming, recording, scoring)
apps/control-plane/   HTTP API: matches, scoring, credentials, broadcast state
apps/home-daemon/     Broadcast worker: pulls SRT, burns in the score, pushes RTMP(S)
packages/protocol/    Shared TypeScript contracts and JSON fixtures
vendor/MediaMTX/      Pinned MediaMTX relay with two small patches
vendor/HaishinKit/    Pinned HaishinKit streaming library for the iPhone app
infra/                Local fixture config and the VPS deployment
scripts/              Integration tests run in CI
```

## Quickstart

Requires Node 22.13+, pnpm 9.15.0, Docker, and FFmpeg with SRT and drawtext support.

```sh
pnpm install --frozen-lockfile
pnpm test
```

Run the API locally with a relay and a mock RTMP sink:

```sh
docker compose -f docker-compose.dev.yml build ingest   # first time only
pnpm local:up
pnpm dev:api                                            # http://127.0.0.1:18787
```

See [docs/development.md](docs/development.md) for the worker, the iPhone apps, and
the integration tests.

## License and security

[MIT](LICENSE) © Conley Chaos LLC. See [SECURITY.md](SECURITY.md) to report a
vulnerability.

# Scorebug

Live-stream a youth volleyball match to YouTube, with the score on the video, from
one iPhone in the stands.

The iPhone films the match, keeps a clean recording on the phone, and streams the
video to [scorebug.live](https://scorebug.live). You keep score on that phone, on
its paired Apple Watch, or on a second phone. The server draws the score on the
video and sends it to your team's YouTube channel.

## Status

Scorebug is in a free private beta at [scorebug.live](https://scorebug.live). The
iPhone app is on TestFlight. Access is invite-only, and accounts are added by hand.

The full path works in production: sign in with Google, connect a YouTube channel
once, tap **Go live**, and the match appears on YouTube with the score drawn on it.
The hosted service is the only one the current iPhone app supports.

## How it works

```text
iPhone (film + record) ──SRT──▶ Cloudflare Stream ──RTMPS──▶ match container (FFmpeg + score) ──RTMPS──▶ YouTube
iPhone / second phone scoring ──HTTPS──▶ Cloudflare Worker (Hono + D1) ──▶ team Durable Object
Watch ◀──WatchConnectivity──▶ paired iPhone
```

- **iPhone app** (`ios/`): signs in with Google, films, records to the phone, and
  publishes the video over SRT. Recording never depends on the network.
- **Worker** (`apps/control-plane`): a Cloudflare Worker that handles accounts,
  teams, YouTube channels, matches and scoring. Each team has a Durable Object that
  holds its live match.
- **Cloudflare Stream** takes in the phone's video. Each match gets its own Stream
  live input, deleted when the match ends.
- **Match container** (`apps/home-daemon`): a Cloudflare Container started for each
  live match. It pulls the video from Stream, burns in the score with FFmpeg, and
  pushes it to YouTube. It stops when the match ends, so nothing runs between
  matches.

See [docs/architecture.md](docs/architecture.md) for details and
[docs/api.md](docs/api.md) for the HTTP API.

## Repository layout

```text
ios/                  iPhone and Apple Watch apps (filming, recording, scoring)
apps/control-plane/   API: the Cloudflare Worker, plus a Node + SQLite build for self-hosting
apps/home-daemon/     Broadcast worker: pulls the video, burns in the score, pushes RTMP(S)
packages/protocol/    Shared TypeScript contracts and JSON fixtures
vendor/MediaMTX/      Pinned MediaMTX relay with two small patches (self-hosting)
vendor/HaishinKit/    Pinned HaishinKit streaming library for the iPhone app
infra/                Local fixture config and the self-hosted deployment
scripts/              Integration tests run in CI
docs/                 Architecture, API, development, field-test and self-hosting guides
```

## Develop

Requires Node 22.13+, pnpm 9.15.0, Docker, and FFmpeg with SRT, H.264 and AAC support.
The iPhone apps need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

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
the integration tests, and [ios/README.md](ios/README.md) for building the apps.

## Self-hosting

The repo also has a self-hosted server: a Node + SQLite API, a MediaMTX relay and the
same broadcast worker, set up by one installer script. The current iPhone app can't
connect to it, because the app signs in with Google and uses team routes only the
hosted service serves. See [docs/self-hosting.md](docs/self-hosting.md).

## Contributing

Issues and pull requests are welcome. CI runs the TypeScript tests and the Docker
images on every pull request, and the iPhone and Watch builds on pull requests that
touch `ios/`.

## License

[MIT](LICENSE) © Conley Chaos LLC.

Vendored code keeps its own license: [MediaMTX](vendor/MediaMTX/LICENSE) (MIT) and
[HaishinKit](vendor/HaishinKit/LICENSE.md) (BSD 3-Clause).

To report a vulnerability, see [SECURITY.md](SECURITY.md).

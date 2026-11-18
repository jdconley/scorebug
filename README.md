# Scorebug

Live-stream a youth volleyball match to YouTube, with the score on the video, from
one iPhone in the stands.

The iPhone films the match, keeps a clean recording on the phone, and streams the
video to [scorebug.live](https://scorebug.live). You keep score on that phone, on
its paired Apple Watch, or on a second phone. The server draws the score on the
video and sends it to your team's YouTube channel.

## Status

Scorebug is a free service at [scorebug.live](https://scorebug.live), open to anyone
with a Google account. The iPhone app is headed to the App Store; until then, builds
go to an internal TestFlight group.

The full path works in production: sign in with Google, connect a YouTube channel
once, tap **Go live**, and the match appears on YouTube with the score drawn on it.

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
apps/control-plane/   API: the Cloudflare Worker (Hono, D1, Durable Objects)
apps/home-daemon/     Broadcast worker: the match container that burns in the score
packages/protocol/    Shared TypeScript contracts and JSON fixtures
vendor/HaishinKit/    Pinned HaishinKit streaming library for the iPhone app
scripts/              Contract and container tests run in CI
docs/                 Architecture, API, development and field-test guides
```

## Develop

Requires Node 22.13+, pnpm 9.15.0, Docker, and FFmpeg with SRT, H.264 and AAC support.
The iPhone apps need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
pnpm install --frozen-lockfile
pnpm test
```

Run the Worker locally:

```sh
cp apps/control-plane/.dev.vars.example apps/control-plane/.dev.vars
pnpm --filter @scorebug/control-plane dev:worker          # http://localhost:8787
```

See [docs/development.md](docs/development.md) for local sign-in, going live, and
the tests, and [ios/README.md](ios/README.md) for building the apps.

## Contributing

Issues and pull requests are welcome. CI runs the TypeScript tests and the match
container image on every pull request, and the iPhone and Watch builds on pull requests that
touch `ios/`.

## License

[MIT](LICENSE) © Conley Chaos LLC.

Vendored [HaishinKit](vendor/HaishinKit/LICENSE.md) keeps its own license (BSD
3-Clause).

To report a vulnerability, see [SECURITY.md](SECURITY.md).

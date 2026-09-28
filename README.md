# Scorebug

Live streaming of volleyball games with a scoreboard, operated from the stands.
An iPhone films and keeps a clean local recording. Score from its paired Apple Watch
or the native Scorebug app on another iPhone, including a watch paired to that iPhone. A portable worker adds the score and sends the broadcast
to YouTube.

> Status: native iPhone/Watch scoring and clean recording/export have passing local
> and simulator checks. Adaptive streaming has laboratory recovery passes. Actual
> paired-Watch delivery, physical camera reliability, sustained 4K and other proxy
> hosts remain unqualified. Not ready for a real game; see the current plan below.

## Current plan

- [Architecture and requirements](docs/architecture.md)
- [Encoding formats and streaming protocols](docs/streaming-formats-and-protocols.md)
- [Delivery milestones and acceptance gates](docs/superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
- [Simulator acceptance and tested platform matrix](docs/simulator-acceptance.md)
- [Local, simulator, phone, and watch validation](docs/local-testing.md)
- [Native scoring API progress](docs/native-scoring-api.md)
- [Media control API and recovery evidence](docs/media-control-api.md)
- [Real SRT relay access and process supervision](docs/relay-conformance.md)
- [Native worker setup and local media checks](apps/home-daemon/README.md)
- [Worker status and native display](docs/worker-status.md)
- [Worker capabilities and startup preflight](docs/worker-capabilities.md)
- [Local sustained media qualification](docs/media-soak.md)
- [Capture SDK compatibility findings](docs/capture-sdk-compatibility.md)
- [Milestone 0 verification results](docs/milestone-0-results.md)

The plan prioritizes reliable local recording, adaptive live quality with a measured
24 fps floor during viable connectivity, watch scoring, and a worker that runs on
home or cloud systems. Qualify the Mac first, physical phone/watch next, and other
worker hosts afterward. Target iPhone 14 and newer, with capability-based support for
older phones; support the current OS and two prior release generations.

## Components

```text
ios/                    Native iPhone/Watch scoring, capture, archive and streaming
apps/scoring/           Legacy PWA prototype; superseded by native scoring
apps/control-plane/     Hono API and game state
apps/home-daemon/       Broadcast worker (name retained from initial implementation)
packages/protocol/      Shared TypeScript contracts
docs/                   Design and validation plans
infra/vps/              Persistent API and managed relay deployment configuration
```

The initial overlay is FFmpeg text. Animated graphics and player callouts are later
work; there is no separate overlay app yet. Local recording, native scoring and both proxy outputs are implemented; remaining
qualification is tracked in the plan.

## Development

Node 22.13+ and the repository-pinned pnpm 9.15.0 are used for the TypeScript apps.

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
pnpm run doctor
pnpm test:container
pnpm test:local
pnpm test:relay
pnpm test:worker software
```

Start the isolated fixtures with `pnpm local:up` and the local API with
`pnpm dev:api`. On a clean host, first build the maintained ingest with
`docker compose -f docker-compose.dev.yml build ingest`; retain an existing
`scorebug/ingest:drain-v1` image. The mock output sink remains stock
MediaMTX. Use `pnpm local:down` when finished. See [local testing](docs/local-testing.md)
and [device testing](docs/device-testing.md) for build and 100 ms worker-report defaults.

For `pnpm test:apple` and Apple development, see the validation runbook's Xcode, XcodeGen, and simulator
matrix. On this Mac use the installed `ffmpeg-full` binary for SRT and text overlays;
the default `ffmpeg` lacks those capabilities. Native macOS workers can use
VideoToolbox; a GPU is not required for lower-profile CPU operation.

The original production hostname is `scorebug.live`; deployment remains unverified.
Hosts and endpoints are configurable rather than fixed product requirements.

## License and security

[MIT](LICENSE) © Conley Chaos LLC. See [SECURITY.md](SECURITY.md) for disclosures.

# MediaMTX relay origin patch

Scorebug's qualification build uses MediaMTX 1.21.0, revision
`2c6727904fbf233615de74a6c54a9b94dbf6025d`, with a small diagnostic patch.
The MIT notice is retained in `LICENSE`. `upstream.json` pins the upstream archive
and touched-file hashes; `scorebug.patch` contains the source changes and Go tests.
Go dependencies remain pinned by the original `go.mod` / `go.sum`. The Docker build
checks the source archive SHA-256 and uses the pinned Go 1.26.1 builder image
with Alpine's version-pinned `patch=2.8-r0` build dependency.
Upstream asset downloaders independently check pinned HLS and RPi asset hashes.

The patch observes the actual first supported MPEG-TS callback passed through the
shared timestamp decoder, without changing the decoder output. A publisher's
private SRT API item includes optional `scorebugTransportClock`:

```json
{ "convention": "mpegts-ingress-origin-90k-v1", "originPTS": "9000" }
```

`originPTS` is the actual ingress PTS in 90 kHz ticks, in `[0, 2^33)`. The existing
API item `id` identifies its publisher connection; readers have separate IDs.
The origin may come from audio and is never inferred from a reader's first picture.
It is unavailable before the first callback, after publisher reader teardown,
for idle/read connections and for alwaysAvailable paths. Keep this API private and
authenticated. This primitive does not associate native attempts or worker reads,
and must not enable adaptive quality by itself.

Build on an ARM64 or AMD64 Docker host from the repository root:

```sh
docker build --platform linux/arm64 -t scorebug/ingest:clock-v1 vendor/MediaMTX
# Or select --platform linux/amd64 for an AMD64 deployment.
```

The image contains a static Linux binary and CA certificates. Mount a configured
`/mediamtx.yml`; the explicit config argument makes an absent file an error. For
local qualification the maintained fixture creates owned loopback listeners and
removes its containers:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:relay-origin
```

The existing `pnpm test:relay-clock` continues to characterize the stock relay.
To confirm that mapped qualification rejects missing metadata, explicitly require
it from the stock image (expected failure):

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-relay-clock.mjs \
  --mapping-image=bluenviron/mediamtx:1.21.0
```

See [the implementation plan](../../docs/superpowers/plans/2026-09-15-relay-origin-metadata.md)
and [boundary contract](../../docs/relay-clock-correspondence.md) for qualification
results and remaining production association work. This build is not yet selected
by the regular local or remote deployment configurations.

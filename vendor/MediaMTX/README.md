# MediaMTX relay metadata, recovery and probe accounting

Scorebug's qualification build uses MediaMTX 1.21.0, revision
`2c6727904fbf233615de74a6c54a9b94dbf6025d`, with relay metadata, bounded H.264 reader recovery and pre-demux probe accounting patches.
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

The clock-v2 build also exposes optional `scorebugReaderSource` on private SRT
reader items. The descriptor is copied from the source selected by the path's
serialized AddReader operation, together with that Stream, then captured when
the SRT reader attaches. For a non-alwaysAvailable SRT source it contains:

```json
{ "type": "srtConn", "id": "<publisher UUID>" }
```

The enclosing API item identifies the reader UUID and path. This is the selected
source identity, not a later lookup of the current path or proof of frame delivery.
Copies keep old snapshots independent of subsequent source replacement; the field
is cleared on reader exit. Idle/publisher connections, unsupported sources and
alwaysAvailable paths omit it. The publisher-only clock metadata stays unchanged.
Production worker pipeline reads still need their own authenticated association;
the qualification fixture's read query is only a unique test marker.

Build on an ARM64 or AMD64 Docker host from the repository root:

```sh
docker build --platform linux/arm64 -t scorebug/ingest:staged-probe-v2 vendor/MediaMTX
# Or select --platform linux/amd64 for an AMD64 deployment.
```

Current cumulative source must use the fresh `staged-probe-v2` tag. Preserve the
previously qualified `receiver-probe-v1` and `recovery-v1` images.

The image contains a static Linux binary and CA certificates. Mount a configured
`/mediamtx.yml`; the explicit config argument makes an absent file an error. For
local qualification the maintained fixture creates owned loopback listeners and
removes its containers:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:relay-origin
```

The mapped command requires actual origin and reader-source metadata for every
reader, in addition to its raw media checks. The existing `pnpm test:relay-clock`
continues to characterize the stock relay. To confirm that mapped qualification
rejects missing reader association, use the previously qualified clock-v1 image
(expected failure after its valid origin check):

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-relay-clock.mjs \
  --mapping-image=scorebug/ingest:clock-v1
```

The stock `bluenviron/mediamtx:1.21.0` image also fails mapped mode, earlier because
it has no origin metadata. Neither omission is filled with a guessed constant.

See the [origin plan](../../docs/superpowers/plans/2026-09-15-relay-origin-metadata.md),
[reader-source plan](../../docs/superpowers/plans/2026-09-15-relay-reader-source.md)
and [boundary contract](../../docs/relay-clock-correspondence.md) for qualification
results and remaining production association work. This build is not yet selected
by the regular local or remote deployment configurations.

## H.264 recovery qualification build

`recovery-v1` retains the clock-v2 origin and reader-source metadata. In the shared
MPEG-TS H.264 writer used by SRT reads/forwarding, a timing-extraction error starts
bounded resynchronization instead of immediately terminating the reader. Audio
continues. A fresh IDR needs current SPS/PPS and consistent timing-header references;
its original PTS is preserved and its DTS cannot precede the last emitted DTS.
Healthy B-frame extraction and upstream initial header parsing are preserved;
initial waiting is also bounded.

Recovery examines at most 128 bytes of each PPS/slice prefix, does not claim full
PPS or pixel decoding, and does not change upstream NAL handling before this helper.
It fails after 300 discarded access units or ten seconds, checked on arriving video.
There is no separate timer promising termination when no video arrives at all.
Missing/invalid pictures remain missing; independent downstream frame-loss and
freshness qualification must still pass. Test fixture constants derived from
mediacommon retain its notice in `LICENSE.mediacommon`.

Relevant Go tests, after applying the cumulative patch to the pinned archive:

```sh
go test ./internal/protocols/mpegts ./internal/servers/srt ./internal/forward/srt
go test -race ./internal/protocols/mpegts ./internal/servers/srt ./internal/forward/srt
```

See the [recovery plan](../../docs/superpowers/plans/2026-09-16-ingest-h264-recovery.md)
for red regressions, packaging evidence and pending native pressure qualification.
The regular local/remote deployment configurations remain unchanged.

## Receiver probe accounting

`receiver-probe-v1` retains the recovery-v1 behavior and adds a bounded publisher
reader wrapper. Before demultiplexing, it counts only complete seven-packet null
messages carrying the versioned probe identity, generation, rate, sequence and
packet ordinals. Other media and anonymous null packets do not count. The wrapper
passes every byte and read error through unchanged, retains one 188-byte partial
packet and scalar state for one attempt, and invalidates proof on malformed,
crossed, duplicated, missing, reversed or over-budget traffic. Invalidation does
not stop media.

The private authenticated publisher API item exposes `scorebugBandwidthProbe`
with convention `mpegts-null-probe-v1`, identity and decimal-string counters.
Receiver timestamps are elapsed nanoseconds since observer creation, measuring
pre-demux reads rather than exact network arrival. Independent snapshots include
complete delivered messages/payload bytes, pending packet count and optional
invalid reason. Teardown clears the observer; idle/read/replacement connections
cannot inherit it. Ordinary publishers omit the field.

The marker is not an authentication credential. Consumers must match the enclosing
publisher UUID and authenticated attempt proof, then the native probe UUID,
generation and offered rate. Missing/invalid/stale evidence cannot authorize a
quality upgrade. The native fixture selects this image only for explicit bandwidth
probe runs, verifies signed publication scope, bounds request/response clock
correspondence and requires all accepted probe messages to arrive. Production
freshness/interval and candidate-cost admission are still separate work.

See the [receiver accounting plan](../../docs/superpowers/plans/2026-09-16-receiver-probe-accounting.md).
The regular deployment configurations and previously tagged recovery-v1 image
remain unchanged.

## Staged probe wire foundation

The cumulative `staged-probe-wire-v2` build preserves `SBUGPRB1` accounting and
adds explicit `SBUGPRB2` parsing. Build a fresh tag for this source:

```sh
docker build --platform linux/arm64 -t scorebug/ingest:staged-probe-v2 vendor/MediaMTX
```

V2 keeps bytes 0–48 of each packet's v1 layout except for the version marker.
Bytes 49–52 carry a big-endian stage in 1...32; bytes 53–187 remain `0xff`.
The first observed stage may exceed one. Replacement requires a higher stage,
a different current UUID, the same publishing generation, sequence/ordinal zero,
and a complete prior message. Stages may skip numbers and change offered rate.
Stage plus UUID is the identity; a UUID from an older stage may return at a later
stage. The observer retains no retired-UUID collection.

Stage replacement resets current-stage message/byte counters and first/last
delivery timestamps. The receiver clock, origin and cumulative complete-message
payload persist; the 16 MiB cap spans every stage in the connection. Same-stage
identity/rate changes, old stages, mixed wire versions, incomplete transitions
and malformed input permanently invalidate evidence without changing media bytes
or read errors. Private publisher snapshots use `mpegts-null-probe-v2`, numeric
`stage` and decimal-string `totalDeliveredPayloadBytes`; existing counter fields
refer to the current stage. V1 snapshots omit the two new fields.

This is a wire and accounting foundation only. Default native probes emit v1;
explicit staged native APIs and a bounded DEBUG scheduler emit v2. Finite
simulator relay/media qualification is recorded below. Authenticated status validates v2 stage and cumulative counters;
shared native matching additionally requires the locally owned stage.
Fixture defaults and regular deployments are unchanged. The previously qualified
`receiver-probe-v1` image remains frozen; its qualification does not cover this
new cumulative source. Repeated native SRT stages, capacity/admission decisions,
physical-device behavior and deployment have not been qualified by these Go tests.
See the [staged wire plan](../../docs/superpowers/plans/2026-09-17-staged-probe-wire.md).

## Staged simulator qualification

The native fixture accepts `SCOREBUG_TEST_BANDWIDTH_PROBE=staged` only with
fixed `540p30`, `blocks16` motion, authenticated publication and worker processing,
a direct RTMP recorder and a bounded 90–600 second hold. It selects
`scorebug/ingest:staged-probe-v2`, records its immutable image ID and runs that ID.
Legacy probe modes retain the frozen `receiver-probe-v1` image.

Independent verifiers reconcile three ordered 500 kbps, 1 Mbps and 2 Mbps stages
against native lease/counter evidence, authenticated relay polling and native
receiver intervals. They preserve the publication clock and cumulative byte
budget across replacements, and reject contradictory endpoint histories.
These rates describe offered probe load; successful delivery alone does not
establish spare capacity or authorize a quality increase.

See the [staged qualification plan](../../docs/superpowers/plans/2026-09-17-staged-probe-qualification.md)
for current test results and the real-media qualification boundary.

The complete iPhone 14/iOS 17.5 simulator run `native-app-PnVEYX` reconciled all
3,411,072 accepted probe payload bytes and 18 independently bracketed intervals
(six per stage). Three boundary intervals were excluded from qualified coverage.
The independent 1080p archive and 540p live output decoded without source loss;
all expected audio markers survived. This finite result does not qualify spare
capacity, automatic quality increases, physical devices or remote deployments.

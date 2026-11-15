# Verified encoder configuration boundaries

The native publisher can now identify the verified configuration associated with
an actual encoder submission and its qualifying completion. This prepares the
bitrate policy for runtime integration; automatic adaptation remains disabled.

`SRTPublisher.setBitRateWithReceipt` returns a publishing generation, configuration
UUID, encoder-session UUID, verified bitrate, acceptance uptime, and the last
successful raw source PTS submitted before that write. The existing `setBitRate`
API delegates to the same operation. A receipt requires successful native property
writes/readback and the existing lifecycle and cancellation checks.

An optional immutable observer receives source/output PTS, session/configuration
identity and submission/completion uptime. The encoder captures these scalars before
submitting the frame. A delayed callback cannot acquire a newer configuration, even
after another write, native session replacement or stop. The observer uses the
existing native qualification path: errors, dropped frames, malformed timestamps,
decompression and compressed passthrough never become encoding evidence. It does
no per-frame task scheduling or I/O and retains no media buffer.

Initial settings and legacy unchecked updates have no verified configuration.
Every verified write, including an identical bitrate, gets a fresh UUID. Native
session replacement resets the configuration and last-submission boundary. Failed
writes or invalidation cannot produce a current receipt. Historical callbacks can
still describe successfully submitted frames from a retired or failed session;
consumers must retain their attempt ownership and never treat arrival as freshness.
Raw marker buffers without an image do not advance the native submission boundary.

These boundaries describe accepted settings at submission. They do not claim an
individual encoded frame immediately realizes the new average bitrate, identify a
resolution transition, or establish sustainable network capacity. The media fixture
measures rate convergence separately.

## Local qualification

The 14-second dual-output fixture changes live video from 6 to 2 Mbps at five seconds
while maintaining the clean archive. A lock-protected recorder stores at most 512
scalar completion descriptors and exports them after joined publisher stop. Overflow
is explicit and fails qualification. No JSON is produced from encoder callbacks.
Each scenario persists its complete structured `*-events.json` separately from the
bounded diagnostic log tail, so the receipt and all descriptors remain replayable.

The independent JavaScript oracle checks all 420 native source identities against
decoded archive barcodes and, for normal/recoverable streams, decoded live barcodes.
It verifies exact generation/session/configuration identity, the pre-write versus
post-write partition, rationally equal source/output PTS, exact receipt membership,
and valid monotonic submission/completion times. Callback order is unrestricted.
Source index matching permits at most one nanosecond of rounding because the
nonzero-origin fixture explicitly quantizes CMTime; receipt and output comparisons
remain exact. Corrupted, duplicate, missing, cross-session or relabeled evidence fails.
Overload still requires the complete archive and encoder evidence but reports live
corruption separately; it cannot claim complete receiver delivery.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:

```sh
swift test --package-path vendor/HaishinKit
swift test --package-path ios/Packages/ScorebugStreaming
pnpm test:tools
pnpm test:dual-output
pnpm test:native-network
xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
python3 vendor/HaishinKit/verify-scorebug-patch.py
```

The SDK regression suite covers interleaved delayed callbacks, repeated writes,
legacy settings, failed writes/conversion, notification during writes, session
replacement, stop, and marker input. One existing clock reuse test now uses graceful
`finish()` before republishing: aborting `close()` can cancel an in-flight socket send,
which intentionally fails the connection. The prior failed run is retained; socket
cancellation semantics and its dedicated regression remain unchanged.

The SDK patch is reconstructed from the preserved upstream baseline. All 162
original hashes must match after reverse application and forward application must
reproduce every patched source byte. Five added source primitives are included.

Runtime source/pressure-window alignment, policy acknowledgment, thermal and worker
pressure classification, real trial/rollback transients, resolution/keyframe changes,
and sustained device/network qualification remain before adaptive enablement.

## Verified results

Final checks pass: 133 SDK tests, 44 Streaming tests, 732 tooling tests including 26
oracle cases, the unsigned combined iPhone/Watch Release build, and all 162 original
SDK hashes plus exact patch round trip. Independent source review approves the final
implementation and evidence retention.

Default suite: `artifacts/qa/dual-output-2i77D4` (all five scenarios). Network suite:
`artifacts/qa/dual-output-3s6nEf` (transparent, recoverable loss/delay, overload).
All eight archives retain 420 frames. Each successful publisher exports 420 qualifying
frame descriptors, with frame 149 before the write and frame 150 first submitted with
the verified 2 Mbps configuration. Normal/recoverable live streams retain 420 frames;
normal bitrate measurement still confirms approximately 6 to 2 Mbps. Both final suites
replay successfully from saved structured events and decoded barcode files.

Overload intentionally fails strict live decode: 378 best-effort decoded frames have
invalid source identities, so fresh-frame/loss measurements remain unknown. The
archive and native submission history are complete; those facts do not qualify the
corrupted receiver output. Peak measured process RSS remains below 96 MiB.

The first successful default run (`dual-output-FRwoTH`) predates the complete event
retention fix and is superseded for replay by the final run above. Stale SwiftPM
source/ABI failures and the abort/reuse test failure are retained separately from
successful evidence. The evidence hash manifest is
`artifacts/qa/encoder-boundary-final-verification.json`.

## Configuration coverage of receiver source intervals

The production `VideoFrameObservationOwner` now retains optional validated scalar
encoding metadata alongside each encoded frame in its existing bounded source ring.
One owner admission updates the aggregate count and source history. Missing or
invalid metadata leaves valid source counts intact; it cannot create a verified
configuration. Capture entries never carry encoder metadata. Ring eviction and
close retain their previous bounded, immutable snapshot behavior.

`PublishingSourceInterval.encodingCoverage` classifies every encoded source frame
in the matched interval `(previous decoded endpoint, current decoded endpoint]`:

- `unavailable`: at least one included frame lacks valid native metadata.
- `unverified`: every included frame belongs to one native session, with no verified configuration.
- `mixed`: included frames span configurations or native sessions.
- `verified(configuration)`: all included frames share the same verified configuration.

The exclusive anchor does not belong to the interval. A new-configuration interval
can therefore begin immediately after an old anchor. Leading and interior receiver
losses remain in the source denominator and configuration check. An absent decoded
frame cannot hide an older configuration. Closed history describes the completed
attempt and does not imply current readiness or freshness.

The dual-output fixture now exercises this production owner and exports its full
closed encoded history, aggregate callback counts and three declared interval
probes around the actual verified write boundary. These probes use finite-fixture
receiver endpoints over real source history; they are not production worker reports.
Independent checks compare every history record with its native callback descriptor,
require exactly one aggregate completion per retained frame, and check unverified,
verified and mixed intervals with exact rational boundaries. Existing decoded media,
A/V, bitrate, cadence and archive gates still run separately.

This completes configuration association for matched source intervals. The app's
initial unchecked settings remain unverified, and automatic bitrate control remains
disabled. Runtime control still needs verified startup/application acknowledgment,
source and pressure window alignment, deadline ownership, and actual trial/rollback
qualification before these classifications can govern live adaptation.

The source-interval checkpoint passes 198 Media tests, 51 Streaming tests, 755 tooling
tests (23 new history-oracle cases) and the combined unsigned iPhone/Watch Release
build. Independent review approves the final source. Default evidence is
`artifacts/qa/dual-output-Bzn0sg`; network evidence is `artifacts/qa/dual-output-uerkep`.
All eight archives retain 420 frames, and all five successful publishers retain 420
matching native descriptors, source-history entries and aggregate callbacks. Each
set of declared interval probes reports unverified, verified and mixed coverage as
expected. Normal/recoverable live media retain 420 frames; overload fails strict live
decode with 394 best-effort frames and invalid source identities. Both suites replay
from saved structured events and barcode files. Evidence hashes are in
`artifacts/qa/configuration-interval-final-verification.json`.

## Owned publishing bitrate updates

`PublishingBitRateChange` is a platform-neutral, immutable receipt containing the
native publishing generation, verified configuration, acceptance uptime and optional
last prior submitted source PTS. `SRTPublisher` and `SRTMediaPublisher` forward the
same receipt. The legacy void setter uses the same single-update gate.

`PublishingSession.setVideoBitRate(_:before:)` owns one mutation task and one deadline
task per request. The optional deadline uses system uptime and is capped at two
seconds from entry. Invalid rates/deadlines, an inactive session, an already-cancelled
caller or an overlapping request fail without dispatch or changing live state.
Admission and dispatch both check current expiry. After reservation, cancellation,
timeout, native failure or an unverifiable receipt retires the live attempt. Shutdown
calls publisher stop to release suspended operations and joins the mutation and timer,
as well as its existing workers. The publisher must cooperate with stop or complete
in bounded time; a timer cannot interrupt a blocked synchronous native call.

Acceptance checks the requested rate, current health, native generation against any
known clock and prior receipt, a fresh configuration UUID, and acceptance time inside
the request deadline. The prior source boundary cannot disappear or move backward
within the same encoder session; a replacement encoder session can reset it. A clock
first observed after acceptance must also agree with that receipt's generation, or
clock evidence is quarantined for the remainder of the attempt. The last accepted
receipt stays explicitly historical after shutdown. It does not prove bitrate
convergence, receiver delivery or current health.

Controlled Media tests qualify ownership, deadlines and cancellation, including a
publisher write that remains suspended after stop until a second completion gate
releases. The dual-output fixture separately qualifies the real typed SRT adapter
with direct asynchronous appends and its existing native drain. It does not claim to
exercise PublishingSession's bounded mailbox or introduce a graceful mailbox drain.

Automatic control remains disabled. Verified startup and policy acknowledgment,
aligned source/pressure windows, and actual automatic trial/rollback qualification
remain required. Local archive ownership and settings are independent of this API.

The owned-update checkpoint passes 213 Media, 52 Streaming and 755 tooling tests,
independent source review and the combined unsigned iPhone/Watch Release build.
Native evidence is `artifacts/qa/dual-output-bnx985` and
`artifacts/qa/dual-output-I0yfww`: all eight archives retain 420 frames, and all five
successful publishers retain matching 420-frame submission/history evidence.
Normal/recoverable live media remain complete. Overload fails strict live decode
with 377 best-effort frames and invalid source identities; fresh-frame/loss metrics
remain unknown. Saved evidence replays for both suites. The evidence manifest is
`artifacts/qa/owned-bitrate-final-verification.json`.

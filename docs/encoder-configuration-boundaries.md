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

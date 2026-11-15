# Encoder configuration boundary implementation plan

> **For agentic workers:** Execute inline with tests before behavior and bounded
> independent review. Parent owns all native/Swift/media execution.

**Goal:** Identify the verified configuration associated with each actual raw-video
submission and its qualifying native completion, without relabeling delayed frames.

**Architecture:** Capture immutable configuration/session IDs in the existing native
completion-observer path. Return a receipt containing the accepted configuration,
acceptance uptime and last successful raw native submission before the write.
Propagate this through the production adapter and qualify with real frame/barcode
media output. No quality controller or archive behavior is enabled/changed here.

**Tech stack:** Pinned Swift HaishinKit patch, VideoToolbox, production Streaming
adapter, fake delayed callbacks, real dual-output fixture and independent Node oracle.

## Contract

A configuration is a UUID ID, native encoder session UUID and verified video bitrate.
The session ID comes from the installed invalidation revision; a new native session
cannot reuse old verified configuration. Initial or legacy unchecked configuration
is explicitly nil until a verified update succeeds. Each successful verified update,
including same-rate writes, creates a distinct immutable configuration ID.

Each completion descriptor contains source/output PTS, native encoder session ID,
optional verified configuration, submission uptime and completion uptime. Construct
the existing observer wrapper before raw `convert` and retain only these scalars and
immutable observers. Notify only through the existing qualifying encoder callback,
so dropped/error/invalid/compressed-passthrough cases retain their existing behavior.
No per-frame task, I/O, blocking flush, mutable-codec capture or media retention.

A receipt records new configuration, acceptance uptime, and last submitted source
PTS from before the write. Track this PTS separately from the frame-rate limiter;
raw buffers without an image must not invent a native submission. Native convert
failure cannot advance it. It resets on native session recreation/stop. Verification
failure or concurrent invalidation cannot publish a receipt or new configuration.
Legacy setters clear current verified configuration. Old callbacks retain their
captured historical identity even after replacement or stop.

These are accepted-configuration submission boundaries, not a claim that the rate
controller's first new frame has an independently measurable new target size. Rate
convergence, source/worker policy alignment and resolution transitions remain distinct.

## Tasks

- [x] Preserve a reconstructed original SDK baseline and verify maintained patch
      provenance before edits. Add public immutable configuration/receipt/frame types
      in `HaishinKit/Sources/Codec/VideoEncoderConfiguration.swift` and a parallel optional
      observer argument through VideoCodec, OutgoingStream and SRTStream. Keep the old
      observer API and ordinary setter compatible.
- [x] Write delayed fake-session tests for old/new callback interleaving, same-rate
      IDs, failed writes, legacy writes, invalidation/recreation/stop, no-image input,
      and last-submission boundary. Compile stubs and capture behavioral red, then
      implement descriptor capture and receipt creation after successful verification.
- [x] Add `SRTStream.setVerifiedVideoBitRateWithReceipt` scoped to current publishing
      generation, with the old setter delegating to it. Wrap SDK descriptor types in
      SRTPublisher's public adapter types and expose optional frame observer plus
      `setBitRateWithReceipt`; keep lifecycle/cancellation guards and ordinary setter.
- [x] Extend the real dual-output fixture with a bounded scalar descriptor recorder.
      Export joined records and change receipt, independently verify old/unverified
      versus new configuration source PTS and decoded source barcodes, and preserve
      existing bitrate, frame, A/V, clock, pressure-window and archive gates.
- [x] Run SDK/Streaming tests, both native suites if their shared path changes,
      full tooling tests and combined unsigned iPhone/Watch Release build. Review source,
      regenerate the patch from the preserved original hashes, verify exact round trip,
      document evidence/limits and commit only verified work.

New files: SDK configuration types and focused SDK regression tests;
`scripts/encoder-configuration-evidence.mjs` and its tests; boundary runbook.
Existing files: codec/outgoing/SRTStream, SRTPublisher, native DualOutputSmoke,
`test-dual-output.mjs`, SDK patch/verifier/README, adaptive telemetry docs.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:
`swift test --package-path vendor/HaishinKit`,
`swift test --package-path ios/Packages/ScorebugStreaming`,
`pnpm test:dual-output`, `pnpm test:native-network`, `pnpm test:tools`, and
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

## Verified checkpoint

SDK 133 tests (six new configuration tests), Streaming 44, tooling 732 (26 new oracle
cases), both native suites, the combined unsigned iPhone/Watch Release build and
all 162 upstream hash/patch round-trip checks pass. Independent review approved the
SDK/adapter and fixture/oracle after adding complete structured event retention and
correcting the exact-rational regression input.

Final default evidence: `artifacts/qa/dual-output-2i77D4`; impairment evidence:
`artifacts/qa/dual-output-3s6nEf`. All eight scenario archives retain 420 frames. Each
successful publisher has 420 qualifying configuration descriptors, partitioned at
149/150 around the verified write. Normal and recoverable live media retain 420 frames.
Overload strict live decode fails, with 378 best-effort frames and invalid identities;
its fresh-frame/loss metrics remain unknown. Both final suites replay from retained
structured events and decoded barcode files. No receiver-delivery claim is inferred
from encoder callbacks.

Retained diagnostic failures: stale SwiftPM source discovery before the new SDK file
was included (owned probe cache cleaned), stale SDK ABI link before its owned cache
clean, and the existing abort/reuse clock-test race. The reuse test now drains via
finish rather than assuming abort can preserve an in-flight socket. Dedicated
terminal-cancellation behavior remains unchanged and tested. Initial successful
native run `dual-output-FRwoTH` preceded the raw-event retention fix; final evidence
uses the repeated default run above.

Hashes and exact commands/results are recorded in
`artifacts/qa/encoder-boundary-final-verification.json`. Runtime adaptive integration,
source/pressure alignment, real trial/rollback media behavior, resolution changes and
physical Watch/phone/remote-host qualification remain open in the parent plan.

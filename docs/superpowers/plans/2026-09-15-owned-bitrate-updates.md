# Owned bitrate updates implementation plan

> **For agentic workers:** Execute inline with failing behavioral tests before
> implementation and bounded independent review. Parent owns native/Swift/media runs.

**Goal:** Make verified bitrate mutation an owned publishing-session operation that
returns a platform-neutral receipt and cannot outlive terminal shutdown unnoticed.

**Architecture:** Add a validated immutable receipt in ScorebugMedia and a typed
MediaPublisher mutation. SRT adapters preserve native verification and lifecycle
checks. PublishingSession serializes changes, owns their deadline/cancellation,
validates receipts against its attempt, and retains accepted historical evidence.

**Tech stack:** Swift concurrency/locks, existing SRT/VideoToolbox verification,
controlled fake operations, real native dual-output media qualification.

## Contract

`PublishingBitRateChange` carries positive publishing generation, validated encoding
configuration, finite nonnegative acceptance uptime and optional numeric epoch-zero
prior submitted source PTS. SRTPublisher exposes this value through its existing
receipt API; SRTMediaPublisher adds `setVideoBitRate` and keeps the old void setter.
The protocol default reports unsupported mutation without exposing implementation
or destination details. Existing publishers remain source-compatible.

`PublishingSession.setVideoBitRate(_:before:)` accepts an optional system-uptime
expiry. Its effective deadline is the earlier of caller expiry and two seconds
from request entry. Invalid rate/deadline, inactive session, already-cancelled
caller or concurrent request fails before dispatch without changing live state.
Admission and predispatch both check fresh expiry. After reservation, one owned task runs the publisher operation. A separate owned
deadline task may terminate the live attempt; there are no per-frame tasks.

A successful receipt must match requested bitrate, known native publishing generation
(from accepted clock and previous receipt), acceptance between request and validation
within deadline, a fresh configuration UUID and nondecreasing prior source boundary
within the same encoder session. Native session replacement may reset that boundary.
A clock first observed after a receipt must agree with that generation or be quarantined.
Health must still hold when validation commits. Only accepted receipts update the
snapshot; the latest accepted receipt remains explicitly historical after stop.

Once dispatched, error, uncertain/mismatched receipt, timeout or caller cancellation
retires this live publishing attempt. Shutdown cancels the operation and timer, calls
publisher.stop to unblock suspended work, and joins all owned tasks. An operation
must not join shutdown from inside a task shutdown itself must join. Stale timers
cannot stop a later completed request. Existing first-terminal-failure semantics,
bounded ingress, archive independence and stop ownership remain intact. The underlying
publisher contract requires bounded operations or cooperation with stop; a Swift
timer cannot forcibly terminate a blocked synchronous native API.

## Tasks and evidence

- [x] Add receipt/API stubs and focused Media tests. Exercise invalid scalars,
  inactive/cancelled/overlapping calls, healthy acceptance, historical retention,
  native errors, mismatch/reused UUID/backward boundary, deadline expiry, stop and
  caller cancellation during suspended writes, and stop joining late completion.
  Use bounded gates; record behavioral red before implementation.
- [x] Implement `PublishingBitRateChange.swift`, MediaPublisher default method,
  session-owned update/deadline tasks and snapshot history. Keep cancellation handlers
  outside locks. Split locked shutdown creation from request entry so deadline and
  completion checks are atomic with state transitions.
- [x] Forward typed receipts through SRTPublisher and SRTMediaPublisher; preserve
  the old setter and shared single-update gate. Extend existing adapter lifecycle
  tests to check typed values and failure/stop/cancellation rejection.
- [x] Use SRTMediaPublisher's typed path in the real dual-output fixture while
  preserving its direct asynchronous append/drain semantics and all existing gates.
  This qualifies the adapter with real encoding; controlled Media tests separately
  qualify session task ownership. Do not invent a graceful session drain or bypass
  the production ingress contract just to make a fixture pass.
- [x] Run Media/Streaming/tooling tests, both native suites and combined unsigned
  iPhone/Watch Release build. Obtain bounded independent review, preserve evidence
  hashes and raw events, document the ownership contract and remaining policy work,
  then commit verified source.

## Files and commands

Create Media `Sources/ScorebugMedia/PublishingBitRateChange.swift` and
`Tests/ScorebugMediaTests/PublishingBitRateUpdateTests.swift`. Modify
`PublishingSession.swift`, Streaming `SRTPublisher.swift`, `SRTMediaPublisher.swift`
and its tests, and `tools/media-sdk-probe/Sources/DualOutputSmoke/DualOutputSmoke.swift`.
Update configuration-boundary and adaptive telemetry docs.

Example invariant: suspend the publisher write, request stop, let publisher.stop
release that write into a second completion gate; stop must remain pending until
that gate releases, the update must fail, and no receipt may enter the snapshot.
Example receipt rejection: after accepting generation7/configurationA, reject
another receipt reusing A or generation8 even when the requested bitrate matches.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:
`swift test --package-path ios/Packages/ScorebugMedia`,
`swift test --package-path ios/Packages/ScorebugStreaming`, `pnpm test:tools`,
`pnpm test:dual-output`, `pnpm test:native-network`, and
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

Automatic quality control remains disabled until verified startup/application receipts
are bound to policy acknowledgments and aligned source/pressure windows, followed by
actual automatic trial/rollback qualification. Physical/radio/remote-host gates remain.


## Verified checkpoint

Behavioral red is preserved in `artifacts/qa/owned-bitrate-media-red.log`,
`owned-bitrate-streaming-red.log`, and `owned-bitrate-review-red.log`. Initial test
compilation diagnostics are retained separately. The complete Media suite passes
213 tests (158 XCTest plus 55 Swift Testing), including 15 new ownership/receipt
cases. Streaming passes 52 tests; tooling passes 755. The combined unsigned
Scorebug iPhone/Watch Release build passes with Xcode 26.2.

Independent review found and then approved fixes for a first clock contradicting
an earlier receipt and expiry between entry/admission/dispatch. Added regressions
also cover replacement encoder sessions, missing same-session boundaries, stale
prior deadlines, and the two-second cap. Review was source-only; the parent ran all
Swift/native/build checks sequentially.

Default native evidence: `artifacts/qa/dual-output-bnx985`.
Network evidence: `artifacts/qa/dual-output-I0yfww`.
All eight archives contain 420 frames. All five successful publishers retain 420
native descriptors, matching source-history records and aggregate callbacks, with
the verified write boundary between frames 149 and 150. Normal and recoverable live
streams contain all 420 frames; measured payload changes from approximately 6 to
2 Mbps. Peak measured RSS remains below 96 MiB. Both suites replay successfully from
saved events and decoded barcode files.

The overload receiver fails strict decode: its 377 best-effort frames contain invalid
source identities, so fresh-frame rate/loss stay unknown. Complete source history
and clean local recording do not qualify this damaged live output. The fixture
qualifies typed SRTMediaPublisher operations; controlled Media tests qualify the
PublishingSession ownership layer. No automatic policy, resolution transition,
physical phone/watch/radio, remote-host or adaptive soak qualification is implied.

Source and complete native evidence hashes, including actual media files, are in
`artifacts/qa/owned-bitrate-final-verification.json`. The next slice must bind verified
startup and mutation receipts to policy acknowledgment and align source/pressure
windows before enabling automatic trials and rollback.

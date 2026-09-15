# Native publishing clock observation implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded
> Media/Streaming implementation and independent spec then quality review. One owner
> at a time runs Swift builds/tests or media qualification.

**Goal:** Expose the actual native muxer clock through publishing-session observations
and bind it to app recording/match/publishing scope for later remote correlation.

**Architecture:** Carry a small immutable Media descriptor converted from the SDK's
existing exact clock snapshot. Sample asynchronously in the existing session health
monitor; synchronous capture and local archive never query it. Retain historical
mapping through shutdown and quarantine contradictory descriptors. The app then
binds this descriptor to its observation scope and exports it in owned fixtures.

**Tech stack:** Swift actors, CoreMedia, ScorebugMedia/Streaming, XCTest, existing
native dual-output and iPhone/Watch validation.

## Design

`PublishingTransportClock` in ScorebugMedia is an immutable Equatable/Sendable scalar
value with `sourceOrigin: CMTime` and `publishingGeneration: UInt64`. A failable public
initializer accepts numeric positive-timescale epoch-zero origins and nonzero
publishing generations. Expose fixed `timescale = 90000`, `presentationLead = 9000`
and `wireModulus = 8589934592` constants with Int64-compatible types. The meaning is
`floor((source-origin)*90000)+9000` before wire modulo; it describes the existing SDK
projection, not a second implementation of arithmetic. Do not duplicate the exact
projection algorithm. SDK-origin conversion must copy the actual selected origin.

Add `func transportClock() async -> PublishingTransportClock?` to MediaPublisher,
with a default nil implementation for existing publishers. The method is diagnostic,
bounded/cancellation-cooperative, and stop must unblock it like health reads.
PublishingSessionSnapshot gains optional `transportClock`. The existing health
monitor queries after a healthy check, outside locks; after the await it rechecks
cancellation and publishing state before accepting evidence. Store the first known
mapping; repeated equal mappings are harmless. Nil means unavailable and does not
erase historical evidence. A different descriptor permanently makes that session's
mapping unknown, without failing media or archive. A new session starts clean.
Snapshot documentation explicitly says this is last-observed historical mapping,
retained after shutdown, not proof of current readiness, receipt or profile revision.

SRTPublisher.transportClock() obtains the SDK snapshot only for its captured active
generation, after native health validation, and rechecks stopping/cancellation and
active-generation identity after actor hops. SRTMediaPublisher forwards through
Operations and gates prepared/starting/stopped/unhealthy/cancelled reads, rechecking
state after suspension. Neither getter mutates encoder settings or owns shutdown.

App integration binds the cached descriptor to the existing VideoFrameObservationScope
and lifecycle. A start clears prior diagnostics; stale teardown cannot replace a
new attempt. Export only bounded scalar origin/generation fields (exact Int64/UInt64
as decimal strings) under matching scope. No worker loss comparison or adaptive
quality change is enabled by this descriptor. Worker session identity and matched
source intervals remain independent required work.

Polling is preferable to a new callback on every encoded frame: the origin is
immutable, the existing monitor already has lifecycle ownership, and observation
failure should leave recording/publishing usable. Inferring origin from the first
captured or remotely decoded frame would be wrong after unequal A/V startup or late
worker joins. The user's standing autonomy authorization covers this integration.

## Task 1: Media and Streaming foundation

**Files:** new `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/PublishingTransportClock.swift`,
`PublishingSession.swift`, Media tests; Streaming `SRTPublisher.swift`,
`SRTMediaPublisher.swift` and adapter tests.

- [x] Add descriptor and optional/default publisher getter API.
- [x] Write behavioral failing tests for origin validation; initially absent, later
  available/equal/nil/contradictory cached mappings; stop during a suspended read;
  retained history and replacement isolation. Add wrapper tests for prepared,
  starting, stopped, cancelled and unhealthy reads and stop while getter suspended.
- [x] Implement monitor sampling/caching with no callback tasks, outside locks and
  post-await state checks; implement exact SDK conversion and wrapper forwarding.
- [x] Run focused/full Media and Streaming tests and retain red/green evidence.
  Obtain specification and quality reviews of the foundation.

## Task 2: Actual native transport evidence

**Files:** `tools/media-sdk-probe/Sources/DualOutputSmoke/DualOutputSmoke.swift`,
`scripts/test-dual-output.mjs`, `scripts/publishing-clock-evidence.mjs` and tests.

- [x] Export the actual native adapter descriptor in the normal dual-output fixture
  after source production and before/after joined shutdown. Require a chosen mapping for
  normal and 123.25-second-origin publication; no guessed origin for recording-only
  or unavailable publication. Preserve all existing frame/A/V/rate/memory gates.
- [x] Compare the actual adapter origin exactly with this fixture's known common
  audio/video source origin (0 or 493/4 seconds). Validate full-width generation,
  fixed projection constants and unavailable clock after stop. Test the evidence
  checker against malformed/lossy/contradictory values. This fixture uses SRTPublisher
  directly; session caching/retention is covered by unit tests and the later app
  qualification, not relabeled as an existing dual-output behavior. Keep mapping
  availability separate from transport success in stalled/absent-receiver cases.
- [x] Clean the downstream package graph for the added source, run five-scenario
  dual-output, and compile combined Apple device/simulator targets as warranted.

## Task 3: App scope and fixture integration

**Files:** `ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`,
`VideoObservationFixture.swift`, associated Film model/export tests and native runner.

- [x] Expose a scoped clock observation tied to the existing logical recording,
  match, broadcast, publishing attempt and profile scope, with historical closure.
- [x] Test unavailable origins, early stop, stale teardown/replacement, diagnostic
  failure and scalar fixture serialization; no scope may silently borrow another
  session's descriptor. Retain exact rational origin and native generation.
- [x] Extend the native app qualification exporter/checker and run the complete
  local workflow, keeping local-recording, scoring, A/V and freshness gates intact.
- [x] Document actual evidence and remaining worker-session/matched-interval work.
  Complete specification/quality review and commit coherent verified checkpoints.

## Tasks 1–2 verification checkpoint

Media passes 112 XCTest and 55 Swift Testing tests; Streaming passes 25 XCTest
tests. Behavioral red evidence precedes both implementations. The exact evidence
checker adds 17 tests; the complete tools suite passes all 448 tests. Independent
specification and code-quality reviews approve the foundation and fixture code.

The five-scenario native run `artifacts/qa/dual-output-CKsfFc` exits 0. Every archive
contains all 420 source frames (0–419), full audio, zero archive rejections and
30 fresh frames/sec in every measured window, including stalled/absent receivers.
Both normal live streams also retain all 420 frames at 30 fps. The exported SDK
origin is exactly 0/1000 for the zero-origin fixture and 123250000000/1000000000
for the offset fixture; both use native generation 1, the documented constants,
and an unavailable direct adapter clock after joined shutdown. Peak RSS is 95.44
MiB across these runs. Source lag peaks at 24.254 ms; archive A/V marker error is
0.021 ms and live marker error stays below 65.365 ms. Existing qualification gates
remain unchanged.

Both downstream Swift package graphs needed cleaning after adding the Media source:
cleaning only media-sdk-probe left media-harness with a stale source list. The
latter failed before media execution; cleaning that graph resolved the build.
Apple device Release and arm64 simulator Debug builds are recorded separately.
Logs use `artifacts/qa/native-clock-observation-*`. This checkpoint does not claim
app scope/export integration or source-loss/capacity qualification.

## Task 3 implementation and test evidence

The app exposes `PublishingClockObservation` using the exact existing full video
observation scope. It clears old history before control-plane waits, samples only
cached session evidence, marks the mapping historical at capture detach, and
publishes final closed evidence only through the existing joined attempt guard.
Fixture export rejects mismatched scope or closure and preserves all Int64/UInt64
scalars as decimal strings. Missing diagnostics and contradictory mappings leave
recording and publication independent.

Behavioral red: 53 focused Swift tests compile with 11 expected failures before
implementation; the early-failure clearing test separately fails two assertions.
The implementation passes 53 focused tests and all 95 FilmModel tests. The final
full run also proves a valid native descriptor was read twice before checking that
an unavailable observation owner still produces no scoped clock and leaves
publication running. Independent specification and quality reviews approve.

The app qualification checker has 25 tests; its initial stub fails the 24 negative
cases. Together with the 17 existing exact-origin fixture cases, 42 focused tests
pass; the full tools suite passes 473 tests. The checker compares the exported
clock's full scope with the separately qualified capture/encode scope and requires
historical closure, exact scalar types/ranges and fixed projection constants. It
does not assume the app's muxer origin equals recording start: publishing starts
later, and a worker may join later still. Actual native workflow and final device
Release evidence are recorded below.

## Actual app workflow and remaining correspondence limit

`artifacts/qa/native-app-0YPFpe` completes with exit 0 on iOS 17.5 / iPhone 14
simulator using the explicit direct RTMP recorder and a 30-second hold. Both saved
MP4s fully decode. The archive contains 1,836 consecutive frames (0–1835), 61.2
seconds at 30 fps, with zero source loss. Live contains 1,427 consecutive frames
(229–1655), 47.567 source seconds at 30 fps, with no loss after acquisition and no
missing encoded tail. Frames 169–228 remain explicitly identified as the 60-frame
startup acquisition interval. Native capture counts 1,488 frames; encoder counts
1,487, with the leading capture frame preceding encoding. Eight complete steady
observation windows report 30 fps for both capture and encoding.

The closed app clock uses the exact matching full scope and actual SDK origin
7733/60, generation 1, and the documented constants. Two historical worker-age
proofs match independently collected windows. The native score update changes 339
overlay pixels; archive diagnostics finish without failure; owned worker/recorder
processes exit 0 and the owned simulator/container are cleaned. Archive A/V marker
error is 0.021 ms, live 65.25 ms; tail offsets are 4 ms and 27.372 ms respectively.
The combined iPhone/Watch device Release build exits 0 after app integration; the
actual workflow also builds/runs the Debug simulator app. Logs use
`artifacts/qa/native-clock-app-*`.

A separate exact-rational inspection reveals an unresolved **end-to-end clock
correspondence offset** in this successful media run. For barcode source frames
229 and 1655, source PTS = 493/4 + frame/30 and the reported native origin project
to 189000 and 4467000 ticks. Worker decoder endpoints instead report 178081 and
4456081: both differ by -10919 ticks (about -121.322 ms). Arithmetic is retained in
`artifacts/qa/native-clock-app-correspondence.json`. This does not invalidate the
scoped SDK-origin export or the fully decoded frame evidence, but it does prevent
claiming direct equality between native wire PTS and worker decoder PTS through
the owned SRT relay path. Earlier file/direct transport calibration did not establish
that end-to-end relay correspondence. The location/cause of the shift still needs
packet-level qualification; do not assume the relay is the cause without that
comparison, infer an origin from a late worker frame, or silently normalize it away.

Next work must qualify this complete path, expose public worker-session identity
(attempt 1 recurs after process replacement), and match source-interval counts.
Applied-profile boundaries and qualified available capacity remain necessary too.
Runtime adaptation stays disabled at the fixed 1080p30 profile. These short barcode
fixtures do not qualify physical cameras, Watch radios, high-motion capacity or
other GPU/cloud hosts.

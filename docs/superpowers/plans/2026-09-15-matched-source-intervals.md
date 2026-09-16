# Matched source interval implementation plan

> **For agentic workers:** Use the existing subagent-driven review workflow for
> independent bounded reviews. Parent owns implementation and all Swift/media
> execution in the validation worktree. No other checkout may be edited.

**Goal:** Derive capture, encoder and decoder counts for the same source interval,
including missing frames between consecutive worker windows, before adaptive policy
integration. This does not replace capacity, thermal or profile-transition work.

**Architecture:** Retain bounded rational source timestamps separately for capture
and actual encoding completion. On the control path, use the SDK's exact existing
TransportClock projection and authenticated relay origin to locate decoder boundaries
in that history. Scope consecutive reports in the app using native attempt/profile,
worker epoch/attempt, reader/publisher identity and clock. No network operation or
projection runs on the capture callback; no per-frame task or media retention.

**Tech stack:** CoreMedia, existing Swift Media/Streaming packages and native model,
existing authenticated worker status and real native A/V qualification fixture.

## Contract

An interval is `(previous decoded last PTS, current decoded last PTS]`. Its decoder
count is the current completed window's fresh-frame count. Only consecutive,
valid, nonempty worker windows with matching immutable scope may form it. This
includes missing frames before the current first decoded frame; using just the
current first/last endpoints would hide those losses. First acquisition, skipped
reports, empty windows, stale evidence and replaced scope remain unknown/gaps.

The Media ledger has fixed capacity per stage (default 2,048; legal 1...8,192),
preallocated ring storage, no buffer/media references, and constant append work.
Keep exact CMTime and monotonic callback time. Invalid/nonfinite/reversed clock,
nonnumeric/nonzero-epoch PTS, or duplicate/reordered PTS sticky-invalidates this
diagnostic history. Preserve retained scalar history and evicted counts; close
freezes it. Snapshots copy chronological scalars and cannot mutate earlier snapshots.
Timestamp progression proves neither image uniqueness nor missing camera callbacks.

Streaming's pure matcher reuses `SRTHaishinKit.TransportClock`; do not duplicate
projection arithmetic. Match modulo 2^33 after subtracting the actual relay origin,
then require the exact unwrapped boundary distance. Reject ambiguous whole-wrap
histories, absent/evicted boundaries, projection failure after origin, quantization
collisions, malformed decoder intervals/counts, or encoded samples lacking capture
provenance. Both boundaries and the current first decoded PTS must match actual
encoded samples. Capture and encoder denominators use the identical open/closed
source interval. Return immutable scope, source boundaries, capture callback times,
counts, capture-not-encoded, encoded-not-decoded and leading missing encoded frames.
These are historical PTS observations, not image uniqueness or viewer receipt.

## Task 1: Bounded history and exact interval primitive

Files: new Media `VideoSourceHistory.swift` and tests; new Streaming
`PublishingSourceInterval.swift` and tests. No runtime collection enabled yet.

- [x] Write executable failing tests for ring eviction and frozen snapshots,
  duplicate/reorder/epoch/clock quarantine, independent stages, close and bounds.
  Use the intended API:
  ```swift
  var history = try VideoSourceHistory(scope: scope, capacity: 512)
  history.observe(.captureVideo, sourcePTS: CMTime(value: 1, timescale: 30), at: 1)
  history.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30), at: 1)
  XCTAssertEqual(history.snapshot.capture.count, 1)
  ```
- [x] Implement the preallocated ledger and run focused/full Media tests:
  `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugMedia`.
- [x] Write failing matcher tests for healthy 150-frame intervals, leading/interior
  losses, capture-to-encoder drops, signed decoder PTS, wire wrap, rational origins,
  quantization collisions, eviction, wrong origin and impossible frame counts.
  ```swift
  let result = PublishingSourceInterval.match(history: history.snapshot, clock: clock,
      relayOriginPTS: origin, previousDecodedPTS: previous,
      firstDecodedPTS: first, lastDecodedPTS: last, decodedFrames: 145)
  XCTAssertEqual(result?.encodedFrames, 150)
  XCTAssertEqual(result?.encodedNotDecodedFrames, 5)
  XCTAssertEqual(result?.leadingMissingEncodedFrames, 5)
  ```
- [x] Implement exact matching with existing SDK projection, run focused/full
  Streaming tests and combined unsigned iPhone/Watch Release build; review and commit.

Task 1 evidence: the executable history stub failed 32 assertions in seven tests;
the matcher stub failed ten assertions across eleven tests. Final qualification
passes 174 Media tests and 39 Streaming tests, including fourteen focused matcher
tests, and the combined unsigned iPhone/Watch Release build. Independent review
approves the implementation. Added numerical regressions cover ambiguous retained
history, SDK projection failure after origin, overflowing decoder endpoint distance,
Int64.min source origins and uneven rational quantization. No app collection or
automatic policy integration is claimed by this foundation commit.

## Task 2: Native scoped consecutive-report integration

Files: VideoFrameObservationOwner, new native `WorkerSourceIntervalObservation.swift`,
CaptureStreamingModel, Film model tests and VideoObservationFixture.

- [ ] Add optional bounded history to the observation owner and explicitly enable
  it for production publishing. Sample PTS/time within the existing serialized
  callback. Snapshot on the control path; archive queues remain independent.
- [ ] Add a model accumulator accepting validatedPublication and
  WorkerDecodedVideoFreshness, plus scoped native clock/history. Baseline the first
  window; same sequence/equal immutable contents is a no-op, contradictory contents
  invalidate, next sequence alone may match. Any gap, expiry, empty/invalid window,
  scope/clock/profile change clears previous interval and re-baselines. A completed
  match remains historical; it must carry freshness separately for any policy use.
- [ ] Add model tests using exact deterministic local/remote timestamps, delayed
  duplicate reports, restart, gap, stale response, invalid history and capture stop.
- [ ] Export bounded matched evidence with the existing owned native fixture;
  validate exact source-frame denominators independently from barcode/native clock
  evidence, without treating export-time reconstruction as runtime measurement.

## Task 3: Runtime media qualification and policy handoff

- [ ] Run the existing full native streaming workflow with clock-v2 publication
  enabled and unchanged archive, A/V, frame, score, drain and cleanup gates.
- [ ] Add deterministic loss/gap fixtures that prove edge losses are counted and
  missing reports/acquisition are not misrepresented as successful intervals.
- [ ] Document measured evidence and outstanding capacity, pressure, monotonic
  window alignment and applied-profile-boundary requirements. Keep automatic
  quality changes disabled until those runtime inputs and impairment tests pass.

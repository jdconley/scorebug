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

- [ ] Add descriptor and optional/default publisher getter API.
- [ ] Write behavioral failing tests for origin validation; initially absent, later
  available/equal/nil/contradictory cached mappings; stop during a suspended read;
  retained history and replacement isolation. Add wrapper tests for prepared,
  starting, stopped, cancelled and unhealthy reads and stop while getter suspended.
- [ ] Implement monitor sampling/caching with no callback tasks, outside locks and
  post-await state checks; implement exact SDK conversion and wrapper forwarding.
- [ ] Run focused/full Media and Streaming tests and retain red/green evidence.
  Obtain specification and quality reviews of the foundation.

## Task 2: Actual native transport evidence

**Files:** `tools/media-sdk-probe/Sources/DualOutputSmoke/DualOutputSmoke.swift`,
`scripts/test-dual-output.mjs`.

- [ ] Export the actual session descriptor in the normal dual-output fixture after
  source production and before/after joined shutdown. Require a chosen mapping for
  normal and 123.25-second-origin publication; no guessed origin for recording-only
  or unavailable publication. Preserve all existing frame/A/V/rate/memory gates.
- [ ] Prove exact conversion by comparing actual chosen origin/generation against
  native adapter evidence or independently retained timestamps, without inferring
  origin from a late worker's first decoded frame. Keep mapping availability separate
  from live transport success in stalled/absent-receiver cases.
- [ ] Clean the downstream package graph for the added source, run five-scenario
  dual-output, and compile combined Apple device/simulator targets as warranted.

## Task 3: App scope and fixture integration

**Files:** `ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`,
`VideoObservationFixture.swift`, associated Film model/export tests and native runner.

- [ ] Expose a scoped clock observation tied to the existing logical recording,
  match, broadcast, publishing attempt and profile scope, with historical closure.
- [ ] Test unavailable origins, early stop, stale teardown/replacement, diagnostic
  failure and scalar fixture serialization; no scope may silently borrow another
  session's descriptor. Retain exact rational origin and native generation.
- [ ] Extend the native app qualification exporter/checker and run the complete
  local workflow, keeping local-recording, scoring, A/V and freshness gates intact.
- [ ] Document actual evidence and remaining worker-session/matched-interval work.
  Complete specification/quality review and commit coherent verified checkpoints.

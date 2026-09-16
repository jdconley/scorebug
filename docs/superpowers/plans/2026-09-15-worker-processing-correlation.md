# Worker processing correlation implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, behavioral red/green
> tests and bounded independent review. Parent runs media/build checks sequentially.

**Goal:** Correlate decoded source frames, filter/encoder submissions and completed
worker packets over one source interval, preserving unknown timing and pending work.

**Architecture:** When encoder timing is enabled, retain a separate bounded history
of decoder PTS/reader times from the existing decoded side channel. Give both trackers
one pipeline scope UUID. Pure queries join exact 90k source coordinates and encoder
rational PTS, requiring retained brackets and valid scope. Continue exposing raw
counts even when pipe arrival order makes a duration unknown.

**Tech stack:** TypeScript/Vitest, existing FFmpeg metadata/pre/post pipes, CPU and
VideoToolbox local fixtures and independent replay of actual collections.

## Contract

Decoder history retains at most 512 scalar records. Existing DecodedVideoParser
validates framing/ordinals; history additionally requires strictly increasing source
PTS and valid nonregressing reader clocks. Invalid history is permanently unavailable
for that attempt. Closure freezes history; no callback after close can revive it.
Both histories have the same pipeline scope identity; mismatched snapshots cannot join.

Map encoder rational times to 90k ticks only when exactly representable and safe as a
JS integer. Reject unavailable/fractional/colliding projections. Do not round to invent
identity. MPEG-TS input timebase is already 90k; unsupported input coordinates stay
unknown until separately qualified.

For (startPTS,endPTS], require exact retained decoder anchors and encoder submissions
bracketing both bounds. The end may be between selected encoder frames after a frame
rate cap; the next submission proves the filter passed that source point. Every
encoder record within the bracket must occur in decoded history. Selected submissions
are those strictly after start and at/before end. Return decoded/submitted/completed/
pending counts and decoded frames omitted before the encoder. Omission includes the
explicit FPS cap, not necessarily accidental loss. An interval containing no selected
submissions has unknown duration, never an invented zero-duration success.

Compute reader-observed decoded-to-submission and decoded-to-completion durations
only when all required timestamps are present and nonnegative. The independent pipes
can be delivered in a different order; a negative observed duration remains unknown
without invalidating valid source counts. These are processing observations after
decode, not decode execution costs, spare capacity or viewer receipt. Missing queued
completions must never appear as healthy completed output.

## Tasks

- [ ] Add shared scope to encoder history and an exact safe 90k conversion helper;
  add `decoded-frame-history.ts` with bounded validated decoder record snapshots.
  Red/green tests cover source duplicates/order, clocks, eviction, framing/closure,
  wide/nonintegral projections and preserved prior snapshots.
- [ ] Add `worker-processing.ts` pure interval join. Red/green tests cover complete
  matching, FPS-cap omissions, pending completions, unknown/negative arrival timing,
  exact missing bounds, mismatched scopes, invalid histories and source mismatch.
- [ ] Wire both histories into the existing opt-in pipeline; expose combined snapshots
  and terminal decoder-history evidence. Ensure decoded-pipe errors cannot escape or
  relabel processing evidence as valid. Add real-child isolation/lifecycle tests.
- [ ] Run full worker/tooling/typecheck checks and actual CPU/VideoToolbox production
  pipeline probes. Replay saved native decoded/pre/post records independently.
  Add a reusable local host-qualification command for this same pipeline fixture.
  Review, hash evidence, update docs and commit verified changes.

Commands: `pnpm --filter @scorebug/home-daemon test`,
`pnpm --filter @scorebug/home-daemon typecheck`, `pnpm test:tools` plus the new
`scripts/test-worker-processing.mjs` via the home-daemon tsx runtime. Default pipeline
arguments stay unchanged; supported FFmpeg options and hardware remain explicit.

Next after this slice: feature-qualified worker runtime, source-window reporting and
initial current-load thresholds validated on paced media. Sustained decoded cadence
plus completed matched worker output and bounded processing delay can establish
current worker health; it does not need to claim hypothetical CPU/GPU spare capacity.
Then wire the native policy adapter and qualify actual automatic trial/rollback.

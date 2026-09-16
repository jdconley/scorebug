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

- [x] Add shared scope to encoder history and an exact safe 90k conversion helper;
  add `decoded-frame-history.ts` with bounded validated decoder record snapshots.
  Red/green tests cover source duplicates/order, clocks, eviction, framing/closure,
  wide/nonintegral projections and preserved prior snapshots.
- [x] Add `worker-processing.ts` pure interval join. Red/green tests cover complete
  matching, FPS-cap omissions, pending completions, unknown/negative arrival timing,
  exact missing bounds, mismatched scopes, invalid histories and source mismatch.
- [x] Wire both histories into the existing opt-in pipeline; expose combined snapshots
  and terminal decoder-history evidence. Ensure decoded-pipe errors cannot escape or
  relabel processing evidence as valid. Add real-child isolation/lifecycle tests.
- [x] Run full worker/tooling/typecheck checks and actual CPU/VideoToolbox production
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

## Verified checkpoint

Worker tests pass (290), tooling tests pass (781), and worker typecheck and targeted
format checks pass. The ES2022 typecheck initially rejected `findLastIndex`; the
implementation now uses a bounded loop, with the failed check retained as evidence.
Independent review approved source/lifecycle behavior and requested two additional
bracket/completion regressions, which pass. Harness review found that output-derived
expectations could conceal incorrect cap selection and unchecked duration arithmetic;
both now have independent expectations and the final review approves the harness.

The final production-pipeline fixtures pass:

| Backend | Source fps | Decoded / output frames | Artifact |
| --- | --- | --- | --- |
| CPU | 25 | 75 / 75 | `worker-processing-ZzjQrd` |
| CPU | 30 | 90 / 90 | `worker-processing-14undD` |
| CPU | 60 | 180 / 90 | `worker-processing-RWTFgC` |
| VideoToolbox | 30 | 90 / 90 | `worker-processing-aTOSKL` |
| VideoToolbox | 60 | 180 / 90 | `worker-processing-C67mAk` |

Each fixture checks exact independent input PTS, expected selection (even source
indices for 60-to-30 fps), output barcodes, complete A/V decoding, audio presence,
closed valid shared scopes, zero pending work and independent duration replay.
The selected interval excludes its first anchor: 74 frames at 25 fps or 89 at 30 fps;
the 60 fps source intervals contain 89 intentional omissions. Both durations are
observed in these runs; regression tests preserve unknown timing when pipe delivery
order is reversed. A separate replay of earlier raw native CPU/VideoToolbox pipe
collections also matches all 90 source/submission/completion coordinates and timing.
Those older VideoToolbox records do not qualify production latency thresholds.

The broader native software-worker harness passes source identity/A/V, overlay change
without restart, 60-to-30 and preserved 25 fps, worker SIGKILL, API lease outage,
source-loss recovery (7245 ms), and match-end stop. Evidence is under `artifacts/qa`;
`worker-processing-final-verification.json` records source and evidence hashes.

These finite local checks do not qualify sustained load, spare capacity, actual
physical phone/Watch operation, remote GPU hosts or automatic adaptation. No app/SDK
source changed in this slice; their previous native build evidence remains separate.

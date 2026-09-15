# Production worker transport clock implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for independent
> specification and quality reviews. One owner runs timing/media validation.

**Goal:** Preserve source transport timestamps in the production proxy's decoder
observations without losing frames at timestamp wrap or altering A/V acquisition gaps.

**Architecture:** Promote the already-qualified `copyts`, timestamp passthrough and
output-only timestamp normalization combination into `buildFfmpegArgs`. Keep the
explicit source-PTS frame cap and decoder side branch. Gate finite qualification on
unmodified production argv; retain the previous paths as negative controls.

**Tech stack:** TypeScript, FFmpeg, Vitest, existing finite MPEG-TS calibration and
worker acquisition/cadence fixtures on Mac software/VideoToolbox and Linux CPU.

## Design and authorization

Native `TransportClock` now gives exact source-to-wire projection per publishing
generation. The worker's default input timestamp rebasing still prevents direct
correlation. Previous calibration found that plain `-copyts` preserves the decoder
clock but VFR output drops wrap-region frames before muxing. Adding output
normalization alone does not fix that. The full preserving/passthrough/normalizing
combination retained all full/late input frames and A/V markers on both FFmpeg
8.1.2 and 5.1.9; see the preceding transport clock calibration plan.

Use that qualified combination in production. Leaving the old path would require
an independently established rebasing offset after every acquisition/reconnect;
using only copyts would knowingly retain the proven frame-loss behavior. The
telemetry branch continues to observe every decoded input frame before the cap.
The live branch retains its input timebase, explicit cap, scaling, overlay and
encoding. `-avoid_negative_ts make_zero` belongs to the outgoing muxer; do not add
`-start_at_zero`, `setpts`, or another input/filter rebase. This does not create a
production source-loss denominator, app clock plumbing or profile transition proof.
Automatic quality changes stay disabled. User standing autonomous implementation
and local-validation authorization covers this step; no external destination is used.

## Task 1: Production command

**Modify:** `apps/home-daemon/src/pipeline.ts`,
`apps/home-daemon/test/pipeline.test.ts`.

- [ ] Add a failing command contract test across software, VideoToolbox and NVENC,
  with/without an explicit profile: exactly one input `-copyts`, output
  `-fps_mode passthrough`, `-avoid_negative_ts make_zero` after input and before
  output format/URL; no start-at-zero/setpts/CFR output-rate options. Retain
  decoder-before-cap and cap-presence assertions for explicit profiles.
- [ ] Run `pnpm --filter @scorebug/home-daemon exec vitest run test/pipeline.test.ts`
  and retain the expected failure before implementation.
- [ ] Add `'-copyts'` before input options, change the existing FPS mode to
  `'passthrough'`, and add `'-avoid_negative_ts', 'make_zero'` before `'-f', 'flv'`.
  Update the comment to explain wrap-frame preservation and output normalization.
- [ ] Run focused/full worker tests and worker type checking. Keep guardian,
  credential logging, API schema, app and local archive behavior unchanged.

## Task 2: Production qualification

**Modify:** `scripts/test-transport-clock.mjs`.

- [ ] Run the `production` case with the exact array returned by
  `buildFfmpegArgs`, without test-added preserving flags. Retain `legacy`,
  `copyts`, and wrap-only `copyts-make-zero` controls by explicitly removing the
  promoted flags and restoring VFR before their existing candidate transforms.
- [ ] Make `chosenCandidate` be `production`; require six fixtures, unchanged
  independent wire/identity/cadence/audio/exit gates and a successful production
  mapping+media result in every fixture. Remove stale experiment-only result names.
- [ ] Before changing production code, run calibration and observe the production
  wire-mapping gate fail. Afterward rerun on Mac and the existing Linux CPU image
  with mounted current sources. Retain exact commands, terminal outcomes and media.
- [ ] Run `test:worker-timestamps` on Mac software and VideoToolbox and Linux CPU:
  retain 30/60/25 fps, real source gaps and unequal A/V acquisition coverage.
- [ ] Run the full tooling suite and independent specification then quality review.
  Record results in this plan and `docs/worker-decoded-video.md` /
  `docs/adaptive-telemetry.md`. Commit the verified production change.

## Remaining boundary

Clock preservation is a prerequisite for correlation, not a loss estimate. App
anchor export, worker convention negotiation, matching source-interval counts,
applied-profile boundaries, usable capacity/pressure and impairment traces remain.
Physical camera/Watch networking and other GPU/cloud hosts remain separately tested.

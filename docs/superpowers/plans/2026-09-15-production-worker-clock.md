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

- [x] Add a failing command contract test across software, VideoToolbox and NVENC,
      with/without an explicit profile: exactly one input `-copyts`, output
      `-fps_mode passthrough`, `-avoid_negative_ts make_zero` after input and before
      output format/URL; no start-at-zero/setpts/CFR output-rate options. Retain
      decoder-before-cap and cap-presence assertions for explicit profiles.
- [x] Run `pnpm --filter @scorebug/home-daemon exec vitest run test/pipeline.test.ts`
      and retain the expected failure before implementation.
- [x] Add `'-copyts'` before input options, change the existing FPS mode to
      `'passthrough'`, and add `'-avoid_negative_ts', 'make_zero'` before `'-f', 'flv'`.
      Update the comment to explain wrap-frame preservation and output normalization.
- [x] Run focused/full worker tests and worker type checking. Keep guardian,
      credential logging, API schema, app and local archive behavior unchanged.

## Task 2: Production qualification

**Modify:** `scripts/test-transport-clock.mjs`.

- [x] Run the `production` case with the exact array returned by
      `buildFfmpegArgs`, without test-added preserving flags. Retain `legacy`,
      `copyts`, and wrap-only `copyts-make-zero` controls by explicitly removing the
      promoted flags and restoring VFR before their existing candidate transforms.
- [x] Make `chosenCandidate` be `production`; require six fixtures, unchanged
      independent wire/identity/cadence/audio/exit gates and a successful production
      mapping+media result in every fixture. Remove stale experiment-only result names.
- [x] Before changing production code, run calibration and observe the production
      wire-mapping gate fail. Afterward rerun on Mac and the existing Linux CPU image
      with mounted current sources. Retain exact commands, terminal outcomes and media.
- [x] Run `test:worker-timestamps` on Mac software and VideoToolbox and Linux CPU:
      retain 30/60/25 fps, real source gaps and unequal A/V acquisition coverage.
- [x] Run the full tooling suite and independent specification then quality review.
      Record results in this plan and `docs/worker-decoded-video.md` /
      `docs/adaptive-telemetry.md`. Commit the verified production change.

## Remaining boundary

Clock preservation is a prerequisite for correlation, not a loss estimate. App
anchor export, worker convention negotiation, matching source-interval counts,
applied-profile boundaries, usable capacity/pressure and impairment traces remain.
Physical camera/Watch networking and other GPU/cloud hosts remain separately tested.

## Implementation evidence

The failing command contract had seven failures (six encoder/profile cases plus the
updated existing VideoToolbox expectation). The production media regression then
exited 1 in `transport-clock-Kdpo0t`: all six unmodified production commands failed
wire mapping while retaining their source frames. Both incomplete copyts controls
retained only 79 wrap-region frames, preserving the earlier counterexample.

After the production change, the exact command passes all six full/late MPEG-TS
cases on both Mac FFmpeg 8.1.2 (`transport-clock-299FJR`) and Linux FFmpeg 5.1.9
(`transport-clock-ip7O7n`). Both qualifiers exit 0, with all 20 underlying worker
processes exiting 0. Production alone passes mapping and media in every fixture;
legacy and incomplete copyts controls retain their expected failures. Each full
fixture has all 120 frames; each late input has all 90. Decoder PTS match independent
raw wire PTS modulo 2^33. Maximum A/V marker error is 0.395833 ms and maximum decoded
audio/video tail separation is 34.270833 ms, within unchanged gates.

The Linux invocation is pinned to image
`sha256:e20b63422cd618190356c5876c153227b244cced909911dd1a9fec920255b4b2`,
with current sources mounted read-only and no network. Its exact argv, image and
exit status are retained in `production-clock-cpu-command.json`.

Full worker tests pass 166 tests across 12 files; focused command tests pass 15.
Worker type checking and all 430 tooling tests pass. The full local software-worker
workflow exits 0: real native scoring updates overlay pixels without restarting
encoding, and worker kill, source loss, API outage, recovery and match-end shutdown
all pass. Recovered output has fresh video near 30 fps plus audio. Its embedded
five timestamp fixtures also pass; results are `native-worker-software/timestamps.json`.
Previous software-worker artifacts were preserved before this run.

Evidence paths above are under `artifacts/qa/`; command logs use `production-clock-`.

The five acquisition/cadence fixtures also exit 0 on Mac VideoToolbox and Linux CPU
(`production-clock-videotoolbox-timestamps.log`,
`production-clock-cpu-timestamps.json` and its command record). Across all three
implementations, decoder counts are 90/180/75/78/90 and output counts are
90/90/75/78/90. Maximum marker offset is 0.270833 ms and track-tail separation is
22.541667 ms. No cadence, gap, acquisition-offset or A/V gate was relaxed.

Specification and quality reviews approve the implementation. Formatting and
`git diff --check` pass. NVENC has command-contract tests only; NVIDIA hardware,
physical native capture/Watch radios and remote deployments were not exercised.
The unchanged status schema does not negotiate old versus new worker clock
semantics yet. Consumers must continue treating that distinction and matching
source intervals as unknown until explicit integration establishes them.

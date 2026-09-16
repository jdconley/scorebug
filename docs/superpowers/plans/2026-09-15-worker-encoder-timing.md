# Worker encoder timing implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, behavioral red/green
> tests and bounded independent review. Run native/process/media checks sequentially.

**Goal:** Measure timestamp-correlated pending/completed worker encoder frames without
assuming optional hardware input-frame identities or mistaking progress for delivery.

**Architecture:** Add an opt-in FFmpeg pre/post encoding statistics pipe, passed directly
through the existing process guardian. A bounded parser/tracker correlates exact rational
PTS, stores at most 256 frames, and exposes historical intervals and observed pending
age. Default pipelines retain their current arguments for compatibility with older
FFmpeg builds. No worker-pressure classification or automatic policy is enabled here.

**Tech stack:** TypeScript/Vitest, Node child processes, real Mac FFmpeg VideoToolbox and
CPU encoder probes, existing worker process lifecycle tests.

## Evidence and decisions

Real three-second probes emitted all 90 packets from CPU and VideoToolbox. CPU emits
optional input-frame identities; VideoToolbox returns unavailable values for ni/ptsi/tbi.
Both retain output PTS/timebase. Pre/post statistics on one shared descriptor preserve
record order in these probes. Records arrive in multiple batches while the process is
running, not only at EOF. The initial VideoToolbox probe omitted production realtime
flags, so its latency distribution must not define a production pressure threshold.

Record pre/post ordinal, PTS and rational timebase. Match reduced rational coordinates
using BigInt; do not convert timestamps to floating point or infer missing identities.
Require consecutive per-stage ordinals beginning at zero, strictly increasing pre PTS,
unique submissions and exactly one matching completion. Post PTS may reorder. Invalid,
oversized, non-ASCII or truncated records quarantine only timing diagnostics. A clock
error also quarantines them. Unknown/incomplete correlation must not become nominal.

Keep at most 256 submissions and a matching pending map. Evict only completed oldest
entries; exhaustion with an outstanding oldest entry quarantines evidence rather than
silently losing a pending frame. Completed interval queries require retained exact
exclusive-start and inclusive-end anchors, all included frames completed, and no
quarantine. Expose actual reader-observed submission/completion times and explicit
mean/max observed duration. These include pipe/scheduling delays, exclude decode and
filter work, and prove neither processor utilization, spare capacity nor viewer receipt.

Close freezes history/current ages; pending frames can remain after an interrupted
encode. A malformed timing pipe cannot affect the separate decoded-video parser or
process shutdown. The guardian passes an additional descriptor; parent always drains
it, joins EOF via child close, and never logs raw credential-bearing diagnostics.

## Tasks

- [ ] Create `apps/home-daemon/src/encoder-timing.ts` and corresponding tests. Write
  stub APIs, then red tests for exact wide/negative/rational PTS; reordered post output;
  unknown/missing matches; ordinal faults; malformed/chunked/oversized/truncated data;
  invalid clocks; 256-entry eviction/exhaustion; immutable closed snapshots; complete
  vs pending historical intervals. Implement validated bounded tracking.
- [ ] Add `encoderTiming` opt-in to PipelineOptions/buildFfmpegArgs and nullable
  snapshotEncoderTiming on PipelineHandle. Add optional terminal evidence, a separate
  pipe through pipeline-guardian.mjs, and isolated drain/end handling. Add argument
  and real-child lifecycle tests for valid/malformed/truncated timing, independent
  decoded telemetry, closure and default-off behavior before implementation.
- [ ] Run complete worker tests/typecheck, scripts tooling tests and normal worker
  native fixtures. Replay real CPU/VideoToolbox paired probe records through the
  tracker, preserving native argument lists and unqualified limitations. Obtain
  source review, record evidence/hashes, update docs and commit.

Commands: `pnpm --filter @scorebug/home-daemon test`,
`pnpm --filter @scorebug/home-daemon typecheck`, `pnpm test:tools`, `pnpm test:worker`.
All artifact probes stay under `artifacts/qa/worker-pressure-probe/`.

Reference: [FFmpeg encoding statistics](https://ffmpeg.org/ffmpeg.html).
Before production enablement, feature-detect or update the worker's older FFmpeg
runtime and qualify decode/filter-to-encoder coverage plus timing thresholds on each
backend. Encoder-only observations cannot establish nominal overall worker pressure.

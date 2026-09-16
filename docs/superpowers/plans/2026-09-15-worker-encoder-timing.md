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

- [x] Create `apps/home-daemon/src/encoder-timing.ts` and corresponding tests. Write
  stub APIs, then red tests for exact wide/negative/rational PTS; reordered post output;
  unknown/missing matches; ordinal faults; malformed/chunked/oversized/truncated data;
  invalid clocks; 256-entry eviction/exhaustion; immutable closed snapshots; complete
  vs pending historical intervals. Implement validated bounded tracking.
- [x] Add `encoderTiming` opt-in to PipelineOptions/buildFfmpegArgs and nullable
  snapshotEncoderTiming on PipelineHandle. Add optional terminal evidence, a separate
  pipe through pipeline-guardian.mjs, and isolated drain/end handling. Add argument
  and real-child lifecycle tests for valid/malformed/truncated timing, independent
  decoded telemetry, closure and default-off behavior before implementation.
- [x] Run complete worker tests/typecheck, scripts tooling tests and normal worker
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

## Review and intermediate evidence

Independent review found a missing timing-pipe error listener. Behavioral tests
reproduced three error/early-close failures; the corrected permanent listener now
quarantines only timing evidence and drains through closure. Follow-up review approves
that fix and a pending-frame retention regression. The first full worker run also
identified an older fake child with only five descriptors; its fixture now models the
six-descriptor guardian contract and retains its original failure/shutdown assertions.
Initial behavioral, typecheck, probe-launch and full-suite failures are retained.

Real `startPipeline` CPU and VideoToolbox probes each submit and complete all 90 video
frames with zero outstanding frames or invalid timing/decoder evidence at EOF. Both
return a complete 89-frame interval after the exclusive first anchor. The local file
input is processed in a burst, so its observed durations are not live-load ceilings.
VideoToolbox reaches 13 observed pending frames, CPU one; neither value alone defines
an overload threshold. Optional input-frame identities are not consumed.

## Final verification

All 261 home-daemon tests, 781 tooling tests and worker typecheck pass. Targeted
format checks and independent source review pass. The real software worker fixture
passes full local media, source timestamps/frame identity and cadence, score overlay
updates, worker SIGKILL recovery, API outage/lease recovery, source-loss recovery
(7241 ms in this run) and match-end shutdown. This default-mode fixture establishes
that the additional descriptor does not regress the existing pipeline; its timing
observer is not enabled.

The separate real CPU/VideoToolbox `startPipeline` probes enable timing observation;
each saved output passes complete A/V decode with zero FFmpeg decode errors.
Replaying the original paired raw native collections through the production tracker
matches an independent 90k-tick/arrival-time reconstruction: all 90 frames correlate,
all 89 frames after the exclusive anchor have complete timing, and pending counts
agree. This is local fixture evidence, not qualification of NVENC, older FFmpeg,
remote hosts, sustained load or overall worker-pressure policy.

Logs, native clips, probe source/raw records/output media and review are retained in
`artifacts/qa/worker-timing-*`, `worker-pressure-probe/` and `native-worker-software/`.
The final verification manifest hashes exact source and local evidence. Reusable
host qualification, worker runtime capability detection and decode/filter-to-encoder
correlation are still needed before this data can support automatic policy inputs.

# Decoded input geometry evidence implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for implementation and independent specification then quality review. Root owns documentation and commits.

**Goal:** Verify actual incoming video dimensions during native quality transitions, before the proxy scales video onto its fixed output canvas.

**Architecture:** An explicit test-only flag adds a named FFmpeg showinfo observer to the existing decoder telemetry side branch after its 1/90000 timebase conversion. The guardian parses only bounded numeric geometry records into contiguous dimension runs and returns them after joined shutdown. This evidence never enters capacity, admission, cadence or health policy. Normal pipelines remain unchanged.

**Tech Stack:** FFmpeg showinfo, existing Node guardian and TypeScript terminal diagnostics, Vitest and an offline dynamic-H264 fixture.

## Current status and boundaries

This diagnostic dependency is reviewed and committed at038a4ec.29parser/470worker tests, typecheck/build and built pipeline integration pass; root verifies66artifact hashes and exact input/output geometry. Native720 recipe is reviewed and committed at43f2229; ordinary automatic ladder remains240/360. Paired physical test retry is blocked before capture by Xcode Watch preparation. No live capture is active. Geometry prototype `artifacts/qa/decoded-geometry-prototype-jalr72oo` decodes18 genuine H264frames: six426×240, six640×360 and six1280×720, while scaling output to1920×1080. The named observer reports all three input geometries, consecutive ordinals and3000tick PTS spacing without filter reinitialization. This proves the local observation mechanism only.

Official references: [showinfo documentation](https://ffmpeg.org/ffmpeg-filters.html#showinfo), [AVFrame-based implementation](https://ffmpeg.org/doxygen/trunk/vf__showinfo_8c_source.html). Installed FFmpeg supports checksum and udu_sei_as_ascii options. Keep raw diagnostic lines inside the guardian because FFmpeg can echo credentialed URLs.

## 1. Bounded observer

Files: create `apps/home-daemon/src/decoded-geometry.mjs` and `apps/home-daemon/test/decoded-geometry.test.ts`.

- [x] Write tests first for actual prototype syntax, fragmented byte chunks, changing dimensions, detached snapshots and joined EOF. Add negatives for wrong/missing timebase, ordinal gap/reset, backward/duplicate PTS, invalid dimensions/numbers, malformed named frame rows, oversized/incomplete lines, pipe failure, drain timeout and more than64dimension runs.
- [x] Implement `DecodedGeometry` with `push(Uint8Array)`, `end()`, `failPipe()`, `timeOutDrain()` and `snapshot()`, matching guardian diagnostic ownership. Retain at most one4096byte line and64dimension runs; after invalidity continue draining at the pipe owner and retain no additional geometry. No raw strings from input may escape in snapshot.

Snapshot contract:

```ts
{
  formatVersion: 1, diagnosticOnly: true, timeBase: '1/90000',
  maximumRuns: 64, ended: boolean, invalidReason: string | null,
  observedFrames: number,
  runs: Array<{
    width: number, height: number,
    firstOrdinal: number, lastOrdinal: number,
    firstPTS: number, lastPTS: number, frames: number, maximumPTSDelta: number
  }>
}
```

Only the fixed instance `showinfo@scorebug_geometry` supplies evidence. Require its config-in timebase1/90000 before first frame. Ordinals begin at0 and advance exactly1; PTS strictly increases as safe integers. Dimensions are positive even integers within7680×4320. For unchanged dimensions extend the current run; otherwise append a run. Retain the first failure enum permanently; no counter saturation or silent eviction may masquerade as complete evidence. Missing frames/timebase is invalid at end. Auxiliary color/side-data lines and unrelated FFmpeg output are ignored, never retained. Any oversize/incomplete framing remains explicitly invalid. Exact width/height derive from showinfo's AVFrame fields, never profile labels.

- [x] Run focused observer tests, retain red/green logs and hashes under `artifacts/qa/decoded-geometry-validation/`.

## 2. Opt-in guardian and terminal integration

Files: modify `apps/home-daemon/src/pipeline.ts`, `pipeline-guardian.mjs`, `worker-terminal.ts`, `index.ts`; extend their existing tests.

- [x] Add `decodedGeometry?: boolean` to PipelineOptions and build argument options. Gate on an actual onTerminal callback, like packetTiming. Existing argument defaults remain unchanged. The decoder side branch becomes:

```text
[decoded]settb=1/90000,showinfo@scorebug_geometry=checksum=0:udu_sei_as_ascii=0,metadata=...
```

Keep observer before metadata output and before the live branch's cap/scale/pad. Keep existing telemetry ordinal/timebase and reinit_filter settings. INFO logging is already enabled for terminal diagnostics.

- [x] Guardian creates the observer only when terminal diagnostics and decodedGeometry are true, feeds existing stderr bytes, propagates pipe failure/drain timeout, ends on owned shutdown and includes optional decodedGeometry snapshot in exit IPC. Preserve encoder exit authority, bounded drain, parent-loss behavior and pipe draining.
- [x] Pipeline copies the snapshot to optional `PipelineTerminal.decodedGeometry` only after pipes join. No other feedback or report messages change.
- [x] Extend `createWorkerTerminalDiagnostics` with a fourth optional flag and returned `decodedGeometryEnabled`. `index.ts` reads `SCOREBUG_TEST_WORKER_DECODED_GEOMETRY`; it has effect only when `SCOREBUG_TEST_WORKER_TERMINAL=1`. Emit one bounded `worker_decoded_geometry` record per run (or one empty summary when no runs), tagged by existing game/generation/pipelineOrdinal, runIndex and full summary counts/validity. Explicitly select numeric fields; never forward unknown/raw input.
- [x] Test gating/default arguments, exact branch placement, safe logging and scope, error/drain/parent ownership and optional terminal propagation. Existing worker/protocol behavior remains unchanged; no device-lab or native changes in this slice.

## 3. Real decoder verification and reviews

- [x] Run worker tests, typecheck/build, and existing guardian/process regressions. Retain exact commands, outcomes and source hashes.
- [x] Repeat the18frame dynamicH264 fixture through the actual built pipeline/guardian using this flag. Use existing local FFmpeg and font; no downloads. Assert terminal geometry has three6frame runs426×240→640×360→1280×720 at increasing source PTS, ordinary telemetry18frames, clean join and actual output1920×1080. This is mechanism validation, not native720/recovery/media qualification.
- [x] Obtain independent spec then quality review, verify reviewed blobs and evidence, commit only this dependency and update session log/current plan.
- [ ] Later integrate explicit ordinary recovery720 lane, native applied-format receipts and independent join to these geometry runs; keep existing timing/cap/global recording gates and qualify complete natural A/V separately.

No heavy builds/media analysis during live hardware capture; pause this slice if the user makes the Watch ready and root starts capture.

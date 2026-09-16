# Live worker processing windows implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, behavioral
> red/green tests and bounded independent review. Parent runs builds/media sequentially.

**Goal:** Make optional worker processing observations available over the same live
source intervals the native app already reconstructs, with portable startup checks.

**Architecture:** A small pipeline-owned tracker observes successive completed decoder
windows. It retains the previous last source PTS as the exclusive anchor, joins the
existing bounded decoder/encoder histories, and retries unfinished intervals while
that completed window is current. It freezes only fully completed observations;
missing evidence remains unknown. A bounded FFmpeg option probe enables diagnostics
on compatible worker startup and leaves unsupported workers publishing normally.

**Tech stack:** TypeScript/Vitest, native FFmpeg CPU/VideoToolbox, Node loopback HTTP
and a paced FFmpeg source fixture. No API or native policy behavior changes yet.

## Contract and design choices

Use the existing decoder five-second window sequence as identity. The processing
range is `(previous.lastPTS, current.lastPTS]`, matching the native source interval
tracker; current.firstPTS and freshFrames must match retained decoded history after
the exclusive anchor. Only adjacent nonempty valid windows without duplicate or
reordered frames are eligible. First acquisition, gaps, malformed data, missing
retained brackets and ended histories produce no current result. Changed contents of
an already seen window or sequence rewind permanently quarantine that collector.
Invalid diagnostic clocks/history also quarantine; they cannot stop publication.

Return the current window sequence, previous sequence, first source PTS, shared
pipeline scope, and the existing processing interval. Pending output remains explicit
and can become complete on later reads of the same window. Freeze a result once all
selected submissions complete; later history eviction cannot change its contents.
Never freeze zero selected submissions as healthy completion. Clear frozen evidence
when the latest decoder window becomes invalid, empty, skipped, ended or otherwise
unusable. Caller must still establish report age and publication/configuration scope.
This collector is not itself freshness, pressure classification or viewer delivery.

Probe only FFmpeg encoder-statistics option availability at startup, with no input,
network destinations or encoder initialization. Use a three-second deadline, bounded
output, fixed failure reasons and owned child termination. No version-number guesses.
Require all four exact option names used by the production pipeline. An `off` config
bypasses the probe. Missing or failed probes disable these optional diagnostics;
actual media encoder compatibility continues to require a real pipeline test.

## Tasks

- [ ] Add `worker-processing-windows.ts` and focused behavioral tests. A fixture feeds
  two adjacent windows plus exact scalar histories; assert `(previous.lastPTS,lastPTS]`,
  counts, pending-to-complete progression, immutable completed results, first-window
  acquisition, gaps, changed/rewound windows, scope changes, invalid/ended state,
  zero submissions and missing/evicted anchors. Run red, then green.
- [ ] Add `snapshotProcessingWindow()` to the pipeline and integrate the collector
  only with opt-in timing. Read decoder once per collector sample and use histories
  from that same synchronous pipeline read. Extend real-child coverage for closure
  and optional absence; default FFmpeg arguments stay unchanged.
- [ ] Add `encoder-statistics-capability.ts`, config `WORKER_PROCESSING=auto|off`,
  and startup enablement in `index.ts`. Test exact option detection, bounded output,
  failure/timeout/cancellation cleanup, sanitized errors and config defaults. Ensure
  shutdown cancels and joins the startup probe before process exit and no loops start
  after shutdown. Unsupported binaries remain usable without extra options.
- [ ] Add a paced local processing command using an owned loopback HTTP source backed
  by FFmpeg `-re`, with 18 seconds of regular source-coded A/V. Sample the production
  pipeline every 100 ms; save raw windows/snapshots. Independently check actual source
  PTS, adjacent window bounds, selected output IDs, counts and duration arithmetic.
  Require at least two complete live processing windows with bounded histories.
  Fully decode saved output and compare every barcode with expected cap selection.
  Run CPU and VideoToolbox serially; unsupported hardware must fail honestly.
- [ ] Run worker/typecheck/tool suites, independent review, preserve hashes and evidence,
  update telemetry/runbook/parent plan, and commit the verified checkpoint.

Next: additive negotiated API/native processing reports tied to existing age proofs,
then classify current-load evidence from paced/overloaded runs and connect the native
quality owner for real automatic trial/rollback. No threshold is inferred from this
short fixture, and physical Watch/phone/remote-host qualification remains separate.

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

- [x] Add `worker-processing-windows.ts` and focused behavioral tests. A fixture feeds
      two adjacent windows plus exact scalar histories; assert `(previous.lastPTS,lastPTS]`,
      counts, pending-to-complete progression, immutable completed results, first-window
      acquisition, gaps, changed/rewound windows, scope changes, invalid/ended state,
      zero submissions and missing/evicted anchors. Run red, then green.
- [x] Add `snapshotProcessingWindow()` to the pipeline and integrate the collector
      only with opt-in timing. Read decoder once per collector sample and use histories
      from that same synchronous pipeline read. Extend real-child coverage for closure
      and optional absence; default FFmpeg arguments stay unchanged.
- [x] Add `encoder-statistics-capability.ts`, config `WORKER_PROCESSING=auto|off`,
      and startup enablement in `index.ts`. Test exact option detection, bounded output,
      failure/timeout/cancellation cleanup, sanitized errors and config defaults. Ensure
      shutdown cancels and joins the startup probe before process exit and no loops start
      after shutdown. Unsupported binaries remain usable without extra options.
- [x] Add a paced local processing command using an owned loopback HTTP source backed
      by FFmpeg `-re`, with 24 seconds of regular source-coded A/V. Sample the production
      pipeline every 100 ms; save raw windows/snapshots. Independently check actual source
      PTS, adjacent window bounds, selected output IDs, counts and duration arithmetic.
      Require at least two complete live processing windows with bounded histories.
      Fully decode saved output and compare every barcode with expected cap selection.
      Run CPU and VideoToolbox serially; unsupported hardware must fail honestly.
- [x] Run worker/typecheck/tool suites, independent review, preserve hashes and evidence,
      update telemetry/runbook/parent plan, and commit the verified checkpoint.

Next: additive negotiated API/native processing reports tied to existing age proofs,
then classify current-load evidence from paced/overloaded runs and connect the native
quality owner for real automatic trial/rollback. No threshold is inferred from this
short fixture, and physical Watch/phone/remote-host qualification remains separate.

## Verified checkpoint

Worker tests pass (323 across 20 files), tooling tests pass (781), worker typecheck
and targeted format checks pass. Real startup tests cover supported and unsupported
options, the explicit off mode, and cancellation before control/report polling starts.
The final cancellation test requires prompt shutdown (under 1.5 seconds), actual probe
exit and no control/report requests. Diagnostic probe timeouts kill and join an
inherited-pipe wrapper descendant. Independent review approves source and harness.

Final paced fixture evidence under `artifacts/qa`:

| Backend/source      | Artifact                   | Source/output frames | Complete live windows |
| ------------------- | -------------------------- | -------------------- | --------------------- |
| CPU 30 fps          | `worker-processing-3xwOh4` | 720 / 720            | 2                     |
| VideoToolbox 30 fps | `worker-processing-tYulx7` | 720 / 720            | 2                     |
| CPU 60 fps          | `worker-processing-McXMf4` | 1440 / 720           | 2                     |

Each final run independently checks exact frame selection and saved output barcodes,
full A/V decoding, current adjacent window/source correspondence, raw count/duration
replay, invalid/closed state exclusion and bounded retained histories. The two live
30 fps intervals contain 146 and 154 complete frames; real arrival windows are not
artificially rounded to 150. The 60 fps intervals contain 292/309 decoded frames and
146/154 submissions, with 146/155 deliberate cap omissions. VideoToolbox has nine
sampled pending observations, up to 12 pending frames, before complete results freeze.
A separate short CPU 25 fps regression (`worker-processing-ldhEpj`) preserves all 75
frames. Normal end leaves no current processing window.

The native software worker with automatic diagnostic probing also passes source
identity/A/V, overlay updates without restart, 60-to-30 and preserved 25 fps, worker
SIGKILL, API lease outage, source-loss recovery (7537 ms) and match-end shutdown.
The verification manifest records source/evidence hashes and a unique copy of these
worker clips so later fixture runs cannot overwrite this checkpoint's evidence.

Retained failures and corrections:

- A 250 ms fake-child deadline could expire before the Node helper wrote its PID;
  the test now permits 1.5 seconds while still checking actual termination.
- The original 1 MiB help limit rejected the installed FFmpeg's 1,094,236-byte help;
  a bounded 4 MiB limit passes, with an oversized-output rejection test retained.
- An 18-second paced fixture yielded one complete post-acquisition interval because
  input analysis consumed about five seconds. Extending the actual source to 24 seconds
  passes two intervals without weakening the gate or inventing startup evidence.
- Review found direct-child-only probe cleanup could hang on inherited pipes. POSIX
  process groups now own that query and descendants. Native Windows returns
  `unsupported_platform` without spawning until equivalent job ownership exists.
- Review also found a source cleanup timeout could skip pipeline cleanup, and the
  native oracle could accept stale frozen sequences. Stops now precede independent
  joins; before/after decoder snapshots establish current window identity.

Reader timing remains backend-dependent. In these paced live windows, CPU observed
completion maxima are under 9 ms and VideoToolbox under 651 ms. Those are fixture
observations, not runtime thresholds or hardware/profile ceilings. The final CPU
30 fps terminal historical interval has unknown duration because some independent
pipe arrivals reverse; both live intervals remain independently matched. Unknown
measurements are preserved rather than replaced by zero.

Limitations: no negotiated API/native processing report yet; no pressure classification
or automatic policy adapter; no sustained/profile-capacity conclusion from 640x360
fixtures. Shutdown/cancellation of the startup probe is qualified, but abrupt worker
death during a still-running startup probe is not covered by this slice's crash test
(which kills an already publishing worker). Physical phone/Watch, native Windows,
remote GPU and cloud qualification remain open. No Apple app/SDK code changed.

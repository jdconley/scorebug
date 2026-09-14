# Isolate archive status reads from disk persistence

Use subagent-driven development for the bounded implementation and independent
specification and quality reviews. Reuse existing agents when capacity prevents
fresh workers. Work only in the existing local-validation worktree.

The ten-minute failure shows a half-second persistence/append overlap. Source
inspection identifies a separate, concrete lock dependency: status snapshots hold
the writer lifecycle lock while waiting for the segment store's disk-operation
lock. Remove that dependency without changing native lifecycle serialization,
segment durability, queue budgets, capture pacing, or encoding profiles.

- [x] Add a deterministic failing regression. A gated segment read must not prevent
  a competing writer operation from acquiring its lock. Use an internal segment-read
  dependency seam if needed to establish ordering; thread-start signals or sleeps
  cannot prove lock entry. Preserve a real store persistence gate integration test.
- [x] Capture writer scalar/lifecycle state under its short lock, release that lock,
  then read committed segments. Document that these fields are not an atomic
  cross-component snapshot; a finished state must never accompany an earlier
  incomplete segment list. Add a scalar accepted-duration accessor for periodic
  Film health polling so that duration reads do not query committed segment storage.
- [x] Observe red/green; verify duration progression and storage failure behavior,
  snapshot semantics, cancellation/finalization races and synchronous durability.
  Run full Media and Film suites, then independent spec and quality reviews.
- [x] Record evidence and commit the reviewed fix. Run an isolated short native
  workflow, then the 600-second hold if the short run passes. Retain and analyze any
  failure without weakening a gate. Passing a deterministic lock regression alone
  does not prove all native persistence stalls have been eliminated.

If the native stall persists, distinguish writer-lock acquisition, native readiness
and append, and persistence phases with bounded diagnostics before choosing another
fix. Asynchronous persistence would require its own bounded queue, failure semantics
and finish barrier; it is outside this focused change. Motion-heavy fixtures and
physical-device tests remain necessary after basic recording reliability improves.

## Implementation evidence

The actual-store gate regression fails on the old lock placement with the expected
assertion that a segment-storage wait blocks the lifecycle operation. It passes
after snapshot scalar capture and segment reading are separated. A concurrent
finish regression checks that an earlier segment view retains its earlier writer
state, and a scalar-duration test checks progression through finalization.

The focused writer suite passes 11 tests, full Media passes 136 (104 XCTest plus 32
Swift Testing), and Film passes 77. Generic unsigned iOS Release build, including
the Watch app, succeeds. Logs are retained as `artifacts/qa/archive-snapshot-*.log`.
Specification and independent quality reviews approve with no remaining findings.
Native qualification is pending. These tests prove the specific lock dependency is removed; the
ten-minute native overflow remains unqualified until a new run is measured.

## Native qualification after the fix

The short run `native-app-OCNlMh` at `da73cdb` passes all native gates: 1296 clean
archive frames (43.2 seconds), 901 live frames through the final encoded frame,
zero rejected/dropped archive samples, native scoring, A/V timing, shutdown,
continued recording, export and age proofs. Both encoder and direct receiver exit 0
naturally. All 2592 archive samples are written.

The 600-second run `native-app-0xF97D` at the same revision passes its native UI test,
all media/observation and direct-delivery checks, then fails the report-age validator:
that separate helper still hardcodes 64 collector windows. The run retained 122 valid
windows, within the collector's explicitly configured 128 limit. The original run
remains failed; post-run checks do not replace it.

Its archive finishes with all 37944 samples written, zero rejects/drops and no first
failure. It contains 18972 consecutive frames 0–18971 (632.4 seconds); live contains
18550 consecutive frames 204–18753 (618.333 seconds) through the final native encoded
frame. Native capture 143 precedes encoder coverage 144–18753; acquisition 144–203 is
explicit. All 123 steady five-second windows report 30 fps for both stages. Archive
A/V end difference is +4 ms; live is +23.197 ms, with maximum marker offset 65.25 ms. Native
scoring changes 342 overlay pixels. Both encoder and recorder exit 0 naturally.

Retained tail timings: maximum persistence 40.291 ms, append 0.251 ms, producer start
lateness 2.223 ms. These describe only bounded retained histories, not omitted earlier
operations. Evidence: `post-run-checks.mjs`, `post-run-independent-checks.json`,
`summarize-pressure.py`, and `pressure-summary.json` in the run directory; both JSON
summaries explicitly retain `qualificationPassed:false`.

Next fix: give the report-age qualifier an explicit trusted collector limit 64/128,
keep its default 64, and pass the same validated limit from the native runner as the
collector uses. Regress >64 evidence with explicit 128, rejection at 129, unsupported
limits, and unchanged adversarial identity/scope/telemetry checks. Review and run
all tooling tests, then repeat the native 600-second workflow on the committed fix.
Do not truncate the evidence or weaken age-proof checks to make this run pass.

The capacity correction now passes 65 focused tests and 292 full tooling tests.
The recorded red run fails 21 new assertions under the old implementation; the
updated qualifier accepts only trusted 64/128 configuration and preserves every
existing integrity check. Replaying the actual 122 retained samples now matches
both native age proofs (sequences 121/122), with no unmatched proofs. The original
run remains failed in both post-run summaries. Specification and independent quality reviews approve with no findings.
A new complete 600-second run is pending.

## Complete ten-minute repeat: pass

`native-app-6o9S2U` at `a49408c` passes the complete maintained 600-second workflow,
including native UI actions, post-stream recording, export, full A/V decode,
source-frame checks, direct delivery, all observation windows and both age proofs.
The runner exits0 and cleans up its owned simulator/receiver/worker resources.

| Measurement | Archive | Live |
| --- | --- | --- |
| Consecutive source frames | 18947 (0–18946) | 18532 (229–18760) |
| Source duration | 631.567 seconds | 617.733 seconds |
| Fresh cadence | 30 fps | 30 fps |
| Missing frames within saved interval | 0 | 0 |
| Maximum A/V marker offset | 0.021 ms | 65.917 ms |
| Audio end minus video end | +5.334 ms | +25.138 ms |

Archive diagnostics are closed with valid full coverage: 37894 samples accepted and
written, zero rejected/dropped samples, no first failure and terminal state finished.
The queue peak is one 3200-byte audio packet. Native capture observes 168–18760;
encoder coverage begins 169. Capture 168 precedes encoder coverage; acquisition 169–228
is explicit, and every encoded frame from 229 through 18760 is saved. All source
frames remain in the clean archive. The archive continues 186 frames past live.

All 125 native observation windows survive without eviction; 122 steady windows show
30 fps for capture and encoder. Both native report-age proofs match independently
collected API windows 121/122. Native scoring changes 340 comparison pixels. Worker
encoder and direct receiver exit 0 naturally, wrapper exit 0, valid worker EOF, and
all 18532 decoder/output-progress frames are present in the live file.

Bounded retained histories contain 32 producer / 64 consumer / 32 persistence records,
with 18915/37830/285 earlier records omitted. Tail-only maxima are 2.131 ms producer
lateness, 6.160 ms generation, 0.036 ms callback, 0.114 ms append and 3.445 ms persistence.
These are not whole-run latency maxima. No claim is made that every possible native
persistence stall is eliminated. The deterministic snapshot lock path is fixed and
this complete native configuration passes.

Evidence: `results.json`, `archive-diagnostics.json`, `video-observation.json`,
`worker-report-age-qualification.json`, `worker-terminal-evidence.json`,
`direct-rtmp-recorder.json`, `pressure-summary.json`, and its reproducible
`summarize-pressure.py` in the run directory. Original failures are retained.

Actual archive/live container rates remain about 0.126/0.102 Mbps, so this is a low
encoded-payload simulator qualification. Continue with the reviewed
[motion workload plan](2026-09-14-native-motion-load-validation.md). Higher bitrate,
physical camera/Watch networking, thermal endurance, adaptive quality and other
worker hosts remain open.

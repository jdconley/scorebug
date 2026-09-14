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
- [ ] Record evidence and commit the reviewed fix. Run an isolated short native
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

# Candidate wait diagnosis

The repeated native run `native-app-yB8xre` retained complete valid media and
deadline evidence but failed before a second candidate result was exported.
A deterministic Core experiment confirms that a 9.409 ms readiness interval can
fall between 100 ms queries. It does not establish the native failed predicate.

## Design

Add a DEBUG-only diagnostic to the existing repeated candidate fixture. Preserve
all functional guard order, await boundaries, freshness limits, poll delays,
probe leases, campaign limits, and bandwidth caps. The diagnostic has no role in
health, readiness, candidate admission, or qualification.

Retain a typed ordered prefix of at most 4,096 events across both campaigns.
Use fixed enums, numeric fields, UUIDs, and bounded identifiers; no raw errors,
URLs, media, or payloads. Bound the final JSON to 4 MiB and latch invalid/overflow
with a saturating omitted count. Serialize only at joined teardown, never per
poll. Export `native-candidate-wait.json` separately from measurement format 4.
A campaign that never binds must still leave poll and terminal evidence.

Each poll records campaign, query start/completion and decision times, observed
probe generation/stage/campaign/lease, and the actual outcome: probe unavailable
or rejected, context unavailable or mismatched, lease expired after await, or
bound. Record context read timing and available readiness revision/healthyThrough/
validUntil. Record operation start, return/failure, post-start context outcome,
measurement join, and campaign end. Cancellation and stop must join before export;
late callbacks must not reopen the trace. Legacy fixtures emit no trace.

## Execution and ownership

1. Parent ran the deterministic Core timing experiment: passed, unchanged policy.
2. One implementation subagent owns native diagnostic module, publisher wiring,
   and focused FilmModel tests. Write tests before implementation; parent runs
   all Xcode commands serially and regenerates the project if needed.
3. Parent owns harness optional collection and documentation. Preserve the trace
   even when a prior collection step fails. Diagnostic absence is not a health
   result and does not change qualification.
4. Independent specification review, then quality review. Parent runs targeted
   tests, full tools/FilmModel checks and simulator build as appropriate.
5. Freeze source, run one fresh repeated native experiment with existing settings,
   inspect actual poll evidence, retain all failures. Only then select a fix.

The user's existing autonomous-work authorization covers these local reversible
diagnostics. Original match files remain read-only and local.

## Verification so far

The deterministic timing test passes, as do all 459 Core tests. Its missed query
phase and successful alternate phase explicitly preserve the two-second deadline.
All 3,306 tools tests pass after optional diagnostic collection was added. The
seven new native trace tests fail to compile against the missing trace/API, as
expected before implementation; this RED is retained in
`artifacts/qa/repeated-live-checkpoint-candidate-wait-trace-red.log`.

All 54 focused candidate tests and all 485 FilmModel tests pass, including eight
new diagnostic tests and extended successful two-campaign assertions. The first
GREEN build attempt exposed Swift's restriction on `Self` in a default argument;
the explicit type name corrected it before these passing runs. Independent
specification and quality reviews approve the implementation. `campaignEnded`
marks completion of the measurement path, not ownership retirement; the export
itself waits for the complete teardown join. No production adaptation behavior
or qualification gate changed.

The arm64 iPhone simulator Debug build also passes. Next is the unchanged
180-second repeated route with the new trace, preserved source hashes, and one
joined result; independent component analysis must not relabel a failed full run.

## Native result: q6s6KU

Source `b8a0609`, all 919 frozen hashes unchanged. Native UI passed in 259.120 s;
full harness joined with exit 1: `binding predates observed native ownership`.
Both candidate measurements and both owned fault cycles completed. The trace
closed with 1,052 events / 365,482 bytes, no omissions, invalidity or overflow.

The sole failing ownership-history comparison is campaign two initial binding
against raw probe event 210. Probe read was
1895702.543272875–1895702.5432826667. Context read then lasted 30.215208 ms.
A same-owner renewal at 1895702.5718719584 preceded binding at 1895702.573508125
by 1.636167 ms, advancing 35,532 bytes and the lease by 100.147542 ms. The saved
snapshot's original lease still covered binding by 198.202167 ms. Assigning this
older snapshot the later binding instant made its exported chronology incorrect.
There is no observed withdrawal/replacement in that interval. Independent review
confirmed this exact predicate and the distinction from runtime ownership loss.

Archive/live full decodes pass: 6,539 / 6,131 contiguous frames at 30 fps, live
maximum gap 34 ms. All 102 live markers match within 64.583 ms, negligible drift;
coverage and direct delivery pass. All 269 deadline rows independently replay
with zero unknowns, and cadence retains 2,054 valid rows. The `time` rejection at
quality event 24 and interrupted recovery remain explicit later policy concerns.
The original failed full run remains failed. Evidence is in
`diagnostic-complete-assessment.json`, `diagnostic-candidate-wait-assessment.json`,
`diagnostic-components-assessment.json`, and `diagnostic-media-assessment.json`
inside `artifacts/qa/native-app-q6s6KU/`.

## Next bounded change

1. Audit all binding consumers, including repeated candidate measurement,
   repeated probe retirement and measured candidate witness qualification.
2. Record explicit probe read start/return times for initial and final snapshots;
   keep binding/completion instants separate. Do not simply move the observation
   timestamp to await return, since the native snapshot may precede that return.
3. Establish a strict schema contract for the new evidence. Missing/malformed
   brackets fail closed. Preserve historical artifacts and legacy routing.
4. TDD a renewal after the probe read but during the context await. Require
   native observations completed before read-start to be reflected in counters
   and lease; prohibit acceptance or renewal borrowed from after read-end.
   Ambiguous overlapping reads need a consistent snapshot ordering, with no
   relaxed time tolerance. Keep original snapshot lease valid at binding and
   reject retirement/withdrawal before binding or measurement completion.
5. Preserve synchronous runtime ownership checks, readiness, poll delays,
   campaign deadlines and 16 MiB. Add cancellation/late-read and mutation tests,
   perform independent specification then quality review, run targeted/full
   checks, freeze source, and run one fresh native experiment.

The readiness-window race is still a separate possibility. If an actual later
trace implicates it, inspect advisory event wakeups and delayed complete-report
availability; immediate driver ticks on worker reports already exist. A wakeup
cannot create freshness or guarantee native startup before a 9.409 ms expiry.

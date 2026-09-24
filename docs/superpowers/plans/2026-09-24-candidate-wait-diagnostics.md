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

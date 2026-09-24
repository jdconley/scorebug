# Independently prove source-expiry invalidation during minimum recovery

Status: complete. Independent review, all 3,415 JavaScript tests, raw preserved-run
reconstruction and a fresh frozen full native fixture pass. User authorization for
autonomous local work remains in force; continue in the existing isolated checkout.

## Reproduced boundary

Frozen source `f35cbd0`, failed full fixture `native-app-aPqApF`, quality event 42:
minimum revision 4, `reason=time`, diagnostic `kind=source`, source sequence 35.
The source ends at uptime 1908623.4927788752. Its age is 1.983599167 seconds at
selection and 2.001051667 seconds at evaluation, after 17.4525 ms of scheduling.
The native two-second time guard correctly rejects it and invalidates policy health.
Both owned decoder faults, all five profile phases and the UI workflow complete;
that does not make the full qualification pass.

The source helper's separate sample age is 0.732532 seconds. Independent review
brackets it in [0.732529458, 0.732568708] seconds using decoder report 1814. Cadence
report 1820 is independently fresh at 0.119778875 seconds. The 250 ms cadence gate
and two-second source gate apply to different observations; never conflate them.
The current repeated verifier deliberately permits only proved cadence-freshness
rejections. Its rejection of this unsupported source/time case must remain in the
original artifact; a blanket metadata whitelist would be wrong.

## Required contract

Add a separate typed source-expiry invalidation only in acknowledged minimum
recovery (revision 2 or 4). Require exact reason/kind, null cadence receipt, matching
diagnostic source key, and original event index. Join the original exported source
interval and its independently qualified proof uniquely, including publication,
worker, native encoder configuration and reset ownership. Prove all other native
time conditions: valid duration, sequence, ordering and acknowledged boundaries.
Selection must be at most two seconds after the source end; evaluation must be
strictly later than two seconds. Arithmetic tolerance may cover representation
rounding only. Independently bound source-report freshness at evaluation to at most
two seconds and validate its status lease and unchanged owner. Preserve independent
cadence validation. Do not accept arbitrary time errors or already-expired selection.

A rejected source consumes the driver's source key but consumes no Core policy
sequence or successful window. Advance the original source-observation cursor and
its end exactly once. Keep the last policy sequence unchanged, clear baseline and
healthy-since state, and award no window, duration or healthy credit. Require a new
whole recovery prefix after the invalidation; a subsequent valid decision can
truthfully carry `telemetryGap`. Avoid conflating source continuity with policy
health continuity. Preserve all existing cadence invalidation checks.

## Execution

- [x] Trace source helper receipt retention/replacement and independently reconstruct
      the first accepted report clock from raw exports. Specify unique joins and
      status lease arithmetic before writing the positive fixture.
- [x] Add timestamp-backed positive and negative tests: ownership/clock/configuration
      changes, missing/duplicate proof, reversed clocks, already-expired selection,
      age at most two seconds at evaluation, stale report/lease, duplicate source
      consumption, policy-sequence advancement and reused recovery credit.
- [x] Implement the narrow typed source-expiry proof and policy replay cursor update.
      Keep runtime thresholds and exported evidence unchanged.
- [x] Independently review the proof and integration; run focused and full JS checks.
      Add native tests only if runtime behavior changes or a missing ownership
      assertion must be established.
- [x] Reconstruct the preserved run as a separately labelled diagnostic using the
      new verifier; never overwrite its original failed result or claim that a
      changed verifier was the frozen original harness.
- [x] Commit/freeze source and run a fresh strict complete native fixture, joining
      all owned processes and auditing unchanged source plus cleanup.
- [x] Update the main plan honestly. A fresh complete pass remains laboratory
      qualification only; production upgrades, physical devices and remote hosts
      retain their existing gates.

## Implementation evidence

The typed proof retains original event/source/proof/report indices. It independently
joins the first retained decoded helper, unchanged subsequent source windows, the
original status lease, source boundary crossing and separate fresh cadence. The
policy consumes the source key without advancing its decision sequence, clears
health and starts new whole recovery coverage. Source expiry never grants a stale
cadence exception. Probe readiness handles this typed invalidation by evaluation
time, including rejection logging after asynchronous probe allocation.

Independent review caught and resolved the readiness integration omission; final
review approves the complete change. All 3,415 tooling tests pass, including 49
source-expiry tests, readiness joins/negatives and a full raw composition regression.
No native runtime or thresholds changed. Earlier test runs preserve setup mistakes
and overly narrow expected-error expressions; corrected runs pass without relaxing
the assertions that reject bad evidence.

`native-app-aPqApF/source-expiry-diagnostic-reconstruction.json` separately records
the new-verifier result. Original event 42 joins source 35 / source and proof index
33 / original report 1814 / fresh replacement report 1821. The second new whole
recovery covers 14.999996 seconds after fresh availability. Its archived synthetic
raw fixture is `scripts/test/fixtures/repeated-source-expiry-aPqApF.json.gz`, with
all 16 raw-export provenance hashes checked independently. This contains no real
match footage. Original harness exit 1 remains unchanged; production upgrades
remain unauthorized. At that reconstruction checkpoint, full A/V, owned backend
and cleanup gates still required the fresh run documented below.

## Fresh frozen complete qualification

`23f0479` / `native-app-Gx1pcB` passes the complete strict repeated route, harness
exit 0. Native scoring, clean archive/export, both measured admissions, all five
240p/360p phases, two owned decoder faults, minimum resets and both whole recoveries
qualify. UI takes 257.764 seconds. This run has no rejected quality events; the
preserved raw source-expiry fixture provides the rejection-path regression.

The archive has 6,546 contiguous frames (0–6545); live has 6,139 contiguous frames
(192–6330). Both MP4s fully decode. Archive finishes with 13,092 written samples,
zero queue drops/rejections. All 108 archive audio markers and 102 expected live
markers match; maximum live offset is 65.25 ms, drift −0.103 ppm. All 276 deadline
rows replay with zero unknown rows; 30 missing deadline observations from controlled
faults remain in the evidence. Whole recoveries cover 10.001922 and 10.000339 seconds.

All 1,162 tracked hashes remain unchanged with a clean working tree. Worker,
encoder and recorder exit zero naturally; the owned simulator and ingest container
are removed, with no known owned processes remaining. Candidate-wait evidence is
closed/valid with 1,005 events and zero omission/overflow. Evidence:
`native-app-Gx1pcB/source-expiry-assessment.json`,
`repeated-measured-recovery-qualification.json`, `results.json`, and
`artifacts/qa/source-expiry-source-verification.json`.

Production upgrades, physical phone/watch, sustained representative 4K, impaired
networks and remote hosts remain unqualified. Next:
[observe actual native encoder selection](2026-09-24-native-hardware-selection.md).

Related files: `scripts/repeated-recovery-invalidation.mjs`,
`scripts/repeated-measured-policy.mjs`, `scripts/repeated-measured-native-recovery.mjs`,
`ios/Sources/Scorebug/Capture/PublishingQualityDriver.swift`,
`PublishingQualitySession.swift`, `PublishingQualityTelemetry.swift`, and
`WorkerSourceIntervalTracker`'s actual implementation. Consult the existing
source-interval qualifier rather than duplicating or weakening its proofs.

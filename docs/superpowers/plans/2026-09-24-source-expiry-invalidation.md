# Independently prove source-expiry invalidation during minimum recovery

Status: diagnosed; implementation not started. Continue in the existing isolated
checkout. User authorization for autonomous local work remains in force.

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

- [ ] Trace source helper receipt retention/replacement and independently reconstruct
      the first accepted report clock from raw exports. Specify unique joins and
      status lease arithmetic before writing the positive fixture.
- [ ] Add timestamp-backed positive and negative tests: ownership/clock/configuration
      changes, missing/duplicate proof, reversed clocks, already-expired selection,
      age at most two seconds at evaluation, stale report/lease, duplicate source
      consumption, policy-sequence advancement and reused recovery credit.
- [ ] Implement the narrow typed source-expiry proof and policy replay cursor update.
      Keep runtime thresholds and exported evidence unchanged.
- [ ] Independently review the proof and integration; run focused and full JS checks.
      Add native tests only if runtime behavior changes or a missing ownership
      assertion must be established.
- [ ] Reconstruct the preserved run as a separately labelled diagnostic using the
      new verifier; never overwrite its original failed result or claim that a
      changed verifier was the frozen original harness.
- [ ] Commit/freeze source and run a fresh strict complete native fixture, joining
      all owned processes and auditing unchanged source plus cleanup.
- [ ] Update the main plan honestly. A fresh complete pass remains laboratory
      qualification only; production upgrades, physical devices and remote hosts
      retain their existing gates.

Related files: `scripts/repeated-recovery-invalidation.mjs`,
`scripts/repeated-measured-policy.mjs`, `scripts/repeated-measured-native-recovery.mjs`,
`ios/Sources/Scorebug/Capture/PublishingQualityDriver.swift`,
`PublishingQualitySession.swift`, `PublishingQualityTelemetry.swift`, and
`WorkerSourceIntervalTracker`'s actual implementation. Consult the existing
source-interval qualifier rather than duplicating or weakening its proofs.

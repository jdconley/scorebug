# Align production candidate start with fresh source health

> Use superpowers:subagent-driven-development with specification then quality review. Existing autonomous implementation authorization applies.

**Goal:** Make normal candidate measurement and fresh receiver/source evidence overlap reliably without relaxing admission, backoff, media deadlines or native probe bounds.

**Current status:** Run13's bounded samples establish a timing mismatch. A five-second receiver source window arrives fresh, but receiver probe time bounds still reject the completed candidate; when receiver proof becomes usable, source age exceeds the unchanged two-second limit. No demand hint is learned because no fully valid evaluation occurs. New source reports are installed promptly; sender observation bucket size does not set this receiver cadence. The scheduling change below is a hypothesis requiring a failing regression before implementation.

## Design

For ordinary production plans only, complete the existing half-rate/full-rate stages and all required holds before awaiting the next qualifying source-health window. Then bind the already-settled final probe and start the candidate immediately. Preserve immutable per-attempt stage/rate selection, joined replacement/retirement, current source-coverage authority, candidate duration, two-second cost lifetime,300ms probe lease, source-wait deadline and all native12Mbps/16MiB/60second bounds. Source readiness remains a trigger, not admission or guaranteed capacity. Keep the existing fixed laboratory ordering unchanged.

This deliberately spends longer at final padding rate while waiting for fresh source. Native pressure, lease renewal, byte/time caps and cancellation must remain active during that wait, with exact cleanup. Do not lower final hold duration, extend source/candidate deadlines, invent future receiver evidence, or change five-second wire telemetry. If a faithful regression does not reproduce the proposed mismatch, stop and reassess the hypothesis rather than changing runtime order on intuition.

## Tasks

- [ ] Add a faithful failing production-schedule regression with half/full0.8/0.5 holds, four-second candidate, five-second source cadence and measured/report-lag receiver time bounds. The existing laboratory cadence fixture with immediately synthesized receiver proof is insufficient.
- [ ] Implement explicit production-only source-wait placement after final hold, retained immutably by each lease. Preserve fixed-plan behavior.
- [ ] Cover ordering, bounded full-rate source wait, cancellation/timeout/pressure/cap cleanup, immutable final binding and original admission/recovery guards. Do not add duplicate or implementation-mirroring tests.
- [ ] Run relevant owned/session/admission/model suites and DebugUI/Releasearm64builds. Resolve independent specification and quality reviews before commit.
- [ ] Run a fresh sampled ordinary vertical after offline work joins. Require actual candidate evaluation and acknowledged increase; inspect previous attempt reasons. Independently qualify media after a successful runtime change. Preserve failed artifacts and the separate waveform-estimator finding.

Repeatable native progress, paired Watch, congestion recovery, physical devices and remote workers remain separate delivery gates. No single successful run establishes all of them.

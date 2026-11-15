# Causal native probe-read intervals

The q6s6KU trace proves a same-owner renewal during a 30.215 ms context await.
The initial snapshot remained live but was exported as current at binding time.
The complete failed run and its source/evidence remain immutable.

## Contract

Repeated candidate envelope version 5 requires `readStartedAt` and
`readFinishedAt` on both initial and final probe snapshots. These bound the actual
awaited probe read. `observedAt` retains its existing application-observation
meaning (initial binding instant or final validation instant), with
`readStartedAt <= readFinishedAt <= observedAt`. Initial read finishes before
binding; final read starts after measurement end and completes before candidate
completion. The original snapshot must still have a live lease at its use instant.
Version 4 retains its original strict replay and cannot opt into bracket semantics
by adding fields. Non-repeated native exports and qualification stay unchanged.

The v5 replay requires a possible native snapshot instant inside the read bracket
consistent with every native acceptance and lease-renewal event. Events whose
observations completed before read-start must be reflected. Counter increments
and lease renewals after read-end cannot be borrowed. Within overlapping reads,
all counter and lease constraints must admit one common snapshot order, not
independently chosen favorable times. Keep exact existing token pacing, equal
counter/timestamp consistency, stage/campaign/generation identity, maturity,
retirement-before-use rejection and lease-at-use checks. No time tolerance or
freshness/bandwidth relaxation is introduced.

## Execution

- Parent audits JS binding consumers and owns verifier/schema plumbing, synthetic
  regressions, documentation, all serial tests/builds and native experiments.
- One native implementation subagent owns publisher snapshot export and native
  tests. Write RED tests first; parent runs them before implementation. Reuse the
  same start/return timestamps for the diagnostic trace, without deriving runtime
  evidence from optional diagnostics. Preserve guard/await order and ownership.
- Add a deterministic gated-context renewal case, final read ordering,
  cancellation/late-read coverage, and legacy shape isolation.
- JS regressions cover a renewal after the read but before bind, renewal within
  an ambiguous read, malformed/missing/reversed brackets, future acceptance or
  leases, pre-read regressions, incompatible mixed counter/lease histories,
  expired leases, terminal ownership and v4 isolation. Cross-proof reconciliation
  must use the new exact bounds and retain cached-admission semantics.
- Independent specification then quality review, focused tests, full Core/tools/
  FilmModel checks as affected, simulator build, then one frozen native run.

A passing component replay does not reclassify q6s6KU or enable production quality
increases. Later policy time-rejection/recovery and startup audio gates remain open.

## Component verification

The native publisher and all repeated binding consumers now implement the v5
contract. The publisher brackets each actual awaited probe read, keeps the original
use timestamps, and preserves the frozen final snapshot against late appends.
The verifier joins the original candidate proof through admission, witness,
retirement and receiver paths. Cached admission observations retain their own
completion-to-evaluation bounds rather than borrowing the final candidate read.

Failing-first native and JS regressions reproduced the missing contract. The
focused native suite passes 55 tests; full FilmModel passes 486; tools pass 3,349.
The arm64 iOS simulator build succeeds. All commands exited zero and were joined
(`repeated-live-checkpoint-probe-read-interval-*` QA logs). The unchanged Core
package retains its previous 459-test passing evidence. Independent specification
and quality reviews approved the implementation. The fresh native result below establishes component progress, not complete qualification.

## Frozen native verification

Source `3040495`, `native-app-3ynqcN`: all 922 frozen hashes unchanged. Native UI
passed in 258.376 seconds, both v5 candidates completed, and independent admission,
profile, policy, owned fault and delivery coverage replay passed. All processes
joined; owned cleanup completed. The full harness exited 1 at readiness:
`Shared recovery evidence was unavailable at native begin`.

Campaign two began at 1897431.4154335835. Source sequence 15 evaluated at
1897431.3215112085 and expired at 1897431.5130364585. Shared source recovery
[1897419.5123606669, 1897429.5130364585] needs overlapping delivery rows 112
(one second) and 114 (two seconds). Their receipts first reached the app after
begin, and the final row evaluated at 1897432.8206513335: 1.405218 seconds late.
No quality rejections occurred. The next fresh source evaluated at 1897436.22089525.

Both full A/V decodes and coverage pass: archive 6,526 contiguous frames, live
6,120, both 30 fps. Live maximum gap is 34 ms, 102 matched audio markers have
maximum error 64.917 ms and negligible drift, audio leads video by 349 ms. Direct
recorder delivery passes with 36 acquisition frames and successful worker/recorder
exits. The candidate-wait trace closed valid with 956 events / 332,282 bytes.

Evidence lives in ignored `artifacts/qa/native-app-3ynqcN`, including diagnostic
media, component, policy and complete assessments. Original raw artifacts remain
unchanged. The next repair must delay repeated probe scheduling until typed delivery
coverage and fresh source readiness both qualify; it must not relax replay.

# Shared delivery readiness before a repeated probe

`native-app-3ynqcN` (source `3040495`) independently qualifies both admissions and
policy recovery, but campaign two starts 1.405218 seconds before the delivery tail
for its ten-second source recovery is available. Preserve the failed run and the
strict `repeated-native-readiness.mjs` gate. This is a scheduler prerequisite,
not a reason to relax media, source health, freshness or ownership.

## Design constraints

- Opt in only for the existing explicitly requested repeated native fixture.
  Initial campaign readiness stays source-only; recovered baseline scheduling
  requires both fresh existing Core readiness and completed delivery coverage.
- Centralize the conjunction at `PublishingQualitySession`'s measurement context
  boundary, which both probe and candidate publishers already reread. No extra
  encoder/probe ownership or publication work is introduced.
- Consume bounded typed successfully validated source windows and delivery
  observations. Audit JSON is never runtime authority; positive delivery rows do
  not add Core recovery credit or authorize a quality action.
- Require a whole source-window prefix of at least ten seconds inside the current
  Core healthy segment and both contiguous, completely healthy 1s/2s delivery
  lanes. Preserve the fixed completed prefix while a later fresh source window
  arrives; requiring delivery through every latest source end would perpetually
  chase a report that arrives after that source expires.
- Keep current configuration, revision, recording/match/publication scope and
  revocable delivery authority joined. Match the remote worker ID, epoch, attempt,
  publication to the current source/cadence owner, too; local identity alone cannot
  combine an old worker source with new worker delivery. Delivery and cadence scope
  IDs are separate namespaces: retain each owner independently, never equate them.
  Clear scheduling evidence on invalidation,
  unknown/uncertain classification, missing input, gaps, changed ownership, writes
  and stop. Bound retention and fail closed on malformed or excessive history.
- A typed negative signal must distinguish failed/missing delivery evidence from
  an ordinary poll with no completed window. Do not silently retain a qualified
  prefix after an audit classification failed. Preserve downward actions.

## Execution

Parent owns source/evidence assessment, final design review, project generation,
all serial test/build/native commands, documentation and commits. One native
implementation subagent owns the bounded helper, session/driver plumbing and
regressions. Independent specification then quality review precede a fresh run.

1. Agree the minimal typed contract, then add native regressions first. Parent
   establishes RED before the implementation is written.
2. Reproduce source ready → delivery tail pending → no context; delivery complete
   but source expired → no context; fresh next source + completed prefix → context.
   Cover moving-tail avoidance, owner/revision changes, revocation, uncertainty,
   gaps, cancellation, stop, bounded storage and unchanged initial/legacy behavior.
3. Implement without changing raw evidence formats or replay thresholds. Run
   focused native tests, affected full checks, simulator build and reviews.
4. Commit/freeze sources, run one complete repeated native route, join cleanup and
   independently verify media and policy. Preserve every failed artifact.

Production upgrades remain disabled. Other historical startup-audio, policy-time
and short-readiness-window failures remain open until separately reproduced/fixed.

## Design review

Independent quality review approved the constraints with the explicit remote
worker identity join incorporated above. The selected implementation contract uses
a bounded locked typed helper for whole source windows and two delivery spans.
Session owns the optional helper; synchronous invalidation can run before a driver
actor suspension. Delivery batches containing any unavailable evidence suppress all
positive scheduling observations while keeping the existing downward path.

## Failing-first verification

The initial tests-only snapshot fails to compile against the old implementation
with the expected missing typed `onUnavailable` contract (`shared-delivery-readiness-red`,
joined exit 65). New regressions cover completed-prefix stability, whole-window
alignment, both delivery lanes, uncertainty/loss/gaps, bounded storage, explicit
invalidation/resumption, source-versus-delivery timing, cancellation/retirement/stop,
and unchanged initial/legacy behavior. Implementation follows this RED checkpoint.

## Focused implementation verification

The session now joins an opt-in bounded coverage helper to current Core readiness,
local configuration and remote source/delivery/cadence ownership. Healthy typed
source windows and both delivery spans must contain a whole ten-second prefix.
Fresh source is queried anew; completed history does not extend its expiry.
Monitor callbacks invalidate synchronously before driver awaits and suppress all
positive scheduling observations in a mixed batch, preserving downward actions.

Focused verification passes 96 tests (`shared-delivery-readiness-green2`, joined
exit 0). The first run had one failing new positive case: its test pressure samples
ended at integer seconds before the fractional source-window boundary. Diagnostic
Core decisions correctly reported unknown pressure. The fixture now supplies the
actual final sample at its current time; no runtime threshold changed. All temporary
diagnostic prints were removed. Independent specification and quality reviews approved. Full FilmModel passes
498 tests and the arm64 simulator build succeeds (joined exit-zero checks). Core
and JS are unchanged from their 459/3,349-test passing evidence. One fresh frozen
experiment is next; full native qualification remains unproven.

## Frozen native pass

Source `89926f4`, run `native-app-cbBvJb`: **complete repeated laboratory route PASS**,
joined harness exit 0, native UI 257.729 seconds, all 924 frozen source hashes unchanged.
Both admissions, five native phases, confirmations, owned decoder faults, resets,
shared recoveries, readiness joins, direct-recorder delivery and full A/V gates pass.

First shared recovery qualified at 1899440.7725119584; campaign two began at
1899444.8923889168, 4.119877 seconds later. Its current source health extends through
1899443.0243494168, while the completed shared prefix ends at 1899438.0249034585.
Thus the runtime waits for delivery and then rereads fresh source without moving
the required prefix forward. No quality rejection events occurred.

Archive/live: 6,538/6,130 contiguous 30 fps frames, complete decoded A/V coverage.
All 102 live audio markers match within 65.583 ms, drift is negligible, audio leads
video by 287 ms. The direct recorder accounts for 38 acquisition frames and no lost
encoded tail. All 274 deadline rows replay; 25 intentional fault deadline misses
remain recorded, with no unknown rows. Cadence retains 2,056 reports. The valid
closed wait trace contains 1,007 events / 350,355 bytes, no overflow or omissions.
Worker, recorder, simulator and container cleanup joined successfully.

Raw evidence, `results.json`, complete repeated qualification, live reconciliation
and compact `complete-assessment.json` remain in ignored
`artifacts/qa/native-app-cbBvJb`. The preceding failed runs remain unchanged. This
passes the repeated local laboratory milestone; production upgrades, network-loss
recovery, physical devices and other proxy hosts remain unqualified.


## September 24 regression: frame buckets at capture-clock boundaries

Frozen `582a339`, `native-app-gN2v2o`, fails before campaign two. A lossless
one-second delivery bucket has 29 expected/on-time frames while its neighbor has
31; two-second buckets likewise vary 59/61. Source PTS remains continuous at 1/30s
and surrounding five-second source windows contain 150 captured/encoded/received
frames. For example, the last capture before uptime 1905000 is 1904999.9989603334;
the next is 1905000.0315604168, and the frame near the following boundary is
1905001.0004223334. No frame is missing, late or uncertain.

Both the monitor and coverage helper currently invalidate recovery whenever a
bucket falls below exactly 30 fps, repeatedly destroying the shared prefix. The
second probe reports `readinessUnavailable`. This is a measured readiness-contract
problem, not evidence that native probe allocation failed.

Reviewed correction: allow **at most one frame below nominal** in only the existing
one/two-second delivery buckets (29/59), with every expected frame delivered on time.
Preserve zero loss/uncertainty, contiguous lanes, ten seconds of whole shared source
windows, current ownership and fresh Core strong health (at least 29.7 fps). A
29-frame delivery bucket alone never qualifies recovery; the 24 fps operating floor
is not the recovery threshold. Apply the same contract to monitor invalidation,
native coverage and independent single/repeated recovery replay. Do not alter source
FPS, timestamps, raw counts, deadlines, loss gates or unrelated 30 fps assertions.

Implementation sequence: timestamp-backed native audit and independent replay
regressions plus bounded-coverage tests must fail against the current strict rule.
Then apply the small rule change and verify positives for 29/31 and 59/61, negatives
for 28/58, loss, uncertainty, gaps, ownership and insufficient source health. Run
native and JS checks, then freeze and run the complete repeated fixture. Preserve
`gN2v2o` as failed regardless of the corrected replay rule.


The correction is implemented. Tests-first native verification fails at the coverage
helper and monitor invalidation assertions (45 tests, two expected failures), then
passes all 45 after the change. Timestamp-backed repeated-policy replay first fails
its strict 30 fps check; the corrected affected suites pass 178 tests. Review found
an additional final coverage gate: it now uses the corrected predicate only for an
explicit recovery mode; probation and the earlier deadline baseline stay unchanged.
Its separate failing-first regression passes after correction. Native 28/58-frame,
24 fps, loss, uncertainty, discontinuity and insufficient source-prefix tests remain
negative. Full native model verification passes 502 tests (66.902 seconds). Independent
review approves the runtime and replay correction, including explicit recovery-only
final coverage. All 3,353 JS tool tests and the simulator build pass. A fresh frozen repeated run follows.


## Frozen correction regression

`d73461b`, `native-app-hT3aOi`: harness **FAIL**, UI workflow passes in 262.682 seconds,
all 1,155 tracked file hashes unchanged. Both native probe campaigns run, the second
360p trial confirms, and recovered readiness is reachable. This is not the required
two controlled-fault cycles: the first trial loses freshness before confirmation,
so the fault scheduler never starts either owned pause. Four profile phases occur,
240p → 360p → 240p → 360p, with no final controlled reset. Preserve the failure.

The first trial's rejected cadence receipt is 243.464125 ms old in its audit row
at uptime 1906271.6720534167. Its server upper bound is 143 ms, request time
97.347417 ms, and audit residence 3.116708 ms. At session evaluation uptime
1906271.690563, its age is 261.973750 ms, beyond the unchanged 250 ms limit.
The first trial is safely revoked; a later healthy recovery admits campaign two.
Do not relax freshness or reclassify this as a complete pass. The second campaign
confirms, but cannot replace the missing original first confirmation in this fixture.

The bounded candidate-wait export is closed/valid with no omissions or overflow.
Archive diagnostics report 13,072 written samples, no queue drops/rejections and a
finished writer. Worker/recorder exit zero; simulator deletion completes. The full
media/qualification pipeline exits at the failed fault scheduler and reports a
secondary owned-cleanup error, so neither full media qualification nor clean harness
success is claimed. Compact evidence is `boundary-count-assessment.json` in the run.
Next native runtime work addresses the independently measured 4K audio starvation;
repeat this strict fixture after that implementation, preserving this freshness case.

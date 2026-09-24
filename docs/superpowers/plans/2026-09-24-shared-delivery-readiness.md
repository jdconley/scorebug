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

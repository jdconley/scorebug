# Repeated native verification implementation plan

> **For agentic workers:** Use subagent-driven-development for bounded native-probe and receiver-evidence tasks, with the parent handling profile/policy/harness integration. Run heavy verification sequentially and obtain independent specification and code-quality review.

**Goal:** Independently verify two complete native upgrade/fault/reset/recovery cycles, then exercise them through the real simulator A/V pipeline without changing production upgrade permission.

**Architecture:** Preserve the current single-cycle verifier. Add explicit repeated-campaign proof support with original campaign/revision identities; do not relabel later evidence as revision zero or convert v3 wire reports into v2. Share invariant checks only where both formats have the same meaning. The combined repeated verifier must account for all five native profile phases, both candidate measurements, both faults, and every intervening ownership/health transition.

**Tech stack:** Node built-in test/assert, versioned Swift JSON exports, existing SRT v3 telemetry and native simulator harness.

## Design decisions

Each cycle is 240p→360p→240p. Campaigns 1 and 2 have independent 16 MiB / 60-second budgets and distinct stage IDs. Campaign 2 requires the same publication clock and newer applied revision; its readiness must follow the first reset and independently reconstructed recovery. A new campaign cannot inherit receiver bytes, encoder cost, or healthy duration from the old one. Full local archive and live decoding remain required, including source-frame IDs, 30 fps timing and audio markers.

Use bounded version-aware verification instead of cloning or rewriting old artifacts. Existing single-cycle fixtures retain their original acceptance/rejection behavior. The user already authorized autonomous implementation; these are local implementation and verification choices, requiring no deployment or new permission.

## Tasks

- [x] Native probe replay: add `qualifyRepeatedNativeBandwidthProbe` in `scripts/repeated-native-bandwidth-probe.mjs`, consuming raw v3 two-campaign exports. Verify ordered stage identities, cumulative/local byte deltas, pacing, lease bounds, terminal joins, campaign separation, readiness metadata and bounded events. Return summaries that explicitly retain campaign identity and do not claim capacity or repeated policy success. Add `scripts/test/repeated-native-bandwidth-probe.test.mjs` with a valid two-campaign fixture and mutations for reused IDs, crossed campaign, stale revision, malformed context, counter reset/carry-over, unjoined/overlapping ownership, nonmonotonic times and excess budgets. Run the test before implementation to establish RED, then after implementation for GREEN.
- [x] Receiver v3 replay foundation: extend raw validation/progress in `scripts/receiver-probe-evidence.mjs` for `mpegts-null-probe-v3`, retaining v1/v2 behavior. Require bounded positive campaign and campaign-delivered counters, same-campaign continuity, fresh restart identity, and nonregressing publication totals. Add failing-first mutation tests in `scripts/test/receiver-probe-evidence.test.mjs` or a separate v3 test file. Do not enable the repeated harness merely because wire reports validate.
- [x] Native media phases: add explicit repeated sequence support to `scripts/native-profile-transitions.mjs`, requiring exactly 240/360/240/360/240 with original receipts, frame continuity and decoded transition evidence. Add failing-first tests for missing/reordered phases, receipt chain breaks and changed dimensions.
- [x] Combined campaign admission: extend receiver interval and candidate-witness replay with original campaign and applied revision; join each candidate proof to the corresponding real baseline phase and exact native profile request. Test cross-campaign substitution, stale measurement and receiver-counter carry-over.
- [ ] Policy/fault replay: qualify each confirmed trial, each exact decoder fault, each reset and recovery, preserving the global event timeline. Verify second-campaign readiness occurs after first recovery and that no ignored events or missing cadence coverage can manufacture healthy duration. Add malicious mutations and preserve existing single-cycle checks.
- [ ] Harness: add explicit repeated options, two causally triggered owned decoder pauses after the respective confirmed trial, bounded 180-second hold and new raw fault envelope. Keep legacy routes unchanged. Require the complete repeated verifier plus all existing archive/scoring/A/V gates before a pass.
- [ ] Run `pnpm test:tools`; obtain independent spec/quality review, then build and run the full native simulator fixture on frozen sources. Preserve raw outputs and failures, decode archive/live media, and compare every cycle. Fix observed failures with failing-first regressions; never relax thresholds to obtain a pass.
- [ ] Update this plan and the portable streaming/Watch plan with evidence and remaining work. Commit verified changes. Continue physical devices and remote proxies; production automatic upgrades remain disabled until their required qualification is complete.

## Evidence

Base commit: `cbbbc8d`. Previous goal turn: progress (native repeatable scheduling, 3,200 passing tests and Release build). Use unique `artifacts/qa/repeated-native-verification-*` files; preserve old raw evidence. Whole-run success is not implied by a component replay pass.


## Replay foundation checkpoint

Tasks 1–3 are implemented. The native replay preserves two original campaign
identities, their applied revisions and readiness metadata, independent aligned
16 MiB / 60-second budgets, ordered stage IDs and leases, and each actual joined
terminal event. Its output explicitly grants neither receiver capacity nor policy
qualification. The v3 receiver validator retains campaign-local and publication
counters, checks pending-message reservations and boundary continuity, and keeps
legacy qualification closed to v3. Polling may skip ordinals or first observe a
restart after messages arrived; the replay does not invent zero snapshots.

Native media exports use a new explicit formatVersion 9 / repeated240 sequence.
The recorder supports five bounded phases, while independent replay requires all
five 240/360/240/360/240 phases, exact receipt ownership, distinct encoders, real
sync frames and decoded boundary/tail coverage. The old measured240 sequence keeps
its original maximum of three phases and cannot accept this new envelope.

Fresh checks: all 439 FilmModel tests and all 2,459 tool tests passed; the supported
arm64 iOS simulator build passed. The generic simulator build failed for x86_64:
the bundled fat SRT archive advertises both architectures but has no `_srt_accept`
definition in its x86_64 slice, while arm64 contains that definition and links.
The original failed log is retained; this checkpoint does not claim Intel simulator
support. No source changes were made to bypass that linker failure.

There has been no full repeated native A/V run. Tasks 4–8 remain required before
that route can pass. In particular, current witness/policy replay assumes a
bootstrap at revision 0 and one trial/reset; later campaigns need explicit original
revision and event-index context, not rewritten or filtered artifacts. The lifecycle
checker already iterates native applications but still requires the old sequence
identifier. Receiver interval rows currently export native probe ID/stage but not
native campaign; add explicit v3 campaign correspondence as part of task 4. Match
candidate A/V frames to the real baseline phase for each cycle, then account for
all policy events and source/cadence windows across both faults and recoveries.
Production upgrade permission remains disabled.

Independent specification and code-quality reviews approved tasks 1–3 with no
remaining actionable findings. The unsigned iPhone/Watch Release build also passed.


## Task 4 execution boundaries

Use two bounded implementation workers alongside parent integration: one owns
independent repeated receiver reconciliation; one owns candidate envelope replay.
The parent owns explicit Swift native-campaign export and the later admission/
lifecycle/policy joins. Each new public replay function consumes raw versioned
proof, revalidates its native dependencies, retains original scope/campaign/revision,
and returns false qualification flags until the complete combined gate succeeds.

`qualifyRepeatedReceiverProbeEvidence(records, scope, nativeProof)` belongs in
`scripts/repeated-receiver-probe-evidence.mjs`. It replays native acceptance itself,
requires authenticated publication ownership and a single receiver clock offset,
reconciles all six stages and exact per-campaign/publication totals, and reserves
pending messages. It must reject missing/crossed stages or publications and cannot
turn delivered padding into spare capacity.

`qualifyRepeatedNativeCandidateMeasurements(proof, {scope, nativeProbe, format,
snapshot, liveIDs})` belongs in `scripts/repeated-native-candidate-measurement.mjs`.
It validates the original v4 two-campaign envelope, replays the v3 probe and v9
five-phase media, applies the existing full v3 candidate A/V validator to each
actual baseline phase, and checks distinct measurement/encoder identities,
chronology, campaign/revision and exact source-frame correspondence. Native probe
binding is checked against the matching third stage; admission-time receiver
headroom and recovery causality remain for the combined gate.

The Swift interval export adds nativeProbeCampaign only when the accepted native
probe has a campaign. Legacy evidence stays unchanged; v3 endpoints and accepted
native campaign must agree. Add failing-first tests that exercise the real tracker
and preserve both valid campaign metadata and rejection of crossed ownership.

## Candidate and receiver boundary checkpoint

The two repeated replay modules now consume their original versioned raw proofs.
Receiver reconciliation accounts for all six stages, per-campaign byte resets and
continuous publication totals, pending-message reservations, one publication and
a common receiver clock offset. Candidate replay validates both complete A/V
measurements against their actual native and decoded baseline frames, independent
encoder identities, original revisions, joined prior ownership, and the matching
third-stage native probe. Interpolated native observations must satisfy both
lifetime pacing and the one-message allowance in both directions against every
native checkpoint and between binding endpoints. Stable acceptance counts and
timestamps remain valid across lease renewals.

The Swift diagnostic export now preserves nativeProbeCampaign and rejects a
receiver interval whose endpoints disagree with the accepted native owner, even
when that row would otherwise be deduplicated. Regression coverage includes
crossed campaign, missing campaign, ID, stage, generation and bitrate.

All 440 FilmModel and 2,565 tool tests passed. The arm64 simulator and unsigned
iPhone/Watch Release builds passed. Failing-first evidence and subsequent checks
are preserved under `artifacts/qa/repeated-native-binding-*`.

Independent specification and code-quality reviews approved this checkpoint.
Review regressions cover the reciprocal pacing gap and unchanged-count timestamp
consistency. All 269,138 previously frozen evidence files remain unchanged.

Task 4 remains open: the interval replay, candidate admission witness, exact
profile request and native retirement/lifecycle joins still need explicit
repeated-campaign support. Full policy/fault/recovery replay and the two-fault
harness follow those joins. The new component outputs explicitly grant no
receiver capacity or policy/upgrade permission. No full repeated native A/V run
has been performed, and production automatic upgrades remain disabled.

## Native lifecycle and retirement joins

Before interval/admission replay can use the third stage's load, independently
bind its retirement to the corresponding native profile request. A bounded probe
worker owns `qualifyRepeatedProbeRetirements(nativeProof, {lifecycle, quality})`
and its mutation tests; the parent owns the shared five-phase fixture and explicit
repeated lifecycle replay. Preserve the raw campaign exports and global quality
event list. Require exactly two trials and two resets, original revisions 0–4,
distinct candidate/application/request identities, and the real receipt chain.

Extend `qualifyMeasuredNativeLifecycle` with an explicit `sequence` option whose
default remains measured240. For repeated240, independently replay the raw v9
media with decoded frame IDs, require four native profile requests and five
bitrate requests, preserve all existing startup/timing checks, and reject skipped
revisions, overlapping applications, stale reset candidate ownership, or a second
trial before the first reset. This output proves receipt correspondence only.

The retirement verifier consumes raw v3 native probes and the original lifecycle
and quality exports. Each trial must synchronously own the active matching
campaign before its exact profile request, and its terminal read must match the
joined cancelled native owner. Repeated probe final events may precede the
lifecycle terminal read because the native wrapper awaits the profile receipt
first; validate causal request/read bounds without reusing the legacy stop-time
ordering. Include rejection tests for cross-campaign substitution, acceptance
after withdrawal, impossible intermediate pacing, stale authority, and resets
masquerading as trial retirement. Keep admission, recovery, policy and production
permission false until the combined gate succeeds.

## Native lifecycle and retirement checkpoint

The explicit repeated240 lifecycle path now independently replays raw v9 media
and decoded IDs, matches all four profile writes and five bitrate writes, and
retains original revisions and global quality event indices. It rejects skipped
revisions, reused measurement/configuration identities, reordered or overlapping
applications, and resets that incorrectly retain active trial authority. Legacy
measured240 remains the default route.

`qualifyRepeatedProbeRetirements` binds both raw v3 campaigns to their exact trial
requests and joined terminal observations, including the later reset's historical
owner. Campaign 1's baseline matches the actual bootstrap receipt; campaign 2's
baseline matches the first reset. Receipt comparison preserves raw UUID spelling
and compares identity semantically because admission exports use lowercase while
native audit/quality exports use uppercase UUIDs.

The admission observation is cached: a valid same-owner renewal may occur before
or after profile dispatch. Replay keeps that cached lease live at dispatch and
validates subsequent native lease/pacing evidence through the observed cancellation,
profile receipt and terminal-read bounds. It does not invent an exact cancellation
instant or require the probe's raw final event to follow the lifecycle read.

All 2,711 tool tests passed, including 146 new lifecycle/retirement tests and the
existing single-cycle regressions. Earlier raw evidence remains unchanged across
269,193 frozen files. Failing-first regressions and checks are preserved under
`artifacts/qa/repeated-native-lifecycle-*`. These changes affect verification and
test fixtures; no new full native A/V run has been performed.

Independent specification and code-quality reviews approved the frozen changes
with no remaining actionable findings. Runtime source hashes match the preceding
verified commit; this checkpoint reran the affected tool suite, not native builds.

Task 4 still requires receiver interval replay and the complete candidate
admission witness for each original campaign/revision. The retirement summaries
now supply the actual third-stage profile request boundary for those interval
checks. Subsequent policy/fault/recovery replay and the two-fault harness remain
required. Component results grant no capacity, admission, recovery, policy or
production upgrade permission.

## Receiver intervals and complete campaign admission

A bounded receiver worker owns explicit repeated interval replay and a shared
raw receiver fixture. The parent owns repeated witness replay and the combined
admission gate. `qualifyRepeatedNativeReceiverIntervals({intervals, records,
scope, nativeProbe, workerRecords, lifecycle, quality})` consumes raw envelopes,
replays native/receiver/retirement dependencies, and preserves global interval
indices. It validates all six stages, exact campaign/publication accounting,
native leases and pacing, conservative freshness, a stable receiver clock and
worker, and independent before/after polling brackets. Edge rows without complete
independent brackets remain checked but cannot contribute covered load.

Add an explicit repeated witness route in `measured-candidate-witness.mjs`, with
original campaign and global quality context. Keep the legacy entry closed to
v3/campaign metadata. Share arithmetic and timing checks without rewriting later
campaigns as bootstrap/revision 0. The repeated route must match the original
baseline event (bootstrap or first reset), third-stage campaign/ID, exact covered
interval pair, captured admission clock and current native observation. Preserve
global row/event indices; later rows cannot improve a historical witness.

The combined repeated admission gate consumes raw candidate, probe, media,
lifecycle, quality, receiver and worker exports and calls those independent
replays itself. Require both actual candidate witnesses, 25% delivered padding
headroom, exact native trial request/receipt ownership and decision deadlines.
This completes the admission portion only; health confirmation, both faults,
recovery and the complete repeated native harness remain separate required gates.


## 2026-09-17: receiver intervals and admission implementation

The explicit repeated receiver route now replays raw native, receiver,
retirement and worker evidence. All six original stages require independent
coverage; unbracketed edge rows stay validated but contribute no load. Global
interval indices, campaign/publication totals and original retirement cutoffs
are retained. App-to-receiver and collector-to-receiver clocks each have one
consistent bound across both campaigns. Worker coverage cannot be borrowed from
another worker attempt.

`qualifyRepeatedCandidateWitness` shares the legacy arithmetic checks while
using the original bootstrap/reset baseline and campaign-specific native history.
It validates the captured pair without retrospective selection or revision
rewriting. The legacy entry rejects repeated envelopes and campaign metadata.
`qualifyRepeatedNativeAdmissions` replays all raw dependencies and joins both
witnesses to their actual native trial requests, exact scalar measurements,
deadlines, encoder receipts and 25% delivered padding headroom. Both campaigns
must pass; media health, recovery, full policy and upgrade flags remain false.

Fresh `pnpm test:tools` passed 2,843 tests (132 added). The combined suite includes
valid complete admissions, stale/crossed ownership, missing raw evidence,
scalar/deadline mutations and independently reconstructed insufficient headroom
in either campaign. Initial failures and subsequent fixes are retained under
`artifacts/qa/repeated-campaign-admission-*`. A test mutation initially added a
non-schema frame field; it was corrected to remove an actual decoded frame.
The runtime source tree is unchanged, so this checkpoint does not require a new
native build. Independent specification and quality reviews approved this admission checkpoint;
all 269,231 previously frozen evidence files remain unchanged. Full policy/fault/recovery replay and the repeated
native harness remain next; no full repeated stream has been qualified.

### Admission review correction

Specification review found that independently plausible native observations
could contradict one another between raw checkpoints. The combined gate now
reconciles candidate initial/final observations, the captured admission probe,
and every interval's matching native observation, including unselected rows.
It uses the same one-message token allowance and unchanged-count timestamp rule
as interval replay. A cached admission probe does not gain a fabricated exact
read timestamp from `clock.after`. Failing-first regressions reproduced ten
messages accepted in ten microseconds and unchanged counts with different
acceptance timestamps; both are now rejected, while a valid bounded interpolation
continues to pass. Specification re-review approved with 185 focused tests.

### Task 5 implementation boundary

Use an explicit `qualifyRepeatedMeasuredNativeRecovery` raw-input entry. Extract
only the generic video/publication/source/processing/report-age/cadence/delivery
replay from `qualifyMeasuredNativeEvidence`, then compose it with repeated raw
admission and five-phase lifecycle evidence. Keep the legacy route closed to
repeated exports. `qualifyMeasuredDeliveryOwnership` already follows arbitrary
original revisions; delivery coverage must name trial revisions 1/3 and recovery
revisions 2/4.

The repeated policy replay must consume one original global event timeline and
retain event/source/policy cursors, applied receipt/revision, source boundaries,
owner, probation and recovery state. Explicit phase/event ranges may share
invariant helpers; do not fabricate bootstrap records, slice away bridge events,
or reset global sequences. Require two confirmations, two owned faults, two
immediate matching resets, shared source/delivery recovery and one final stop.
Preserve ten-second probation within acknowledgement plus 22.5 seconds,
500-ms maximum cadence gaps and 250-ms decision freshness. Each controlled
fault occurs after confirmation, which clears the controller's failure count;
therefore each recovery requires ten seconds, rather than assuming the second
must require twenty seconds.

Use an explicit v2 raw fault envelope with two campaign-labelled pause records,
original confirmation index/candidate/trial revision, process identity and
before/paused samples. Reuse process/sample validation; make trial/reset revisions
and native phase indexes explicit without weakening the legacy stall route.
The second probe readiness must follow independently reconstructed first recovery
and match its actual configuration, health sequence and acknowledgement. Native
readiness duration alone is not health credit.

Create a new full-policy fixture retaining the admission fixture as a component
case. Its present second campaign at uptime 173 is intentionally not evidence of
full recovery after the reset at 160; move the second campaign and all dependent
bindings consistently when constructing the full timeline. Test skipped bridge
events, reset global sequences, reused health/fault/PTS, early second readiness,
cadence gaps, duplicate confirmation, extra resets and foreign-revision delivery.
For Task 6, native quality JSON is currently written at stop, so causal live fault
injection needs a bounded confirmation checkpoint referencing the original event
and candidate. A fixed pause delay is insufficient for the repeated harness.


Quality review additionally established a real causal ordering: the native
candidate snapshot refreshes its current probe after freezing the completed
measurement diagnostic. Symmetric pacing alone allowed that current probe to
regress below the candidate's final accepted count. A failing-first combined
regression reproduced the issue. The gate now enforces nonregressing count,
last-acceptance time and lease from final measurement to admission, without
inventing an exact read timestamp. The focused checkpoint passes 186 tests.


The final ordering check also compares candidate/admission snapshot upper bounds
with actual interval read brackets. Only provably ordered reads receive
nonregression floors; overlapping or unknown reads retain symmetric pacing.
A failing-first final-candidate-to-later-interval regression is preserved in
`repeated-campaign-admission-read-order-*`. Specification and quality reviews
approved the final correction; the focused checkpoint passes 187 tests.
Task 4 is complete. The complete repeated policy, faults, recovery and native
harness are still pending, and production upgrades remain disabled.

## Task 5: fault causality and shared media replay

The next checkpoint implements the explicit two-fault boundary separately from
health credit. The raw v2 envelope has `mode: repeated`, `closed: true`,
`failed: false`, the original publication scope and exactly two `campaigns`.
Each campaign records the original candidate ID, trial revision, global
confirmation event index, owned process identities and before/paused samples.
No fixed timer is accepted as proof that the corresponding trial was confirmed.
The repeated route keeps the full global quality and cadence histories and
matches trial revisions 1/3 to immediate reset revisions 2/4, native phases 1/3
and independently qualified source frames. Fault qualification grants no
recovery, full repeated-policy or production permission.

The parent extracts `qualifyMeasuredNativeMedia` from the existing measured
composition without changing its raw video, publication, worker, source,
processing, cadence or deadline checks. The single-cycle routes immediately use
that shared replay. The eventual repeated composition must also call it before
using structured media results; admission component fixtures cannot stand in for
complete source/cadence/delivery evidence.

The full policy replay still needs one global cursor through all source windows,
trial confirmations, failure/reset decisions and recovery, followed by readiness
joins and both healthy delivery lanes. A useful full-policy fixture can preserve
the existing native phase times: first reset transition 159–161, followed by
whole healthy windows 161–166 and 166–171, then a fresh 171–172 window before
campaign 2 starts at 173. Its native readiness context must be updated to match
that actual policy health history. This avoids assuming that a ten-second
recovery must begin at the next five-second grid boundary. The current compact
fault fixture is only a causality component contract, not this full-policy proof.


The fault checkpoint now rejects confirmation/fault pairs that agree with each
other but differ from the original applied trial. Candidate and confirmation
application, encoder receipt, profile receipt, acknowledgement, revision and
profile must match that actual trial, and the candidate must follow its applied
event. Five failing-first regressions cover this substitution and ordering gap.
The complete tooling suite passes 2,903 tests, including 60 new repeated-fault
cases; the focused new and legacy fault/stall suite passes 152 tests. No runtime
source changed and no new native build or repeated A/V run is claimed. Task 5
remains open until the global policy/recovery replay and readiness joins exist.
Evidence: `artifacts/qa/repeated-policy-replay-*` and
`artifacts/qa/repeated-policy-fault-*`.

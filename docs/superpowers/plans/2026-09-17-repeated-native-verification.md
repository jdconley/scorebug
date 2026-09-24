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
- [x] Policy/fault replay: qualify each confirmed trial, each exact decoder fault, each reset and recovery, preserving the global event timeline. Verify second-campaign readiness occurs after first recovery and that no ignored events or missing cadence coverage can manufacture healthy duration. Add malicious mutations and preserve existing single-cycle checks.
- [x] Harness: add explicit repeated options, two causally triggered owned decoder pauses after the respective confirmed trial, bounded 180-second hold and new raw fault envelope. Keep legacy routes unchanged. Require the complete repeated verifier plus all existing archive/scoring/A/V gates before a pass.
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


## Task 5: global policy, readiness and raw composition

The global replay consumes the complete original event list and carries source,
policy, configuration, probation and recovery state across both cycles. The first
matched source interval follows an already observed worker window (sequence 2 or
later), then subsequent source and policy sequences stay continuous. Consumed source
rows must match the original exported array prefix. A trailing source interval
may finish during shutdown after policy consumption stops; it stays in the raw
media replay and gains no policy health credit. This matches the saved
`measured-recovery-mnaRRb` export (source sequences 2–21; policy consumed 2–20)
without changing that historical run's result. Warm-up cadence reports remain in the original audit but receive no health credit before
the first qualified source interval. Pressure, decoder continuity, owned faults
and raw delivery deadlines are independently replayed. Recovery uses only whole
source windows after resumed progress, covered by both one- and two-second
delivery lanes; overlapping lanes never add time together.

`qualifyRepeatedNativeReadiness` independently replays raw native probes and
joins both original readiness contexts to the reconstructed baseline health
history. It requires the original configuration/acknowledgement, four seconds
initial health or ten seconds after reset, and fresh source/receiver observations.
The second campaign must follow all source and delivery evaluations needed for
the first shared recovery. Its reconstructed `qualifiedAt` prevents future
delivery evidence from authorizing an earlier probe.
A context read may precede asynchronous native allocation and diagnostic logging:
a newer healthy checkpoint is allowed only while its health start and baseline
remain unchanged. An intervening weak decision or health reset invalidates it.

`qualifyRepeatedMeasuredNativeRecovery` composes the shared raw media verifier,
five native phases, actual lifecycle and admissions, global policy, readiness and
both probation/recovery delivery coverage. Its current boundary tests reject
single-cycle evidence and incomplete admission-only fixtures. Positive component
integration covers raw admissions/lifecycle with both decoder and delivery faults,
including mixed routes, on one synthetic publication identity. These component
fixtures still supply explicit source/media qualification contracts; they do not
constitute a complete positive raw-media or native A/V run. Next wire the repeated
harness to this raw entry and acquire a diagnostic run; it may report success only
when the full raw gate and all existing A/V, archive and scoring checks pass.
Until that wiring exists, the current harness continues to reject repeated mode.
Production automatic upgrades and network-loss recovery qualification remain
disabled.

Evidence for this checkpoint is under `artifacts/qa/repeated-policy-integration-*`
and `artifacts/qa/repeated-global-policy-*`. The historical raw recordings and
exports remain immutable. Task 5 remains open for complete raw integration;
Task 6 still needs causal live confirmation checkpoints and both owned pauses.


The complete tool suite passes 3,016 tests, including 113 new policy, readiness
and integration/boundary cases. Source-suffix regressions preserve the original
native shutdown semantics without weakening leading/interior coverage. The stop
schema has no independent terminal policy cursor; a removed final decision is
indistinguishable from a source interval that the controller never consumed.
A future native terminal checkpoint can make that distinction explicit. This
checkpoint grants no extra tail health and does not claim complete native
qualification. All 269,319 prior frozen evidence files remain unchanged.


## Resumed freshness review and next harness boundary

The global cadence replay now checks cross-report last-fresh-time consistency.
For unchanged decoder scope and PTS, intersect the feasible native arrival bounds
`[evaluatedUptime - sampleAgeSeconds - progress.ageMs / 1000,
 evaluatedUptime - progress.ageMs / 1000]`. A cached snapshot may retain its
sampled age while its sample-age bound grows; it cannot repeatedly acquire a new
fresh arrival time without a new PTS. Preserve this constraint across owned
stalls and resumption partitions. Only representation-scale tolerance is applied.
The new synthetic fixtures use one explicit frame-arrival schedule for cadence ages and raw delivery packets.
Their owned 1.8-second pauses and resumed observations agree through a
fixture-only clock mapping; the verifier assumes no exact clock offset.
The saved `native-app-ceM4Yc` evidence passes a read-only check of these bounds
for 1,039 applicable reports, including 84 repeated-PTS reports. This does not
requalify the historical run or replace a complete repeated native run.

Task 6 must replace the repeated route's fixed-delay fault scheduling with two
bounded confirmation-driven campaigns. The current driver writes its complete
quality export only at stop. Add simulator-only live checkpoints that preserve
the original global event index, applied revision, candidate and source identity.
Before pausing, wait for a subsequent whole source interval after the matching
confirmation and sample the same owned decoder. Revalidate its process identity
immediately before each pause, always resume in teardown, and join the previous
campaign before another starts. Keep the existing single-cycle delay route
unchanged. Terminal evidence must reconcile each live checkpoint with the final
quality history; live checkpoints alone grant no qualification. Connect the
raw repeated composition and retain every existing archive, live A/V, scoring,
ownership and teardown gate before attempting the full simulator run.


## Task 6 checkpoint: live history before fault-runner wiring

The simulator driver now emits an exact original v4 event prefix inside a v1
repeated checkpoint with attempt identity and original event count. One in-flight
write and the latest pending prefix bound the queue; coalescing never removes
interior events. Stop joins the terminal checkpoint before exporting final quality.
The envelope's closed flag means the joined stop boundary: a failed session may
first appear in a nonterminal prefix and is an immediate harness abort.
The default hook is nil, and only the validated DEBUG simulator repeated route
installs the atomic file writer. Filesystem I/O is detached. JSON serialization
still uses the bounded MainActor drain; its real simulator timing cost remains
part of the next run's assessment.

The Node checkpoint tracker preserves prefix identity across polls, validates
native receipt/application ownership and the original applied→candidate→confirmed
ordering, then claims each campaign once only after a whole healthy source
window starts after confirmation. Its terminal reconciliation requires both claims
and exact final history. These are fault-scheduling gates, not independent media
qualification. Missing receipts and a reset relabelled as a trial cannot schedule
faults. The actual two-pause runner and app-container polling are still to be wired.

The prior iOS 17.5 simulator destination is no longer installed in the current
environment. The next build check uses an available arm64 iOS 26.2 simulator;
this does not replace the earlier compatibility evidence or establish a new
full native run. Real volleyball content testing is recorded separately in
[representative match testing](../../representative-match-testing.md).

Verified checkpoint: 3,043 tool tests and 446 FilmModel tests passed (including
28 driver tests); all 27 checkpoint-reader tests passed. The arm64 iOS 26.2
simulator build and unsigned iPhone/embedded-Watch Release build passed.
Independent specification and quality reviews approved the frozen runtime/test
sources. All 269,407 earlier evidence files and both supplied original videos
were verified unchanged. Evidence is under `artifacts/qa/repeated-live-checkpoint-*`.
This is a harness foundation checkpoint; full repeated native A/V qualification
and the real-match network test remain open.


## Task 6 wiring checkpoint — September 23

The harness now preserves the literal repeated probe mode and selects the fresh
`scorebug/ingest:campaign-probe-v3` image, leaving legacy image selection unchanged.
The paired repeated-recovery flags require a measured trial, 240p live output,
360p candidate, 1500 ms delivery budget, all existing full-pipeline opt-ins, and
exactly 180 seconds. Repeated candidate exports permit the native 512 KiB bound;
the legacy bound remains 256 KiB.

The live reader rejects oversized/nonregular/symlink inputs and validates an
immutable original event prefix. Its shared deadline bounds both campaigns.
Ready source identity joins the correlated fixture worker, epoch, attempt and
reader; UUID comparison handles native casing without rewriting raw scope.
Both the re-read checkpoint and pre-pause status must retain their original
ownership. The runner pauses only its discovered child decoder after scoped
process revalidation, resumes it in finally, and joins before a second campaign.
Cancellation or persistence failure records failure and cannot authorize a pass.

All 3,163 tool tests pass, including legacy schedules and the new ownership,
cancellation, terminal-save and native-boundary regressions. Independent reviews
approved the wiring after the documented regressions were corrected. The pinned
campaign relay image builds on this Mac. The first complete native attempt failed as documented below; all original archive, scoring, ingress, A/V, direct-recorder and
raw repeated-policy gates remain required.

Reproduce the explicit route on an installed simulator runtime:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
SCOREBUG_IOS_RUNTIME=26.2 \
SCOREBUG_TEST_STREAM_HOLD_SECONDS=180 SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 \
SCOREBUG_TEST_MOTION_FIXTURE=blocks16 SCOREBUG_TEST_RELAY_PUBLICATION=1 \
SCOREBUG_TEST_WORKER_PROCESSING=1 SCOREBUG_TEST_LIVE_PROFILE=240p30 \
SCOREBUG_TEST_BANDWIDTH_PROBE=repeated SCOREBUG_TEST_CANDIDATE_PROFILE=360p30 \
SCOREBUG_TEST_CANDIDATE_HEADROOM=1 SCOREBUG_TEST_MEASURED_TRIAL=1 \
SCOREBUG_TEST_MEASURED_RECOVERY=repeated SCOREBUG_TEST_DELIVERY_DEADLINE_MS=1500 \
node scripts/test-native-app.mjs --streaming
```

Build the relay first with the pinned recipe in `vendor/MediaMTX/README.md`.
Do not infer a physical-device or production upgrade pass from this command's
unit tests or build alone.


### Native run and original-scope correction

`native-app-fNvViE` stopped before app launch because the UI-test boundary still
required the legacy staged mode. That failed run is preserved. The corrected
boundary explicitly admits repeated only with its 180-second measured route.

`native-app-9da4Oo` passed the iPhone 14/iOS 26.2 UI workflow (native scoring,
publish/stop and recording export), and archive analysis completed. The overall
harness failed waiting for the first qualified upgrade; no decoder fault was
injected. The final raw history contains only bootstrap, baseline evaluations
and stop. A component/UI pass is not a repeated-media pass.

The first candidate encoded all 121 accepted frames with nominal pressure, but
its final-stage probe retired at 1882493.540205 and measurement ended at
1882493.548302, 8.1 ms later. The next eligible healthy source decision arrived
another 851 ms after retirement. Five-second source windows arrived about 1.74s
after their ends, leaving narrow intervals inside the unchanged two-second
freshness gate. The eight-second final-stage schedule missed measurement and
admission; simply weakening the freshness gate is not acceptable.

Next regression: permit a repeated-only final-stage scheduling ceiling of
12 seconds / 120 default polls while preserving the native cumulative 16 MiB,
60-second campaign limits, 0.5-second probe maturity and all independent
receiver/admission gates. Real terminal/profile withdrawal still ends it early.
The legacy route keeps eight seconds. Budget exhaustion without admission remains
a failure; additional fixture time never grants capacity evidence.

The real export also confirmed that original capture scope revision `1` and
controller bootstrap revision `0` are different domains. The polling/owned-fault
code now preserves a canonical UInt64 original scope and binds its first queue
checkpoint, rejecting later scope changes. Trial revisions remain exactly `1`
and `3`; raw media replay still requires the actual fixed source revision.
All 3,167 tool tests pass after this correction, and independent scope review
approved it. Source hashes and diagnostic evidence use `repeated-harness-*`;
failed run artifacts are retained unchanged.


### Final-stage scheduling verified; telemetry delay remains open

The repeated-only final-stage scheduling fix is implemented: 12 seconds and 120
default polls, while the first two stages and the legacy route retain their
eight-second ceilings. The native cumulative 16 MiB / 60-second campaign and
300-ms lease limits still terminate earlier, as does actual profile withdrawal.
The 0.5-second maturity, two-second source freshness and all admission thresholds
are unchanged. Four new regressions cover observed late admission, the absolute
ceiling, early native budget termination and bounded derived poll counts.
Failing-first evidence and the 30/30 focused, 450/450 full FilmModel passes are
in `artifacts/qa/repeated-live-checkpoint-repeated-probe-*`. Both independent
reviews approved the correction.

On frozen sources, `native-app-HJeP6C` passed the iPhone 14/iOS 26.2 native UI
workflow in 270.705 seconds, including scoring, publish/stop and recording
export. Unlike the preceding failed attempt, its original quality history
contains a real trial application (event 8), candidate (9), confirmation (13),
and healthy evaluation (14). The harness still failed its shared readiness
deadline. No decoder fault was injected and no repeated recovery was qualified.

Events 15 and 19 reject cadence freshness; events 16 and 18 reject source time.
Source interval 14 first appeared fully processed only about 82.9 ms before its
two-second freshness limit; interval 16 had about 206.2 ms remaining. The cadence
audit contains 2,040 rows, with a maximum audited sample age of 165.7 ms, below
the 250-ms decision limit. Crucially, the nearest audit row cannot be assumed to
be the decision input: earlier rows could have aged beyond the limit by the
rejection, while the newest rows remained fresh. The current rejected events
lack the receipt/evaluation join needed to distinguish actor scheduling, old
input capture, and other local delays. Add that bounded diagnostic before
changing runtime scheduling. Do not weaken freshness, discard rejected events,
or classify stale reports as decoder stalls.

Tasks 5 and 6 above now describe implemented/reviewed code. Their checkmarks do
not imply completion of task 7’s full repeated native media gate, which remains
open. Production automatic upgrade permission is still disabled.


### September 24: two observed cycles and exact stale-report diagnosis

Diagnostic-only changes now join a rejected decision to its original cadence
receipt or source key. Each invocation captures immutable scalar selection,
dispatch, actual session evaluation and catch timing. The session reuses its
existing validation instant; the DEBUG driver adds no suspension point. Early
failures have nil evaluation times, never a previous invocation's values. The
cadence audit exports the same receipt ID. Seven regressions cover exact identity,
ages, original errors/results, selection ordering and early failures. Three export
assertions failed before implementation, then all 67 focused and 457 FilmModel
tests passed. Independent spec and quality reviews approved the diagnostics;
3,167 tool tests and the unsigned iPhone/embedded-Watch Release build passed.

On frozen diagnostic sources, `native-app-jQCpxM` passed its iPhone 14/iOS 26.2 UI
workflow in 263.843 seconds. Original revisions 0→1→2→3→4 are present, with trial
confirmations at events 12 and 31. Both owned fault records are joined, closed
and nonfailed; pauses were about 1.875 seconds each. The controller returned to
healthy minimum quality after both. These observations do not establish a full
media/recovery qualification.

The harness failed collection because `native-receiver-intervals.json` was
missing. The simulator writer's selector listed `renew`, `expire`, and `staged`
but omitted `repeated`. That selector now includes repeated; a regression first
failed only for that mode and passes after the correction. All 458 FilmModel
tests and the arm64 iOS simulator build pass, and independent review approved
the selector fix. Legacy selection
and DEBUG/simulator restrictions remain unchanged. No missing historical file
was fabricated; the failed run stays failed.

The cadence audit also reached its 2,048-row limit and set overflow. It cannot
prove the complete run. Its one stale audited report, original row 742, uniquely
joins rejection event 17 at minimum-profile revision 2. It was already 263.223 ms
old at audit: 147 ms server age + 112.798 ms request + 3.425 ms residence. At actual
session evaluation it was 294.990 ms old, only 1.465 ms after provider selection.
The decoder reported advancing, nonstalled progress. This instance is stale
input availability, not substantial actor-dispatch delay. Exact original indices
and timings are saved in `repeated-evaluation-diagnostic-native-assessment.json`.

#### Next bounded implementation work

- Add an explicit repeated-audit envelope/capacity for the 180-second route and
  its UI/setup/stop overhead. Preserve every original row, retain a finite byte
  and count bound, and leave the legacy 2,048-row contract unchanged. Test overflow,
  wrong-mode/version inputs and all consumers before running the native fixture.
  Do not downsample or discard rows to fit the old bound.
- Model only explicitly supported `cadence-freshness` invalidation during
  acknowledged minimum-profile recovery revisions 2/4. Preserve the event and
  original indices. Require exact receipt/audit ownership, independent raw age
  arithmetic, ordered selection/dispatch/evaluation/catch/event clocks, unchanged
  application/receipt and benign advancing decoder progress. Reject unsupported
  phases/reasons, duplicate receipts and forged diagnostic ages.
- Match `QualityController.invalidateTelemetry`: clear accumulated health and
  pending readiness without advancing source/policy sequences or creating an
  action. Grant zero health credit for the unavailable interval, then require
  complete healthy recovery and both delivery lanes after it. Explicitly account
  for the joined unavailable audit row in every cadence/fault validator; merely
  expanding an event whitelist is insufficient. Keep all other freshness limits.
- Obtain independent review and a new frozen-source native run. Require the
  receiver export, complete audits, all media/deadline/ownership gates and both
  raw reconstructed cycles before claiming repeated qualification. Production
  upgrade permission remains disabled.


#### Repeated cadence audit capacity — September 24

The longer simulator route now has an explicit cadence-audit contract: version 2,
mode `repeated`, at most 3,072 original rows and 16 MiB of serialized JSON. This
covers 307.2 seconds at the nominal 100 ms polling interval, including the
180-second stream hold and setup/stop work. The previous run's 2,048 retained
rows occupied 7,971,218 bytes; the byte bound remains independently enforced.
Neither estimate is proof that a future run is complete: overflow still fails.

Native selection requires the validated measured-trial fixture, repeated probe
mode and an exact 180-second hold. Legacy routes retain version 1 and the
2,048-row limit. Rows are never sampled or trimmed to pass qualification. A
count or byte overflow latches, preserving only the original bounded prefix
and explicitly marking it incomplete; later smaller rows cannot hide the gap.

The native regression tests first reproduced the old capacity and missing
version failures, then passed after implementation. All 461 FilmModel tests
pass. Independent inspection approved the Swift capture/export changes.
The shared JavaScript consumers now require explicit caller-selected repeated
mode, including the nested delivery-failure path. Ten new tests first failed
against the old implementation; all 595 focused tests and all 3,177 tool tests
then passed. The arm64 iPhone simulator build also passes. Independent review
approved the JavaScript routing and reran all ten new capacity tests. No telemetry freshness
or health credit rules have changed, and this capacity fix does not qualify repeated
recovery. The narrow recovery-time invalidation replay above is still required.


#### Recovery invalidation replay — component implementation, fresh native result below

Only an original `rejected` / `cadence-freshness` event during acknowledged
minimum-profile recovery (revision 2 or 4) may enter the supported path. It must
join one original cadence receipt and preserve ownership, raw row/event indices,
configuration, application and sequence state. A stale receipt is unavailable
telemetry, never a healthy or stalled sample. Other rejection reasons/phases
continue to fail qualification.

The diagnostic uses independently sampled monotonic clocks. Its sample age must
not be compared for exact equality to audit age plus uptime delta. From the
native sampling order, let S be server cadence age in seconds, D request duration,
Q request-start uptime, R response-received uptime, E session evaluation uptime
and C caller catch uptime. The admissible age bracket is:

`S + D + E - R <= diagnostic sample age <= S + C - Q`.

Use only representation-scale outward rounding. Separately replay audit age
as `S + D + residenceSeconds`, validate all original ordered timing stages,
receipt uniqueness, freshness/TTL, same decoder/publication ownership and benign
progress. Diagnostic agreement is a consistency check, not freshness authority.
For the preserved failed run, the bracket is approximately 294.988–296.092 ms;
the recorded 294.990 ms fits and the raw report was already stale at audit.

Match native invalidation by clearing accumulated strong health and readiness,
advancing the evaluator clock to E, and retaining source/policy ordinals,
last source end and transition state. Native `healthySince` restarts at the next
accepted window's actual start, even if that window straddles E. Independent
recovery credit is stricter: require whole contiguous healthy windows starting
after resumed decoder progress, the latest rejection's `caughtAt` and the
proved fresh replacement report's audit time, plus both
verified delivery lanes, for at least ten seconds. Earlier credit cannot carry
across the rejection. A straddling window remains in raw/native replay but earns
no post-invalidation shared recovery duration.

Readiness must also consider a validated rejection's evaluation time, not just
its asynchronously serialized event time. A rejection evaluated before probe
begin invalidates old readiness even if its event was exported after begin.
The joined unavailable row must be accounted for explicitly in cadence/fault
validation; all other gaps, stalls, identities and freshness checks remain.


The implementation now proves each supported rejection from the complete raw
version-2 audit and quality history. Both the repeated policy and fault entry
replay that proof independently. Cadence continuity accepts only the exact
proved row index/receipt on the repeated route; legacy callers remain strict.
Readiness requires the policy proof and uses the evaluation timestamp even if
the rejection was serialized after probe begin. Trigger/resumption freshness
and ordinary cadence/delivery budgets remain unchanged.

Tests first reproduced the missing invalidation behavior. All 69 helper tests,
12 integrated policy/fault tests and 33 readiness tests pass. The integrated fixture extends actual synthetic raw delivery lanes to
22 seconds so it can prove a fresh ten-second interval after invalidation; it
does not fill missing coverage with a summary. Both fault kinds and mixed
campaigns pass. Negative cases cover missing/forged proof, duplicate receipts,
unjoined stale rows, clock/owner changes, and insufficient later recovery.
The earlier native failure remains failed. Independent spec and quality reviews
are approved and each reran all 114 focused tests. All 3,262 tool tests pass. A
fresh frozen-source native run is next; production upgrades stay disabled.


Review found and reproduced two false acceptance cases before a new native run:
a diagnostic age could be fresh or younger than the same receipt's earlier audit,
and multiple rejected calls could have overlapping timing that regressed the
recovery cutoff. Added behavioral regressions now require strictly stale actual
session age, the elapsed lower bound `auditAge + (evaluation - selection)`,
selection before the next audited receipt, serialized rejection calls, and
monotonically accumulated cutoffs. Representation rounding never expands the
250 ms freshness boundary.

The independent recovery cutoff also includes the adjacent fresh receipt's
proved availability. A whole source window starting after rejection but before
replacement stays in native replay and earns no independent recovery seconds.
A regression with rejection near 170.75 seconds and replacement at 171.05 now
requires the complete 172–182 interval. The prior native `healthySince` is never
rewritten. This handles the explicitly joined stale receipt and its replacement;
it does not claim to reconstruct every possible unlogged later rejection.


#### Fresh native result — September 24, `native-app-ApmZnO`

Source `4b1a333` was frozen across 913 files and independently checked unchanged
after the run. The UI test passed (265.122 seconds), including scoring, publish,
stop and recording export. The full harness exited 1: repeated readiness timed
out after the first confirmed trial/fault/minimum reset. All owned jobs joined;
the owned simulator and container were removed. Original evidence is retained.

The capacity and export corrections worked: cadence audit v2 has 2,076 rows,
8,083,779 bytes, closed/valid/no overflow; the failure export contains all 46
receiver intervals, closed and valid. The archive fully decoded 6,605 contiguous
barcode frames at 1080p, maximum PTS gap about 33.3 ms. A separate post-run decode
of the live recorder succeeded with 6,199 frames at 360p and maximum PTS gap
34 ms. Different start/stop intervals mean these counts are not a loss ratio;
media timestamps alone do not prove wall-clock delivery through the fault.

The new rejection joins report 998: fresh at audit (124.603 ms), stale at session
evaluation (377.890 ms). Report 999 is independently stale (357.338 ms), followed
by fresh report 1000. The next source window also reports worker pressure unknown
with no filter duration. Current narrow invalidation replay intentionally does
not qualify this sequence. Its original evidence must not be rewritten as the
previous already-stale/adjacent-fresh supported case.

Readiness correctly resets twice. The new strong-health start is
1888511.3896225; subsequent windows cover 4.976412 and 9.976831 seconds, so the
strict ten-second threshold is first satisfied at evaluation 1888528.185.
Meanwhile, stage three started at 1888519.284 and consumed 11,134,676 bytes over
8.987 seconds before candidate binding. Only 3,246,104 campaign bytes remained.
The native byte cap then stopped the owner after 79/121 candidate inputs.

Next bounded implementation and verification:

- [ ] Add a repeated-only wait after stage two is retired and joined, before
  allocating stage three. Poll current valid readiness finitely within the
  original 60-second campaign deadline; spend no probe bytes while inactive.
- [ ] Require the same immutable publication/configuration/revision as the
  campaign. A new `healthySince` may represent legitimate recovered readiness;
  pin that fresh context across allocation and use the existing strict
  `sameConfiguration` check afterward. Do not weaken its shared semantics.
- [ ] Preserve origin, cumulative 16 MiB budget, 300 ms leases, 0.5-second
  maturity, stage-three 12-second ceiling and exactly two campaigns. Own every
  returned allocation before cancellation or revalidation, and join on failure.
- [ ] First reproduce absent readiness, resumed readiness with a new health
  start, bounded exhaustion, cancellation and allocation-time context changes
  in behavioral tests. Run focused tests, full FilmModel tests, simulator build
  and independent spec/quality reviews before another frozen native run.
- [ ] Independently specify any broader telemetry replay needed for the newly
  observed stale-at-selection/adjacent-stale/unknown-pressure sequence. No
  threshold expansion, health credit for unavailable data, or invented rows.

The stage scheduling change is an evidence-backed hypothesis, not a guaranteed
native pass. Full repeated qualification and production upgrades remain closed.
Assessment: `artifacts/qa/repeated-recovery-invalidation-native-assessment-20260924.json`.

#### Follow-up design: recovery segments, not retroactive health replacement

Independent inspection of the latest raw evidence identified a further verifier
boundary. One reset revision can contain valid recovery, campaign startup,
telemetry loss, then a new recovery. A single final invalidation cutoff must not
retroactively invalidate the earlier legitimate startup or let that earlier
health authorize a later candidate. Preserve separate segments and select proof
as of the action being checked. This design is not yet implemented or qualified.

- Separate exact rejected-call anchors from unavailable audit spans. A joined
  receipt may be fresh at audit but stale at selection/evaluation. Independently
  reconstruct its audit classification and require the session-age lower bound
  `serverAge + requestSeconds + evaluation - receivedUptime` to exceed 250 ms
  for delayed-staleness cases. Preserve exact diagnostic timing and ownership.
- Validate every original row through the first fresh replacement: bounded
  gaps, unchanged publication/decoder, TTL, arithmetic and nonstalled progress.
  Equal cached PTS can be legitimate; retain the existing global arrival-bound
  consistency checks. Never label an unlogged audit row as a rejected call.
- Replay an unknown-pressure evaluated window from its actual evidence and
  retain source/policy ordinals, configuration, timing and counts. Require the
  corresponding unknown state/reasons and no action. Clear baseline and health;
  the window earns no healthy duration.
- Retain each segment's original invalidation indexes, availability cutoff,
  native health start, strong checkpoints and independently credited whole
  windows. Require both validated delivery lanes and at least ten seconds.
  Startup joins the segment valid then; candidate admission joins the segment
  valid at admission. Earlier proof remains historical after invalidation.

The driver deduplicates consecutive rejection events by revision/reason. Current
exports cannot establish whether report 999 was selected or exactly when a fresh
report was consumed. Exclude the unavailable audit span conservatively; do not
invent invocation timestamps. Exact invocation replay would require a separate
bounded trace of every cadence call, including absent input, successful no-ops
and suppressed rejections. Keep any extension confined to acknowledged minimum
recovery (revisions 2/4); trial, fault, ownership, ordinal and legacy checks stay
strict. The failed run cannot pass regardless of this extension because its
second candidate/trial/fault/recovery never completed.


#### Stage-three readiness checkpoint

Implemented the repeated-only joined-stage wait and post-allocation revalidation.
Exhaustion stops with `readinessUnavailable` before marking the campaign finished
or restarting. A returned allocation is always owned before cancellation, clock
or context checks. Deadline checks cover both the readiness read and an allocation
created before the deadline but returned afterward. Historical startup context
and the shared candidate comparison remain unchanged.

Nine new behavioral regressions first reproduced the missing gate. The complete
focused class passes 39/39; all 470 FilmModel and 3,262 tool tests pass. The arm64
simulator build passes. Independent spec and quality reviews approved the change.
Evidence uses `artifacts/qa/repeated-live-checkpoint-stage-readiness-*`.

The quality review confirmed a remaining timing constraint: the first two stages
spend about 2.5 MB, leaving roughly 9.52 seconds at 12 Mbps within 16 MiB. If the
0.5-second maturity requirement misses a fresh source-health slot, measurement
and admission could still arrive too late. The next frozen native run tests this
scheduling hypothesis; no budget, health requirement or verifier is weakened.


#### Fresh stage-readiness native run — September 24, `native-app-LeTozN`

Frozen source `2a0a718` (913 hashes unchanged) passed the native UI workflow in
261.486 seconds. Both controller cycles completed, with applied revisions
0→1→2→3→4 and two closed, successful owned-fault records. Each candidate
measurement completed 121 inputs. Stage-three allocation followed an inactive
joined-stage gap of 3.987963 and 3.769069 seconds. Final campaign totals were
14,581,280 and 14,719,460 bytes, below the unchanged 16 MiB cap. Both native
owners joined, and independent raw v3 probe qualification passes. This measures
scheduling progress without claiming broader recovery-policy qualification.

The full harness exited 1 at live A/V coverage: video starts at 0; audio starts
at 0.395011 seconds. This is missing early audio, not allowed leading audio from
keyframe acquisition. Do not expand the 100 ms missing-audio-head limit. The
archive fully decoded 6,503 contiguous 1080p frames, with audio/video both starting
at zero and maximum video gap about 33.3 ms. Live media fully decoded 6,130
contiguous source frames (160–6289), with 30 fps timestamps and maximum gap 34 ms.
A separate diagnostic extraction into new files matched 102 audio markers, with
maximum offset 65.594 ms and drift approximately −0.021 ms. Ongoing content sync
passes that diagnostic; initial audio coverage and full qualification do not.

The cadence audit contains 2,045 rows, valid and without overflow; 46 receiver
intervals are closed and valid. Two initial revision-0 rejection events occur
about 20 ms after bootstrap (`cadence-ownership`, `local-ownership`), before
source health. They contain no evaluation diagnostic. The strict invalidation
component rejects their unsupported metadata. Do not silently discard them or
claim policy qualification merely because the controller finished both cycles.
Future replay must establish startup semantics explicitly, separately from the
recovery-segment design above.

Independent startup timing diagnosis:

- Native first AAC PTS is about 21.333 ms after first video; native mux keeps
  that separation (10919 versus 9000 ticks). Startup audio was produced.
- First video encoding took about 440.358 ms, and 21 native audio packets were
  muxed before the first video packet. The writer flushes startup pending packets
  in arrival order after both tracks become available.
- Publication origin is 10919. The first live source frame 160 maps to native
  PTS 27000, then worker PTS 16081 after the common relay shift. This common
  normalization alone does not explain differential audio loss.
- RTMP recorder input already starts audio at 395 ms; recorder output retains
  it. The recorder did not create the gap.
- The earlier representative 1080p native/SRT/proxy passes used a direct SRT
  listener and bypassed this relay. They do not qualify its startup boundary.

Next bounded diagnostic: retain the first approximately two seconds of packet
identities and PTS at native mux, relay ingress, actual reader egress, and worker
input/output. Identify the earliest retained AAC packet at each boundary before
choosing a fix. Current evidence localizes the loss after native mux and before
RTMP recorder input, but cannot separate relay acquisition and worker startup.
Preserve the originals, scope/ownership, existing timestamp budgets and failed
run. No new heavy native retry is justified until that diagnostic is concrete.

All owned jobs joined; the simulator and owned container were removed. Evidence:
`artifacts/qa/repeated-stage-readiness-native-assessment-20260924.json`, with
separate `diagnostic-live-marker-sync.json`,
`diagnostic-native-probe-qualification.json` and
`diagnostic-invalidation-scope.json` inside the native run. Production upgrades
and full repeated qualification remain disabled.

#### Bounded worker startup packet trace

First instrument the actual worker's FFmpeg demux and output-mux boundaries;
existing native mux and RTMP recorder traces bracket them. This smaller step can
separate worker startup loss from loss already present at worker input before
adding relay instrumentation. Use an explicit test-only packet-timing opt-in
alongside terminal diagnostics. Normal production arguments and media timestamps
remain unchanged.

Retain a numeric-only ordered prefix of at most 128 packets in each of four
lanes (demux/mux × video/audio), plus saturated counts and framing/error flags.
This covers at least the first two seconds at the selected 30 fps / AAC rates
when packets are recognized, without assuming stderr interstream ordering or
claiming packet delivery/health. Join stderr at actual encoder exit under the
existing bounded drain. Never export raw stderr, URLs, addresses or codec labels.
Emit separate scoped chunks of at most eight records so the existing 4 KiB log
line and 256-event bounds remain unchanged; retain original lane indexes and
counts, including truncation. An absent or malformed trace is unknown evidence.

A bounded parser worker owns its module/tests; the parent owns guardian/pipeline,
worker logging and fixture collector integration. Test parser framing, prefix
retention, malformed/unsafe values and shutdown; then test real child-pipe
propagation, explicit opt-in isolation, scoped sanitized collection and log-size
bounds. Run focused and relevant full suites, typecheck/build and independent
reviews before one new diagnostic native run. Preserve the 100 ms coverage gate.


The bounded worker trace is implemented behind both exact test flags. Its parser
passes 32 focused cases and parses the installed FFmpeg's actual sampled output
without malformed, oversized or incomplete rows. Integration tests first failed
for absent argument wiring, real guardian-pipe propagation, dual opt-in and
scoped chunk export; those checks now pass. All 100 focused worker tests, 429
full worker tests and 3,276 tool tests pass; worker typecheck and build pass.
Independent specification and quality reviews approve the change. A worst-case
eight-packet record is 2,011 bytes, below the unchanged 4 KiB collector bound.

Next run uses `SCOREBUG_TEST_WORKER_PACKET_TIMING=1` on the same repeated fixture.
Treat the debug output as diagnostic: it can affect scheduling and does not
qualify health or throughput. Keep source hashes frozen, retain all failed
artifacts, and compare native mux, worker demux/mux, and recorder timestamps.


#### Worker packet-trace native run — September 24, `native-app-hB7NWJ`

Frozen source `809fd0d` (916 hashes unchanged) completed the native UI workflow
in 262.897 seconds and both controller cycles through revision four. The trace
contains all 64 ordered chunks, with clean framing, drain and collector flags.
The full harness exited 1 because its direct-recorder lifecycle allowlist did
not yet admit diagnostic packet records. Owned jobs joined and the simulator
and container were removed. Preserve the failure and raw evidence unchanged.

The verifier correction requires a trusted, explicit second-option opt-in.
It validates all four complete prefixes, consistent counts/flags, scope, and
terminal-before-trace-before-exit ordering. The default remains strict; packet
records confer no health/delivery credit. Existing lifecycle, media, count and
exit requirements remain unchanged. Two new positive tests failed before the
correction. All 79 focused and 3,287 full tool tests now pass; independent spec
and quality reviews approve.

Offline analysis in `native-app-hB7NWJ/diagnostic-media-and-delivery.json`
passes media coverage and the corrected direct-delivery component, not the full
run. The archive has 6,529 contiguous frames with both tracks starting at zero;
live has 6,117 contiguous frames (192–6308), about 30 fps and maximum gap 34 ms.
All 102 live markers match, maximum offset 64.917 ms with negligible drift.
Live audio starts at zero and video at 605 ms, within the existing leading-audio
acquisition allowance. The old 395 ms missing-audio head did not recur.

The acquired video prefix changed from six frames to 36. Worker input starts
video at 106081/90000 and audio at 53760/90000 (581.345 ms audio lead).
Worker output begins video at 1.179 seconds and audio at 0.574 seconds; the
recorder preserves that 605 ms lead under common normalization. Native AAC count
9614 minus worker input count 9586 equals 28; the first input AAC timestamp also
maps to native packet index 28. No large worker audio delay is demonstrated.
The prior run lacks these worker traces, so its loss boundary remains unknown.

Next bounded experiment is one fresh run of the same traced 180-second route
after this integration correction, seeking recurrence of early video acquisition.
Read-only inspection found no shorter invocation preserving campaign-probe-v3,
the repeated owners, native 240p/worker 360p and reporting configuration. Do not
introduce a new test mode merely to shorten this experiment. Inspect first worker
demux timestamps before choosing relay instrumentation or a media fix. Retain the
100 ms missing-audio gate and failed runs; production upgrades remain disabled.

#### Fresh trace reproduction — September 24, `native-app-L9jBCE`

Frozen source `5cb09ae` (916 source hashes unchanged) passed the native UI
workflow in 260.881 seconds, completed both controller cycles, and passed media
coverage plus direct delivery with the corrected diagnostic route. Full harness
qualification still exited 1: delivery audit overflow, not malformed packet
tracing or an A/V coverage failure. The audit retained its original 256-row
prefix (16,624,334 bytes) and marked overflow. Both prior native runs also have
this overflow flag; their earlier failures prevented reaching this gate.

The complete worker trace starts input video at 94081/90000 and audio at
71040/90000. Output video starts at 1.045 s and audio at 0.766 s; recorder audio
leads video by 279 ms. Native AAC count 9625 minus worker input 9588 equals 37,
matching first AAC PTS / 1920. This further demonstrates variable acquisition,
not a fix for the old missing-audio head. The archive has 6,533 decoded video
frames and live has 6,128. Do not rerun again merely to seek the old timing.

Next bounded correction: retain the entire repeated deadline audit. Its two
scheduled lanes produce roughly 1.5 rows/second, so the 180-second hold plus
startup/teardown naturally exceeds the legacy 256 rows. Keep legacy format1,
256 rows and 256 phases unchanged. Add an explicitly selected repeated format2
with at most 512 rows and 32 MiB serialized bytes (the existing artifact file
limit). Match the validated repeated native fixture prerequisites; raw metadata
must not select the verifier route. Preserve a terminal prefix on row/byte
exhaustion, set overflow, and never grant native health from an unretained row.
The verifier must require exact repeated metadata and closed/nonoverflow/valid
status, then apply all existing row, clock, scope, source and deadline checks.

Use bounded parallel ownership: a Swift implementer owns native audit storage,
fixture wiring and native regressions; the parent owns the JS envelope/replay
route and regressions. Parent alone runs heavy tests/builds. Establish RED for
boundary retention and legacy isolation, then test GREEN, relevant full suites,
simulator build and independent reviews. Preserve the overflowed failed artifacts;
no truncated historical run can qualify after this change. Broader policy replay
and startup acquisition remain separate open issues.


The repeated deadline-audit correction is implemented. Seven native regressions
cover full prefix/count retention, unchanged legacy and phase bounds, exact
fixture prerequisites, serialized byte exhaustion, serialization failure and
withholding health for unretained rows. Behavioral RED reproduced the old row
limit and missing byte guard. An independent serialization RED reproduced the
invalid JSON export. A count-only fixture initially reached the byte cap first;
reducing its valid history isolates the independent row cap without changing
limits. All 477 FilmModel tests now pass, including those seven regressions.

All 3,306 tools tests pass. Nested regressions initially exposed missing trusted
mode propagation through policy and delivery-failure replay; both are corrected.
Synthetic repeated fixtures use the new envelope, while original native artifacts
remain untouched. The arm64 iPhone simulator build passes. Independent native/JS
specification and quality reviews approve. Next is one fresh frozen native run
with complete audit retention; no component pass grants production upgrades.


#### Complete audit native run — September 24, `native-app-yB8xre`

Source `6d55083` remained frozen across all 918 files. Native UI passed in
260.869 seconds. The new delivery audit closed with 283 rows / 18,452,702 bytes,
format 2 repeated metadata, no overflow and no invalidity. All 283 rows pass
independent deadline replay with no unknown rows. Cadence has 2,053 valid rows.
This verifies the bounded audit correction with actual native data.

Full harness exited 1 during collection: second repeated quality readiness timed
out. The first owned decoder pause completed and joined; no second pause began.
Quality has 44 events, applied revisions one and two only, and no rejection events.
The secondary cleanup message repeats the owned-fault failure; actual worker
stdout joined with wrapper exit 0, and owned simulator/container removal succeeded.
Failed native candidate/probe exports are preserved under
`failure-app-data-YlIBrE/QA/`, since collection failed before their top-level copy.

Separate analysis fully decoded both A/V tracks. Archive has 6,538 contiguous
frames (0–6537), 30 fps and zero initial A/V offset. Live has 6,131 contiguous
frames (192–6322), 30 fps and maximum gap 34 ms. Audio leads video 517 ms; all 102
live markers match within 64.917 ms with negligible drift. The scoped direct
recorder component also passes. Worker demux begins video 100081/90000 and
audio 55680/90000, output video 1.112 and audio 0.595 seconds. These results do not
reclassify the failed full run. Evidence: `diagnostic-complete-assessment.json`,
`diagnostic-deadline-replay.json` and `diagnostic-media-assessment.json` in the run.

Campaign one completed 121 accepted/encoded candidate frames. Campaign two began
at 1893741.515333 with valid revision 2 health/context. Stages accepted 486,920,
1,920,044 and 14,369,404 bytes. Stage three ran 1893761.449047–1893773.112177,
then terminated `byteLimit` at 16,776,368 accepted bytes: 848 bytes below16 MiB,
insufficient for another 1,316-byte packet. Ownership joined without invalidity.
Only one candidate campaign is exported. That proves no second exported result,
not that no allocation attempt occurred.

The strongest timing hypothesis is a missed readiness window. Native candidate
readiness allows health age at most two seconds; the candidate wait polls 100 ms.
Healthy evaluation 26 completed at 1893766.524149 with health.end 1893764.533558,
leaving 9.409 ms freshness at stage 3+5.075 s. Evaluation 27 arrived at stage 3+9.985 s;
the byte cap ended probing at+11.663 s, too soon for a four-second measurement.
Successful `L9jBCE` bound candidate 2 at+5.052 s, completed at+9.130 s and withdrew
its probe at+10.040 s. Poll outcomes are absent; exact failed predicate remains
unknown. Nothing here establishes that audit storage caused the failed campaign.

Next bounded action: deterministic scheduling reproduction of a 9 ms readiness
opportunity with 100 ms candidate polling. If existing results cannot distinguish
failure causes, add a bounded candidate-wait/attempt diagnostic with failed guard
and freshness timing. Preserve the two-second rule, 16 MiB cap, ownership checks,
and failed run. Do not extend budgets or rerun unchanged merely to obtain a pass.

#### Candidate wait diagnostic — September 24

The deterministic Core test confirms that a 9.409 ms readiness interval can be
missed by one 100 ms phase and caught by another, without relaxing the two-second
freshness deadline. Actual native cause remains unproven. The new separate DEBUG
`native-candidate-wait.json` records repeated fixture polls and operation outcomes,
including never-started candidates. Its typed 4,096-event prefix / 4 MiB export
has invalid/overflow latches and joins teardown before one export. It cannot grant
health or admission. Harness collection is optional and precedes qualification.

All 459 Core, 3,306 tools, 54 focused candidate and 485 full FilmModel tests pass;
arm64 simulator build passes. Eight new trace tests cover bounds, invalid input,
never-started candidates, suspended context, expired leases, cancellation, start
failure and legacy isolation; an existing two-campaign test verifies successful
operation/context records. Independent specification and quality reviews approve.
See [bounded diagnostic plan](2026-09-24-candidate-wait-diagnostics.md). Next is one
fresh frozen instrumented repeated native run. Freshness, leases and 16 MiB remain
unchanged, and the prior failed native run remains failed evidence.

#### Instrumented native run — September 24, `native-app-q6s6KU`

Source `b8a0609` stayed frozen across 919 files. UI passed in 259.120 seconds;
full harness joined exit 1 at repeated candidate binding qualification. Both
candidate measurements and owned fault campaigns completed; applied revisions
are 1, 2, 3 and 4. Quality has 48 events, including a retained `time` rejection at
event 24. The new wait trace closed with 1,052 events / 365,482 bytes, no omitted
rows, invalidity or overflow. It shows both starts and post-start contexts passing.

Independent review identifies one exact chronology contradiction: campaign two
initial binding against raw probe event 210. The probe read completed at
1895702.5432826667; a 30.215208 ms context await followed. The same owner renewed
at 1895702.5718719584, advancing 35,532 bytes and 100.147542 ms lease. Binding
at 1895702.573508125 incorrectly became the saved older snapshot's observation
time. The original snapshot still had 198.202167 ms lease remaining. This explains
the verifier's `binding predates observed native ownership` failure without
claiming withdrawal or replacement. It is separate from yB8xre's unresolved short
readiness window; this run successfully caught its available candidate windows.

Independent media replay fully decodes archive and live: 6,539 contiguous archive
frames and 6,131 contiguous live frames (192–6322), both 30 fps; live maximum gap
34 ms. All 102 live markers match within 64.583 ms with negligible drift. Live
audio leads by 420 ms; media coverage and direct delivery pass. Native startup
frame 159 to saved frame 192 is a 33-frame acquisition prefix. Worker and recorder
exit 0. Delivery audit retains 269 rows / 17,563,116 bytes; every row independently
replays, with zero unknown rows. Cadence retains 2,054 valid rows. Owned simulator
and container cleanup completed. Full run remains failed, not production-qualified.

Evidence: `diagnostic-complete-assessment.json`,
`diagnostic-candidate-wait-assessment.json`, `diagnostic-components-assessment.json`,
`diagnostic-media-assessment.json` and original exports in the run directory.
Next: explicit native read intervals, separate from binding time, with strict
causal counter/lease validation and downstream-consumer audit. See the
[bounded diagnostic plan](2026-09-24-candidate-wait-diagnostics.md) for the TDD
sequence. Do not remove the ownership check or extend freshness/probe budgets.

### September 24 — probe-read interval repair

Repeated candidate envelope v5 now exports actual initial/final probe-read brackets.
All candidate, admission, witness, retirement and receiver consumers join those
original bounds and require one common snapshot instant across counter and lease
history. Original leases must cover use; terminal ownership, freshness and budget
checks stay strict. Cached admission reads use separate completion-to-evaluation
bounds. V4 remains strict and cannot opt into v5 by adding fields.

Failing-first native and JS regressions precede implementation. Current evidence:
55 focused native tests, 486 full FilmModel tests, 3,349 tools tests and arm64
simulator build pass, with joined exit-zero commands. Core is unchanged from the
459-test pass. Independent specification and quality reviews approve. Next is one
fresh frozen native run; `q6s6KU` remains a failed historical run. See
[the repair plan](2026-09-24-probe-read-intervals.md) for the exact contract.

# Recovery policy app integration plan

> **For agentic workers:** Use `superpowers:executing-plans`, test-first verification
> and review in the existing isolated worktree. Autonomous execution is authorized.
> Keep the complete portable streaming and Watch goal active.

**Goal:** Run the existing real-match staged adaptation route with an explicit,
replayable recovery-budget policy, without changing historical evidence semantics.

**Architecture:** Carry native policy identity and a constant-size snapshot of the
last successfully validated raw SRT collection through the publisher and app probe
observation. Bind policy at every owner/candidate comparison and preserve native
revocation. Export and independently replay that raw collection. Select the new
probe and pressure policy together only on the complete measured-network route;
quality/admission evidence must explicitly identify the new policy. Then run the
full prepared-match impaired route and preserve all failures and media gates.

**Tech stack:** Swift/Swift Testing/XCTest, native SRT, Node evidence validators,
existing simulator runner and local CPU relay/worker.

## Design choices and scope

The previous goal turn is progress: commits27cbf1c and19b7d2b implement native
recovery-budget probing and matching pressure classification. Native, Streaming,
app-model and tooling checks pass. The working tree is clean at this plan's start.
The policy is not yet selected by the app, so another unchanged media run would
repeat the known legacy-admission failure.

A policy string alone would identify intent without showing the admitted native
measurements. A per-datagram trace would grow with traffic and add unnecessary
recording/export pressure. Choose one immutable latest successful preflight check:
checkedAt, sampledAt, elapsed time, sent/retransmitted bytes, sender drops, RTT,
backlog and actual sender delay. It is local native-send evidence, not receiver
capacity or a claim that every retransmission arrived. Receiver payload, candidate
cost, media health and deadline evidence remain independently required.

Native admission keeps the existing100ms freshness,300ms lease,60s campaign and
16MiB payload bounds. Snapshot reads must not re-check or refresh telemetry times;
failed preflight checks retain the prior successful observation plus terminal
reason. Replacements/restarts get their own fresh observation and inherited policy.
Missing/malformed recovery observations cannot establish app ownership. Policy
changes cannot reuse prior app owner state or candidate binding.

The initial network route is the existing complete file/measured/staged experiment;
repeated/outage routes retain their current policy until separately integrated and
qualified. This is an ordered prerequisite, not removal of recovery/repeated or
physical device/GPU requirements from the goal. No production adaptation is enabled
by this laboratory selection.

## Tasks

- [x] Add public read-only `SRTBandwidthProbeRecoveryObservation` in the native
  transport-guard file, plus `recoveryObservation` on native/publisher snapshots.
  Guard keeps its last successful check time and exact raw sample without a history.
  Test initial values, accepted retries, cached collections with new check times,
  immutable old snapshots, retained observation after failure/cancel, nil legacy
  evidence and propagation through native replacement/restart and adapters.
  Introduce the API, observe behavioral red, then wire the data.
- [x] Add policy and raw observation to `PublishingProbeObservation` and
  `NativeBandwidthProbeSample`. Change the app permit closure to take policy as an
  explicit fourth argument. Update all app/test call sites; native closures forward
  the requested policy to native authority. `isActive` requires staged recovery,
  valid raw evidence and a check in this stage no later than evaluation. Legacy
  observations require absent recovery evidence. Compare policy at app owner,
  candidate pinning and binding/admission boundaries. Red/green tests must reject
  wrong policy, missing/malformed evidence and changed policy across suspension.
- [x] Export policy and raw observation through probe events, candidate bindings,
  frozen admission witnesses and lifecycle diagnostics. Preserve legacy field
  omission and formats. Add a new explicit native proof/admission format for the
  recovery policy; add a shared JS raw-observation validator with canonical bounded
  counters, fresh checked/sample times, same-collection reserve checks, unchanged
  cached values and monotonic validated observations. Snapshot order uses actual
  check times, not the order in which overlapping async reads return.
- [x] Wire one explicit DEBUG network-recovery route selection through the native
  fixture start and pressure classifier, plus the host options and qualifiers.
  Reject partial/unsupported combinations. Historical verifiers must reject new
  policy evidence rather than reinterpret it. The encoding-only candidate payload
  contract may remain unchanged; every authority/headroom/witness join must compare
  policy and replay the new raw observations.
- [ ] Run focused and full native/Streaming/app/tool checks serially, review the
  final integration, then run the existing90-second prepared-match impaired route
  using400ms actual SRT delay and slice decoding. Freeze source/input hashes before
  launching, join the same live process, preserve failure artifacts, verify owned
  cleanup and media/audio/score/recording continuity. Investigate failures without
  weakening any fps/deadline/recording/admission gate. Update the main plan and
  commit coherent verified work; continue production/device/portable-host work.

Use the existing joined wrapper and unique names:
`python3 artifacts/qa/repeated-live-checkpoint-run-check.py NAME COMMAND...`.
Heavy checks run serially with Xcode26.2 and cached dependencies; no deleted
simulator runtime needs reinstalling for this batch.

## Foundation checkpoint

Native snapshots now retain the exact last successful recovery preflight collection
and its check time. Reads and renewals do not invent fresher telemetry; failed
preflight/cancellation retains the last successful collection beside the terminal
reason. Publisher snapshots carry it through real connected replacement and restart.
App ownership closures explicitly forward policy. Missing/malformed raw recovery
evidence cannot establish an active owner, policy changes revoke prior receiver
coverage, and both candidate pinning and admission require exact policy equality.

Probe, candidate-binding and lifecycle diagnostics now copy policy and raw fields.
Frozen recovery admission witnesses use format2 / `measured-candidate-ipv4-recovery-v1`;
legacy witnesses remain format1 and omit new fields. The independent
`scripts/recovery-probe-observation.mjs` helper checks exact fields, canonical bounded
counters, freshness at the original check, reserve limits, fixed per-owner sender
loss and monotonic counters. It compares cached collections exactly and orders
observations by native check time rather than asynchronous read completion. Its
4096-entry bound covers combined bounded histories without modifying the input.

Verification: native321, Streaming179, app-model530 and tooling3758 tests pass.
New behavior was first observed failing for missing raw snapshots, malformed app
observations, lost adapter propagation, mixed-policy ownership/admission and missing
exports. All corresponding focused checks subsequently pass. The83 raw replay
checks include independently valid cached-gauge mutations from review. Two scoped
read-only reviews found no actionable issues. Joined logs and exit records are under
`artifacts/qa/repeated-live-checkpoint-recovery-app-*`; standalone replay red/green
logs are `artifacts/qa/recovery-probe-observation-*.log`.

**Still pending:** selecting recovery policy in the native fixture; explicit native
proof/quality formats; threading the raw replay helper through all host joins and
retirement/lifecycle checks; rejecting mixed policy metadata on historical routes;
complete route selection and the new impaired-match run. No runtime route currently
selects the new app policy. This checkpoint is foundational verification, not a new
network qualification or production adaptation pass. No simulator runtime was
installed and private footage was not modified or uploaded.

## Native proof format checkpoint

The native fixture now accepts an explicit policy argument, defaulting to legacy.
Recovery starts are restricted to staged candidate-headroom mode and rejected
before publisher startup in unsupported modes. Its staged start passes the policy
to the real native adapter; every recorded sample must match the selected policy
and carry valid original preflight evidence. Recovery exports format4 with an
explicit root policy; historical1/2/3 formats retain their prior meanings.

The host native-proof qualifier accepts format4 only with explicit recovery policy
and the staged candidate-headroom schedule. It independently replays all raw
observations and preserves the existing token, acceptance, lease, retirement and
campaign gates. Historical single/staged/repeated qualifiers reject recovery
metadata; repeated replay also rejects explicitly requested unsupported policies.
This new gate still certifies local acceptance only, never receiver capacity.

Review found a missing join between otherwise valid raw checks and sent-byte
progress: a forged proof could repeat the initial raw check while accepting more
traffic. Four new mutants reproduced the gap before the fix. The qualifier now
requires admission-time evidence for empty stages, unchanged raw evidence when
acceptance is unchanged, and later preflight checks after prior completion when
acceptance advances. Preflight must precede its acceptance and already have
sufficient total token-pacing credit. These conditions apply to this qualifier's
active/cancelled snapshots; unsuccessful-send terminal reasons remain rejected.
Follow-up review found the gap closed with no new findings.

Focused native fixture41 and host proof230 checks pass; the full app suite passes
532 tests. Native/Streaming runtime code is unchanged from the preceding321/179
passes apart from the DEBUG fixture's explicit policy selection. Full tooling
passes3782 tests; verification is recorded in `repeated-live-checkpoint-recovery-native-proof-tools-full`.
Red/green app proof-format logs, repeated-policy rejection logs and all four
acceptance-mutant failures are preserved under `artifacts/qa/recovery-*`.

**Next at this checkpoint:** implement the recovery-aware automatic profile-change
retirement join, quality format and admission/candidate/lifecycle host joins. At
this checkpoint the recovery native qualifier explicitly rejected
`measuredRetirement`; the following checkpoint supplies matching raw-policy coverage. App environment selection remains
legacy, so no new real-match run or production adaptation pass is claimed. Existing
repeated/outage formats and pressure policy remain unchanged. Then freeze the full
source and prepared input and run the actual400ms/slice impaired-match experiment.

## Retirement and candidate join checkpoint

The recovery-aware native qualifier now accepts automatic profile-change retirement
only with matching versioned context: quality5 / `transportPolicy=recovery-budget-v1`,
native4 / recovery policy, and admission2 / recovery convention. The actual
quality exporter selects that envelope from the same immutable transport limits
used by pressure classification. Legacy settings still export the original v4
object, and the app environment factory still selects the historical policy.

Retirement joins exact raw observations across the frozen admission, candidate
binding, pre-request owner and terminal read, then independently validates their
combined native acceptance history. The receiver interval gate explicitly forwards
the selected policy when recomputing native qualification. Candidate headroom and
frozen witness replay require matching policy/native format and join all initial,
final, admission and native probe observations. Legacy defaults reject the new
metadata rather than silently interpreting it with historical rules. Later reset
and repeated recovery-budget routes remain explicitly unsupported.

The reusable acceptance-history helper preserves the raw check-time ordering and
also compares accepted-byte progress per owner independently of async read return
order. It does not make different native collections have equal gauges. One initial
negative test incorrectly required that; a diagnostic identified the distinct
collection, and the corrected test now rejects frozen initial evidence while a
positive case preserves legitimate gauge changes at a distinct collection time.
No verifier bound was relaxed.

Review found that candidate final observations had not been pinned to the candidate
owner: a changed final UUID could form an unrelated valid raw history. New legacy
and recovery mutants reproduced the gap. Final identity, generation, campaign,
stage, rate, start and policy now match the binding, its observation lies between
measurement end and completion, and its active lease/counters are checked against
native history. Repeated envelope5 also replays the final native read interval.
Final and later-returned admission reads may overlap; their counters are not ordered
merely by return time. Follow-up review found the gap closed and no new findings.
The receiver-completion boundary test was updated with a valid final snapshot at
its deliberately moved completion, preserving that test's original target.

**Next:** thread explicit policy through the complete measured native evidence and
successful-trial pressure replay, the remaining lifecycle gate, and the harness.
Add complete DEBUG file/measured/staged/network route validation and select the
native probe and pressure policy together. Keep repeated/outage routes historical.
Then freeze and run the prepared real-match400ms/slice experiment. The pure replay
unit fixtures attach synthetic raw metadata to recorded scalar chronologies;
they are not a new real native/network qualification. Production remains at the
minimum and no simulator runtime was installed.

Verification for this checkpoint: full app-model533 and tooling3840 tests pass.
The focused quality-driver suite passes30, and legacy/repeated plus recovery witness
checks pass103 after the final-owner repair. The initial full tooling run passed3820
before those20 new ownership mutants. Red logs retain the missing implementation,
policy mixing, detached final-owner and quality-envelope failures; the completed
full checks are joined under `repeated-live-checkpoint-recovery-retirement-quality-models-full`
and `repeated-live-checkpoint-recovery-retirement-candidate-final-tools-full`.
The native321/Streaming179 suites remain the preceding verified baseline; their
runtime libraries were not changed in this checkpoint. Read-only review and its
follow-up found no remaining actionable findings in this slice.


## Complete trial and DEBUG route checkpoint

The successful full-trial qualifier now explicitly selects the recovery probe policy
and forwards it through lifecycle/native/receiver/witness joins. Lifecycle joins the
binding, pre-request and terminal raw observations with exact owner identity. The
pressure replay requires matching independently qualified lifecycle/witness policy
and quality5; it applies recovery-budget rules to the original transport samples.
A behavioral fixture with five-percent recovered retries passes only the new policy;
actual drops, unknown delay and exhausted RTT/backlog reserves still reject. A
controlled mutation restoring historical pressure forwarding failed that test.
Later reset/repeated and confirmed-prefix recovery-policy routes remain unsupported.

`SCOREBUG_TEST_PROBE_POLICY=recovery-budget-v1` now selects both native probe and
pressure policy on the complete DEBUG simulator file/measured/staged/network route.
Host validation rejects partial, malformed, repeated and fault combinations before
creating resources. App validation runs before optional selector returns and uses a
nonrecursive leaf predicate. The host, generated Xcode scheme, UI test launch and
app carry the same value; full-trial replay receives it explicitly. An absent flag
retains historical behavior. The delayed link still requires actual400ms peer delay;
this policy opt-in is not production upgrade authority.

Verification: route red/green tests, full app-model534 and tooling3850 pass. The six
Swift route tests and35 host option tests cover complete/partial/unsupported choices.
Two read-only reviews found no actionable issues in the trial integration and route
wiring. Runtime libraries are unchanged from the preceding native321/Streaming179
passes. Joined full logs are `repeated-live-checkpoint-recovery-route-models-full`
and `repeated-live-checkpoint-recovery-route-tools-full` under `artifacts/qa`.
The pure full-trial unit fixture combines synthetic raw observations with recorded
scalar chronology; it does not qualify real network adaptation.

The next actual run is prepared in
`artifacts/qa/native-measured-link-recovery-budget-run.py`: ninety-second file hold,
iPhone14/iOS26.2, static bidirectional30ms/every500th-datagram loss,400ms SRT delay,
slice decoder,1500ms deadline and explicit recovery policy. It freezes source and
prepared clip hashes, joins the same process and preserves all failures. Current
installed iOS/watchOS runtimes are26.2 and27; older-runtime coverage is historical,
not a claim that deleted runtimes remain installed. No runtime was reinstalled.


## First recovery-policy impaired-match attempt

Commitd8b3d80 ran as `native-app-4a378Y`, frozen by
`recovery-match-freeze-uh5i8mjs` (1216 hashed inputs unchanged at joined completion).
The full harness exited1 at the unchanged24fps capture-window gate. Both offending
five-second steady windows occurred late,110–115s and115–120s after the publication
observation anchor: capture/encode were10 and9.6fps. File-source diagnostics record
maximum read0.835s, total reads10.678s and maximum nominal source lag9.127s; their
aggregate timing does not establish exactly which reads caused each bad window.

The new native recovery policy worked independently: all three stages completed,
242 observations replayed successfully,12,349,344 accepted padding bytes, actual
400ms sender delay and no quality `localPressure` events. Native acceptance is not
receiver capacity/adaptation permission. The link qualifier independently confirms
53 forward/16 reverse injected drops,30ms directional delay and no unintended loss.
Quality5 / recovery policy exported556043bytes with no overflow.

A separate earlier candidate failure prevented any profile upgrade. Its measurement
accepted one raw frame and stopped with `inputRejected` / `audioOpeningCoverage`.
There are zero profile requests. The failed opening packet was not retained by
that implementation, so startup callback-order loss is a hypothesis, not a proven
cause. It occurred around37s; the late capture slowdown occurred over70s later.
Do not conflate them or weaken audio, frame-rate or deadline requirements.

Saved media checks establish contiguous archive IDs0–3739 and live IDs216–3540,
with archive continuing6.633s beyond live. All AAC frame timestamps remain within
0.205ms of cumulative sample time; three source-anchored natural-audio windows per
output pass, and live score-template checks pass0–0 then1–0. Complete natural-audio
phase anchors/adaptation were not qualified. Frame-identity continuity does not
prove timely real-time delivery. The closed local archive/persistence gate passed.
Owned simulator, relay, API and child-process cleanup was verified independently.
`native-app-4a378Y/failure-assessment.json` preserves the bounded findings.

Next investigation: retain one rejected opening audio receipt plus original armed
and evaluation times, with no payload/history, and repeat the frozen route after
focused/full checks. This diagnostic does not relax the opening coverage gate or
alter scheduling. Keep the earlier failed attempt visible even if the next passes.


## Opening-audio diagnostic checkpoint

The transport now freezes one `openingAudioFailure` receipt when the existing
opening-coverage check fails: original armed time, source PTS, observed/evaluated
times, generation, format and byte count. It retains no payload or history. Later
callbacks cannot overwrite the terminal result. DEBUG measurement export includes
it only when present, preserving successful/historical output omission. Host run
configuration and final results now also record the selected probe policy.

The diagnostic and its export each failed their targeted tests before implementation.
Focused transport16 and export2 checks pass; full Streaming180 and app-model535
pass. A read-only review found no issues. Logs are the joined
`repeated-live-checkpoint-opening-audio-*` records. Native321 and tooling3850 are
the preceding passes; no native transport rules or host qualification rules changed.
The diagnostic does not fix either observed failure. The next frozen experiment
uses `artifacts/qa/native-measured-opening-audio-run.py` with the same route/limits.


## Candidate startup routing repair design

The second diagnostic run (`native-app-x7dq7N`, frozen `opening-audio-freeze-cqyq035t`)
completed the121-frame candidate and confirmed240→360. It did not reproduce opening
failure or the severe capture slowdown. The full benchmark still failed because
152/154 delivery rows met its stricter30fps count; the other overlapping rows had
29 and59 frames, all on time with zero late/missing/uncertain frames. No timing limit
is changed and this attempt remains failed. Independent native/receiver/lifecycle/
candidate/policy replay passes; this is not full-trial qualification.

Read-only review found a concrete owner startup omission independent of whether it
caused the first attempt: audio routing remains disabled after transport arming until
encoder startup completes. Also, the startup task can run before its router entry is
installed. The transport already has a bounded16-packet/128KiB pre-raw queue, but
these packets never reach it. A new real-transport/real-candidate-encoder regression
holds startup after arming, injects an opening packet through the owner, then admits
two video frames and the following audio packet. It reproduces `audioOpeningCoverage`
with the current implementation. The original owner test also assumed early audio
must be discarded; it now expects raw admission to remain withheld while armed audio
can reach its transport.

Repair: gate the existing one startup task until the reserved entry is installed
and its identity validated. Enable only audio routing immediately before releasing
that gate; the transport still ignores unarmed/wrong-generation input and enforces
its existing finite queue. Raw video admission waits for encoder startup as before.
Cancellation, terminal completion and stale identity disable both routes and retain
the original shared shutdown join. No per-packet task, payload history, gate
relaxation or production quality promotion is introduced. Verify focused/full
Streaming and app suites and review cancellation/startup ordering before another
frozen network experiment.


## Startup routing repair verification

The real encoder/transport regression first reproduced missing opening coverage
through the owner. With the repair, that packet reaches the existing pre-raw queue
and the mux completes; its original source timestamp and observed time survive.
Fifteen focused owner tests pass, including stale identity, held startup, cancellation
and shared stop/retirement. Full Streaming181 and app-model535 pass. Read-only
review found no new race, lock inversion, unbounded retention or cleanup issue.
Joined red/green and full logs use `repeated-live-checkpoint-candidate-startup-audio-*`.
This proves the startup ordering fix, not its causal role in the first native run.

The second run's independent component replay, three baseline audio windows per
output and27 phase audio anchors pass. Archive IDs0–3856 and live IDs200–3638 are
continuous; archive extends7.267s beyond live. All154 delivery rows contain zero
late/missing/uncertain frames, with the strict laboratory30fps count failing only
the overlapping29/59-frame rows. The user24fps floor is maintained; no verifier
threshold was changed or failed benchmark retroactively promoted.1216 frozen inputs
and owned simulator/relay/API/process cleanup were verified. The next actual
experiment uses `artifacts/qa/native-measured-startup-audio-repair-run.py` with the
same source, static link, SRT budget and delivery criteria.


### Measurement startup clock repair (in progress)

The third frozen run (`native-app-Jts7xm`, freeze `startup-audio-repair-freeze-o7r6bolm`) joined with exit 1 and all 1,216 source hashes unchanged. Candidate transport failed `audioOpeningCoverage` after one raw frame; there were no profile requests. Its first raw PTS was 166.25 s, rejected AAC PTS 166.275583291 s, arm time 1950475.9192127085 and packet observation 1950475.9397460418. The 25.583 ms source gap exceeds one 48 kHz AAC packet (21.333 ms). This preserves the failure without proving when a prior packet arrived.

Review separately found that measurement `startedAt` was recorded after native startup, while valid AAC could already be retained after arming. The unchanged cost validators correctly reject such out-of-window evidence. The previous regression fabricated an earlier measurement start and masked this integration gap.

Repair design: establish measurement time and the existing five-second deadline before arming/native startup; keep raw admission separately disabled until startup completes; include startup time in the same five-second budget and reject late readiness even if the timer is delayed. Pass generation through the production measurement startup operation so arming occurs after its clock. Preserve joined cancellation, terminal ownership and all AAC/cost gates. Replace the fabricated measurement regression with real measurement/encoder/transport and final cost validation; test held startup, raw readiness and exhausted startup budget. Behavioral red confirmed before implementation. This clock fix does not claim to fix the third run's opening source gap.


### Cold-start opening audio anchor (next implementation)

Third-run media assessment: capture steady windows all 30 fps; archive frame IDs 0–3870 and live IDs 237–3651 are consecutive. The archive continues 7.3 s after live; three baseline waveform windows per output and score glyph checks pass. Maximum cumulative AAC timestamp error is below 0.114 ms. These checks are recorded in `native-app-Jts7xm/failure-assessment.json`; they do not qualify the failed candidate or an upgrade. Owned harness shutdown/deletion/container-removal logs are retained.

The opening failure is consistent with a needed predecessor packet having passed before arming, but its existence/arrival was not recorded. Do not reconstruct callback time by subtracting an AAC period: observed callbacks may arrive in batches.

Proposed repair: after the existing measurement clock and transport arming, observe one valid same-generation AAC packet before opening raw admission. Keep its source PTS as an immutable lower bound for the first raw frame. Ignore early raw samples before encoder/transport admission, rather than marking them as rejected input; open only for raw PTS at or beyond that audio anchor. The existing bounded pending queue keeps the packet, and subsequent opening coverage/cadence/following checks remain authoritative. The lower bound cannot advance between readiness inspection and first raw admission, so an audio callback cannot invalidate that decision; terminal transport failures still reject admission. No raw queue, timestamp rewriting, pre-arm media cache, new per-frame task or longer deadline. Silent/missing audio consumes the same five-second measurement budget then fails. Tests must cover no audio, raw PTS below the anchor, successful cold-start completion through real native cost validation, and retained failure on a later AAC gap.

Clock repair verification: focused 36 tests, full Streaming 183 and app-model 535 tests pass. Read-only review found no actionable issues with ordering, cancellation, timer joining or the unchanged cost gate. Joined logs use `repeated-live-checkpoint-measurement-startup-clock-*`. No native network run yet claims this clock repair fixes the independent opening source gap.

Opening-anchor implementation checkpoint: production measurement now defers raw against an immutable post-arm AAC source floor. The first raw frame must have PTS at or beyond that floor. The monotonic preflight leaves strict encoder/transport admission and all audio gates unchanged; no per-frame work or larger buffer was added. Behavioral red reproduced pre-audio raw admission; focused owner 19 and full Streaming 189 tests pass. Read-only review found no issues. All 535 app-model tests also pass. Joined logs use `repeated-live-checkpoint-candidate-opening-anchor-*`. Next is a frozen run of the same impaired match configuration.


### Fourth impaired match: opening repaired; retirement replay correction

Frozen `native-app-NCUMkX` / `opening-anchor-freeze-jh7nshwy` joined exit 1, all 1,216 hashes unchanged. Candidate completed 121 native frames, transport completed, and the controller requested/applied 360p. No local-pressure or delivery-failure events occurred. Full qualification stopped at `active observation exceeds token budget` in the host retirement replay; do not count it as a full pass.

The exact failing comparison is binding vs renewed native event 169: both accepted 1,119,916 bytes, with identical last acceptance 1951470.8371150417 and raw check 1951470.83710275. Renewal projects a checkpoint 19.209 microseconds after that unchanged acceptance. An older async binding read returns after the renewal. The token inequality itself passes (zero extra bits); the verifier incorrectly requires the historical send to occur after renewal. This does not show excess sender pacing.

Repair: distinguish unchanged acceptance from positive byte progress. Equal counters must keep exactly the same acceptance timestamp (and recovery raw check); only positive progress requires a new paced interval. Preserve every positive-delta one-message/elapsed-rate allowance and all ownership/lease gates. Historical and recovery regressions reproduce the false rejection; extra-packet and changed-timestamp mutants remain rejected. Behavioral red confirmed before implementation.

Independent media checks retain consecutive archive IDs 0–3948 and live IDs 230–3726; the archive continues 7.4 s after live. Three baseline audio windows per output and score changes pass, and AAC cumulative timestamp error stays below 0.432 ms. `failure-assessment.json` and `retirement-token-failure.json` preserve the evidence. Full host replay and phase audio checks remain to be run after the correction.


Retirement correction verification: focused 94 and full tooling 3,856 tests pass; read-only review found no issues. Joined logs use `repeated-live-checkpoint-unchanged-renewal-binding-*`. Replaying the frozen raw media with the corrected verifier passes native probe retirement, candidate admission, lifecycle and controller policy, with phases 240p→360p and confirmation. The unchanged full trial still rejects strict30fps delivery: 139/157 rows pass, while 18 rows contain 29 or 29.5 fps. All 157 rows have zero late/missing/uncertain frames and none falls below 24 fps. Steady capture windows stay at least 29.6 fps. Both outputs pass 27 additional phase audio anchors. Owned simulator/relay are removed and the API port is closed.

`final-retirement-replay-assessment.json` records the final independently replayed components and the remaining full-trial failure. `retirement-replay-final-source/` retains the exact verifier/test/replay sources and hashes. The original frozen harness remains exit 1; it is not retroactively relabeled a pass. These observations meet the requested 24fps floor in this run, but do not replace the stricter existing benchmark, qualify outage recovery, enable production upgrades or prove physical-device performance. Next work should distinguish the requested performance floor from strict30fps laboratory cadence, investigate representative-source pacing as needed, and address bounded pressure-path export before causal capacity/outage runs. Avoid retrying identical runs solely to get favorable one-second frame counts.

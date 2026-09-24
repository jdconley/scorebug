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
- [ ] Export policy and raw observation through probe events, candidate bindings,
  frozen admission witnesses and lifecycle diagnostics. Preserve legacy field
  omission and formats. Add a new explicit native proof/admission format for the
  recovery policy; add a shared JS raw-observation validator with canonical bounded
  counters, fresh checked/sample times, same-collection reserve checks, unchanged
  cached values and monotonic validated observations. Snapshot order uses actual
  check times, not the order in which overlapping async reads return.
- [ ] Wire one explicit DEBUG network-recovery route selection through the native
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

**Next:** implement the recovery-aware automatic profile-change retirement join,
quality format and admission/candidate/lifecycle host joins. The recovery native
qualifier currently explicitly rejects `measuredRetirement`; it must not be removed
until that join has matching raw-policy coverage. App environment selection remains
legacy, so no new real-match run or production adaptation pass is claimed. Existing
repeated/outage formats and pressure policy remain unchanged. Then freeze the full
source and prepared input and run the actual400ms/slice impaired-match experiment.

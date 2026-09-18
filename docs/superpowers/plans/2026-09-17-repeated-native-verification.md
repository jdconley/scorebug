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
- [ ] Combined campaign admission: extend receiver interval and candidate-witness replay with original campaign and applied revision; join each candidate proof to the corresponding real baseline phase and exact native profile request. Test cross-campaign substitution, stale measurement and receiver-counter carry-over.
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

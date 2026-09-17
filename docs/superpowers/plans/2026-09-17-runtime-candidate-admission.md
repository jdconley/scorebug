# Runtime candidate admission implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded implementation and spec/quality review. The parent owns integration, native runs and final evidence. The user's active autonomous goal authorizes proceeding without another approval gate.

**Goal:** Authorize a reversible live quality trial from fresh measured candidate A/V cost, repeatedly delivered probe traffic and current qualified media health.

**Architecture:** Add a measured-only recovery strategy and a separate candidate admission event. Health windows accumulate recovery independently; an absent candidate never creates permission or erases valid healthy coverage. A typed app adapter joins native measurement, current baseline receipt, revocable probe authority and receiver chronology. The existing owned application, acknowledgment, probation and minimum-profile reset handle the resulting trial.

**Tech stack:** Swift Core policy, CoreMedia/VideoToolbox typed candidate results, native SRT probe authority, authenticated receiver tracker, simulator qualification and independent Node replay.

## Decisions and constraints

Reusing `usableVideoCapacity` would confuse nominal video rate with actual whole-stream cost. Reusing receiver-validated trials would retain a capacity-missing bypass. Use a distinct measured strategy. The laboratory overhead convention remains explicit IPv4; unknown mobile/IPv6 routes receive no implicit qualification.

The current observation scope identifies the publishing attempt, not the current policy revision. Bind candidate evidence to the acknowledged baseline settings, revision and exact native receipt separately. Bootstrap must finish before that binding: the old fixture treats every bitrate write as revocation. Native writes intentionally retire the probe after application admission; expiry after that point must not retroactively invalidate the owned two-second application or ten-second trial confirmation.

Candidate freshness is two seconds; source windows are approximately five seconds and leases about 300 ms. Admit against the latest still-fresh healthy window, without reconsuming it or inventing additional healthy duration. Require overlap with candidate measurement. Candidate admission is independent of source-window arrival; no full extra window is required after candidate completion.

## Task 1 — measured-only policy event

Files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`, new `QualityCandidateAdmission.swift` if separation helps, and `Tests/ScorebugCoreTests/QualityCandidateAdmissionTests.swift`.

Add `RecoveryStrategy.measuredCandidateTrials` (requires progressive behavior), and immutable candidate input with this public contract:

```swift
public struct CandidateAdmission: Sendable {
    public let id: UUID
    public let attemptID: UUID
    public let appliedRevision: UInt64
    public let baseline: Settings
    public let settings: Settings
    public let measuredStart: Double
    public let measuredEnd: Double
    public let evaluatedAt: Double
    public let validUntil: Double
    public let candidateTransportBitsPerSecond: Double
    public let deliveredPaddingBitsPerSecond: Double
}
public mutating func evaluateCandidate(_ admission: CandidateAdmission, at now: Double) throws -> Decision
```

- [x] Write focused failing tests: healthy windows alone never increase; missing candidate preserves four-second recovery credit; valid exact-next admission yields a trial without adding healthy credit; actual cost uses a 25% margin; insufficient padding never implies a downshift; wrong attempt/revision/baseline/target, nonfinite times/cost, future/stale cost, stale/nonoverlapping health and replay cannot authorize. Ordinary capacity cannot bypass measured admission.
- [x] Run `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugCore --filter QualityCandidateAdmissionTests` and retain the failing log.
- [x] Implement immutable input, exact proposed-settings validation, bounded one-time chronological candidate consumption, and pending advice bound to candidate identity. Admission expiry is at most the input deadline and latest health/receiver deadline. Preserve existing application deadline, confirmation coverage, timeout, resets and cooldowns.
- [x] Test supersession by source/local/deadline evidence, invalidation, application admission/acknowledgment, trial confirmation after candidate/probe expiry, and rollback. Run the complete Core suite; request spec then quality review.

## Task 2 — typed cost and receiver chronology

Files: new `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/PublishingCandidateCost.swift` and matching tests; `WorkerReceiverProbeTracker.swift` and tracker tests; new app `PublishingCandidateAdmission.swift` and FilmModel tests.

- [x] Convert only a joined successful `PublishingCandidateMeasurement.Result` to immutable actual-cost evidence. Verify identity/profile/scope/generation, requested dimensions/rate, complete mux/audio, finite ordered source/admission/submission/completion times, >=24 measured fps, <=1.5-second per-frame latency and bounded payload/counts. Preserve exact bytes/messages and source/submission durations; never infer actual cost from settings.
- [x] Expose receiver start/end conservative `ContinuousClock` bounds from the tracker's reconciled offset. Retain latest two distinct contiguous intervals in a bounded admission observer. Missing evidence breaks pair coverage, contradictions preserve quarantine, and stage/publication changes cannot splice intervals.
- [x] Build the app adapter using actual native result, current baseline receipt/settings/revision, same-probe binding/current authority and receiver intervals. Compare `1.25 * 8 * (bytes + 44 * messages) / min(sourceDuration, submissionDuration)` with minimum delivered padding payload rate. Require current lease, candidate age <=2s, receiver and last-delivery age <=1.5s, causal coverage/overlap, and newest receiver lower endpoint after candidate completion.
- [x] Add mutation tests for cost, identity, generation, stage, chronology, authority, latest-pair selection, lost coverage, insufficient load and expiry. No JSON parsing in runtime admission; JSON remains independent audit output.

## Task 3 — owned live application and explicit simulator route

Files: `PublishingQualitySession.swift`, `PublishingQualityDriver.swift`, `CaptureStreamingModel.swift`, candidate/probe fixtures, associated FilmModel/UI tests, `ios/Project.yml`, native harness/verifiers.

- [x] Add session candidate evaluation and bind pending advice to its typed authority. Recheck exact current receipt, revision, publication, probe identity and fresh authority immediately before `beginApplication`. Stale advice must dispatch no native writes and must leave recording/live publishing intact.
- [x] Read candidate input after actor awaits, using a current provider like the delivery input provider. Evaluate after downward/deadline checks. Retain bounded typed candidate results through export; bind only after bootstrap acknowledgment. Normal production routes remain disabled until qualified.
- [ ] Add one explicit simulator measured-trial route: baseline240, selected next candidate, current health, actual native profile and bitrate acknowledgment, ten seconds of post-change receiver health, and reset to240 on unhealthy/unknown evidence or timeout. Preserve independent recording and join all owners.
- [ ] Run local native sufficient-load trial and controlled insufficient-load/withdrawal/rollback cases. Independently decode archive/live, verify source identities/audio, actual candidate accounting, admission timing, native receipts and trial outcomes. Preserve unsuccessful runs without modifying their evidence.

## Task 4 — verification and continuation

- [ ] Obtain spec and quality reviews, run affected Swift/Node/API checks, clean simulator and unsigned phone/Watch builds, provenance and source/runtime/evidence hashes. Recheck all 5,450 prior frozen files. Update main plan and commit only reviewed, verified work.
- [ ] Continue through repeated upward recovery, long sessions, phone/Watch networking and portable proxy deployment. Do not mark the full goal complete from a local fixture or partial contract.

Worktree `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, base `693f962`. Prior goal turn: progress. New evidence prefix `runtime-candidate-admission-`. Heavy Apple/native/Docker/Go jobs are sequential; the parent grants the slot explicitly. No external broadcasts, deployments or license acceptance.

## Integration notes from contract verification

The current control loop already polls every 100 ms when a quality driver or probe fixture is present; its receiver/probe owner still must be read and revalidated after asynchronous candidate retrieval. A cached 300 ms lease cannot be refreshed by relabeling its observation time. Publication and recording identity need a model-owned revocation token when the provider is installed.

The old delivery-failure fixture intentionally disables positive source-health evaluation. A measured route must explicitly permit qualified source-health windows while retaining delivery, cadence and local-pressure priority. A healthy source event without an action must continue to candidate admission in that same cycle.

Keep the existing fixed-profile headroom route and its evidence contracts intact. The live-trial route needs its own opt-in and independent verifier: it must distinguish expected probe/candidate retirement caused by an admitted configuration change from pre-admission withdrawal, and collect native format evidence across the baseline and new encoder. A successful contract test with controlled native operations does not qualify an actual simulator stream or physical device.

## Live integration checkpoint

Contract commit `4e4e295` passed 426 Core, 143 Streaming, 350 FilmModel and 306 independent replay tests, a clean simulator app build and unsigned iPhone/Watch Release build. Its immutable manifest rechecked 5,450 earlier evidence files. The next phase uses `measured-live-trial-` evidence with 5,554 frozen prior files; it does not overwrite the contract checkpoint.

The explicit `SCOREBUG_TEST_MEASURED_TRIAL=1` simulator route uses native240/350 kbit/s, candidate360/600 kbit/s and fixed worker 360p output. The worker initially upscales240, then preserves the actual360 detail after admission; archive capture remains1080. Keep existing headroom options and validators unchanged. Require staged probing, structured motion, direct local RTMP recording, publication and processing evidence, and a 90–600 second hold. Other quality controllers, scheduled transitions and fault routes are incompatible with this initial positive case.

- [x] Install the current candidate provider after bootstrap and recheck ownership after awaits. Revoke cached admission on recording/tap replacement, publication/probe retirement and teardown; monotonic native reads cannot roll leases or counters backward. Measured mode retains source/cadence health alongside delivery failures.
- [ ] Observe the shared native publisher's baseline and changed encoder, including exact receipts and first-new-frame sync. Preserve completed candidate evidence separately from later lifetime retirement. Export the actual admission-time receiver pair and clock bounds; future observations cannot tighten historical permission.
- [ ] Join admission/application IDs to owned native writes, candidate/probe retirement, acknowledgment and ten seconds of qualified post-change media. Unknown/unhealthy evidence must reset or roll back. A successful trial uses exactly240→360; failed trials retain their full evidence and are not relabeled as passes.
- [ ] Independently validate the live360 output and1080 archive, complete decoding, per-frame dimensions, source continuity and audio identities. Run sufficient-load, withdrawal and rollback cases, then reviews, builds and immutable evidence checks before enabling any production upgrade.

### Measured-route diagnostics and verification in progress

The first two native runs deliberately remain failed diagnostics, with immutable evidence:

- `native-app-60FKaw` (A): worker reports arrived at 1 Hz, preventing the 250 ms freshness gate from admitting source health. Candidate transport cost was 4.034 Mbit/s versus 9.817 Mbit/s delivered padding, but the runtime rejected admission. Independent replay fully decoded the 1080 archive (3,753 frames) and worker 360p output (3,312 frames), both at 30 fps with no lost fixture frames. Worker360 was an upscale of native240, not a native upgrade. Its initial bitrate receipt also exposed a harness join omission, now corrected.
- `native-app-POjmCK` (B): explicit measured mode now requests 100 ms worker reports. The unchanged one-second delivery budget correctly rejected normal source-to-decoder delays: conservative bounds ranged from 1.156–1.431 seconds. Archive (3,676 frames) and live output (3,265 frames) again decoded at 30 fps without lost fixture frames; no native upgrade occurred. This reproduced the previously documented reason for a 1.5-second experimental deadline.

Measured mode now explicitly requires `SCOREBUG_TEST_DELIVERY_DEADLINE_MS=1500`; this does not relax the independent 250 ms report freshness gate. Its audit also captures bounded raw worker cadence/delivery responses for independent replay. A focused RED/GREEN test proved the raw-evidence route is enabled only with the complete measured fixture prerequisites. All 362 FilmModel tests passed before that final audit-routing change; focused audit/fixture tests passed afterward.

The new witness replay verifies the exact frozen candidate cost, selected receiver pair and native probe history, and reports media health and upgrade authorization as false. Review found additional chronology/lease consistency cases to tighten before accepting the replay implementation. Native diagnostic C uses the explicit deadline and raw report export; no live-trial qualification or production upgrade is claimed until the actual application and post-change evidence are independently verified.

Diagnostic C (`native-app-fe4eFd`) now independently verifies 130 healthy source-to-decoder deadline windows (88 one-second windows and 42 two-second windows) against 820 raw worker reports. All 5,160 classified frames across those overlapping lanes were on time; 21 rows remain unknown, not healthy. Both archive and live media fully decoded at 30 fps with no fixture-frame loss, and the independent candidate witness passed with cost 4.072 Mbit/s, delivered padding 9.861 Mbit/s and required margin 5.090 Mbit/s. There was still no native profile change.

C exposed a caller timing bug: the driver consumed the one-shot candidate at uptime 1327305.854 while its latest source window was stale and nonoverlapping. The next overlapping healthy source arrived at 1327305.983. The session now performs an atomic caller-readiness check after the provider await and returns a deferral without consuming candidate identity until current matching source ownership, <=2-second window/receiver freshness and strict measurement overlap exist. Revoked authority still rejects; Core still controls strong health, recovery duration, cooldown and one-shot policy decisions. Focused RED/GREEN verification passed 37 tests, and spec/quality reviews found no implementation defect. Diagnostic D exercises that fix; native lifecycle/transition qualification remains open.

Witness review fixes passed 55 tests: the latest available receiver pair must be selected, counter/time values cannot precede the native renewal for the exact lease, and omitted intermediate polling can conservatively narrow clock bounds without relaxing independently replayed chronology. The expanded affected independent replay suite passed 451 tests. All 5,554 prior frozen evidence files remain unchanged.

Diagnostic D (`native-app-ua1Z6T`) exercised an actual measured240→360 application, followed by a reset to240. Native profile receipts identify both new encoders and zero dropped raw frames; exact bitrate receipts follow each profile acknowledgment. The trial was admitted before its probe deadline and completed within its separate two-second owned-application deadline. It did not confirm ten seconds of probation.

D exposed another integration bug: first delivery at revision 1 was a fully on-time 30-frame window (sample age 188 ms), but session bookkeeping treated its expected revision change from 0 as telemetry invalidation and latched reset. The corrective change must advance deliveryRevision and clear per-lane ends only after successful native/policy acknowledgment, retaining the worker authority token so real context replacement still invalidates. A second native run will verify the correction; stale/unknown observations must continue to fail conservatively.

Independent replay decoded D's 1080p archive (3,652 frames) and worker 360p live output (3,262 frames), both 30 fps with no fixture-frame loss and all 60/54 audio markers respectively. Raw deadline replay qualified 124 healthy windows; unknown rows remain unknown. D intentionally fails the existing fixed-native-format verifier once dimensions change: new measured transition/lifetime evidence and end-to-end trial qualification remain required. Do not weaken the old fixed-profile validator or relabel this diagnostic as a qualified successful trial.

### Next native evidence increment

Keep lifecycle evidence independent from the closed candidate measurement. A bounded opt-in `native-candidate-lifecycle.json` should capture candidate identity and current authority synchronously before native profile dispatch, then request/completion times, exact receipt, and terminal probe read brackets. Do not relabel an asynchronous terminal read as the acknowledgment instant. Stop must join owned native work before exporting; missing evidence remains unknown. Bound the number of profile applications and include failure outcomes.

Compose the shared SRT publisher's pre-mux and encoder observers with an explicit measured transition evidence sequence (a new schema/version). Capture actual baseline 240p, target 360p and any reset 240p phases. Preserve strict fixed-profile validators unchanged; a phase-limited baseline proof must be labeled as such and joined to complete transition coverage. Join the candidate witness to exactly one admitted application and its exact profile/bitrate receipts. Verify ten seconds of contiguous qualified post-ack source health, or correctly classified reset/rollback. Probe retirement after owned admission must not be confused with pre-admission withdrawal.

Only after this independent gate exists should the measured harness report a whole-run pass. Ordinary production automatic upgrades remain disabled, and physical-device and remote-proxy performance remain unqualified.

The expected-revision fix now advances deliveryRevision and clears deliveryEnds synchronously after successful native receipt validation and policy acknowledgment; it retains the same revocable deliveryAuthority. Behavioral RED reproduced a spurious reset and failed confirmation, then 78 focused tests passed. Regression coverage includes same-authority healthy delivery through ten-second confirmation, replacement authority, uncertain/missing delivery and old-revision rejection. Reviews approved the narrow production change. The revoked-candidate driver regression now additionally requires exactly one staleAdvice rejection across repeated ticks.

Diagnostic E (`native-app-MFE1mj`) confirms the first-post-ack delivery revision fix: the native 360p trial survives that sample and reaches a probing source-health window. It later resets on `cadence-freshness` before confirmation. A raw current cadence report was already available 11 ms earlier with 140 ms age and no stall, suggesting the driver used its older tick argument after actor awaits. The next change supplies current cadence and diagnostics at execution time, preserving 250 ms freshness and authority checks. It must not fall back to an old tick snapshot when an installed provider has no current input, nor permit positive source/candidate evaluation through missing current evidence.

E's 1080p archive (3,638 frames) and worker 360p live output (3,262 frames) fully decoded at 30 fps with no lost fixture frames and all 60/54 audio markers. Independent deadline replay classified 121 windows, 119 of them meeting the 30 fps healthy threshold; all 4,798 classified frame instances were on time, 18 rows were unknown, and no classified window fell below 24 fps. This remains a failed whole-run diagnostic, with no ten-second trial confirmation or complete native transition/lifecycle qualification.

The current-cadence provider is now installed with exact session/attempt/recording/tap ownership. The driver reads it after delivery work and the policy actor await, and uses its matching current diagnostics. An absent owner supplies no fallback diagnostics and permits only deadline handling; missing cadence from a current owner invalidates positive recovery/probation while preserving already justified Core downward advice. Consumed receipt/progress/stall history remains monotone, with explicit freshness revalidation if an old receipt reappears after a gap. All 180 affected tests passed and spec/quality reviews approved the implementation. Diagnostic F exercises this version.

One earlier expanded model run exposed a timing-sensitive fixture failure in the latest-pair admission test. The fixture generated a 1 ms-old receiver status and a 300 ms native lease before unrelated control-plane awaits; exact rejection cause was not logged, so do not call that failure proven candidate expiry. A test-only hardening follows F: generate observedAt at actual status response delivery, keep scripted counts/lastDelivered unchanged, renew the fake native lease at its read boundary, and inject 400 ms pre-status delay. Preserve existing captured-response semantics for all other server fixtures and retain current-pair/revocation assertions. Production freshness limits remain unchanged.

Diagnostic F (`native-app-ce84PE`) again applied native 240p→360p→240p. This time the current report really aged beyond the 250 ms limit: its age was 218 ms when recorded and approximately 261 ms at rejection, with the next report arriving later. The fallback is correct; ten-second confirmation remains unproven. Preserve the limit and investigate telemetry scheduling separately from control-plane maintenance instead of rerunning until timing happens to pass.

Independent replay fully decoded F’s 1080p archive (3,654 frames) and 360p worker output (3,264 frames), both approximately 30 fps with no lost fixture frames and all 60/54 audio markers. Deadline replay classified 117 windows, including 115 healthy windows and 4,678 on-time frame instances across overlapping lanes. Another 24 rows remain unknown; no classified window fell below 24 fps. The old fixed-format gate correctly rejects the native dimension transition, and complete native transition/lifecycle qualification remains pending.

The test-only timing hardening reproduced the delayed-admission failure before the change and passed all 85 model tests afterward. The fake receiver samples its observation time at the response boundary while preserving packet evidence; fake lease renewal is opt-in at the native read boundary. The regression injects 400 ms delay and verifies real delivery age, latest-pair selection and stop revocation. Production freshness budgets are unchanged.

For the next scheduling investigation, instrument control maintenance, HTTP status request, native probe join and policy actor delay separately. `ContentView.monitorStreamingControl` currently sleeps for the poll interval after `pollControl` completes; `pollControl` persists, flushes reports and recovers coordinator state before requesting worker telemetry. Those dependencies identify work to measure, not a proven bottleneck. Preserve ownership/revocation and monotonic report history if telemetry is later separated from control maintenance.

### Verified integration checkpoint

The final full FilmModel suite passed all 374 tests. The affected independent replay suite passed 451 tests. Clean simulator build-for-testing and unsigned iPhone/Watch Release builds succeeded using licensed Xcode 26.2. Spec/quality reviews approved the runtime changes; the final test-only timing hardening also received a clean quality review. Immutable evidence is indexed by `artifacts/qa/measured-live-trial-final-verification.json`, including all six failed native diagnostics and the prior-evidence integrity check.

This checkpoint wires and verifies measured candidate admission in the explicit simulator route. It does not qualify sustained native trial confirmation, enable production increases, or establish physical-device/remote-proxy performance. Next implement complete native transition/lifecycle replay and investigate telemetry scheduling, then run controlled withdrawal, rollback and repeated recovery before longer sessions and device testing. The autonomous goal remains active.

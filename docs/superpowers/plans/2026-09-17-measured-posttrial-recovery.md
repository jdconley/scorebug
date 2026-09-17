# Measured post-trial failure and recovery

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded independent implementation and spec/quality reviews. Parent owns harness integration, native execution, and final evidence. Work only in the existing local-validation worktree.

**Goal:** Exercise a controlled real decoder stall after a qualified measured native increase, and independently prove the reset and subsequent healthy minimum delivery with an intact independent archive.

**Architecture:** Add an exclusive Node test option alongside the existing measured route. Reuse the owned-process pause/resume mechanism with a bounded 70-second pre-fault schedule and before/during status observations. Timing schedules the experiment only: qualify that the captured before-pause progress belongs to actual higher-profile source frames after independent trial confirmation. Never mix Node fault time with phone uptime. Keep ordinary successful-trial qualification strict. Share raw-evidence foundations and add explicit prefix/recovery verifiers without fabricating stopped events, changing raw proofs, or granting production permission.

**Tech stack:** Existing Node native harness, Swift measured control path, SRT relay and worker, raw cadence/delivery/native lifecycle proof exports. No production behavior change is intended unless the experiment exposes a real defect.

## Authoritative baseline

Previous goal turn is progress: clean commit `3bc886b` passes all 2,080 tool tests and the complete fresh native run `native-app-LkAs1j`. It independently qualifies a 240p→360p measured increase, approximately15 seconds probation, healthy delivery, 1080p archive and native scoring. Production automatic increases remain disabled. Preserve its manifest, raw artifacts and all prior frozen evidence.

## Design choices

A fixed 70-second delay is a bounded scheduling aid; retrospective raw progress correspondence must prove this is a post-confirmation fault or the run fails. A new native live checkpoint/export or additional production telemetry would add instrumentation without being required for that proof. Network impairment remains a later distinct scenario; pausing only the exactly owned decoder first gives a clear causal stall with deterministic resume in finally.

The reset verifier must distinguish decoder-stall versus delivery-failure precedence using actual exported decisions. It must not require an invented preferred reason or infer healthy recovery merely from a successful encoder write. Each configuration's receipt/lifetime/source frames remain independently bound. Successful post-reset delivery needs contiguous windows and owned fresh telemetry; no overlapping lane credit. Repeated fresh candidate campaigns and ramp-up after reset remain required future work, not a claim of this initial gate.

## Implementation tasks

- [x] Freeze prior evidence and classify current processes before running anything. Add exclusive command logging/source snapshots for all new checks/native runs.
- [x] Add explicit measured recovery option (`SCOREBUG_TEST_MEASURED_RECOVERY=decoder-stall`) gated by the complete measured prerequisites and minimum90-second hold. Preserve legacy options. Add bounded fault schedule input to the owned decoder helper, record it, and keep default20-second behavior. Test invalid schedules, cancellation, process replacement, before/paused samples and finally-resume.
- [x] Extend measured policy replay with a separately named prefix verifier: independently prove bootstrap, candidate admission and confirmed probation from unchanged raw events through the confirmation boundary. It may accept the already-qualified full native three-phase history but must expose exactly where proof ends; the full successful verifier remains strict. Extend causal probe retirement only through explicit recovery context, allowing one later owned reset and preserving first trial ownership/counters.
- [x] Integrate the recovery option into the local fixture and harness. Copy all raw artifacts once; retain archive/scoring/A/V/ingress/processing/direct-recorder checks. A diagnostic cannot print a complete recovery pass until a mandatory independent recovery verifier exists and passes. No loss-policy weakening to make the fault pass.
- [x] Run one stable native diagnostic after model/tool checks and review. Preserve any failure, prove exact pre-fault confirmation from raw evidence, and implement/refine recovery replay against actual artifacts. Require native reset receipt/deadline, causal failure evidence, minimum-profile source correspondence and at least10 seconds of healthy contiguous post-reset delivery/telemetry. Test negative mutations and prior successful/no-fault artifacts.
- [ ] Run affected regressions, independent spec/quality reviews and a complete fresh native recovery gate once stable. Investigate unexpected failures without widening freshness, frame-loss or application limits. Update plans/evidence, verify old artifacts unchanged and commit. Keep the overall goal active.

## Boundaries

Do not accept Xcode licenses, deploy externally or claim physical phone/Watch/network certification. Use licensed Xcode26.2, sequential heavy native jobs and immutable evidence. If the native fault exposes a legitimate stream gap that violates existing media completeness, investigate rather than suppressing it. Production increases, repeated post-reset ramp-up, broader network loss, long runs and additional proxy hosts remain open.

## Diagnostic findings and refinement

`native-app-PZGuFl` exercised confirmed 240p→360p, a decoder-stall-triggered reset,
and healthy minimum delivery. Its real pre-pause observation was 273.134 ms old
against the unchanged 250 ms bound. Preserve it as failed evidence. A full process
re-inventory after the HTTP sample caused most of that delay; revalidation now
uses one scoped `ps` query for the three already selected identities, with exact
PID, parent, executable and start-time checks and cancellation before signaling.
Initial discovery and finally-resume checks remain intact.

`native-app-TPUMig` reduced pre-pause age to 144.409 ms and paused for 2009.523 ms.
This time the controller's higher-priority one-second delivery failure crossed
24 fps before decoder progress had been stalled for one second. Add an explicit
observed delivery-first causal verifier, bound to the exact raw deadline receipt,
failed source frames, unchanged paused progress PTS, and subsequent fresh stalled
and resumed observations. Keep the decoder-stall route separately supported;
neither route may invent a signal or mix Node timestamps with native uptime.

The second run remains failed: late post-reset polling contained a 1.685-second
gap (including 1.585 seconds of pre-status control maintenance), exceeding the
unchanged 500 ms continuity bound. A smaller preceding gap also exceeded it.
Archive/A/V and preceding harness checks passed. Investigate maintenance without
attributing the aggregate delay to a particular operation without evidence, and
retain this raw run as a negative regression. A later complete run must pass both
causal qualification and all existing continuity/recording/media gates.

The next run, `native-app-mnaRRb`, passed the shared raw-evidence gates and had a
maximum fresh-report gap of 151 ms. Its original harness result is still failed:
the verifier supported only the one-second delivery branch, while the controller
correctly used its two-second source-loss rule (5 missing of 59 expected frames).
Generalize delivery-trigger replay to the exact native rules for both lanes,
including the native zero-on-time state/reason and simultaneous stalled-cadence
cases. Keep source correspondence, causal pause ownership, fresh raw reports,
minimum reset receipts, and all recovery coverage requirements unchanged. Replay
this unchanged artifact independently, then require a fresh complete harness run.

The earlier maintenance delay remains unresolved. Evidence isolates it before
status HTTP but cannot separate synchronous state persistence from coordinator
recovery or actor scheduling. A subsequent diagnostic can add DEBUG brackets
around restore, persistence, report flushing and coordinator recovery, with
controlled fake-storage/transport tests. No durability ordering or production
polling behavior is changed in this increment.

The unchanged C artifact now passes the complete pure recovery replay. Its first
minimum source window is validated but excluded from health credit because the
original paused progress is still observed at its start. Credit uses only whole
windows after independently observed resumed progress and inside both healthy
delivery lanes. All 2,269 tool tests and the final combined review pass; the raw
A and B failures still reject. C's original native-harness exit remains 1.

## Verification checkpoint: complete native pass still pending

Fresh run `native-app-4xzLz8` used the frozen reviewed sources and exited 1 before
recovery qualification. The local archive passed its media checks: 3,609 consecutive
1080p video frames, audio and video both starting at zero, and complete audio
markers. The failure is in the **streamed output**: video starts at zero and audio
at 0.429002 seconds, exceeding the unchanged 100 ms audio-lag budget. This is not
an archive-start failure. Its raw artifacts and failed exit remain preserved.

All 2,269 tool tests pass. Independent replay qualifies the unchanged C recovery
evidence, while A's stale fault and B's late polling gaps remain explicit negatives.
The new native harness gate is mandatory and cannot print a complete pass merely
because control reset or media export succeeded. Final combined reviews approved
both native delivery-failure lanes, exact deadlines, process ownership, and recovery
credit after fresh resumed progress. Production increases remain disabled.

Next investigate the streaming audio startup gap across publisher, worker, RTMP
recorder and export timestamps. Preserve the 100 ms A/V limit and all prior raw
failures; do not trim, silence-fill or redate evidence to obtain a pass. A complete
fresh recovery run remains required. Separately instrument the unresolved control
maintenance delay if it recurs, then proceed to repeated fresh candidate campaigns,
longer adaptive sessions, physical phone/Watch networking and other proxy hosts.
The goal remains active. Evidence is indexed by
`artifacts/qa/measured-posttrial-recovery-final-verification.json`.

A bounded packet-level comparison also shows D's first AAC packet PTS/DTS at
0.429002 seconds, versus zero in C, with no exported skip-samples side data on
those first packets. The gap therefore exists in the recorded packet presentation
timeline too; the responsible upstream or mux stage is still unlocated. Next add
bounded first-audio/first-video PTS diagnostics at the necessary publisher, worker
and recorder boundaries, preserving each clock domain and excluding credentials.

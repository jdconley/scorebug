# Pipeline geometry correlation — September 26

## Starting state and objective

Authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch
`codex/local-validation`, starting HEADd8d4317. Previous goal turn made progress:
native720recipe43f2229 and bounded decodedgeometry038a4ec are reviewed, tested and
committed. Worktree was clean on resumption. Goal remains the full native
recording/scoring/Watch/progressive-streaming vertical, not component completion.

Physical Watch preparation is still pending a device-specific readiness reply.
The last retry stopped before camera capture; no active jobs carried into this
turn. Phone automation approval persists. Do not retry unchanged Watch state.
No heavy builds or media analysis may overlap any future live capture.

## Current work

Implementer `/root/applied_transition_implementation` owns the source/test slice
in the [correlation plan](../superpowers/plans/2026-09-26-pipeline-geometry-correlation.md).
Root owns documentation, independent verification and next recovery720 integration
design. Public domain-separated hash keys will correlate accepted native decoded
windows with actual proxy geometry while preserving private read IDs. This slice
must retain legacy compatibility, existing authenticated scope checks, exact
signed PTS and4096byte diagnostics. No production ladder change yet.

Next: source spec/quality reviews and commit, then explicit ordinary240→360→720
confirmation/congestion/recovery through allthree media outputs. Keep timing,
resource limits,750kbps constraint and540second recording budget unchanged; failure
remains failure. Preserve original matchmedia and all earlier failed artifacts.

## Next720 lane design

Root drafted [ordinary720recovery](../superpowers/plans/2026-09-26-ordinary-720-recovery.md)
and obtained a read-only feasibility review. The current policy can legitimately
descend720→360→240 under ordinary pressure, so the checker must not infer direct
minimum reset. Keep four climbs consecutive; fallback qualifies the observed
minimum ACK after the actual cap, retaining observed intermediate changes without
claiming an exhaustive2second-sampled chain. Geometry interval endpoints must
belong to the same contiguous expected-resolution run, rejecting a720→240→720
sandwich. Startup has no profile-change appliedTransition receipt and instead
requires actual minimum decoder geometry. Existing timing/policy stays unchanged.

## Hardware revalidation

One bounded read-only `devicectl list devices` joined0 during implementation.
`physical-paired-current-mtc1mc54/devices-correlation-readiness-20260926.json`
reports both phone00008140-001474110C13001C and Watch00008310-0000B2CE3E08A01E
paired but disconnected, with DDI services unavailable. This is stronger current
connection evidence than the earlier generic unlock/preparation message. No
capture/rebuild/repeated device-info timeout was started. Existing readiness
question remains pending; phone automation approval persists.

## Correlation verification and commit

The source slice is committed as `026189c` after independent specification and
quality approvals. Both reviewers matched the same 17 source/test blobs to
manifest SHA-256 `ca0844c98554165c6ad5d8772430897a5722b96fa649c6163175bfd4b335eb99`.
Root independently verified all 78 manifest entries, source Git blobs, command
exit codes, test/build success markers and the diagnostic budget. Evidence:
`artifacts/qa/pipeline-geometry-correlation-validation/root-verification.json`.

Final checks: protocol 9, control plane 609, worker 475 distinct tests (474 in the
default run plus its explicitly enabled recording test), Swift Core 503 and
276 affected app tests. Node typechecks/builds, Debug UI build-for-testing and
Release device build passed. Pressure diagnostics measured 4053 bytes; the
conservative phase union measured 4056/4096 bytes, with 2734 protected bytes.
Production driver, ladder, thresholds and timing were unchanged. Failed red tests,
fixture-policy experiment and initial TypeScript optional-property build failure
remain in the manifest; their corrected final runs are separately identified.

No jobs remained at commit. The actual 720p integration is now delegated as the
next cohesive source slice. Root owns its documentation and subsequent live run.
Fresh local preflight: Docker has no running containers, LAN is 192.168.1.130,
installed iOS/watchOS 26.2 runtimes remain available, and disk has 222 GiB free.

## Ordinary720 run preparation

Recomputed the prepared 600-second source SHA-256 and confirmed the original
qualification hash: `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.
The preserved qualification contains 18,000 consecutive source frames, 48 kHz
audio, and source origin 123.25 seconds; no new media generation was needed.

Prepared `artifacts/qa/map-ordinary-720-recovery-media-20260926.mjs` as a separate
root-owned offline helper. It retains the existing actual-frame/audio mapping,
requires the explicit v2/recovery720 contract and ten ordered selected phases,
and requires successful native, transport and geometry replay before mapping.
`node --check` passes. Actual data execution remains pending the reviewed source
slice and native run; syntax validation does not qualify its result. The old
six-window helper remains unchanged.

The paired offline replay helper is
`artifacts/qa/replay-ordinary-720-recovery-20260926.mjs`. It reads the unique accepted
broadcast-start command outcome from the closed lab SQLite database to determine
expected game/generation, instead of assuming generation one or inferring it from
worker geometry. It hashes raw input files, preserves separate native/transport/
geometry outcomes, and does not claim recorded-media qualification. Syntax check
passes; an independent read-only helper review is pending. No native capture has
started for the new lane.

## Offline helper review findings and corrections

Independent read-only helper review found possible false passes from replacing the
native attachment after replay, mixing stale decoded artifacts, and accepting
infinite FPS from equal output timestamps. A follow-up found that consistently
hashed media from another run still needed explicit run/lab ownership binding.
All are corrected in the new720 helpers; historical helpers/results are untouched.

`verify-ordinary-720-media-20260926.py` now wraps the existing full decode and audio/
overlay checks in fresh directories. It hashes input media and producing code
before and after, captures command exits and hashes all produced files. The mapper
requires that manifest, verifies the replayed attachment hash, current run/result
and lab/setup hashes, unique output paths with realpath containment, the accepted
broadcast-start recording ID, finite strictly increasing timestamps and finite
FPS. No quality thresholds were relaxed.

Synthetic guard tests pass10 cases under
`artifacts/qa/mapper-720-guard-fixtures-yedz3rfp/guard-results.json`, including a
consistently hashed cross-run media substitution. The prior9-case fixture set is
preserved. These are helper guard tests only; no new native/media qualification is
claimed. Final helper re-review is pending.

Final helper re-review approved all four files; root matched the reviewed hashes
and ten guard results. Evidence: `artifacts/qa/ordinary-720-helper-review.json`.
Actual run/media qualification remains pending.

## Ordinary720 source review

Initial freeze covers13 source/test files. Root independently checked59 manifest
entries, all13 Git blobs, and actual app/build logs.310 affected app tests pass,
including35 real owned publisher cases. The128-case host run plus the89-case final
evidence subset contains130 distinct passing test names (two new rejection cases).
Debug UI and Release device builds pass. Final diagnostic trial/phase union is
4093/4096 bytes, pressure4072, protected-only3110; no driver compaction change.

Formal spec review found a closed-contract receipt continuity gap: internally valid
next receipt PTS/native timestamps could precede the previous transition, and a
changed fallback generation could seed recovered climbs. The implementer is adding
exact cross-transition lower bounds and unchanged generation, with mutation tests.
Fallback may retain unsampled intermediate transitions, so do not require a direct
encoder link when its revision skips transitions. Quality review has not started;
source is not committed and no new720 capture is running. Keep original failed
review evidence and the first frozen manifest.

The completed spec review added two checker corrections: inspect constrained
observations through restoration, including observations after the selected minimum;
and when a native exclusive anchor precedes a run's known first PTS, require that
known boundary to be the first included PTS. This does not reconstruct unknown
interior timestamps. These corrections and targeted negative fixtures are in the
same checker-only revision; unchanged app/build suites need no repeat.

The corrected freeze passes specification re-review. Root verified75 manifest
entries and13 current source blobs. Final checker suite98 passes, with139 distinct
host test names across the relevant runs; unchanged310 app tests and Debug UI/
Release builds remain valid. Original first-freeze files are retained with
`.before-receipt-review` suffixes. Manifest SHA-256:
`29cdd25af4b56409b477d1c5937e77271a35f017a7a0c3875e327ebecc776add`.
Root evidence: `ordinary-720-integration-validation/root-verification.json`.
Quality review is now running read-only; no source/build/capture jobs are active.

## Ordinary720 source committed

Both independent reviews approved the same final13 blobs. Root rechecked hashes
before committing `8495c79` (production720 ladder, ACK-bound native receipts,
explicit ordinary recovery720 lane, native/geometry qualification and tests).
All implementation jobs are joined. Actual recovery and media qualification are
still pending; root is starting the authorized owned-simulator run next.

Actual run started: `ordinary-native-TJzyrf` / `device-lab-XyI9PU`, runtime HEAD
`1941623`, source `8495c79`, owned iPhone14 simulator
`067FE046-09C5-48F6-967E-4312B0E73E3B`. Root exec session97301 owns the runner.
Its Debug build passed and ordinary workflow launched with the verified600-second
fixture hash. Source/build/media work is frozen until capture and lab shutdown
join. No adaptive or media outcome is claimed while the run is active.

## Actual720 workflow and first independent replay

Runner97301 joined exit0: workflow passed, cleanupFailures empty, worker exited0
without force, mock recorder finished. Native actual export spans173 saved segments;
25 XCTest attachments were exported. Recovery attachment is
`9800FC5D-A6FC-4D1B-B98F-C3C9E2A4D554.json` in the run's attachments directory.

Independent replay passes native, actual750kbps transport and geometry. Four climbs
are revisions1/2/5/6; final fallback is revision4. Proxy decoded geometry contains
six runs240/360/720/240/360/720 totaling9942frames. All ten accepted windows contain
150 frames within their expected contiguous geometry run.20474 token operations
prove the actual finite upload constraint. No exhaustive fallback transition chain
is inferred from sampled native observations.

Root offline wrapper session89823 is now running complete decode/audio/overlay
checks. A read-only phase/geometry sanity review runs independently. No capture or
build is active. Media qualification and ten-window mapping remain pending.


## Actual720 media failure and physical readiness

Offline wrapper89823 and separate A/V diagnostic84225 both joined exit1. Native,
actual750kbps transport and geometry checks pass; complete media qualification fails.
Archive10313 sequential IDs0–10312,30freshfps, no audio timestamp gaps. Both live
outputs9942 frames,45 repeated/corrupted/nonconsecutive ID transitions,24 audio
gaps and maximum videoPTS gap2.033s. Worker reports138 decoder errors and51
concealments. All ID breaks occur in output indexes4366–4410, resuming at source
ID4665; all audio gaps occur within146.82–150.37s. This localizes a shared live-path
loss episode but does not alone identify queue expiry or decoder recovery cause.
Archive waveform71 probes and sampled clean glyph checks pass. Separate live A/V
coverage fails at about−1351ms. Keep media-production-manifest.json failed;
no full media mapping/qualification claim. All jobs joined before hardware builds.

User confirmed automation prompt approval and both devices ready. Fresh devicectl
inventory now shows both physical devices available (prior disconnected evidence
is retained). Started bounded current-source phone then Watch builds, session36830,
labels phone/watch-720-paired-ready-20260926, Conley Chaos LLC B222J9J7B8. On success,
physical paired vertical takes priority over further simulator experiments.


Preserved70 failed-media/provenance/diagnostic files in
`ordinary-native-TJzyrf/failed-media-evidence-manifest.json`; original producing
manifest remains unchanged and failed. Read-only source review found223 upstream
queue overflow drops (176508wire bytes), zero injected drops,262116byte queue peak,
and2795ms maximum residence. First overflow occurs162–262ms after cap response.
The ACK witness reports actual120ms publishing-hop SRT delay,238ms RTT and909ms
sender buffer. Native applications take457–465ms;250ms local sampling and one-rung
descent can amplify loss. A274KB/100ms offered burst needs original/retransmit and
encoder-stage attribution before choosing a fix. The active worker read URL has
no explicit latency override; do not attribute the legacy route's1s setting to it.
The strict1500ms capture-to-decoder deadline is separate from these hop settings.
The next diagnostic comparison should isolate publishing-hop recovery delay,
retain strict benchmark results, and judge actual media instead of ACK success.
No production timing, queue bound or qualification threshold changed.

Phone rebuild passed. Watch rebuild timed out connecting (exit70), but subsequent
bounded devicectl details succeeded and now reports connected/developer services.
Started a fresh Watch build only after this state change (session86956). Earlier
inventory's 'available (paired)' label did not itself establish a connected tunnel.


Watch connected build86956 joined exit0. Started current-source physical paired
runner18049, `physical-paired-live-iuYDle` / `device-lab-pcgG8w`. No heavy work
runs concurrently. The Watch must reach its real companion-offer wait before the
phone starts camera capture. No fixture identity or credential is passed to Watch.


At03:44:16 Xcode's preflight explicitly requested Watch unlock; no phone capture
started. Asked user to unlock the Watch itself on wrist. Both builds and developer
connection are now proven; do not confuse device inventory availability with
an unlocked test destination. Compacted NEXT to current evidence/actions and kept
historical commands/results in session logs.


Physical runner18049 joined exit1 after its240s companion readiness gate expired.
Xcode continued waiting for Watch unlock; root sent SIGINT to the verified owned
Node PID50388, which aborted/joined the Watch process and stopped the lab. Result
records joined:true, Watch interrupted, no phone workflow/camera started. Both
builds remain successful. Unlock question is pending; do not rerun unchanged.

Additional historical review found already implemented source-cadence pacing and
native property experiments (September16/17 plans). Low-latency rate-control
creation returned−12908; MaxFrameDelayCount returned−12900 in tested simulators.
The opt-in pacer removed drain batching in its measured run but live media still
failed during a demonstrably over-capacity upward trial. Keep it experimental;
reuse these findings rather than rebuilding diagnostics or assuming a fix.
Rechecked primary Meta COPA, Apple MaxFrameDelayCount and Haivision RTT-multiplier
references; they support separate encoder/queue/recovery budgets, not a universal
production timing number. No source behavior was changed this session continuation.

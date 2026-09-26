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

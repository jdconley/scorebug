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

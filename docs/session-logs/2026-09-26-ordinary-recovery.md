# September 26 — current trial evidence and ordinary recovery integration

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`.
Starting HEAD: `7909cda`. The end-to-end goal remains active.

## Device boundary

The user's automation approval remains valid. A read-only Xcode inspection with
the supported computer-use API again reports that the Mac is locked and automatic
unlock failed. No device preparation retry, installation, capture or automation
prompt was started. The existing Mac-unlock question remains pending; do not ask
for the already-approved phone prompt again.

## Current work

The current-trial implementer is adding pure Core state and bounded DEBUG session
diagnostics. Initial behavioral red is retained; an initial selector executed
zero tests and was corrected, so it is not counted as red evidence. Core's full
502-test suite passes. Final focused checks/builds and independent reviews remain
pending. Source is uncommitted until reviewed.

Read-only integration design is incorporated in
[the implementation plan](../superpowers/plans/2026-09-26-ordinary-recovery-integration.md).
Root corrected an ownership ambiguity: the trial digest includes applied revision
and receipt, so it must change across fallback/recovery and remain stable only
within each probation-to-confirmation transition. Native session attempt identity
must remain unchanged across the complete recovery run.

Two current diagnostic scalars are also needed: native acknowledgment uptime to
reject pre-constraint fallback, and attempt identity to reject restart. Root
requested those from the implementer before final validation. Node phase times
and simulator native uptime have distinct origins and must be joined by request
brackets, not directly compared.

The integration must clear ambient publisher host/port overrides in the scoring
test server. Per-phase media qualification additionally needs existing source
PTS/capture uptime mapping; MP4 duration alone cannot supply it. These requirements
are recorded as open work, not passing evidence.

## Reviewed implementations

Current diagnostics committed `56338ff`. Both independent reviewers approve the
same five blobs. Final502Core and252app tests, DebugUI build-for-testing and Release
arm64 build all pass. Populated diagnostic2703/4096bytes. Root verifies every
manifest source/log hash and test/build success marker; retained results are in
`artifacts/qa/current-trial-diagnostic-validation/root-verification.json`.

Lab/controller committed `1a2e54b` after separate specification and quality
reviews.33focused tests pass, including real loopback HTTP/UDP ordering,
unauthorized/oversize/concurrent rejection, unfinished-request cleanup and an
actual control-plane process confirming ambient publisher overrides are cleared.
An actual lab startup/stop smoke at `artifacts/qa/device-lab-MNMeHf` joins cleanly:
workerexit0, recorderfinished with no sessions, shutdownfailures[]. No capture or
media qualification occurred. Manifest:
`artifacts/qa/ordinary-recovery-control-validation/manifest.json`.

The native recovery lane is now under implementation. Root's independent native
phase checker has15passing synthetic qualification/rejection cases; it remains
uncommitted and awaits interface convergence/review. No live recovery run yet.

## Native lane and independent checker review

Native lane implementation passes16runner tests (including compiled Swift guard
predicates),193app model tests, DebugUI and Release arm64 simulator builds. The
populated diagnostic with scope/source mapping is2976bytes. Specification review
found that archive-continuation/deadline failures still bypassed native export;
the implementer is preserving those failures through export before final review.
No native capture has run in this session yet.

Independent checker specification review identified stale actor observations,
unanchored phase deadlines, host/native elapsed mismatch, intermediate owner
changes, incomplete queue conservation/prefix joins, and future ACK observation.
All are corrected with targeted negative tests;26tests pass, including actual
750kbps UDP denial and ledger replay. Final spec reviewer approves blobs
`016906c740474be8501ee76d9efbb7ad71327ac0` and
`3ba4421dd0299a641ec7736eaf74a8f5a00279a8`; quality review is pending.
These remain independent phase/transport checks, not media qualification.

## Frozen native lane and restored device connection

Native slice committed `a83d18e` after both reviews. Quality review identified a
second deadline issue: real `tap` uses the expired shared deadline. One bounded
90-second terminal budget now begins before either stop tap, preserving the
540-second recording failure. The regression replays actual deadline-sensitive
wait behavior.17runner tests and finalDebugUI build pass;193model tests and
Release arm64 simulator build remain valid for unchanged production files.
Root verifies all5source and12log hashes in the refreshed manifest.

Independent checker committed `266c8a5`:29tests pass. Quality review additionally
required trial identity across intermediate observations and an inactive initial
minimum; final review approves both corrections. It still grants neither media
nor full-system qualification.

Fresh read-only Watch inventory reports paired/booted/developer mode enabled,
`tunnelState=connected`, `ddiServicesAvailable=true`. Results are retained as
`physical-paired-current-mtc1mc54/watch-recovery-session-readiness-20260926*`.
This justified one new signed destination build; that build is currently pending.
Fresh signed phone build passes and a process inventory finds no running Scorebug
process. An in-place phone install is underway. No user recordings are deleted.
Prioritize physical paired testing while the device connection is available;
ordinary recovery simulator test follows. No capture process currently runs.

## Physical paired attempt and first ordinary recovery run

Current Watch signed build succeeds. Direct Watch install fails CoreDevice4000,
"device disconnected immediately after connecting." Root uses Xcode's own
installation/test path with a fresh lab and private xctestruns in
`physical-paired-live-6wsz9p` / `device-lab-ENrHbT`. Watch runner exits70 before a
test, destination busy connecting. Phone capture never starts. All runner/lab
processes join; workerexit0, shutdownfailures[]. No repeat automation approval was
requested, and no camera/media pass is claimed.

First ordinary recovery run is active: `ordinary-native-te5IoU` /
`device-lab-zCd4QF`, runtime`a83d18e`, owned iPhone14 simulator
`B78A789D-5AF6-4D9E-B31D-196A790A3D63`. Source hash matches the verified600second
fixture. Exec session89424 owns the complete runner. The app workflow is launched;
no heavy analysis/build runs concurrently. Actual results remain pending.

## First ordinary recovery result and offline qualification

Runner session89424 joins exit1; native test runs253.283seconds and preserves
“Trial revision changed before confirmation.” through stop/export. Initial240
→360rev1 confirms,750kbps constraint produces240rev2 fallback, restoration
produces360rev3ACK, then240rev4ACK9.001seconds later. All lab processes join,
cleanupFailures[]. Actual native export contains94 hash-verified archive
segments. The owned simulator is cleaned up; failed artifacts are retained.

`independent-recovery-evidence.json` passes actual transport accounting and
27693-operation FIFO/token replay with token denial; native qualifier correctly
rejects the retained workflow failure. This is not full recovery qualification.

Offline decoder session78784 exits0: archive5532consecutive source frames0–5531;
direct/overlay5276identical frames137–5412,30freshfps,zeroaudio timestamp errors
above3ms,119frame archive tail. Waveform/glyph session1095 exits0:39archive and
37probes per live output pass; live glyphs change0–0→1–0 and archive matches
neither score template. Reports are under `native-media-verification/decoded/`
and `av-overlay-verification/`;17checker/report hashes retained in
`offline-verification-manifest.json`. These are whole-run media checks, not
complete per-phase adaptation or hardware qualification.

Read-only diagnostic review confirms an actual acknowledged fallback rather than
a UI timeout. Current mutable events cannot causally link local pressure or
telemetry invalidation to the revision4 acknowledgment. Both successful and
failed trials carry historical renewalRejected/obsolete fields; those do not
uniquely explain the failure. The next slice retains one bounded DEBUG applied
transition cause, without policy changes or additional admission awaits, under
[the diagnostic plan](../superpowers/plans/2026-09-26-applied-transition-diagnostic.md).
Implementer `/root/applied_transition_implementation` owns source/tests; root owns
docs and independent media verification. No unchanged live rerun is justified.

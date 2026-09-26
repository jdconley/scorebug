# Production broadcast timing integration — September26

Start73536ea on codex/local-validation in the authoritative isolated worktree.
Previous goal turn is progress: reviewed/committed upload-budget option, actual
700ms-requested run, clean three-output initial240p media and verified strict
deadline rejection before ramp/cap. All jobs joined before this source slice.
Watch unlock remains pending; no unchanged hardware retry.

## Decision

Use existing broadcast-reliability3000-v1 for the normal app factory, sharing its
3000ms decoder/3500ms capture-evaluation budgets across session, driver and
continuous classifier. This reflects reliability-first broadcast requirements;
it is not an industry-standard number or an inserted delay. Strict1500 remains
available through explicit construction and the existing fixture benchmark.
Report freshness, stall handling, loss/fps checks, transport bounds, candidate and
advice lifetimes are unchanged. The new ordinary diagnostic protects the active
profile and both budget values under its existing4096byte limit.

## Verification

Causal red app run7803 joined65: two tests execute and fail six assertions for
missing timing fields; no unexpected failures. Logs under
`artifacts/qa/production-broadcast-timing-validation`.
Implemented factory choice, bounded diagnostic fields, profile documentation.
Root app test run41827 covers CaptureStreamingModelTests,
PublishingQualityDriverTests and PublishingDeliverySourceWindowTests. Spec review
is read-only and ongoing; no capture active.


All verification jobs joined:199app tests pass (115CaptureStreamingModel,
48DeliverySourceWindow,36Driver),8Core timing boundary tests pass, DebugUI and
Release arm64 device builds pass. Full current diagnostic stress4045bytes and
pressure4091bytes remain under4096. Source/log hashes in verification.json.
No media or recovery pass is inferred; source review is still required before run.


Spec review approved four exact source blobs without blockers; quality review
is now read-only against the same blobs. Retained strict constructor diagnostics
report1500/2000; ordinary constructor reports3000/3500. No runtime threshold or
source edits occurred after the green app/Core/build runs.

Quality review approved the same four frozen blobs. Root verified each source/log
hash; verification.json records both approvals. All pre-run jobs joined.

Committed reviewed source as e147ac4. Full ordinary recovery720 run started:
`ordinary-native-JZQQai`, lab `device-lab-vVhC6B`, runner66725, sourcee147ac4,
requested700ms. User reports phone/Watch automation prompt approved and both
ready. Finish active capture before rebuilding current source for paired hardware.

Ordinary run joined with workflowPassed:true and no cleanup failures. Actual native
archive export157segments collected. Independent native,750kbps transport and
pre-scale geometry replay all pass. All129sample diagnostics report broadcast
profile3000/3500; negotiated transport readback still to extract. Full media
verification deferred while user-ready physical devices take priority.

Fresh e147ac4 phone and Watch builds pass (labels phone-broadcast-ready and
watch-broadcast-build-20260926 in physical-paired-current-mtc1mc54). Watch readiness
read joins0, paired/connected, developer mode/DDI enabled. Started physical paired
runner80113, artifact `physical-paired-live-BIKKzC`; no heavy parallel work.

Native timing readback confirmed: all129samples carry3000/3500 and both
pressure-bound applied receipts (revisions3/4) carry actual700ms sender delay.
Six distinct applied receipts include both720→360 and360→240 steps. Retained
`timing-readback-verification.json` binds the source attachment hash.

Physical run BIKKzC again reaches Xcode preflight but reports Watch locked at
04:16:57. A new async question requests unlocking the Watch itself and leaving it
on wrist; phone capture has not started. Wait only within the bounded readiness
window, then join before offline media analysis. Automation permission is not
being requested again.

BIKKzC Watch never reached the companion-offer wait within240s. No phone workflow
started. Root verified runner77189 identity, interrupted it after the gate, and
joined80113 exit1. Both signed builds remain successful; physical paired acceptance
is still open. Offline full JZQQai media verification now runs after all capture
and lab owners joined. Preserve315upstream overflow drops as transport evidence;
no inference yet whether recovery concealed or repaired the media.

## Completed result and next work

All jobs joined. Media wrapper98987 exits1, preserving its failed manifest.
Archive9328frames IDs0–9327,30freshfps, no video/audio discontinuities. Both live
outputs8995frames with identical ID arrays, first147/last9216,28barcode breaks,
26audio timestamp gaps and a minimum1fresh frame in a complete second. Maximum
video gap is about0.933s. Both damaged intervals span decoded indexes3509–3536;
valid source resumes3758. Audio gaps occur around118.72–121.50s. Archive has111
frames after live ends, satisfying independent continuation.

Separate AV diagnostic54546 exits1: archive64waveform probes and clean glyph
samples pass; both live coverage checks fail by about1234.7ms. This sums audio
samples and is a content/coverage failure, not proof of permanent presentation
sync offset. Live waveform/glyph checks are not reached after coverage failure.
Do not map accepted windows or mark media qualified.49files are hashed in
`failed-media-evidence-manifest.json`, with original failed producing manifest
unchanged.315upstream overflow drops/297900wire bytes remain, peak256packets and
262112bytes. The wider timing contract permits complete policy recovery but does
not repair constrained-transition loss.

Physical lab `device-lab-MObUL1` cleanup confirms worker0/notforced, receiver
finished with no sessions and failures:[]. Watch unlock remains pending after
fresh successful signed builds. No active capture/build/media processes remain.
Next prioritize paired hardware if unlocked; otherwise diagnose the original vs
retransmitted packet burst at collapse using existing bounded SRT packet diagnostics.
Inspect existing source-cadence pacing experiment before changes; it already removed
drain bursts in an earlier experiment but did not qualify media. Do not repeat
unchanged buffer/deadline tuning, raise queue bounds, or relabel either failed720run.

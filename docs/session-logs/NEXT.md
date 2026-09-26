# Next session handoff

## Objective and workspace

Complete native phone recording/scoring and paired Watch scoring, progressive
SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlay MP4.
The goal remains active. Use `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`; never edit the original checkout.
HEADaedd639; reviewed app source8495c79. No PR requested.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns goals/status/todos. [Current session](2026-09-26-ordinary-transport-budget.md)
owns chronology and artifacts. Preserve Downloads originals, user recordings and
failed evidence. No runtime downloads, unrelated simulator deletion, or heavy
build/media jobs during capture. Sign Conley Chaos LLC B222J9J7B8.

## Physical readiness

All capture/build/media jobs joined. New explicit lab upload-budget option passes25
focused tests and spec review; quality review pending. Commit source before the
700ms comparison. App policy/queues/decoder deadline unchanged.
Physical paired attempt `physical-paired-live-iuYDle` / `device-lab-pcgG8w`,
source1941623, stopped before camera capture: Xcode waited for Watch unlock and
never reached the companion-offer wait within240s. Root interrupted only its owned
runner after that gate expired; resultjoined:true, Watch interrupted, no phone
workflow started. Async unlock question remains pending. Preserve this failure.

Both current phone and Watch builds PASS. Watch developer tunnel connected, but
an unlocked destination remains necessary. Recheck readiness before another
attempt; do not repeat unchanged or ask again for already approved phone automation.
Helper: `artifacts/qa/run-physical-paired-instrumented-20260926.mjs`.
Build/readiness evidence: `physical-paired-current-mtc1mc54`, labels
`phone-720-paired-ready-20260926`, `watch-720-connected-20260926`,
`watch-user-ready-details-20260926`. Sign Conley Chaos LLC.

## Current720 finding and next streaming work

`ordinary-native-TJzyrf` / `device-lab-XyI9PU` has joined completely.
Native workflow, actual750kbps transport replay and ten accepted pre-scale
geometry windows PASS. Four climbs revisions1,2,5,6; minimum fallback revision4.
Actual native export173segments. Production ladder240/360/720.

Full live MEDIA FAILS: clean archive10313 sequential frames at30fps, no audio gaps;
both live outputs9942frames,45 barcode discontinuities,24 audio gaps and2.033s
maximum videoPTS gap. All damage localizes to one constrained-transition episode.
Archive71 waveform probes and clean glyph samples pass; live A/V coverage fails
by about1.35s. Keep producing manifest failed.70-file preservation manifest:
`ordinary-native-TJzyrf/failed-media-evidence-manifest.json`.

Read-only diagnosis:223 upstream queue overflow drops,262116byte peak,2795ms max
residence, first overflow162–262ms after cap. Actual publishing-hop SRT delay120ms;
ACK witness RTT238ms/buffer909ms. Sampling250ms; encoder applications457–465ms;
confirmed pressure descends one rung. A274KB/100ms burst needs attribution to
original/retransmitted data and encoder drain. Worker read URL has no explicit
latency override; legacy1s route is unrelated. Strict1500ms decoder deadline is
separate from SRT recovery. Do not change bounds or relabel failed evidence.

Before new encoder experiments, read existing September16 low-latency and
source-cadence pacing plans plus September17 candidate-frame-delay results.
Low-latency creation and MaxFrameDelayCount were unsupported on the tested simulator.
An existing opt-in cadence pacer removed drain batches but did not qualify live
media under an over-capacity trial. Do not reinvent it or claim it solves this run.

After hardware priority, isolate publishing-hop recovery time in a short matched
120/700ms diagnostic with identical source/cap/queues. Measure actual media,
reaction and packet bursts. Existing2000/3000ms timing profiles are explicit
experiments, not accepted production defaults. Use the published platform research
and actual stage budgets; a longer decoder deadline alone cannot restore loss.

## Verified baseline and open limits

Two complete ordinary360recovery passes: `ordinary-native-93koj3` and
`ordinary-native-rpRZ6E`;30freshfps, audio/score/clean archive and six mappings.
Earlier `ordinary-native-te5IoU` rollback remains unexplained; preserve it.
Older `native-app-9IVqF0` audio gap/evidence exhaustion remains failed.
Phone camera baseline and separate physical Watch scoring passed previously;
combined acceptance still open. Paired simulator WC7018/companion-not-installed
is unresolved; do not inject identity/setup or infer physical behavior from it.
Sustained hardware, higher profiles, outages/routes, other scorers, remote hosts
and YouTube acceptance remain in the delivery plan.

Reviewed source evidence: `pipeline-geometry-correlation-validation/root-verification.json`
and `ordinary-720-integration-validation/root-verification.json`.
Offline720 helper hashes/review: `artifacts/qa/ordinary-720-helper-review.json`.
Ten-window mapper requires a successful producing manifest and must not qualify
this failed run. Old six-window helper is unchanged.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; use installed runtimes.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130.
Phone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2
`00008310-0000B2CE3E08A01E`, watchOS26.6.
Verified600s fixture `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`:
18000consecutive IDs,1080p30/48kPCM, sourcePTS123.25,
SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.
Full historical commands/counts are in session logs, not this handoff.

# Next session handoff

## Active objective and workspace

Active unbounded goal: complete the native recording/scoring/Watch/progressive-streaming vertical through a portable overlay proxy to mock RTMP MP4 and optional overlay MP4. Do not mark complete from component tests. Use `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`; never edit original `/Users/jd/src/scorebug`.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos. [Current session](2026-09-26-recovery-repeatability.md) owns commands, review history and artifacts. No PR requested/created. Keep source reviews before commits, preserve failed artifacts/Downloads originals/user recordings, and do not download runtimes or delete unrelated simulators. No heavy builds/media analysis during live capture.

## Current execution — recovery repeatability

No active capture/media jobs remain. Repeat `ordinary-native-rpRZ6E` /
`device-lab-bZHKqz`, source1254e2d, passes native/transport/three-output media and
six accepted phase-window mappings; this is the second consecutive complete local
recovery pass. Prior unexplained failure remains preserved. Archive5541frames,
bothlive5282,30fps,zeroaudioPTSgaps,120framearchive tail;39/37/37waveformprobes.
See run's `offline-verification-manifest.json`.

Native720 recipe dependency is reviewed and committed as `43f2229`; root verified
18 manifest hashes and five reviewed blobs.84Streaming,206+66Media,3app tests,
DebugUI/Release pass. Automatic ladder remains240/360. See
`native-720-profile-validation/root-verification.json`.

Physical retry at43f2229: phone signed build passed; Watch build exited70 at
destination preparation with “may need to be unlocked to recover from previously
reported preparation errors.” Fresh devicectl info timed out30seconds. Both owned
commands joined; no lab/camera started. Evidence labels `phone-720-build-20260926`,
`watch-720-build-20260926`, `watch-720-readiness-20260926` under
`physical-paired-current-mtc1mc54`. A new async question asks the user to wake/unlock
the Watch itself on their wrist near the Mac. Phone automation approval persists.
Do not repeat unchanged while waiting. Use retained paired helper after readiness.

**ACTIVE implementation:** `/root/applied_transition_implementation` owns the
[decoded geometry diagnostic](../superpowers/plans/2026-09-26-decoded-geometry-evidence.md),
worker-only opt-in bounded pre-scale evidence. No native/ladder/lab changes in this
slice. Root owns documentation, independent checks, reviews and commits. The next
[correlation dependency](../superpowers/plans/2026-09-26-pipeline-geometry-correlation.md)
has read-only design approval; raw private read IDs remain private. Pause
builds/media analysis/source edits before any live hardware capture.

After hardware acceptance, implement ordinary three-rung integration and real
media qualification. Native720 is3Mbps;1080native6Mbps fits current cap,
4K24Mbps/camera capture remains separate work. Do not substitute the final1080
canvas for proof of actual720 input. Retain causal diagnostics for rollback.

## Ordinary recovery result

Instrumented `ordinary-native-93koj3` / `device-lab-ezsyqi`, runtime1254e2d, joins
exit0; native304.462seconds, cleanupFailures[]. Independent native replay and
actual750kbps transport replay pass:240→confirmed360→240fallback→confirmed360.
Archive7009consecutive IDs0–7008; both live6763identical137–6899,30freshfps,
noaudioPTSgaps>3ms,109frame archive tail. Waveform/glyph checks pass49archive and
47perlive probes, live0–0→1–0, clean archive. Six accepted native source windows
map to actual decoded IDs/waveform anchors in every output. Exact network-boundary
interpolation, whole-phase latency and repeatability are not inferred.
Provenance: `ordinary-native-93koj3/offline-verification-manifest.json`.

Prior `ordinary-native-te5IoU` / `device-lab-zCd4QF` remains failed: second360
trial rolls back9.001seconds afterACK. Its transport and allthree media outputs
pass, but no original causal witness exists. The new run did not reproduce it;
do not claim a behavioral fix. The diagnostic now makes another observed failure
actionable. Preserve prior evidence and750kbps/policy/gate settings.

Diagnostic source `1254e2d` is committed after both reviews;259app+502Core tests,
DebugUI and Release device builds pass. Final30hash root verification:
`applied-transition-diagnostic-validation/root-review-verification.json`.
The earlier physical attempt `physical-paired-live-6wsz9p` was connection-blocked
before capture. No user recordings or unrelated simulators have been deleted.

## Ready ordinary recovery lane

Committed and reviewed components:
- `488c50b`: separate publisher endpoint,599control-plane tests.
- `09cef26`: bounded manual UDP phases,392regression tests.
- `56338ff`: truthful computed current native trial/owner diagnostics,502Core+252app tests, DebugUI/Release builds.
- `1a2e54b`: lab-owned750kbps forward cap and authenticated loopback XCTest control,33tests plus actual clean no-capture lab startup/shutdown.
- `266c8a5`: independent native phase/transport checkers,29tests, both reviews. Leaves explicitly do not qualify media/full recovery.
- `a83d18e`: explicit ordinary recovery runner/native UI lane, current source PTS-to-uptime mapping, stable source-scope digest;17runner+193app tests, DebugUI and Release arm64 simulator builds, both reviews.2976/4096byte populated diagnostic. Failed timing checks retain failure through a separate90second stop/export budget; recording limit remains540seconds.

See [integration plan](../superpowers/plans/2026-09-26-ordinary-recovery-integration.md). One instrumented ordinary recovery run passes; the earlier run failed (above). The invocation is:

```sh
node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane recovery
```

Input:600seconds,18000consecutive frames0–17999,1080p30 H264+48kmonoPCM, sourcePTSorigin123.25, SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`. Fully decoded/verified source, no looping. Preserve original390second input.

Recovery sequence: initial240→150second360ACK→30second actual probation/confirmation→750kbps cap→60second minimumACK strictly after constrain response→restore→150second fresh360ACK→30secondconfirmation. Same attempt and source scope; owner digest changes per revision, stable within each trial. XCTest systemUptime seconds and Nodeperformance milliseconds have different origins; join via retained request brackets. Independent functions in `scripts/ordinary-recovery-evidence.mjs` replay phase/transport evidence. Raw attachment `OrdinaryRecoveryStreaming-recovery-phases`, controller audit and closed UDP ledger remain required. Check all three media outputs separately after all capture processes join.

## Existing successes and preserved limits

Ordinary run14 `ordinary-native-owpmLF` / `device-lab-KCyGMI`, production runtime3926e83, passes native source-only240→360ACK/scoring/stop/export. Native archive2372frames0–2371 and both live2109identical153–2261,30freshfps, no audioPTS errors>3ms,110frame archive tail; waveform/glyph/cleanarchive checks pass. This was ACK only, not confirmed-trial or recovery qualification. Reports under its `native-media-verification/` and `av-overlay-513tap/`.

Paired simulator `ordinary-native-LhOSEV` / `device-lab-kv7aZq` passes phone adaptation/export but Watch companion registration fails: activated/reachabletrue yet installedfalse, WC7018. Zero Watch commands. Do not rerun unchanged; [Apple guidance](../research/2026-09-25-watch-companion-registration.md) favors physical devices but does not prove all simulator APIs unsupported. Archive6762/live6481consecutiveframes pass basic decode; no Watch-glyph qualification.

Older experimental `native-app-9IVqF0` still fails21ms liveaudio continuity and32MiB evidence exhaustion (20.4seconds uncovered). Offline513tap audio checker correction does not fix that real gap. Do not raise caps, relax thresholds or repeat unchanged failures. Wider ladder, sustained/full-match operation, outages, route changes, other native scorers and remote hosts remain open.

## Environment and analysis helpers

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installediOS26.2/watchOS26.2. FFmpeg/ffprobe `/opt/homebrew/opt/ffmpeg-full/bin/`. LAN192.168.1.130. Docker maintained `scorebug/ingest:campaign-probe-v3`, normal worker100ms reports. Disk last230GiB free.

Phone16Pro `00008140-001474110C13001C` iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E` watchOS26.6. Physical xctestruns: exact phone `Scorebug_iphoneos26.2-arm64.xctestrun`; fresh Watch `ScorebugWatch_watchos26.2-arm64.xctestrun` (do not select older arm64-arm64_32 sibling).

For file-source runs after shutdown: `artifacts/qa/collect-ordinary-export-20260925.py RUN_ROOT`, `analyze-ordinary-recordings-20260925.py INPUTS NEW_OUTDIR`, `verify-ordinary-av-overlay-20260925.mjs INPUTS DECODED NEW_OUTDIR`. Collect actual native exports, never concatenate segments as a substitute. New analysis directories retain provenance. Physical camera helper `verify-physical-three-output.py` needs inspection before reuse; synthetic barcode checks do not apply to camera footage.

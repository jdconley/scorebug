# Next session handoff

## Direction and checkout

Simulator-first. Batch related changes, run focused checks, reuse saved passing
acceptance and incremental builds. Hardware/external hosts are deferred. No agents,
pushes, real broadcasts or purchases. Preserve originals and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; the [acceptance matrix](../simulator-acceptance.md) owns retained evidence.
[Faster iteration](2026-09-28-faster-media-iteration.md) documents the diagnostic harness.

## Active checkpoint

Production remains4c43b7a: bounded UHD sender pacing, unchanged encoder and queue
limits, broadcast-reliability3000-v3 timing. The latest session adds faster SDK
simulator diagnosis and `--timing-audit off` for long native diagnostics, preserving
all production checks and the2048-row audit cap. See
[session evidence](2026-09-28-simulator-candidate-limit.md).

Direct iOS26.2 SDK test reproduces4K unresolvedInputLimit in2.697seconds with real
footage:27accepted/26output,473ms initial/919ms max completion. Low-latency mode
cannot create an encoder (-12908). EncoderID anon-1; hardware and max-delay readbacks
are unsupported, not proof of software. Earlier Mac normal mode90/90frames succeeds.
Do not enlarge queues or switch modes. Owned simulator cleanup[0,0].

`headless-native-ZiHDud`180s: archive/publish survive,360/720 confirm, valid closed
1803-row audit, cleanup[]. `headless-native-3aD0U5`360s: archive/publish survive,
360/720 confirm,1080 trial225s then minimum reset239s. Reset is sourceScopeChanged /
telemetryInvalidated, not observed media loss. Sample478 contains the witness;
469–477 contain prior scope digest/sequence46.30on-time frames/no loss at reset,
134ms report age. Actual receiver geometry has uninterrupted30fps through1080.
Exact changed scope field is not captured.4K is not attempted; no media acceptance.
LabUV6LXk; exec76004 joined0/cleanup[]. All jobs joined.

Earlier full simulator ordinary-native-aK6INv confirms1080 and completes native4K
export (166segment hashes), then reports4K candidate pending-input failure. Reuse
that evidence; don't confuse it with the distinct Mac telemetry-identity reset.

## Reuse, don't repeat

- Native two-phone create/join/scoring, Watch B41mm takeover/relaunch/end, uncertain
  command recovery and archive fault recovery pass. Watch setup fixture/directHTTP
  does not qualify WatchConnectivity.
-1080 ladder/real receiver geometry/archive/live A/V/overlay: `ordinary-native-PpPozK`.
- Short native4K record/export/playback/relaunch: `recording-quality-20260928-media`.
- Relay generations/stale credentials/late reader, API/worker crash and Mac service
  outputs have retained passing checks. Severe congestion loses media; larger peer
  buffering worsened it. Keep broadcast3000/default SRT policy and avoid parameter-only reruns.

## Next work

1. Diagnose native sourceScopeChanged reset using saved3aD0U5 samples. Inspect
   PublishingQualitySession.SourceScope and its construction. It compares capture,
   native clock, worker identity/epoch/attempt, publication and optional processing
   scope. Which field changed is unknown. Add compact changed-field evidence if
   required, then targeted model checks; do not remove identity/ownership checks.
2. Keep simulator4K encoding limit explicit. Use real native Mac pipeline to diagnose
   full4K admission without UI/export overhead. Runner accepts --timing-audit off
   for longer diagnostic runs; this omits optional audit only and is not media
   acceptance. No blanket rerun until a causal fix. SDK simulator test selector
   must include uhdNativeLatencyDiagnostic(lowLatency:); base selector runs zero tests.
   After full climb, qualify saved media using retained verify-2160-climb,
   verify-uhd-media and native-export collection helpers, matching their scopes.
3. Audit remaining delivery/pressure TODOs against existing coverage, then sustained
   profiles, physical companion/radio and external hosts. Hosted CI remains unverified
   until a push is authorized. Do not retest established two-phone/Watch features.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; scope DEVELOPER_DIR.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`. Installed26.2 runtimes; generic simulator
builds require `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`. Last LAN192.168.1.130.

4K600s source: `artifacts/qa/uhd-app-20260928/input.mov`, SHA256
`be959258221b1427697d911daae4e54f99721fa69a82ae0c66f7b39922970d1a`.
1080 source: `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`.
Run: `node scripts/test-ordinary-native-app.mjs --host <LAN> --source <absolute.mov> --lane quality2160`.
Default relay remains `scorebug/ingest:drain-v1`; UHD lane explicitly usesv4.

Never print generated ordinary-environment.json; it contains test credentials.
Do not clear physical Watch Keychain or reconcile pending pairing blindly.

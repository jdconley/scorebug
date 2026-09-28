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

Production now selects `broadcast-reliability3000-v3`:3s media deadline,1s control
report age,4.25s capture evaluation allowance. Old profiles unchanged. Core, native
cadence/delivery/scheduler, diagnostics and host validators share the profile.
Focused delayed HTTP/expiry/ownership and actual-scheduler checks pass; full sim
build passes. Failed preliminary v2 used an incompatible3.5s evaluation allowance;
its stopped run `ordinary-native-ClWHlf` is retained, cleanup[].

Final `ordinary-native-z1va0e`, labvgxwUF, exec55738 joined1/cleanup[].360 and720
probation pass.1080applies just after its150s gate; UHD still unqualified. Padding
headroom is the next blocker: candidate7.185Mbps/padding7.698Mbps, retry7.153/8.841;
later6.977/9.171qualifies. No timing rollback reproduced. One intervening candidate
fails at candidateJoined. Use saved attachments; do not blindly extend gates.

UHD export failed because the test's90s terminal allowance clipped its180s export
wait. Harness now grants240s terminal for UHD only; this small change awaits runtime
verification. Raw archive/prepared MP4s retained; no successful native export claim.
No full offline media analysis on this failed checkpoint. All jobs joined.

[Current session](2026-09-28-production-report-timing.md) contains exact evidence.

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

1. Isolate native UHD probe pacing/headroom throughput with a short SDK/headless
   check before another full simulator run. Sender requests more padding than the
   receiver gets; actual cause is not yet proven. Preserve25% measured admission,
   ownership, bounded queues and old protocol contracts. Review
   `NativeCandidateAttempt.swift`, SDK `SRTBandwidthProbe.swift` (one-message token
   cap), `SRTProbeWakeSchedule.swift` and actual sender pump before proposing changes.
   `scripts/test-headless-streaming.mjs` avoids UI/export overhead; test clips bounded
   to under~200s keep its2048-row timing audit intact. Saved120/180s harness evidence
   in `headless-native-hmNggn`/`headless-native-qfiBCM` remains diagnostic only.
2. After focused throughput fix, qualify full4K climb and saved media with retained
   `verify-2160-climb-20260928.py`, `verify-uhd-media-20260928.py` and
   `collect-ordinary-export-20260925.py`. Native frame/media thresholds unchanged.
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

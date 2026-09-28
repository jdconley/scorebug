# Next session handoff

## Direction and checkout

Simulator-first. Batch related changes, run focused checks, reuse saved passing
acceptance and incremental builds. Hardware/external hosts are deferred. No agents,
pushes, real broadcasts or purchases. Preserve originals and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; the [acceptance matrix](../simulator-acceptance.md) owns retained evidence.
[Current session](2026-09-28-faster-media-iteration.md) records the faster diagnostic path.

## Active checkpoint

UHD app integration carries v4 budgets through publisher/request/readback, selects
2160 only for4K source + fresh2160 output capability, and scales raw queues.
Fixed a lost budget at the lower owned-operation handoff and a candidate64MiB raw
limit that only held five4K frames. UHD candidate source now gets192MiB; ordinary
64MiB,4queued/16unresolved frames,16MiB/input and deadlines remain unchanged.

Focused model13/owned8/runner30, native4K→360encoder1, SDK3tests/six cases pass.
Full simulator builds and maintained SDK original-hash/patch round trip pass.
quality2160 defaults to VideoToolbox; explicit software and other lanes unchanged.

Latest `ordinary-native-Xg2t0t`, labBOKJBq, exec92183 joined1/cleanup[]. Native4K
archive/export and240→360 measured increase/probation pass.720increase times out:
measuredcost3718715bps, repeated source-wait/cancellation,40s recovery backoff.
No4K upload/media pass. All jobs joined; no active owned simulators/labs. Hardware
untouched. Log: `artifacts/qa/uhd-app-20260928/native-gpu-run.log`; exported xcresult
attachments retained. Session log records earlier failures and their fixes.

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

1. Use `scripts/test-headless-streaming.mjs` for focused real-native media diagnosis
   before another full simulator/UI/export run. It uses the real archive, production
   quality models, local proxy and mock recorder, retaining raw segments and timing
   audit. First120s run `headless-native-hmNggn` passes joined lifecycle, reaches360;
   acquisition cadence age stays below115ms, so simulator freshness is not reproduced.
   Extended180s `headless-native-qfiBCM` reaches720 then resets240 on cadence freshness:
   HTTP168ms + server119ms + residence2.6ms =289.7ms; native probe only0.034ms.
   Second delayed response457.6ms.1798audit rows/two over250ms. Both native paths
   remain active; exit0/cleanup[]. All jobs joined. This is not UI/media acceptance.
   Current diagnostics now separate cumulative recovery coverage from latest-window
   duration and preserve the exact rejected cadence's age breakdown outside trials.
   Next fix the production report timing using this exact HTTP-delay regression.
   Preserve strict250ms benchmark and immutable historical contracts; any production
   age-budget change needs coherent versioning across Core/telemetry/delivery.
   Do not treat delayed evidence as fresh or weaken ownership/media criteria.
   After a focused fix passes, qualify full4K climb/media using the retained helpers.
2. Audit remaining delivery/pressure TODOs against existing focused coverage.
   Investigate severe-outage losses from saved evidence; no repeated unchanged captures.
3. Sustained profile qualification, then physical companion/radio and external hosts.
   Native hosted CI remains unverified until a push is authorized.

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

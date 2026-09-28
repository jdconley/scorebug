# Next session handoff

## Direction and checkout

**Simulator-first; finish missing features faster.** Hardware is deferred. Batch changes, use focused checks, reuse incremental builds, and run one relevant integration workflow per completed failure mode. Reuse prior recording/Watch/two-phone acceptance rather than rerunning it for every edit. Do not spend another session repeating small congestion tweaks.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Use current Git HEAD. [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/current status/todos; [latest session](2026-09-28-scoring-and-recording-faults.md) owns exact evidence and limits.

## Current checkpoint

- `native-scoring-recovery-Ff9bG1`: pending point → real API takeover/stale rejections → offline native relaunch → original receipt → explicit native takeover → undo/end passes in60.47seconds. Exactly seven intended durable commands, one accepted point. App-data collection, outbox preservation and cleanup pass. Use `test-apple.mjs --pending-takeover --ui-only`; two focused proxy checks pass.
- `recording-faults-20260928-fixed`: one full-app test covers source interruption, low storage and blocked writer, recovery and export. Each output has180consecutive30fps frames/6seconds, no audio gaps,28ms A/V end difference. Segment hashes/metadata pass. Source event at8seconds loses2seconds; do not infer exact last-callback tail for storage/queue. All jobs joined, no live owned simulators. Explicit arm64 incremental build passes; generic x86_64 simulator link is unsupported by the local SRT library.
- Failed fixture attempt `native-scoring-recovery-5cbiS3` and initial recording build failure retained. Original scorer runner callback failure bypassed cleanup; its exact Xcode process was confirmed terminal, app data preserved and owned simulator removed (`scoped-cleanup.json`). Callback failure now enters normal cleanup. Do not rerun successful native checks for this helper change.
- Earlier growing-buffer warning implemented and verified by45native telemetry and19independent replay checks. It requires byte/time growth over250–500ms, stable known sender delay, valid ownership/freshness and a quarter-delay threshold; it only permits decreases.
- `ordinary-native-IZI72F` passes the native720→minimum→720 workflow, replay, geometry, archive/export and cleanup. Minimum-profile acknowledgment improves to856–887ms. Archive11,122consecutive30fps frames. Live output still fails strict media:87missing IDs,5repeat/corrupt observations,16audio gaps,2.4s maximum gap;98.833% of all5s windows≥24freshfps. Keep partial improvement; no blanket congestion pass. All its capture/analysis handles joined.
- `server-crash` passes in `ordinary-native-SvL3gk`: actual API/worker SIGKILL,15-second outages, automatic recovery, archive2,510consecutive frames/43hashed segments, correct final score in both output MP4s, final A/V ends within26ms. Interrupted output tails retain508–548ms extra audio.36launcher checks pass. All capture/verifier handles joined and cleanup passes; **no live jobs**.
- Main plan now credits existing full-app forced-termination/relaunch/export, backend readiness and deployment instructions. Older recording documentation no longer claims Watch/adaptation are merely planned.

## Next work

1. Verify publishing cleanup/restart when capture is interrupted in the real local media workflow. Offline archive fault cases now pass; preserve that distinction. Use existing runners/model coverage and add only missing integration checks.
2. Assemble one consolidated simulator acceptance result from valid existing checkpoints plus those missing cases. Keep severe-collapse/sustained-profile limitations explicit. Production latency remains unqualified; do not weaken existing failed media contracts.
3. Actual local Mac service operation and documentation/CI matrix. External GPU/cloud and physical devices stay deferred until simulator-testable features work together.

## Evidence to reuse

- `native-created-simulators-opRrou`: complete two-phone vertical passes native match creation/discovery/takeover/undo, independent archive/export, changing visible overlay in both MP4 outputs,30fps continuity and audio sync.
- `native-created-simulators-yjIyo3`: separate Watch B takeover/scoring/undo/relaunch/end while phone A records/streams;41mm controls;11durable scoring commands. Setup fixture/direct HTTP is explicitly not WatchConnectivity qualification. Cleanup false alarm was fixed; do not rerun for that fix.
- `ordinary-native-q9n288`: bounded remote match retirement; archive/live A/V ends within40ms.
- `ordinary-native-QOuplL`: API SIGKILL plus graceful worker restart; uninterrupted native archive and automatic output recovery. Interrupted output tails retain about0.5seconds extra audio.
- `backend-capabilities-20260928`: actual software/VideoToolbox initialization, NVENC rejection on Mac, fresh/stale API heartbeat preflight; sustained throughput unqualified.
- `vps-stack-wozlWz`: repaired local container wiring, durable SQLite recreation and authenticated managed relay cleanup. Mac service helper/Linux runbooks exist; actual service/external deployment remains open.
- Full-app offline recording/relaunch/export: [native-film-app](../native-film-app.md), iOS17.5/18.5/26.2 preserved runs. Low-space/source interruption are separate remaining gates.

Do not repeat rejected minimum-GOP, bitrate-first, relative-pacing or source-cadence experiments. Baseline congestion evidence is `ordinary-native-PvbKtK`; rejected one-second GOP is `ordinary-native-rVojgQ`; offline ACK replay is `ack-backlog-20260928`. Both rejected candidate code and tests were restored before the current earlier-warning change. Preserve originals and failures.

## Environment and commands

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed26.2runtimes. FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; relay image `scorebug/ingest:drain-v1`. Last LAN address192.168.1.130; recheck before starting a lab.

Prepared source: `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov` (600s/18000frames); SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.

Set DEVELOPER_DIR and use `node scripts/test-ordinary-native-app.mjs --host <en0> --source <absolute-prepared-input> --lane <implemented-lane>`. Lanes include `server-recovery`, `server-crash`, `recovery720`, `watch-direct`. The720comparison uses explicit `--publish-peer-latency-ms 700`; this is not a production recommendation.

Offline720checkpoint: `python3 artifacts/qa/finish-recovery720-checkpoint-20260927.py <run>`. Existing crash/graceful-recovery media scripts are under `ordinary-native-QOuplL/native-media-verification/`; copy/reuse without altering assertions. Never concatenate separate outage recordings to conceal gaps.

Physical Watch has preserved uncertain pending setup; historical lab identity is not current proof. Do not clear Keychain, reconcile blindly, retry signing or repair pairing now. Preserve Downloads footage, recordings and unrelated simulators.

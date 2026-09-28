# Next session handoff

## Direction and workspace

**Simulator-first; move faster.** The owner explicitly deferred hardware testing until simulator-testable features work together. Batch changes/reviews, run focused tests for changed behavior, and reserve broad checks/media analysis for completed workflows. Do not resume physical Watch connection/pairing recovery or rebuild signed apps for small changes.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Latest implementation is on this branch; use the current Git HEAD. [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns current goals/status/todos; [current session](2026-09-26-simulator-first.md) owns history/evidence.

## Current checkpoint

Latest work: [September28 separate Watch vertical](2026-09-28-separate-watch-vertical.md). `native-created-simulators-yjIyo3` at e3e5269 passes all three native app workflows and11durable scoring commands. Paired-to-B Watch uses fixture setup/direct HTTP; transport itself is not qualified. Archive109segments/export and sampled final1–2 in both live MP4s pass, end alignment<17ms. Original runner false is an already-shutdown cleanup false alarm; independent acceptance proves all data preserved/devices removed. Cleanup correction has a focused regression; do not repeat the native run for it.

Remote Watch end was fixed in [bounded retirement](2026-09-28-bounded-stream-retirement.md) using the maintained `drain-v1` relay and graceful worker withdrawal.

Previous work: [September28 deployment](2026-09-28-portable-deployment.md). `node scripts/test-vps-stack.mjs --image <existing-api-image>` verifies the repaired deployment with a focused owned-container check; CI reuses its built API/relay images.

- `native-created-simulators-opRrou` atf3428a0: **complete vertical passes**, including native creation/discovery/takeover/undo, independent archive/export, both live recordings, full decode/frame continuity/audio sync and visible score sequence. `vertical-acceptance.json` binds evidence.
- `ordinary-native-q9n288`: Watch/phone workflows, restored pairing, scoring/end, native archive/export and cleanup pass. Targeted decoded end coverage passes: archive29.3ms, direct39.5ms, overlay39.8ms. Only tail/cadence checks were repeated, not the entire waveform/score audit. This closes the454ms retirement failure inUFjmr8. Base8c7d1e7 plus changes fingerprinted in `implementation.json`; see session log.
- Direct-to-minimum fallback measured in `ordinary-native-PvbKtK` ateade9ac. Native/transport/geometry pass; one720→240 application, ACK about1.03s. Archive is continuous11290frames. Each live output still has93 missing IDs,11 repeated/corrupted observations,26audio gaps and2.4s maximum video gap. Strict media fails. Do not repeat unchanged or claim fixed.
- Mac service helper and Linux worker deployment runbook are implemented. VPS Compose persistence/native relay repair now passes local container checks (`vps-stack-wozlWz`); persistent Mac service operation and external runtime/TLS/media remain open. No service installed.

Use focused checks, incremental builds and completed-workflow media verification. Current two-phone UI retry fixed only keyboard dismissal. Do not repeat hardware readiness work or broad suites for that change.

## Next priorities

1. Implement/verify native capture across API and worker restart. Inspect current reconnection behavior first; reuse the existing native file source and owned lab. Keep clean recording continuous and return to current score/live output.
2. Add backend capability reporting beyond static encoder selection, distinguishing configured, available and runtime-qualified capabilities.
3. Diagnose remaining congestion from savedPvbKtK evidence before another capture; do not repeat prior failed bitrate-first/relative-pacing/source-cadence experiments.
4. Consolidate existing recording/scoring recovery evidence with only genuinely missing focused checks. Offline/forced-termination UI results already exist in `docs/native-film-app.md`; do not rebuild or rerun everything for small edits. Hardware remains deferred.

## Existing evidence and open limits

- Basic native phone recording/scoring, SRT, overlay and both output MP4s work. Long1080p/4K file replays pass. Two ordinary240→360→minimum→360 simulator recoveries pass their media checks.
-720p direct-minimum comparison now has133overflow packets versus309previously; successful controller transitions do not erase the remaining live-media failure. Use saved packet/transition/decoded evidence before choosing another experiment.
- Physical filming phone plus separate native iPhone14 simulator scoring passes the command/record/stream/export route. The native-created two-phone simulator vertical now passes fully.
- Watch standalone scoring/relaunch is implemented and tested; direct/companion routing has model/protocol coverage. Real companion delivery and radio-route acceptance remain hardware gates.
- Physical Watch has preserved uncertain pending setup. Historical candidate `device-lab-SM9KM1` is not live identity proof. Last guarded inspections never entered test bodies because Xcode lost the destination. All jobs joined; do not clear Keychain or retry this now.

## Useful environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed iOS/watchOS26.2 runtimes. FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; Docker image `scorebug/ingest:drain-v1`. Latest en0 address192.168.1.130; recheck before lab launch.

Prepared finite source: `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov` (600s,18000frames), SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.

Existing launcher: `node scripts/test-ordinary-native-app.mjs --host <current-en0> --source <absolute-prepared-input> --lane <watch-direct|recovery720|...>`. Set DEVELOPER_DIR. Use only lanes actually implemented in current source. The720p comparison previously used `--publish-peer-latency-ms 700`.

Existing post-run helpers: `collect-ordinary-export-20260925.py`, `analyze-ordinary-recordings-20260925.py`, `verify-paired-ordinary-av-overlay-20260925.mjs`, `replay-ordinary-720-recovery-20260926.mjs`, `verify-ordinary-720-media-20260926.py` under `artifacts/qa/`. Inspect their arguments/contracts before use. Preserve failed runs, actual output identities and original footage.

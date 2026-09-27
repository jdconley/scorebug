# Next session handoff

## Direction and workspace

**Simulator-first; move faster.** The owner explicitly deferred hardware testing until simulator-testable features work together. Batch changes/reviews, run focused tests for changed behavior, and reserve broad checks/media analysis for completed workflows. Do not resume physical Watch connection/pairing recovery or rebuild signed apps for small changes.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Implementation checkpointb341b94. [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns current goals/status/todos; [current session](2026-09-26-simulator-first.md) owns history/evidence.

## Current checkpoint

`ordinary-native-UFjmr8`: direct Watch/phone native workflows and frame/audio-timestamp/decode checks pass. Waveform/score-image checks pending. Current next implementation is native-created two-phone simulator integration; focused40checks passed, execution pending. Hardware remains deferred.

## Active batch

1. Progressive transport pressure now requests the minimum directly, preserving thermal-only/legacy behavior and existing guarded application. Core-focused tests pass; no new media result yet.
2. Implement explicit `watch-direct` simulator vertical. Real native phone file capture/publishing/archive, native Watch scoring/relaunch, API, overlay proxy and mock/proxy MP4s. Only server-issued Watch setup transport is fixture-injected. The previous real WatchConnectivity simulator lane fails7018 registration; preserve it as a separate qualification gate rather than repeatedly rerunning it.
3. Add repeatable native Mac worker service tooling/runbook in parallel, without installing/loading a persistent service on this host.
4. Next workflow: native phone B creates/scores, phone A discovers/joins/captures; then native Watch takeover. Follow with worker/source/control-plane restart checks and complete media verification.

Check current git state and agent results before editing; app/simulator capture starts only after relevant source/build work joins. No heavy builds/media analysis during a timed capture.

## Existing evidence and open limits

- Basic native phone recording/scoring, SRT, overlay and both output MP4s work. Long1080p/4K file replays pass. Two ordinary240→360→minimum→360 simulator recoveries pass their media checks.
-720p collapse still loses live A/V while clean archive survives. One measured run first overflows at516ms, first pressure decision542–570ms, first downward ACK1001–1029ms. The direct-minimum change avoids an intermediate replacement but cannot erase initial loss; measure before claiming recovery fixed.
- Physical filming phone plus separate native iPhone14 simulator scoring passes the command/record/stream/export route. Current combined native-created simulator role workflow remains open.
- Watch standalone scoring/relaunch is implemented and tested; direct/companion routing has model/protocol coverage. Real companion delivery and radio-route acceptance remain hardware gates.
- Physical Watch has preserved uncertain pending setup. Historical candidate `device-lab-SM9KM1` is not live identity proof. Last guarded inspections never entered test bodies because Xcode lost the destination. All jobs joined; do not clear Keychain or retry this now.

## Useful environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed iOS/watchOS26.2 runtimes. FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; Docker image `scorebug/ingest:campaign-probe-v3`. Latest en0 address10.0.0.122; recheck before lab launch.

Prepared finite source: `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov` (600s,18000frames), SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.

Existing launcher: `node scripts/test-ordinary-native-app.mjs --host <current-en0> --source <absolute-prepared-input> --lane <watch-direct|recovery720|...>`. Set DEVELOPER_DIR. Use only lanes actually implemented in current source. The720p comparison previously used `--publish-peer-latency-ms 700`.

Existing post-run helpers: `collect-ordinary-export-20260925.py`, `analyze-ordinary-recordings-20260925.py`, `verify-paired-ordinary-av-overlay-20260925.mjs`, `replay-ordinary-720-recovery-20260926.mjs`, `verify-ordinary-720-media-20260926.py` under `artifacts/qa/`. Inspect their arguments/contracts before use. Preserve failed runs, actual output identities and original footage.

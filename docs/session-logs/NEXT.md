# Next session handoff

## Direction and checkout

Objective: complete the planned system quickly, with necessary focused
checks only. Native phone/Watch scoring, independent clean recording, adaptive SRT,
score overlay, mock RTMP MP4 and optional proxy MP4 remain the required scope.

Worktree `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch
`codex/local-validation`. Primary `/Users/jd/src/scorebug` has pre-existing dirty
files; do not overwrite it. No agents, pushes, purchases or external broadcasts.
Preserve originals, recordings and unrelated simulators. The
[plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns TODOs;
[acceptance](../simulator-acceptance.md) owns results. See live job status below.

## Current readiness and next work

**LIVE standby; user explicitly requested pause before capture.** One-hour physical
4K archive/1080p stream/audio setup passes, recording off. See
[hour setup](2026-09-30-hour-stream-setup.md). Backend exec87395 is live in
`device-lab-1wgb5o`; finite two-hour expiry is in
`physical-hour-preparation-20260930/standby.json`. Phone4K selected,166.65GB free.
Prepare59573/build88150 joined0. Wait for positioning confirmation, then check
backend lifetime and execute `physical-hour-preparation-20260930/run-hour.sh`.
Hour hold/export not run; do not mark sustained acceptance. After media collection,
write `stop\n` to87395 and join owned backend. No agents or Watch rerun.


Physical local adaptive upload now reaches real1080p at6Mbps. See
[adaptive phone debugging](2026-09-29-adaptive-phone-debug.md).

Two fixes: fair thermal state is known/non-elevated (matches candidate encoder),
and internal100ms telemetry no longer redraws all SwiftUI tabs. Control/health
cadence and pressure gates are unchanged. Focused checks:45telemetry,38driver,
125capture-model,2transition tests and10runner checks. Matching25s CPU profiles
show main-thread21.95→6.31CPU-seconds; total24.75→11.525.

`physical-recovery-T2Pdtv` passes the consecutive240→360→720→1080 climb, native
phone point, stream stop, independent archive continuation and native export.
`1080-acceptance.json` includes full saved-media decode/encoded continuity: archive7555
frames, both outputs7242frames, A/V ends≤44ms, visible score change. Receiver confirms
1254 actual1920×1080 frames at30fps. Explicit700ms publishing
peer latency; software proxy; screenshot-only XCTest capture. All owned phone/lab
processes joined; cleanupFailures[]. Phone originals retained. No Watch rerun.

Next focused physical work: sustained1080p, then fallback/recovery. An earlier
run `physical-recovery-uusTBV` reduced720→240 on the extra growing-sender-retention
warning (230ms buffer/700ms delay,12.193ms RTT, zero drops/retransmits). It did not
recur in the accepted climb. Thresholds unchanged; bounded last12gauges now persist
in pressure-transition journals to distinguish sustained buildup from bursts.
Do not call full-match stability, radio handoffs or perceptual sync qualified.

Reuse accepted paired physical workflow `physical-paired-live-LlJlWn`: real
phone/Ultra2 companion setup/scoring, clean archive and changing overlaid outputs
with continuous encoded A/V. It used240p upload. Saved setup was reconciled safely;
do not repeat the old recovery actions or delete Keychain/recordings. Reuse simulator
core vertical and native sustained4K results below; no unchanged broad test reruns.

TeamB222J9J7B8 remains authorized. Xcode26.2 and LAN192.168.1.130. Watch automation
works while on-wrist/unlocked; initial phone automation may need manual passcodes.

Broader interrupted-tail timing/load/backends remain unqualified. No speculative
shortest flag or timeout change: single-input proxy comparisons did not reproduce
the bad tail, and the old independent-input shortest test lost audio. Deprecated
muxer shortest was removed from FFmpeg8; see session references.
Simulator UHD/congestion and colocated VideoToolbox/probe limitations remain gated;
failed candidates retain applied settings and recover conservatively.

Use the working hands-on simulator launcher now. One affected check per real fix,
no broad suites or unchanged soaks. No agents, pushes, external broadcasts or
purchases. Preserve original videos and unrelated simulator data.

## Reuse these passes

- Current phone/Watch full vertical after DTS interleaving:
  `native-created-simulators-m1tVpX/vertical-acceptance.json`. All3UI workflows pass;
  archive6495/live6068continuous30fps frames, gap-free audio,9waveform anchors,
  changing phone/Watch scores, ends≤48ms,7.8s archive continuation. Original runner
  reported a Watch shutdown race; current inventory verifies all3owned devices
  absent with data preserved. Runner now rechecks failed cleanup against fresh
  state;6focused checks pass. See [session](2026-09-28-current-simulator-vertical.md).
  This is current simulator functional acceptance, not companion/radio/UHD stress
  qualification. No unchanged full simulator rerun.

- Native phone creation/join/scoring, separate41mm Watch takeover/undo/relaunch/end,
  archive/export, changing overlay and both outputs: acceptance matrix. Watch setup
  fixture does not qualify WatchConnectivity/radios.
- Native Mac/software proxy sustained UHD: `headless-native-yFO9Hu/sustained-acceptance.json`;
  1050s capture,754.5s actual4K, no input/media loss, all saved A/V passes. Do not rerun.
- Latest Linux proxy: `headless-native-wJYttO/linux-integration-acceptance.json`;
  120s real local SRT/RTMP, confirmed240→360, archive3628/live3547consecutive frames,
  gap-free audibleaudio, all3files decode, ends≤26ms. Static overlay/first climb only.
  Capture67041/export-media45761 and10adapter checks55966 joined0; cleanup[].
- Linux image `scorebug/home-daemon:qa-timing-trixie` is retained. Trixie FFmpeg7.1.5
  supplies required encoder timing; old Bookworm5.1.9 did not. Short compiled-image
  timing/media result: `linux-worker-20260928/acceptance.json`.
- Native network/congestion/loss/recovery results remain in the acceptance matrix;
  no unchanged fault sweeps. Latest worker crash after guardian pipe isolation:
  `headless-native-8guvcT/worker-crash-acceptance.json`; continuous2125frame archive,
  same publisher,17.267s live gap; interrupted tail still106–107ms, recovered≤37.5ms.
  Latest incoming/mux boundary timing is now in `headless-native-tC9YyK` and `headless-native-a1rmZ9`;
  no evidence supports changing guardian timeouts.

## Hands-on use and environment

[Fast iteration](../fast-iteration.md): `node scripts/simulator-lab.mjs --host <LAN>
--duration 1800 [--source /absolute/prepared.mov] [--worker-image <built-image>]`.
No UI tests; Watch needs Join offered match. Three `Scorebug Manual ... qiL8sA`
simulators remain booted/preserved; `manual-simulators-qiL8sA/devices.json` owns IDs.
Their backend is stopped. No silent deletion of those app containers/recordings.

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; FFmpeg
`/opt/homebrew/opt/ffmpeg-full/bin/`; last LAN192.168.1.130, recheck if needed.
Prepared1080 source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`600s;
4K `artifacts/qa/uhd-app-20260928/input.mov`600s. Allow startup/finalization headroom.
Native export helper `artifacts/qa/publisher-blackhole-20260928/export-current.py`
reuses the current FilmModel bundle. Never concatenate native archive payloads or
rerun non-overwriting media scripts in a completed output directory. Never print
private setup/environment files. Individual session logs retain exact histories.

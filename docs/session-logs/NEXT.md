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

Hour capture finished; no live jobs. See [hour result](2026-09-30-hour-stream-setup.md).
`physical-hour-preparation-20260930/hour-acceptance.json` is the current result.
Clean4K/audio archive recovered on Mac:60m26s,108796decodedframes, continuous
encoded A/V. Both overlaid outputs fully decode, rolling5s minimum29fps; seven
short video gaps, audio continuous. Actual1080 input lasted14m20s total; sustained
1080 and physical stop/export remain failed/unqualified.

Phone exited during stop/finalization; exact original recording
33D2FF99-7918-42EA-8D41-9A5C076B2011 preserved on phone and copied to
`physical-hour-preparation-20260930/phone-original-recording`. Mac native recovery
export is `device-lab-1wgb5o/phone-clean-archive.mp4`. Do not promote interrupted
completion status or manually concatenate segments.

Fixed archive verification/copy buffer retention: isolated real-hour recovery
RSS13.8GB→35MB.20focused archive-store tests pass; signed iPhone build passes and
updated app installed. No new capture or physical export confirmation afterward.
Next, reuse this exact saved recording to check fixed phone recovery/export, then
a short stop check; do not start another hour until its unresolved questions warrant it.

Adaptive causes: initial receiver-proof invalidation resets1080→240; single
proxy timestamp-cap omission/151frames classified as worker pressure drops1080→720;
phone serious temperature then drops720→360→240. Transport nominal, worker timings
4.35/7.17ms. Distinguish deliberate cap removal from actual overload and log local
receiver-proof rejection reasons before altering policy. Retain authority/thermal
safety gates. USB charging+clear case initially; user unplugged~44min; no quality
recovery through finish. Isolate thermal workload after algorithm fixes.

Reuse earlier short physical1080/paired Watch and accepted simulator passes below.
No broad suites, unchanged soaks, agents, pushes or external broadcasts. Keep plan
pure goals/status/TODO; session logs retain exact experiments. TeamB222J9J7B8.

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

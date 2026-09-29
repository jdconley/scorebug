# Next session handoff

## Direction and checkout

Goal remains active: complete the planned system quickly, with necessary focused
checks only. Native phone/Watch scoring, independent clean recording, adaptive SRT,
score overlay, mock RTMP MP4 and optional proxy MP4 remain the required scope.

Worktree `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch
`codex/local-validation`. Primary `/Users/jd/src/scorebug` has pre-existing dirty
files; do not overwrite it. No agents, pushes, purchases or external broadcasts.
Preserve originals, recordings and unrelated simulators. The
[plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns TODOs;
[acceptance](../simulator-acceptance.md) owns results. No lab/test jobs active.

## Current readiness and next work

The user has explicitly renewed simulator-first delivery and faster iteration.
Do not poll physical devices or request passcodes now; earlier readiness questions
are superseded for current work. Existing local functional passes stand, but the
remaining simulator/media failures below are not green.

Latest production change: bounded TSWriter DTS interleaving (256PES/8MiB/2s),
clean drain, unchanged timestamps and immediate single-track behavior.57focused SDK
checks and complete short crash media pass. See [session](2026-09-28-dts-interleaving.md).
`headless-native-a1rmZ9/interleave-acceptance.json`:2123continuous archive frames,
matching live62–443/962–2102, all five MP4s decode, no internal A/V gaps;
interrupted tails59.159ms, recovered≤16.889ms, cleanup[]. Do not rerun unchanged.

Next local investigation: FFmpeg per-track shutdown/decoder queues or an ordered
transport observation for the general abrupt-tail gate. Independent demux logs
show track boundaries, not wire arrival order; neither the prior50.655ms nor the
current71.978ms demux lead proves upstream emission order. Source interleaving is
now covered, but prior107ms/native and500ms/simulator tails are not declared fixed.

Saved simulator congestion loss is confined to the actual restriction; before/after
periods remain30fps and the archive is continuous. Do not repeat failed GOP/latency
sweeps or the direct SDK simulator UHD failure. Failed candidates retain the
applied profile and back off; no larger queues or invented fixed ceiling.

For each implementation batch, run only the directly affected check. Repeat the
full simulator vertical only when a shared contract changes or to accept a finished
feature batch. No broad suite, sustained 4K run, device readiness check, or
cross-platform qualification in the routine edit loop. If evidence is insufficient,
add the smallest missing diagnostic rather than starting another parameter sweep.

Local backend/endurance and interrupted-tail gates remain open, not silently
waived. Quality failure handling is already conservative: joined candidate failure
retains applied settings and requires fresh health/backoff before another trial.
Do not add a hard-coded simulator ceiling or larger queue without new evidence.
Simulator UHD/congestion and colocated VideoToolbox/probe limits remain documented.

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

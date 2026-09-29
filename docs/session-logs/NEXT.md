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

Hardware work resumed on September29 after the user supplied the phone, Watch and
TV volleyball footage. See [session](2026-09-29-physical-tv-capture.md).

Current simulator core vertical and targeted API/worker crash regression pass; reuse
them unchanged. Physical phone app-loopback control probe passed. Short physical
capture `physical-recovery-EcJuQu` produced a143s clean1080p archive and both overlaid
MP4s, all fully decoding with continuous encoded A/V; phone point/export/independent
archive continuation observed. Adaptive360p confirmation failed before impairment,
resetting to240p on missing capacity/unknown thermal evidence. Do not call recovery
accepted. New bounded raw thermal/freshness diagnostics are built for the next run;
one focused native transition check and signed phone build passed.

Actual Watch saved-setup inspection passed after the user kept it unlocked on-wrist.
It confirmed the old owned test pairing; normal receipt-first expiry reconciliation
passed against an owned backup at the original endpoint. Original database, Keychain
and recordings preserved. Temporary recovery API stopped and joined.

First paired run failed because the phone still had the exact old test setup
request. Identity delivery worked; normal guarded phone-request reset passed.
Physical paired vertical `physical-paired-live-LlJlWn/vertical-acceptance.json` now
passes: both phone/Ultra2 workflows, real companion setup, Watch takeover/point/undo/
away/end, independent clean archive continuation/export, changing score in both
recorded outputs. Archive3829frames/127.637s; live3283frames; all3fully decode with
continuous encoded A/V and≤72ms track-end differences. All owned processes joined;
no active test/lab jobs. Reuse this pass.

Next: physical adaptive qualification, not another unchanged paired-scoring test.
The successful paired run stayed240p; one captured candidate failed capacityHeadroom.
The first recovery run's360p rollback had unknown thermal evidence; do not conflate
that with the failed paired run's70ms buffer versus60ms negotiated-delay limit.
Raw thermal diagnostics are added, but no successful application in the latest run
exercised them. Extend only the missing bounded evidence or reproduce one concrete
cause; do not weaken health gates or restart broad suites. Saved originals remain.

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

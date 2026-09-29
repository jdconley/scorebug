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

Core simulator features are accepted together. Use the hands-on launcher in
[fast iteration](../fast-iteration.md); do not repeat the full vertical or gate
manual use on another architecture, soak, or crash-tail experiment. The plan's
**Immediate delivery checkpoint** identifies the supported local path and the
failed/unqualified combinations without declaring them fixed.

User priority: fewer tests, faster implementation, simulators first. Hardware and
other-host qualification are deferred. A read-only device check during this session
found both physical devices unavailable; no automation or passcode request followed.
Do not repeat the check. The proposed emulated AMD64 smoke was not started because
it does not close a current simulator feature gap.

Latest bounded investigation: [shortest-tail isolation](2026-09-28-shortest-tail-isolation.md).
Watch foreground retries already exist. A4second isolated FFmpeg SIGTERM comparison
rejects adding shortest:7video frames/no decoded audio versus baseline134/190frames.
Artifact shortest-tail-uod24p16; all commands joined. Do not repeat or adopt this
option as a generic crash-tail fix. Explicit platform/backend gating is now checked;
resolving those failures remains qualification work, not a claimed pass.

No production code changed after e40294e. Current two-phone/Watch acceptance below
stands. All local feature checklist items are implemented; remaining local work is
fault bounds and known backend/platform limits. Keep those visible without conflating
them with missing scoring/recording/overlay features.

If continuing a fault fix, first identify the failing boundary from saved evidence.
Independent FFmpeg demux logs are not ordered wire evidence. General abrupt-tail
bounds remain open despite the latest short DTS-interleaving run's59ms tail; no
speculative timeout/decoder change or unchanged live crash rerun. Simulator UHD and
severe-congestion failures and colocated VideoToolbox/probe loss are not waived.
Candidate failure retains applied settings and requires fresh health/backoff.

One directly affected check per implementation batch. No app tests for documentation,
no broad suite after a focused pass, and no unchanged integration/endurance run.
Do not spawn agents, push, or broadcast externally.

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

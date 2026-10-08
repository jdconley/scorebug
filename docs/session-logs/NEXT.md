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

Follow the [focused remediation plan](../superpowers/plans/2026-09-30-sustained-4k-recording-1080-streaming.md).
Target: new iPhone18Pro (iOS27.0.1), USB charging and normal case (confirm current case), home LAN/software proxy;
progressive startup followed by60continuous minutes of actual1080p30/6Mbps input
while recording clean4K30/audio, then successful stop/export/playback/relaunch.
Implementation checkpoint: saved phone hour recovery/export/playback/relaunch passes;
original interrupted status retained. Cap jitter loss is reproduced/fixed; only
corroborated deliberate cap omissions are excluded from resource overload, with
legacy/unknown loss and time/pressure guards retained. Cause checkpoints and
camera/CPU/memory/thermal/battery diagnostics are implemented. Signed phone build
and focused checks pass.

One affected simulator1080 vertical and all three full saved-media/source-ID checks
pass: `ordinary-native-nncHUb/media-source-validation/result.json`, actual1080 input
1065frames/35.5s, archive7795/live7493consecutive IDs, gap-free audio, ends≤45ms.
Saved-export, archive-stop and600/1800/3600-second combined modes are implemented;
new combined collection/hold gates have not yet run on hardware.

Current device: `00008160-000C5CAE20434036`, iPhone18Pro, wired/trusted/paired.
Xcode `/Applications/Xcode.app/Contents/Developer`27.0/SDK27.0 builds current app/tests.
Developer Mode is enabled, DDI usable and phone unlocked. No capture/test has
started. Current blocker: Xcode27 device build reports No Account for TeamB222J9J7B8;
app/runner profiles omit the new UDID. Conley team is visible in Xcode UI but profile
refresh did not resolve CLI authentication. The account sign-in sheet is open for
the user; pending async question asks them to finish Conley authentication.
Harness now selects actual SDK and explicitly forwards selected Xcode to shared
commands;3focused environment/process checks pass. Legacy simulator defaults remain.
After auth, verify selected-device registration/signing profiles, then run short
archive-stop; do not repeat failed builds without new account-state evidence.
Old hour is retained on old phone/Mac; no recovery attempt on this new phone.
Mac space is now78GiB, sufficient headroom for staged tests; no task cleanup done.
See [new-phone session](2026-10-08-new-phone-setup.md).
Next: short fresh Stop, then an instrumented combined600-second trace for the
remaining receiver-proof cause and measured phone thermal workload. Cap attribution
and the qualification harness are implemented; physical resource/collection checks
remain open. After an attributed fix,30-minute checkpoint then
one final60-minute confirmed1080p hold. Keep real safety guards. No unchanged Watch
suite or blind hour retries. Case-off/battery comparisons are diagnostic only.

Hour capture finished; no live jobs. See [hour result](2026-09-30-hour-stream-setup.md).
`physical-hour-preparation-20260930/hour-acceptance.json` is the current result.
Clean4K/audio archive recovered on Mac:60m26s,108796decodedframes, continuous
encoded A/V. Both overlaid outputs fully decode, rolling5s minimum29fps; seven
short video gaps, audio continuous. Actual1080 input lasted14m20s total; sustained
1080 and fresh physical Stop remain failed/unqualified; saved phone recovery/export passes.

Phone exited during stop/finalization; exact original recording
33D2FF99-7918-42EA-8D41-9A5C076B2011 preserved on phone and copied to
`physical-hour-preparation-20260930/phone-original-recording`. Mac native recovery
export is `device-lab-1wgb5o/phone-clean-archive.mp4`. Do not promote interrupted
completion status or manually concatenate segments.

Fixed archive verification/copy buffer retention: isolated real-hour recovery
RSS13.8GB→35MB.20focused archive-store tests pass; signed iPhone build passes and
updated app installed. Saved phone native recovery/export is now confirmed; fresh Stop remains open.
Next, run only the short fresh Stop check on the new phone after setup/readiness; do not start another hour until its unresolved questions warrant it.

Adaptive causes: initial receiver-proof invalidation resets1080→240; single
proxy timestamp-cap omission/151frames classified as worker pressure drops1080→720;
phone serious temperature then drops720→360→240. Transport nominal, worker timings
4.35/7.17ms. Cap attribution and local receiver-proof rejection reasons are now implemented.
Resolve the remaining physical reset with one short instrumented trace; do not alter freshness merely to hold quality. Retain authority/thermal
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

Xcode `/Applications/Xcode.app/Contents/Developer`27.0 for the new phone (old26.2 remains installed); FFmpeg
`/opt/homebrew/opt/ffmpeg-full/bin/`; last LAN192.168.1.130, recheck if needed.
Prepared1080 source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`600s;
4K `artifacts/qa/uhd-app-20260928/input.mov`600s. Allow startup/finalization headroom.
Native export helper `artifacts/qa/publisher-blackhole-20260928/export-current.py`
reuses the current FilmModel bundle. Never concatenate native archive payloads or
rerun non-overwriting media scripts in a completed output directory. Never print
private setup/environment files. Individual session logs retain exact histories.

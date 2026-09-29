# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, reuse passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. [Plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current milestone and next action

Native→Linux proxy integration now passes:
`headless-native-wJYttO/linux-integration-acceptance.json`,lab`device-lab-0tavVM`.
120s normal native capture, real local SRT, Linuxarm64 CPU proxy, RTMP mock and
proxy MP4. Confirmed240→360 at71s; actualreceiver1467frames240/2080frames360 with
exact3000/90000steps. Archive3628consecutive frames, live3547matching source62–3608;
archive continues19frames. All3fully decode with gap-free audibleaudio and ends≤26ms.
Capture67041/export-media45761 joined0; ten focused adapter tests55966 pass;
worker exit0,cleanup[],no Docker containers remain. No broad UI/hardware run.

New --worker-image option on device-lab, simulator-lab and headless lane reuses
prebuilt `scorebug/home-daemon:qa-timing-trixie`. Mac Docker Desktop adapter maps
only state/recordings, uses private envfile, routes loopback viahost.docker.internal,
requiresCPU/timing, neverpulls, and removes ownedcontainer. Container crash injection
is intentionally separate. [Session](2026-09-28-native-linux-proxy.md). No lab/test
jobs active; three earlier manual simulators remain preserved. Static overlay in
this run; dynamic scoring has separate native/Mac results. Otherhost/full-ladder/
full-match and livecrashtail remainopen. Do not repeat this120s run unchanged.


Linux image timing gap fixed: worker Dockerfile now Node22/Trixie, FFmpeg7.1.5.
Bookworm5.1.9 probe returned unsupported. Strengthened existing container check
requires actual completed encoder timing and fully decodes paced720p FLV+MP4.
Pass `linux-worker-20260928/acceptance.json`; image `scorebug/home-daemon:qa-timing-trixie`
retained locally. Scope Linuxarm64 Docker VM, no actual RTMP/SRT network or sustained
qualification. Build7457 and final check50899 joined0; all owned containers removed.
[Session](2026-09-28-linux-worker-timing.md). Next portable check can reuse this image
for real local relay/API/RTMP integration; do not rerun unchanged startup checks.


Hands-on launch now available: `node scripts/simulator-lab.mjs --host <LAN>
--duration 1800 [--source /absolute/prepared.mov]`. No UI automation. Synthetic
source by default; source option reuses existing staged-file capture. Watch must
tap Join offered match first. Guide: [fast iteration](../fast-iteration.md).
Startup/build/install/launch/cleanup check passed, `manual-simulators-qiL8sA`,
lab `device-lab-XEnHSX`; no new scoring/media acceptance claim. Three named
Scorebug Manual simulators are retained and booted for inspection; devices.json
contains their IDs. Lab/process15891 and screenshots47582 joined0. No lab/test jobs
active; backend is stopped. Do not silently delete their app data.

Latest direction: prioritize speed and simulator feature completion. The local
functional checklist is complete on documented paths; no hardware readiness prompts
or repeated unchanged acceptance. See [fast iteration](../fast-iteration.md).

Parent-loss pipe defect fixed: guardian now owns FFmpeg progress/decoded/timing
readers and drains them after worker death. Three new regression cases produced
EPIPE before and pass after;45focused lifecycle tests and worker typecheck pass.
Short actual worker-SIGKILL/FFmpeg comparison `guardian-drain-20260928/run-kQF0u8`
fully decodes before/after with tails1.8/11.8ms; guardians joined. This does NOT
explain the retained107ms/508–548ms live tails. See
[parent-loss session](2026-09-28-guardian-parent-loss.md). No active jobs.

Current guardian verified with actual native worker crash:
`headless-native-8guvcT/worker-crash-acceptance.json`, lab`device-lab-xVZMvn`.
Capture45847 and native-export/media22561 joined0; cleanup[]. Archive2,125consecutive
frames/37segments; both output sequences62–443 then962–2104, gap17.2667s. Worker
absent15.235s; same publisher. All five files decode without within-session frame/
audio gaps. Interrupted tail106.24msmock/107.24msproxy; recovered≤37.5ms, archive13.3ms.
Tail effectively unchanged by pipe isolation; no unchanged rerun or timeout tuning.
Next tail investigation needs incoming/mux/decoder timing at the live crash boundary,
which current saved diagnostics lack. No speculative interleaving/queues. Other
backend/hardware/full-match qualification remains open. No lab/test jobs active.
[Session](2026-09-28-live-crash-pipe-isolation.md).

Sustained native UHD PASSES: `headless-native-yFO9Hu/sustained-acceptance.json`.
1050s capture/1056throughfinalization, normal ladder,4Kconfirmed316s. Receiver22635
actualUHDframes/754.5s with exact30fps; no SDK/appdrops/submiterrors, hardwareselected.
Archive31,534/live31,452consecutive frames, gap-free audibleaudio, all3files fully
decode and A/V ends≤35ms.527segment hashes. Archive continues20frames past live.
Capture80073 and export/media88436 joined0,cleanup[]. **No active jobs.**
[Session](2026-09-28-sustained-native.md). Duration guards committed83d2d7e;
producing source and fixture hashes bound in the artifact. Do not repeat this soak.

Prepared source `artifacts/qa/sustained-native-20260928/input.mov` is1200s,
stream-copiedH264, exact30fpsPTS, first600sPCM repeatedonce. SourceIDs repeat18000;
all sourcepacket timestamps and decodedjoin verified. Final verifier checks exact
modulo18000 identity and continuousPTS; no ignored loop interval. Originalfootage
preserved. Last observed disk81GiBfree; do not delete recordings/evidence automatically.
Offline scripts in sustained-native-20260928 have now both passed; don't rerun on
completed artifact directories. `sustained-media` contains PCM, packets, IDs, reports.

Remaining: interrupted-tail bounds, other backend/platform and full-match limits,
physical readiness and Watchroutes/camera qualification, authorizedexternal/CI.
No production changes justified by prior file-input decoder comparison; current
nativeworkercrash tail107ms, older simulator/VT508–548ms. Reuse all completed local
UI/scoring/fault results. Primary `/Users/jd/src/scorebug` is dirty (pre-existing docs/
README files), so don't merge/overwrite it without accounting for those changes.
Authoritative work stays in this worktree. Hardware has been deferred per user.

## Backend limits and useful short diagnostics

Use software proxy for colocated Mac UHD. Probe-only warmup with VideoToolbox proxy
causes SDK input loss; candidate-only and probe/software cases pass. The internal
shared-resource cause remains unproven. Simulator UHD candidate encoder hits its
pending-input limit; do not enlarge queues or repeat unchanged simulator runs.

If a future change requires UHD isolation: `--direct-uhd on --duration 55` skips
middle rungs but retains normal admission/timing; not full-ladder acceptance.
Other diagnostic warmups/freeze modes and exact evidence are in
[probe/backend session](2026-09-28-uhd-probe-backend.md). They must not become
production shortcuts or false acceptance. No more speculative parameter sweeps.

## Reuse, do not repeat

- Native two-phone create/join/scoring; separate41mm Watch takeover/relaunch/end;
  offline/lost-reply/stale-authority recovery. Watch setup is not radio qualification.
-1080 full vertical/media: `ordinary-native-PpPozK/1080-final-acceptance.json`.
- Archive storage/queue/source recovery, short4K export/playback/relaunch.
- Native reconnect, API/worker crashes, relay generations, Mac service/container
  deployment.25s publishing blackout preserves archive and resumes outputs with
  29.3333s live gap;25s relay suspension recovers with35.5667s gap. No equivalent rerun.
- Retained deterministic fault/audit coverage: [matrix](../local-fault-coverage.md).
- Native Mac/software-proxy congestion passes with no video/audio loss. Prior
 simulator collapse retains87missing IDs/16audio gaps; no retroactive pass.
 Buffer/GOP candidates were worse and rejected.
- Hosted CI requires authorized push. Physical routes, devices, other hosts and
  YouTube remain deferred gates, not inferred from local evidence.

## Environment and commands

`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130; AppleM4Max.
4K600s fixture `artifacts/qa/uhd-app-20260928/input.mov`;
1080 `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`.
Never modify Downloads originals or print generated endpoint/token configs.

Headless: `node scripts/test-headless-streaming.mjs --host <LAN> --source <absolute.mov>
--duration <seconds> --quality 2160 --timing-audit off --worker-encoder software`.
Audit-off retains production control but not complete delivery-audit/UI evidence.
Native export when relevant: `python3 artifacts/qa/missing-processing-20260928/export-retained.py <artifact>`.
Current-bundle no-build variant: `artifacts/qa/publisher-blackhole-20260928/export-current.py`.
Never concatenate native archive payloads. New single-decode media verifier is
`artifacts/qa/uhd-readiness-20260928/verify-final-media.py`; do not rerun it on the
completed artifact (outputs already exist). It documents the RTMP precision bound.

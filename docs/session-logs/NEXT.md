# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, reuse passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. [Plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current milestone and next action

Starting ba0c570; current code adds only a private TCP outage fixture and a combined
headless option. `headless-native-KJYNvL/client-network-acceptance.json` passes
25-second native API/SRT loss: continuous 2,727-frame archive, gap-free audio,
same generation, one Start/Stop, restored output at 40s. 366 API connections rejected,
no API bytes or SRT sends during loss. Both outputs match; all five files decode,
A/V ends≤49ms. Live gap27.233s. Capture53810/export-media9029 joined0; cleanup[].
[Session](2026-09-28-client-network-outage.md). **No active jobs.**

Normal native240→360→720→1080→2160 and complete saved media remain passed with
software proxy: `headless-native-nZ4tzv/final-acceptance.json`.330s run including74s
UHD; no SDK/app drops, archive9927/live9846consecutive frames, gap-free audio.
[Prior session](2026-09-28-adaptive-uhd-media-pass.md) documents RTMP timestamp
precision correction from retained packets, without another decode. UI/Watch and
changing-score results are separate retained passes, not part of these headless runs.

Next address intermittent packet loss and severe-congestion A/V loss, then abrupt
output tails and sustained/backend qualification. Do not repeat completed client,
publisher or relay outage captures, nor reopen the resolved software-proxy UHD path.
Use existing severe-congestion evidence to identify a concrete fix before another
capture; no unchanged parameter sweeps.

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
- Healthy congestion periods pass; severe collapse still has87missing IDs,
 16audio gaps/2.4s max gap. Buffer/GOP candidates were worse and rejected.
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

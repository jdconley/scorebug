# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, reuse passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. [Plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current milestone and next action

Starting7eef49d; new harness supports `--congestion-seconds 25`, no production
policy/codec/timing changes. `headless-native-44b0fy/congestion-analysis.json` passes
normal adaptive720→minimum→720 through25s at750kbps using Mac native/software proxy.
Archive9,926/live9,844consecutive frames, zero audio gaps, all5s windows30freshfps,
A/V ends≤35ms.167segment hashes; fullA/V decode, same publisher/gen1, oneStart/Stop.
Forward queue peak28,968bytes, no drops/errors, pending0. Capture44417/export4256
joined0,cleanup[]. Initialbi8j3p/3887 failed before fault on log-creation race;
ENOENT retry fixed,cleanup[]. [Session](2026-09-28-native-congestion-pass.md).
**No active jobs.** Earlier simulator failures remain failures; configuration
comparison does not prove an isolated platform/backend cause.

Combined25s API/SRT outage remains passed in
`headless-native-KJYNvL/client-network-acceptance.json`: continuousarchive, same
broadcast, livegap27.233s, bothoutputs restored. Normal native adaptiveUHD/media
remain passed in `headless-native-nZ4tzv/final-acceptance.json`:330s including74sUHD,
zero SDK/app drops, allmedia consecutive/gap-free. UI/Watch/dynamic scores separate.

Next: intermittent packet-loss integration; abrupt output tails; sustained/backend
qualification. Reuse native congestion/outage/UHD passes. Do not repeat unsupported
simulator low-latency properties, bitrate-first or buffering experiments; older
session logs document failures. Simulator congestion/UHD and localVideoToolbox/probe
limits remain tracked, not erased by native software-proxy results.

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

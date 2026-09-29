# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, reuse passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. [Plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current milestone and next action

Starting36c93c2. `--worker-crash-after 15` adds a short native integration lane;
no production settings change. `headless-native-MAuIfq/worker-crash-analysis.json`:
actualSIGKILL,15.186s down, same nativepublisher/gen1 and archive.37segments,
archive2,124consecutiveframes; bothoutputs62–442 then962–2104, gap17.3s.
All5filesdecode, no within-session video/audio gaps; interruptedaudio107ms,
recoveredends≤36ms. Capture10982/export53068 joined0,cleanup[].
[Session](2026-09-28-interrupted-tail-comparison.md). **No active jobs.**

Four6s production-proxy file-input/SIGTERM comparisons (automatic/slice × VT/software)
all endwithin29ms, so do not justify a decoder-default change. Process43499 joined0;
artifacts/interrupted-tail-20260928/run-krr5eu. Earlier fixture failed before spawning
FFmpeg due unopened log descriptor, fixed with pipe/freshdirectory. General crash-tail
bound across load/backends remains open; oldsimulator508–548ms is not a native pass.
TSWriter only buffersstartup; audio/video then emitonarrival. Live source encoder
lag is a possible contributor, not a proved cause. Do not add speculative mux queues.

Next prioritize sustained local1080/UHD qualification using the workingsoftware
proxy; reuse all completed UI/scoring/fault results. No unchanged crash or file-input
comparison rerun. SourceMOVs last600s; native runner max600s, leave startup/drain room.
Retained periodicloss MUpcfR, congestion44b0fy, API/SRToutageKJYNvL, adaptiveUHDnZ4tzv
remainpassed. Simulator congestion/UHD and colocatedVideoToolbox limits stay explicit.

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

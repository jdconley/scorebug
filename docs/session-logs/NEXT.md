# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, reuse passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. [Plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current milestone and next action

Starting7467e56. New short headless `--packet-loss-every 100` reuses existing
UDP impairment/diagnostics; no production changes. `headless-native-MUpcfR/loss-acceptance.json`
passes1% periodic loss in both directions:167forward/63reverse drops, all124data
losses later forwarded as retransmissions; trace complete. Archive2,724/live2,643
consecutive30fps frames, no audio gaps, all5s windows30freshfps, A/V ends≤15ms.
47segment hashes, bothMP4s, samepublisher/gen1, oneStart/Stop. Capture9406 and
export/media83451 joined0,cleanup[]. [Session](2026-09-28-intermittent-loss-pass.md).
**No active jobs.**

Retain completed native Mac/software-proxy congestion (`headless-native-44b0fy`),
clientAPI/SRT outage (`headless-native-KJYNvL`) and normal adaptiveUHD
(`headless-native-nZ4tzv`) passes; do not rerun unchanged. Simulator congestion/UHD
and colocatedVideoToolbox limits remain explicit, not retroactive passes.
UI/Watch/changing-score results are separate retained evidence.

Next: interrupted output tails, then sustained/backend qualification. Guardian
SIGTERMs FFmpeg immediately on workerIPC loss. Pipeline defaults toautomatic input
decoder threading and already supports explicitslice; retained crash outputs had
508–548ms extraaudio. A short controlled decoder-mode comparison can investigate
buffered decoding before any shutdown/latency change. Not a proved root cause.
Avoid a full native app/Watch/adaptive capture to isolate that small question.

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

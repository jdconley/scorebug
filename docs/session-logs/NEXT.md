# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, reuse passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. [Plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current milestone and next action

**ACTIVE capture80073: headless-native-yFO9Hu. Rejoin; do not restart.**
Started17728d0 plus two opt-in duration guards (JS/Swift): no-finite-audit headless
runs allow1200s; audit-enabled stays600s. No production changes. Actual1050s
normalUHD/software-proxy run has confirmed360at76s and720at161s. No acceptance yet.
[Session](2026-09-28-sustained-native.md). No other session jobs active.

Prepared source `artifacts/qa/sustained-native-20260928/input.mov` is1200s,
stream-copiedH264 with exact30fps packet timestamps; exact600s PCM repeated once.
SourceIDs repeat18000; decodedjoin17994…17999,0…5. Allvideo/audio packet timestamps
verified; source-qualification.json binds hashes. Prep47289/qualification60768 joined0.
Downloads/originalfixture untouched. Initialdisk104GiB; preserve all evidence.

After capture terminal success, export once with currentbundle:
`python3 artifacts/qa/publisher-blackhole-20260928/export-current.py
artifacts/qa/headless-native-yFO9Hu`.
Then `python3 artifacts/qa/sustained-native-20260928/verify-media.py <absolute-run>`
and `python3 artifacts/qa/sustained-native-20260928/analyze.py <absolute-run>`.
These new offline scripts syntax-check but have not run. Require>=600sconfirmedUHD,
>=18000actualUHDreceiverframes, normal ladder, noSDK/appdrop/submiterror, all3files
fullydecode with exactcontinuousPTS, IDsmod18000, gap-freeaudio andends<50ms.
Do not claim long-run pass merely from1050elapsed or selected4K. Completehashbinding.
Do not start another native build/media workload during this capture.

Previous workercrashMAuIfq passesrecovery, notgeneral tailbound: archive2124frames,
interruptedaudio107ms, recoveredends≤36ms, livegap17.3s; alljobsjoined.
Retain periodiclossMUpcfR, congestion44b0fy, API/SRToutageKJYNvL, shortUHDnZ4tzv.
Simulator/backendlimits andphysical/full-match qualification remainexplicit.

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

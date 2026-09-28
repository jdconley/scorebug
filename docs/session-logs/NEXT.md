# Next session handoff

## Direction and checkout

**Simulator-first; finish missing features faster.** Batch behavior changes, run
focused checks, reuse incremental builds and saved acceptance. Hardware and external
hosts are deferred. Do not repeat passing app workflows or small congestion tweaks.
No proactive subagents. Preserve originals, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch
`codex/local-validation`. Use current Git HEAD. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; the [consolidated acceptance matrix](../simulator-acceptance.md) owns
current cross-feature evidence. [Latest session](2026-09-28-uhd-probe-protocol.md)
contains exact new results and limitations.

## Current checkpoint

- Explicit UHD probe protocol foundation passes focused native/Go/API/Swift checks.
  SRTStream supports a fixed `.uhd` budget: v4,48Mbps,64MiB/campaign,200µs wake floor,
  one packet maximum, unchanged leases/lifetime and strict v1–v3 bounds. Replacement
  and restart retain budget. Relay/API/Swift receiver parsev4. SDK upstream round trip
  and relay pinned-archive patch application pass. No image built, no app4K enabled.
  See [design](../superpowers/specs/2026-09-28-uhd-probe-budget.md). All jobs joined0.

- Film now offers1080p/4K recording. Source/archive geometry matches and quality
  locks through startup/recording/shutdown. Ten focused model checks and simulator
  phone/Watch builds pass. Native4K record/export/playback/relaunch and saved media
  pass:247consecutive30fps frames, no audio gaps,21.333ms A/V ends, no archive queue
  losses. Evidence `recording-quality-20260928-media`. Menu-idle and artifact-copy
  failures from earlier attempts are retained in the log. No live jobs/simulators.
  Streaming remains capped1080; actual sustained4K input/output is still next.

- Production ladder now240→360→720→1080(6Mbps), verified in`ordinary-native-PpPozK`.
  Native climb/confirmation, actual pre-scale1080receiver geometry, archive/live
  consecutive30fps, waveform, changing score and cleanup pass. Archive8518frames,
  live8260frames;1077receiver frames at1080. A/V ends≤34ms; archive110frames longer.
  Initial offline checker assumptions were corrected without recapture; see log.
  Native19182joined0, media27663joined1for the preserved initial checker failure;
  final hash-bound acceptance passes. No live jobs.

- Real relay generation/worker-session replacement, retired report/credential rejection,
  late current reader decoding and scoped cleanup pass. No live owned jobs remain.
- Retained phase analysis proves baseline and buffered candidate healthy periods have
  30minimum freshfps, zero missing/non-increasing IDs and zero audio timestamp gaps.
  All missing source IDs fall inside the forced constraint; strict whole-stream failures
  remain unchanged. See latest log/hash-bound artifact; no native capture repeated.

- Bounded production candidate scheduling is implemented. Four focused model checks
  pass; `ordinary-native-kStE7J` completes the full720→minimum→720 native workflow,
  independent transport/geometry/transitions and cleanup. No hardware or broad suite.
- Larger4second peer buffer is rejected as a production improvement: archive12,991
  continuous frames; live149missing IDs,6repeated/non-increasing observations,15audio
  gaps and4.033s maxgap. Packet analysis rejects truncated NAK ranges. All failures
  preserved. Factory restored to3000ms, API/lab peer bound120–2000ms(default unset).
  Explicit6000ms diagnostic contract/guards remain, but are not production-selected.
- New6second bounded stop now has native evidence: live A/V ends≤97ms, archive
  continues127frames, cleanup[]. All processes joined; no live jobs.

- `ordinary-native-C7yloY`: live file-source interruption → publisher idle → recover/export
  → fresh recording/broadcast → normal stop/export passes. Archives1320/882 consecutive
  30fps frames; both output sessions decode; final1–0 visible; all A/V ends≤45ms.
  Four accepted start/stop generations1–4; correct interrupted/stopped associations.
- `device-lab-P7D4bv`: actual compiled Mac launchd worker, real API/relay, score and
  both MP4 outputs pass.12.2seconds, visible1–0, A/V ends≤71ms. Observed worker exit0,
  four owned processes gone, service booted out. No persistent installation.
  Failed first configuration attempt `device-lab-Iw8o04` retained/cleaned.
- Source lane28checks and service/options11checks pass. Build/syntax/format/diff pass.
  Saved-output score checks were incorporated into the service runner without another
  live run. Publisher cleanup hardening not separately fault-injected.
- New path-filtered native CI adds Swift/model checks and full phone/embedded-Watch
  simulator build; YAML validated, hosted execution not yet performed.
- All current jobs joined; owned lab/simulator cleanup passes. No live jobs.

## Next work

1. Wire the new UHD budget through ScorebugStreaming owned reservations/snapshots,
   candidate plans and source/output selection. Native low-level budget is implemented,
   but wrappers/NativeCandidateStagePlan still retain12Mbps/16MiB/8Mbps limits. Select
   UHD only for4K capture + fresh2160output capability; other paths retain1080 ceiling.
   Source4K recording is qualified; use the existing120s4K derivative, extending it
   only for the actual ordinary climb. Build `scorebug/ingest:uhd-probe-v4` separately
   and update the new lane's explicit audit validators. Current lab image staysdrain-v1.
   Prove measured4K climb, real receiver input/output, native scoring and independent
   archive/live MP4 media. The v4 budget does not itself prove throughput.
2. Keep prior production latency. No more parameter-only congestion captures: bounded
   scheduling is fixed, larger buffering worsens media, and healthy-period FPS passes.
   Investigate actual forced-outage loss from saved evidence when needed. Remaining
   delivery-audit/stale-pressure TODOs should reuse existing complete model coverage.
3. Confirm native CI when a push/hosted run is authorized. Actual external Linux/TLS,
   other GPU backends and hardware remain deferred until local feature gates resolve.

## Reuse, don't repeat

See the acceptance matrix for two-phone native creation/scoring/overlay, Watch B
41mm takeover/relaunch/end, native uncertain-command recovery, offline archive
faults, API/hard-worker recovery and remote Watch end. These are incremental results,
not a same-revision full suite. Watch setup fixture/directHTTP isn't WatchConnectivity.

Rejected congestion experiments: minimum one-second GOP, bitrate-before-resize,
relative pacing and source cadence. Baseline `ordinary-native-PvbKtK`; rejected GOP
`ordinary-native-rVojgQ`; offline ACK replay `ack-backlog-20260928`.
The new earlier growing-buffer warning is retained; don't repeat rejected variants.

## Environment and commands

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed26.2runtimes.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; relay `scorebug/ingest:drain-v1`.
Last LAN192.168.1.130; recheck before labs. Generic simulator builds need explicit
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`; local SRT has no working x86_64 simulator link.

Prepared600s source: `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`, SHA256
`6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.
45s interruption copy: `artifacts/qa/prepared-source-interruption-20260928/input.mov`.

Use `node scripts/test-ordinary-native-app.mjs --host <LAN> --source <absolute.mov> --lane <lane>`
with scoped DEVELOPER_DIR. `source-interruption` requires the short clip. Other lanes
include `quality1080`, `server-recovery`, `server-crash`, `recovery720`, `watch-direct`.
Use `node scripts/test-apple.mjs --pending-takeover --ui-only` for only that native UI.
Mac service: build home-daemon then `node scripts/test-macos-worker-service.mjs --host <LAN> --duration 120 --encoder videotoolbox`.

Physical Watch pending setup is preserved. Do not clear Keychain, retry signing,
reconcile blindly or repair pairing. Do not concatenate separate outage outputs.

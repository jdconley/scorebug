# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, retain passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current finding and next action

Starting8db60e7. Two short DEBUG-only comparisons:
- `headless-native-mx1Wwc`: real direct UHD admission then freeze worker-status and
  quality polling.18SDK raw drops,0app drops, hardware selected, median sampled
  UHD submission33.05ms. Ongoing polling is not sufficient to explain the loss.
- `headless-native-dZDuaa`: production UHD publisher wrapper/initial240 with a manual
  guarded UHD change, no measurement campaigns.909consecutiveUHD receiver frames,
 0drops, hardware selected. Publisher setup alone does not reproduce the slowdown.
Both recording/publishing survive; both incremental builds/targeted lifecycle tests
pass. Reports are `isolation-analysis.json` in each capture with source patch/hashes.
See [session](2026-09-28-uhd-polling-isolation.md).
Handles23488/29036 joined0, cleanup empty. **No active jobs.**

Next isolate pre-upgrade candidate native encoding from bandwidth probing, e.g. a
short measurement warmup before the passing owned-publisher transition. Join the
actual candidate lifecycle; do not fake admission evidence. No resource leak has
been proven: candidate terminal code explicitly drains/stops/clears its codec.
Do not make another history-copy, queue-size or timing optimization speculatively.

Retain the faster real adaptive reproduction `--direct-uhd on --duration 55`:
`headless-native-MuMtrg` reachesUHD26s and loses first SDK frame37s, with hardware
confirmed. Its first rollback reason differs from full-ladder sourceLoss. Native
submission stacks wait for VideoToolbox XPC; service cause remains unproven.
Skipped rungs mean diagnostic only. No unchanged300s climb/full media decode;
verify a fix here before returning to the full ladder.

Already isolated: single/triple native hardware UHD encoders and verified SDK
1080→UHD replacement each deliver450/450frames without drops; plain encoder count,
selection and replacement alone do not reproduce loss. Low-latency mode fails.
Fixed-UHD first35s and later content region both pass short receiver cadence.
The iOS simulator UHD encoder hits its pending-input limit; do not enlarge queues
or rerun unchanged. Keep this platform ceiling distinct from the native Mac loss.

## Reuse, do not repeat

- Full1080 vertical/media: `ordinary-native-PpPozK/1080-final-acceptance.json`.
- Native two-phone create/join/scoring, separate41mm Watch takeover/relaunch/end,
  offline/lost-reply/relaunch/stale-authority recovery. Watch setup fixture does
  not qualify physical WatchConnectivity/radio routes.
- Clean archive storage/queue/source fault recovery; short4K recording/export/playback.
- Native reconnect, API/worker crashes, relay generations, local Mac service and
  Docker deployment.25s publisher-hop blackout preserves continuous archive and
  resumes both outputs, with29.3333s measured live gap.25s relay suspension also
  recovers, with35.5667s gap. No equivalent reconnect reruns.
- Retained fault/audit terminal coverage reconciled in [fault matrix](../local-fault-coverage.md).
- Healthy congestion intervals pass. Severe collapse loss, abrupt output tails,
  intermittent loss/whole-client outage, sustained profiles remain open. Do not
  repeat rejected buffer/GOP sweeps. Hosted CI needs authorized push.

## Environment and commands

`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130; AppleM4Max.
4K600s source `artifacts/qa/uhd-app-20260928/input.mov`.
1080source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`.
Later-content slice `artifacts/qa/uhd-readiness-20260928/content-250-300.mov`.
Do not modify Downloads originals. Do not print config/setup/environment secrets.

Headless: `node scripts/test-headless-streaming.mjs --host <LAN> --source <absolute.mov>
--duration <seconds> --quality 2160 --timing-audit off`.
Short fixed diagnostic adds `--fixed-uhd on`, maximum60s/no outage; skips adaptive
policy/probing and cannot establish adaptive acceptance. Audit-off retains
production controls but not full delivery-audit/UI qualification.

Native archive export when relevant:
`python3 artifacts/qa/missing-processing-20260928/export-retained.py <headless-artifact>`.
Uses incremental FilmModel build and real RecordingLibrary export; never concat.

Short combined replacement: fixed command above plus `--fixed-uhd-transition on`.
Direct adaptive reproduction: normal command with `--direct-uhd on`, quality2160,
audit off, no outage/fixed mode,≤120s. Private130s slice available at
`artifacts/qa/uhd-readiness-20260928/content-215-345.mov`.

Polling ablation: direct command plus `--freeze-uhd-polling on`,≤60s. It deliberately
halts adaptive reaction after UHD; never acceptance. Owned-publisher transition:
fixed-transition command plus `--owned-uhd-transition on` (starts240, no campaigns).

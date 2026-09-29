# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, retain passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current finding and next action

Starting92d2369, added short DEBUG-only diagnostics; normal production settings
unchanged. Combined guarded1080→UHD replacement (`headless-native-19R4qp`) passes:
908consecutiveUHD receiver frames,0drops, hardware selection,36ms max submission.
Direct adaptive240→UHD (`headless-native-MuMtrg`) reaches UHD26s and reproduces SDK
raw loss37s; two trials yield15SDK drops, app drops0, hardware confirmed. First
rollback reasons are missingCapacity/unknownPressure/trialRollback, not the previous
sourceLoss decision. Native encoder waits on VideoToolbox XPC in a brief stack
sample; root cause inside that service remains unproven. First loss precedes
sampling, but389ms maximum at profiling/rollback is not an undisturbed measurement.
See [session](2026-09-28-fast-uhd-reproduction.md); both artifacts contain
`isolation-analysis.json` and producing HEAD/patch/hashes.
Handles11000/63939/16512 joined0, cleanup empty. **No active jobs.**

Next investigate adaptive probing/observation versus the passing combined
replacement. Long runtime/intermediate transitions are not required to reproduce.
Use `--direct-uhd on --duration 55` (normal admission/timing; skipped middle rungs,
not full ladder acceptance). Preserve normal queues and thresholds. Profile native
service work or isolate adaptive components before another production optimization.
No unchanged300s climb, broad suite or full decode when boundary loss already fails.

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

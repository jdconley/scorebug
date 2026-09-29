# Next session handoff

## Direction and checkout

Simulator-first; defer hardware/external hosts. Batch related changes, focused
checks only, retain passing evidence. No agents, pushes, broadcasts or purchases.
Preserve footage, recordings and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; [acceptance](../simulator-acceptance.md) owns retained results.

## Current finding and next action

Startingfe332cb. Short real measurement warmups isolate bandwidth-probe/backend
interaction: candidate-only/VideoToolbox proxy passes786consecutiveUHD frames;
probe-only/VideoToolbox proxy drops17SDK frames; probe-only/software proxy passes
790consecutiveUHD frames with0drops. Native hardware selected in all cases.
Artifacts `headless-native-fw3Zum`, `headless-native-LC8Cpq`, `headless-native-zDpc9c`
retain source patches and hashed `isolation-analysis.json`. Handles69955/28797/60166
joined0, cleanup empty. No normal adaptive/full-media pass claimed from these.
See [session](2026-09-28-uhd-probe-backend.md).

**ACTIVE: exec80423**, normal adaptive UHD with software proxy, duration330s,
source `artifacts/qa/uhd-app-20260928/input.mov`, timing-audit off. Artifact
`headless-native-nZ4tzv`, parent log `artifacts/qa/uhd-readiness-20260928/adaptive-software.log`.
No direct/fixed/freeze/warm flags. Source HEAD/patch saved before capture. Poll/join
this exact handle; observation timeout is not terminal. No other jobs active.
If UHD receiver/native cadence passes, export clean archive through native library
and verify actual archive/both output media. Otherwise inspect the reason first.

CPU proxy is a plausible working local4K path. Preserve local shared-VideoToolbox
limitation; its internal cause is not yet proven. Ongoing adaptive polling, publisher
setup, long runtime, guarded replacement and candidate encoding alone were excluded
as sufficient causes by the earlier short comparisons. No more speculative queue,
history-copy or timing changes. Use the55s direct path for targeted future fixes;
only repeat full climb for a material change, such as the currently tested backend.

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

Finite warmups require owned/fixed transition: `--warm-uhd-candidate on` and/or
`--warm-uhd-probe on`. Both actual owners join before the manual profile change;
the concurrent combination is available but untested. Runner now accepts
`--worker-encoder software|videotoolbox` (default VideoToolbox).

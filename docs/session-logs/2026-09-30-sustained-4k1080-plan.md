# September 30: sustained 4K recording / 1080p streaming plan

## Scope and starting state

User requested a systematic plan to sustain 1080p streaming with 4K recording on
the current device and fix the app exit at Stop. Planning only; no new capture,
builds, installation or runtime tests. Authoritative worktree:
`/Users/jd/.codex/worktrees/scorebug-local-validation`, branch
`codex/local-validation`, starting commit `978d27d`; clean at start. No agents.

Read current delivery plan, NEXT, hour acceptance, hour session findings, affected
archive/capture/adaptation/proxy paths and current physical harness options. The
archive memory fix is implemented/installed, but physical recovery/export and
fresh Stop remain unverified. Sustained1080 remains unqualified. No live jobs.

## Decisions

- Added the [focused implementation plan](../superpowers/plans/2026-09-30-sustained-4k-recording-1080-streaming.md).
  Normal configuration includes the clear case and USB charging on the home LAN
  with software proxy. Keep the present H.264/AAC/SRT architecture first.
- Final gate is60continuous minutes of confirmed actual1080p input after normal
  progressive startup/trial settlement, with4K/audio recording throughout. Output
  upscaling does not qualify. Source freshness, loss, thermal/resource trajectory
  and native stop/export/playback/relaunch are separate acceptance gates.
- First reuse the exact preserved interrupted hour recording on the fixed phone,
  then make a short fresh Stop check. Mac memory evidence strongly implicates the
  prior buffer retention; absence of an OS report prevents claiming confirmed jetsam.
- Instrument exact receiver-proof outcomes before choosing its fix. Reproduce the
  timestamp-cap omission and distinguish expected selection from overload without
  hiding actual lost frames. Retain genuine expiry/authority and pressure guards.
- Profile only the comparisons needed to isolate phone load. NV12, disabled
  HDR/stabilization, fair-temperature classification and UI polling improvements
  already exist. HEVC is conditional on measurement, not an assumed thermal fix.
- Add explicit harness modes before publishing new commands. One30-minute combined
  checkpoint must pass before the final hour; stop at an attributed failing gate.
  Reuse unaffected Watch/simulator evidence. Battery/case-off trials diagnose heat
  but do not replace the requested configuration's acceptance.
- Updated delivery milestones, NEXT, log index and the stale hardware-deferral
  sentence in fast iteration. Historical experiment details remain in the prior
  hour session log; no accepted status was changed.

## Research and review

Checked [Apple TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
for capture-drop classification and the public VideoToolbox hardware-encoder query.
Verified the query's iOS17.4 availability in the installed iPhoneOS SDK header;
the plan requires guards and distinguishes requested/verified/unknown acceleration.
Reused the existing platform adaptation research rather than inventing platform
thresholds or redoing the broader survey.

Documentation verification: reviewed goal/task coverage, exact local paths and
links, and checkbox scope. The local link/code-path validator returned no errors;
`git diff --check` passed. The focused plan is122lines, with all unresolved delivery
gates left unchecked. No application tests were run for this documentation-only
change. The final staged diff check includes the new plan and log.

## Next action

Execute task1 inline: narrowly selected recovery/export of saved recording
`33D2FF99-7918-42EA-8D41-9A5C076B2011`, preserving interrupted status and originals;
then a short new4K/audio Stop/export/relaunch check. Recheck phone/LAN availability
at execution time. Do not begin another hour or remote proxy work first.

# Physical adaptive upload debugging — September 29

## Request and scope

Diagnose why the physical phone stays at low upload quality on the local network,
and verify a real 1080p upload. Reuse the accepted paired scoring and simulator
vertical; run only affected checks and focused phone captures.

## Reproduction and cause

- Baseline `physical-recovery-aMWCVj`, software proxy, ordinary physical camera,
  explicit 700ms SRT peer latency; new `quality1080` lane uses existing confirmed
  240→360→720→1080 gates and stops before injected impairment.
- Attempt `3c95458b-14b9-427a-8190-d2d0d8484f8b` reached360p at600kbps,
  then reset240p. Its applied-transition journal proves the triggering five-second
  interval had150captured/encoded/received frames, zero lost frames, nominal
  transport/worker pressure and fresh, enclosing **fair** thermal samples.
- The source adapter incorrectly mapped fair to unknown, although the native
  candidate encoder permits nominal/fair. Unknown pressure caused trial rollback
  and blocked later healthy recovery. Telemetry gap at the transition is recorded
  separately; the first accepted trial window began within the existing5.25s
  allowance and the unknown thermal classification independently forced rollback.
- Apple calls fair slightly elevated; serious is high and critical significantly
  affects performance: https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/fair
  Policy choice: treat fair as known/non-elevated for foreground publishing while
  retaining all measured frame/loss/queue/transport checks and serious/critical
  fallback. Missing, stale or unenclosed samples remain unknown.

## Changes and focused checks

- Bounded DEBUG latest raw thermal/source health diagnostics expose decisions even
  when minimum quality produces no transition journal entry.
- Explicit physical quality1080 runner lane; existing production thresholds retained.
- Thermal mapping regression failed with unknown versus nominal before the fix;
  all45PublishingQualityTelemetryTests passed afterward.
- Physical runner option/environment tests:10passed.
- Baseline wrapper joined with cleanupFailures[]; saved original media retained.

## Second capture: genuine thermal pressure

`physical-recovery-WgC0Nr` confirms360p while fair: the mapping fix works.
At100s after recording start, fresh serious thermal samples trigger the existing
local-pressure reduction to240p. It does not reach720p; no1080 acceptance claim.
Capture/score/stop/export finish, wrapper joins, cleanupFailures[].
The tester waits out its150s720 gate because reset telemetry lacks a current
source owner; this is diagnostic-run inefficiency, not permission to admit stale
source observations.

The generated xctestrun was using PreferredScreenCaptureFormat=screenRecording,
adding continuous UI video capture to physical camera/archive/publisher/probe load.
For this physical diagnostic lane, select screenshots instead (the installed
XCTestCore/IDEFoundation recognize this format); production behavior unchanged.
Hypothesis: removing this extra encoder makes the thermal measurement more
representative. Environmental heating was also queried, without blocking work.
All PublishingQualityDriverTests pass with the bounded diagnostics.

## Verification in progress

`physical-recovery-SLSAw7` stopped before capture: temporary phone bridge port49173
refused connections. It is not a streaming/thermal result; wrapper joined with
cleanupFailures[], though the in-app bridge shutdown reported no listener.
`physical-recovery-oAiKrj` repeats with the same app and screenshots, fresh bridge
port49174. Preflight works and physical capture is active.
Do not treat this entry as acceptance before the workflow and media results land.

## Active-capture CPU root cause and fix

The screenshots-only `physical-recovery-oAiKrj` also reached serious temperature;
removing XCTest video alone did not resolve the heat. Its late CPU sample covers
stop/export and must not be called an active-capture profile.

`physical-recovery-HaIPwh` collected a25s Time Profiler sample automatically after
local publishing began (PID80038). Of24.750 sampled CPU-seconds,21.950 were on the
main thread;11.488 inclusive seconds were in AttributeGraph updates and9.869 in
SwiftUI render. Native video encoding was a minor app CPU consumer. Instrumentation
may affect the run, so this run diagnoses CPU work, not media acceptance.

The model published internal telemetry and control-busy flags at100ms cadence,
plus identical visible worker/command/settings/storage state. Root ContentView and
FilmView subscribe to the whole model, turning these into repeated full UI updates.
A regression counted228 UI notifications across ten ordinary polling cycles.

Fix: keep internal telemetry current without publishing it to SwiftUI, notify only
on actual visible state changes, publish controlBusy only while its setup sheet is
shown, and give the DEBUG diagnostic readout its own small observable object/view.
Health/control/probe cadence and acceptance rules remain unchanged. The regression
now sees zero redundant whole-screen notifications, while stop still notifies and
the diagnostic readout updates independently. All125CaptureStreamingModelTests pass;
38driver and45telemetry checks already passed.

`physical-recovery-uusTBV` now verifies the same real1080 ladder with both fixes and
a matching25s active-capture CPU profile. Prior lab processes are joined.

CPU comparison in matching25s captures: total sampled CPU24.750→11.525s; main
thread21.950→6.310s; SwiftUI render9.869→1.452s; AttributeGraph11.488→1.699s.
This verifies the redundant-publication fix materially reduces app CPU work.

## Remaining sender-retention gate

`physical-recovery-uusTBV` confirms360p and720p and remains fair throughout the
recorded health samples. At176.5s after recording request, a local transport
warning reduces720→240. Journal has230ms peak sender buffer,700ms negotiated delay,
350ms hard buffer ceiling,12.193ms RTT versus175ms ceiling, zero drops/retransmits.
This isolates the extra growing-retention heuristic as the reason, not thermal
pressure. It does not establish whether the buildup is sustained or a normal burst.
No policy thresholds changed. Preserve the distinction between a warning and
actual delivered-frame loss.

Added journal-only last12transport gauges (time, buffer-ms, buffered-bytes, sent,
retransmitted, RTT, pacing maximum, send period) to capture the next pressure cause;
excluded from the4096-byte UI diagnostic. The physical1080 lane now fails promptly
on a recorded downgrade even when the new revision lacks a source owner.
Focused transition test passes; signed build passes.
`physical-recovery-C1fA64` failed before capture on automation enable timeout; all
owned processes joined. User approved prompt. Current run `physical-recovery-T2Pdtv`
uses fresh bridge port49178 to gather the missing cause sequence.

SRT primary reference: https://github.com/Haivision/srt/blob/master/docs/API/statistics.md
(msSndBuf is instantaneous unacknowledged time span, not decoded loss).

## Final physical1080 acceptance

`physical-recovery-T2Pdtv/1080-acceptance.json` passes the consecutive production
240→360→720→1080 ladder at6Mbps. Attempt
`efa31f16-5dfc-407f-aec3-7a1738c7a999`; recording
`09C10C21-BA42-4461-8163-738502934B16`. The closed transition journal has exactly
three successful trial applications, no reset/rollback and no overflow.
Receiver geometry verifies1489frames240p,2249frames360p,2250frames720p and
1254 actual1920×1080 frames (about41.8s). Maximum receiver PTS step is3002/90000s.
Native1080 ACK occurs206.1s after recording request; confirmation222.8s. No thermal
or sender-retention downgrade occurs. This proves the short climb, not sustained
stability or fallback/recovery. Explicit700ms peer latency, software proxy,
screenshot-only XCTest, no Time Profiler in this final run.

Native phone point, stream stop, independent archive continuation and export pass.
Original phone export is copied without deleting it. Full strict H264/AAC decode:
clean1080 archive7555frames/251.84s, both overlaid outputs7242frames; no video gap
above50ms or audio gap above5ms, all track-end differences≤44ms. Visual spot checks
show the archive is clean and proxy score changes0–0 at20s to1–0 at233s. Initial live
audio precedes video by about1.56s; track-end agreement/encoded continuity do not
establish perceptual sync or full fresh-motion qualification.

Focused transport-journal regression additionally passes: selected raw gauges
persist in the bounded8192-byte journal, do not enter the UI diagnostic, and do not
overflow. Final focused counts:45telemetry,38driver,125capture-model,2transition,
10runner checks. Signed phone build and physical workflow pass. Diff reviewed for
observable-state consumers: removed publications are internal telemetry; actual
visible state still notifies, and setup control guards remain intact.

All owned wrappers, lab, profiler, export/copy, media verification and focused test
processes joined. No Watch rerun, agents, push or external stream. Plan and acceptance
matrix updated. Next work is sustained physical1080p and fallback/recovery; if the
retention warning recurs, use the new gauge sequence before changing thresholds.

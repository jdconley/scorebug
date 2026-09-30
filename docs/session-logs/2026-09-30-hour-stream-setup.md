# One-hour physical 4K recording / adaptive 1080p upload

User requested a one-hour audio/video run, 4K clean archive and1080p live stream,
then an explicit pause before capture for phone/TV positioning.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`, base2453ea7. No production behavior changes.

## Prepared and verified

- Signed physical build passes with the test-only preparation/hour modes. First
  build caught optional publishing-start time; corrected with XCTUnwrap and rebuilt.
- Native preparation test passes (98.759s): saved Score/Film connections join the
  new seeded match, normal app-loopback preflight passes, 4K selection and audio
  label verified. Phone storage166.65GB. Recording/streaming remain off. Original
  recordings/Keychain retained; no existing capture terminated.
- `artifacts/qa/physical-hour-preparation-20260930/prepare.xcresult` and exported
  attachments contain `PhysicalHourPrepared` and idle4K screenshot.
- Software proxy1080p30/RTMP+record, explicit700ms publishing peer latency,
  decoded-geometry diagnostics, real SRT relay and mock RTMP MP4 recorder are live
  in `device-lab-1wgb5o`. Normal capabilities keep4K recording independent and cap
  the normal upload ladder at1080p/6Mbps. Audio included in both.
- `caffeinate -ims` holds Mac awake while backend runs. Backend exec87395 remains
  live on purpose. Build88150 and preparation59573 joined0. No active camera/test.
- User approved the phone automation prompt during preparation.

## Paused before capture

Do not start until the user confirms phone/TV positioning. Live metadata and
expiry: `physical-hour-preparation-20260930/standby.json`. Backend standby is finite
(two hours from setup); verify it is live and sufficient lifetime remains before
starting. If expired, recreate backend and reprepare settings; old tokens are not
usable. No automation/goal was created.

After confirmation, execute `physical-hour-preparation-20260930/run-hour.sh` in
this checkout. It uses prepared `hour-ready.xctestrun`, real phone, screenshot-only
capture, fresh bridge49180, finite5400s runner allowance. The test selects4K, starts
recording/upload, retains normal startup/climb gates, samples quality/thermal/worker
and duration every30s, and holds until3600s after local publishing begins. Normal
adaptive fallback remains active; downgrade alone does not abort the hour hold.
Any initial confirmation failure remains recorded rather than becoming a pass.
It then stops streaming, observes independent archive continuation, stops capture,
and allows900s for native export. The hour hold/export are prepared but not yet run.

Estimated archive at30Mbps:13.5GB/hour, plus native export duplicate. Mac68GiB free
at preparation. Preserve phone originals. Collect exact new recording export and
closed transition journal; assess actual4K archive and1080 input geometry, whole
saved A/V decode/timestamps, audible content, quality duration/heat and continuity.
Then stop backend by writing `stop\n` to exec87395, join owned processes and report
acceptance accurately. A completed UI test alone is not whole-stream qualification.


## Active run and quality investigation (not final acceptance)

User said ready. Runner73033 and monitor69435 active; backend87395 retained.
Normal native4K capture/audio and proxy outputs started around07:09Pacific.
Early0–0→1–0 overlay observed; decodable audio present but low signal level.
User asked to explain drops during the hour; investigation continues without
restarting/rebuilding the phone. An optional charging/case question is pending.

Live XCTest session diagnostics expose applied transitions before the final result
bundle is closed. Parsed snapshots saved in
`physical-hour-preparation-20260930/live-transition-snapshots.json`. This is a
provisional subset; collect closed phone journal after export for authoritative
complete bounded history. Attempt2b50433b-0ecd-4a44-9fe6-8348a390b76a.

- Initial1080 trial resets to240 on `deliveryAuthorityChanged` /
  `telemetryInvalidated`. Last sampled source was healthy/nominal temperature.
  Need distinguish actual receiver context replacement from revocation/recreation
  after one temporarily unavailable/stale report; do not assert root cause yet.
- Recovery reaches1080/6Mbps and holds for about14minutes before a720 reduction.
  Transition7→8 reports151captured/encoded/received, zero source loss, healthy
  transport, fresh fair temperature, and **one omitted proxy frame**. Filter peak
  4.3496ms/processing7.1687ms, against250/1000ms limits. Code treats any omission
  as elevated worker pressure. Pipeline intentionally caps30fps by source timestamp
  buckets; omission can represent cadence normalization, not resource saturation.
  Distinguish intentional cap removal from overload;1/151=0.66% is below the plan's
  less-than1% stable-profile frame loss target. No policy changes during run.
- Subsequent reduction to240 reports fresh **serious** phone temperature with
  healthy transport and zero publisher queue. Phone heat is real OS evidence;
  physical cause (workload/charging/case/ambient) remains to be isolated. Current
  4K archive/outputs continue; no blanket home-network bottleneck conclusion.

Proxy stayed in producing_output with no pipeline restart; sampled process CPU
about51% of one Mac core. That is no evidence of CPU saturation. Apple recommends
reducing CPU/GPU/I/O at serious thermal state:
https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious
Camera guidance distinguishes occasional frame loss from chronically slow processing:
https://developer.apple.com/library/archive/technotes/tn2445/_index.html

Do not attach a profiler or run builds/tests against this live qualification.
Assess temperature timeline, identity changes and actual saved proxy omissions after
capture. Full saved media validator is prepared in the artifact directory, with a
single complete libavcodec/ffprobe decode per file to avoid three redundant passes.

User reports the phone was USB charging with Apple clear case, then unplugged it.
Report received around07:54Pacific (~44min); actual unplug time is approximate.
Treat later thermal recovery as an observational intervention, not controlled proof
of charging/case causality. Capture continues unchanged.


## Final hour result and preserved media

Run started14:09:35UTC; live output stopped15:09:52UTC. The one-hour hold and
archive continuation after stream stop completed. Phone app87865 exited while
stopping/finalizing recording before native phone export. Runner73033 joined65.
No current Scorebug termination report was available in the device crash listing;
do not label the OS termination reason confirmed. The adaptive initial1080
confirmation had already failed on a proof reset; the hour lane preserved that
failure and kept recording. Do not promote this workflow to green.

Exact recording33D2FF99-7918-42EA-8D41-9A5C076B2011 contains1815 committed bundles,
including initialization and1814media segments. Copied to
`physical-hour-preparation-20260930/phone-original-recording` without modifying
phone originals/status. Closed journal has10transitions, overflowfalse. Native
production ArchiveSegmentStore/ArchiveExporter on Mac recovered all13,672,251,222
payload bytes, verified checksums, remuxed and fully decoded the export. Completion
metadata remains interrupted; Mac recovery does not qualify phone stop/export.

`device-lab-1wgb5o/phone-clean-archive.mp4`:3840x2160 H26430Mbps/AAC48k mono,
3626.644s,108796 decodedvideo frames,174078912 decodedaudio samples. Packet-only
second pass matches native frame count; no video gaps>50ms/audio gaps>5ms;
minimum rolling5s encoded30fps; track ends15.667ms apart. This avoids a duplicate
full4K decode after native export already decoded every sample.

Both proxy and mock outputs fully decode via FFprobe/libavcodec explode:
108426frames each,3614.695s video. Minimum rolling5s encoded29fps, no window below24.
Seven shortvideo gaps, maximum200ms; strict zero-gap check fails, while unchanged
24fps/99% encoded-cadence gate passes. Whole-file30fps count deficit15/108441
(0.014%); do not infer stable-profile fresh-frame loss from this aggregate.
Audio has no gaps>5ms; track ends52.051/29.889ms apart. At3550s proxy audio peak
-10.03dBFS/RMS-39.75. Inspected clean and proxy snapshots show TV volleyball changing,
clean archive without Scorebug overlay, overlaid HOME1–0AWAY and visibly soft final
240p source upscaled to1080. Sampled motion/audio do not qualify full fresh-motion
or perceptual synchronization.

Actual decoder geometry (11runs, no overflow/invalid reason) confirms25,810actual
1080 frames,860.423s total; longest1080 span854.956s (~14m15s). Final64700frames
were240p. Final MP4 dimensions1080 are proxy output scaling, not evidence of1080
source throughout. `hour-acceptance.json` explicitly leaves sustained1080 false.

Proxy terminal/input108431frames versus108426submitted/output; five omissions.
One66.656ms gap at1274.079s matches the single omitted frame that triggered720
fallback; four latercap gaps cluster near2547s. Initial reset/transition gaps200/100ms
remain. Pipeline's explicit timestamp cap is its frame-removal stage; classifying
all intentional cap removals as resource pressure is an algorithm mismatch. Source
transition proof invalidation is also distinct from bandwidth failure: same worker
pipeline/publication throughout. The journal lacks the exact local tracker-rejection
reason, so add that reason before changing authority safety behavior. Revision9
was720→360 on serious heat, then revision10→240; it was not an1080 retry.

## Bounded archive memory correction

A production native recovery/export replay reached14,441MiB sampledRSS. Isolated
recovery-only replay on the exact saved archive confirmed13,772,488,704byteRSS after
verification, baseline7,127,040bytes. Temporary FileHandle/Foundation buffers
accumulated across the long recovery/copy job. This strongly explains the phone
stop failure, but a device OS termination record/recheck is still required.

Initial128MiB single-pass memory assertions did not expose the failure. Refined
nine-pass recovery/assembly within one outer pool reproduced retained payloads:
recovery+1,213,628,416bytes, assembly+1,078,231,040bytes, each exceeding32MiB.
Only then changed production `Disk.verifyAndCopy` to drain an autorelease pool for
each1MiB read/hash/write. Size bounds, checksum validation, exclusive paths, final
sync and errors are retained. No adaptation thresholds/thermal guards changed.

Focused20ArchiveSegmentStore tests pass, including both memory regressions and
corruption/symlink/exclusive-write cases. Fixed production recovery-only replay
verifies same1815segments/13.7GB in7.965s with35,110,912byteRSS (about33.5MiB).
Unfixed isolated replay takes9.190s with13.8GBRSS. Signed incremental iPhone build
passes; updated app installed, not launched for another capture. No fresh hardware
stop/export or full simulator/Watch rerun. Self-review checked buffer lifetime,
EOF/growth/checksum handling and cleanup. User's no-agent constraint retained.

Artifacts under `physical-hour-preparation-20260930`: archive-memory-red-refined.log,
archive-assembly-red-refined.log, archive-memory-green.log, real-hour-recovery-memory-
baseline/fixed.json, archive-memory-ios-build.log, fixed-app-install.json,
hour-media-validation.json, native-recovery-export.json, actual-source-geometry.json.
Native helper links unchanged pre-fix FilmModel media object for baseline/recovery;
fixed isolated helper links current SwiftPM media objects. Preserve these distinctions.

## Cleanup and next work

Backend87395 joined0 after capture stopped; worker exit0, receiver sessionfinished,
shutdown failures[]. Monitor69435 joined0. Copy/export/validation/build/install
processes joined. Media validator exits1 only for the retained strict zero-gap gate;
all decodes and encoded cadence targets pass. Xcode/phone test exits65 remain failures.
No original recording/video/simulator cleanup, external broadcast, agents or push.

Next: verify updated phone recovery/export using this exact hour archive, followed
by a short stop check if needed. Address cap-omission pressure and local receiver-proof
reset with saved-window replays/instrumentation, then isolate phone thermal load.
Do not rerun an unchanged hour or disable serious-thermal/authority safeguards.

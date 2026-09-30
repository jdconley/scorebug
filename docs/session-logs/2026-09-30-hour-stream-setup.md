# One-hour physical 4K recording / 1080p upload preparation

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

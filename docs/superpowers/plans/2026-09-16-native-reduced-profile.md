# Qualify a reduced live profile with independent full-resolution recording

The isolated 960×540 profile reduces structured-source video payload to 3.521 Mbps.
It is a candidate, not an established 4 Mbps network fallback. The next gate is a
fixed-profile full native run before dynamic encoder replacement.

Add an immutable publishing profile argument to the maintained SRT adapter. Keep
1080p30/6 Mbps as its default; add 540p30/1.5 Mbps as an explicit choice. Audio and
local archive settings remain independent. Select the reduced profile only through
an explicit DEBUG simulator qualification flag in the app. The existing production
app continues to choose the default. Add matching 540p30 portable worker output.

The runner accepts only `SCOREBUG_TEST_LIVE_PROFILE=540p30`, with structured motion,
direct output recording, publication/processing evidence and at least a 90-second
hold. Reject combining this fixed profile with the adaptive-quality flags. Permit
the owned uplink proxy for this separately validated mode while preserving every
existing adaptive-mode prerequisite. The UI/app boundary also validates the choice.

Keep the decoded local archive at 1920×1080 and require 960×540 live output. Scale
only the barcode/score sampling coordinates for live video, and retain frame
identity, >=24 fps, <=1% loss, full decode, A/V sync, post-stream local continuation,
archive diagnostics, source/processing/publication and direct-recorder gates.
Measure the reduced output payload without claiming the existing 1080p workload
calibration band applies to it. Label reduced-profile success diagnostic: neither
native bitrate adaptation nor dynamic profile changes are qualified by a static run.

Run pure option/dimension tests, streaming profile and app fixture tests, worker
profile/pipeline tests and relevant regressions. Run a native pass-through baseline,
then assess measured wire use before the scheduled 4 Mbps experiment. Retain any
failed attempts and normally finalize/export local recording when live checks fail.
Dynamic transitions, real-camera visual quality, physical phone/Watch and other
hosts remain separate required gates.

## Pre-worker source-profile proof

The worker scales its input, so live output dimensions alone cannot prove the phone
sent 540p. Add an immutable, optional pre-mux scalar observer to the maintained SRT
stream. It reads dimensions/codec/PTS/readiness from each actual compressed buffer,
including final drain, without retaining media or changing delivery. The app's
DEBUG fixture keeps a constant-size per-attempt accumulator; generation, format,
invalid payload, non-encoded passthrough, non-increasing PTS and count overflow latch
invalidity. Persist only after joined adapter stop. Scope includes recording, match,
broadcast generation and publishing attempt. The verifier matches every encoded
callback count and first/last source identity, native publishing generation and
actual 960×540 dimensions. Reject native 1080p even if the worker output is 540p.

The later network budget uses publisher-side proxy traffic, never post-worker video
payload. The callback is optional and inert for existing callers. Tests cover actual
sample metadata, invalid payload, scope/format/generation changes and bounded memory.

## Implementation checks and retained attempts

The pre-mux observer copies actual metadata from compressed samples, including the
final drain. Its `wasEncoded` provenance comes explicitly from the encoder-output
versus passthrough call site, not mutable latest-input state. Native SDK tests check
five delivered frames with exact source timestamps, dimensions and generation.
The 540p overlay samples grayscale before cropping so its odd 375-pixel width and
odd 465 vertical offset are not rounded by YUV chroma subsampling: real FFmpeg output
is 22500 bytes, versus 22440 with the prior crop-first order.

All 55 streaming package tests, 135 vendor SDK tests, 183 app-model tests and 908 tooling
tests pass. The worker's parallel run hits five existing one-second child-process
readiness/exit deadlines; the complete serialized rerun passes all 334 tests and
worker typechecking. The original failures remain retained, without weakening their
deadlines or changing worker supervision.

`native-app-GQBAf6` stops at the UI environment guard before launching the app: the
new build setting was not yet forwarded by the Xcode scheme. Add the explicit scheme
environment entry and repeat. The guard correctly rejects a missing profile instead
of silently validating the default 1080p path. No capture occurs in this attempt.

## Full native pass-through result

`native-app-g2yQ6I` passes the fixed-profile diagnostic. Actual pre-mux metadata
qualifies all 3293 native encoded frames (157–3449) at 960×540. The worker/direct
recording preserves all 3258 acquired frames (192–3449) at approximately 30 fps,
zero source loss, 201 changed score pixels, complete A/V decode and sync. All 3665
local frames (0–3664) remain 1920×1080 at 30 fps with zero source loss. Archive state
is finished, persistence complete and first failure absent. Native UI scoring,
post-stream local continuation, source/publication/processing/age and direct
recorder gates pass. There are no Sendable conversion warnings in this repeat.

The owned phone-side proxy conserves 53,254,388 forward wire bytes over 110.463 seconds
between first and last forwarding: whole-publication mean 3.857 Mbps. This includes
UDP/IP/SRT/audio/muxing/retransmission traffic and startup/tail; it is not a steady
peak or a capacity guarantee. Worker-output compressed video averages 4.440 Mbps and
must not be substituted for phone uplink traffic. Schedule the actual 4 Mbps phone
uplink test because its margin is narrow. Evidence remains diagnostic, not dynamic
resolution/adaptation or physical-camera qualification.

## Scheduled 4 Mbps result

`native-app-cxuzn7` passes the fixed 540p diagnostic with the 180-second hold.
The phone-side cap applies for 60.000137 seconds and forwards 29,097,120 wire bytes
in that phase (3.880 Mbps mean), with zero overflow or other drops. Forward traffic
continues for 81.520 seconds after the cap is removed. All phases and packet/byte
conservation qualify. Across the publication, 92,989 forward packets carry
97,463,164 wire bytes (3.869 Mbps whole-publication mean). This remains a narrow
margin on this deterministic fixture, not a general capacity guarantee.

Actual pre-mux evidence qualifies all 6025 native 960×540 frames (157–6181).
The direct recorder preserves all 5990 acquired live frames (192–6181), through the
final encoded frame, at approximately 30 fps with zero qualified source loss.
The 35-frame acquisition interval remains explicit. There is no encoded tail.
Worker output averages 4.441 Mbps compressed video; this is a separate network leg
and does not contradict the measured phone-side cap. Native scoring changes 187
sampled overlay pixels. Full A/V decode, sync, source/publication/processing/age and
direct-recorder checks pass.

The independent local recording preserves all 6365 consecutive 1920×1080 frames
(0–6364), 212.167 seconds at 30 fps, including recording after streaming stops.
Its full decode and A/V sync pass, terminal state is finished, persistence is
complete, timing is valid and no first failure is recorded. The independent
read-only evidence review finds no blockers. Automatic profile reduction and
recovery have not been implemented or qualified by this fixed-profile test.

## Next gate: deliberate transitions before automatic selection

The existing SDK settings setter invalidates the encoder when video size changes;
the next input installs a session and invalidates its predecessor. That behavior is
not yet proof of a lossless live transition. First qualify a deterministic
1080p→540p→1080p sequence with exact encoder-session and source-frame ownership,
including outstanding callbacks, fresh keyframe/format headers and final drain.
Bound transition work and queues; stop/cancellation must win over a pending change.
Do not let a late completion from the previous session claim the new profile.

Then exercise the same sequence through SRT, worker decoding and output recording
while the local 1080p archive continues. Evidence must distinguish every format
interval and transition loss; the fixed-profile accumulator deliberately rejects
mixed dimensions and cannot be reused as a transition verifier. Only after these
gates should the quality policy choose profiles automatically under the scheduled
bandwidth limit and verify subsequent upward recovery. Real-camera quality,
thermal behavior and long adaptive runs remain necessary afterward.

## Default 1080p regression

`native-app-9zxvu3` passes the existing structured-motion, pass-through quality-loop
run without the reduced-profile flag. Both outputs remain 1920×1080: 3635 local
frames (0–3634) and 3209 acquired live frames (215–3423), approximately 30 fps with
zero qualified source loss. Normal archive finalization/persistence, native scoring,
full decode/sync, publication/processing/age and direct-recorder checks pass.
The native control verifier records 17 evaluations, two trials, two confirmations,
zero rollbacks and final requested bitrate 7.26 Mbps. This proves the existing
control/receipt regression gate, not achieved payload-rate or capacity control.

Reproduce the reduced-profile experiment with the selected licensed Xcode and the
following explicit fixture settings; use `passthrough` and a 90-second hold for its
baseline. Do not set the native quality or confirmation flags for either fixed run.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
SCOREBUG_TEST_RELAY_PUBLICATION=1 SCOREBUG_TEST_WORKER_PROCESSING=1 \
SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_MOTION_FIXTURE=blocks16 \
SCOREBUG_TEST_STREAM_HOLD_SECONDS=180 SCOREBUG_TEST_LIVE_PROFILE=540p30 \
SCOREBUG_TEST_UPLINK_PROFILE=rate4m pnpm test:native-streaming
```

The unsigned combined iPhone Release build succeeds and validates the embedded
Watch app (`native-reduced-release.log`). This is compile/package validation, not
signed installation or physical Watch networking qualification. The independent
read-only reviewer approves the completed default regression and its source/receipt
claims. All owned native and build processes have exited before evidence hashing.

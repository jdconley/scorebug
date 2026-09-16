# Preserve the SRT reader through damaged H.264 timing

The adaptive pressure repeat identified a terminal H.264 DTS-extractor error in
MediaMTX's SRT reader after publisher MPEG-TS/PES decoding warnings. Continue the
authorized plan with a causal regression before changing the reader or rerunning
native pressure. Use a fresh pinned archive and cumulative Scorebug patch, with
unchanged Go dependencies. Show a complete picture-order sequence succeeds, then
reproduce the failure by removing pictures without changing remaining timestamps.

On timing failure, stop emitting undecodable video and seek an IDR with valid
parameter sets. Reset only that reader's H.264 timing state at the recovery point;
preserve input PTS and reject a replacement DTS behind the last emitted DTS. Keep
healthy B-frame handling unchanged. Audio continues through the same writer and
session. Waiting uses bounded state, at most 300 video access units and ten seconds
(checked on arriving video); exhausting either bound fails the reader. After established output is damaged, a recovery candidate must pass bounded
SPS/PPS/slice-prefix association and timing checks. This is not full PPS/pixel
validation; healthy extraction, upstream initial header parsing and pre-helper
NAL handling remain unchanged. Initial waiting is also bounded. A successful timing check does not by itself count as healthy video.
Fixed diagnostics report recovery; existing independent checks still see every
omitted frame. Do not synthesize timestamps or relax media qualification gates.

This preserves a useful stream through transient damage. Blindly ignoring timing
errors risks invalid timestamps; terminating every reader forces a destination
reconnect even when the next IDR could restore decoding. The shared MPEG-TS H.264
path serves SRT reads and forwarding; tests must cover the integrated writer.

- [x] Reproduce picture-order loss against the unchanged extractor.
- [x] Add failing tests for valid IDR recovery, malformed data, clock continuity,
      timeout/count bounds, healthy B-frames and parameter changes.
- [x] Implement and integrate bounded recovery; verify same-reader video recovery
      and uninterrupted audio on original source timestamps.
- [x] Run relevant Go and race checks sequentially; review.
- [x] Regenerate the vendor patch and verify pinned originals, clean apply, exact
      source round trip and evidence hashes.
- [x] Build a separately versioned ARM64/AMD64 qualification image and probe it.
- [ ] Qualify controlled transitions and actual adaptive pressure with unchanged
      archive, source-loss, frame-rate, A/V and quality-policy gates.

Independent follow-up: the local RTMP fixture must accept sequential connections
without overwriting or concealing earlier recordings, with joined cleanup and
qualification spanning every attempt. Helper or reader success alone does not
complete adaptive qualification or the portable streaming/Watch objective.

## Causal and integrated checks

The fresh source is `artifacts/qa/ingest-recovery-source`, verified against the
pinned archive and all original-file hashes before applying the existing patch.
The complete synthetic timing sequence preserves every DTS. Removing pictures
7–21 without altering the remaining PTS reproduces `too many reordered frames
(14)` in the unchanged extractor. These are syntax-only access units testing the
actual timing parser; they do not demonstrate pixel decodability.

The actual FromStream/Stream reader regression then failed with that same terminal
error before integration. After integration, one reader remains active, resumes
video at a new IDR with original source PTS, and writes all eleven test audio units
with exact original timestamps and payload order. The encoded MPEG-TS is parsed
back independently. No access unit is invented to cover the loss.

Helper coverage includes unchanged B-frame DTS, parameter changes between parsed
1920×1080 and 1280×960 SPS/POC formats, initial acquisition, malformed/empty headers,
missing parameter sets, regressed restart timestamps, and original (non-extended)
recovery deadline/discard limits. Full MPEG-TS, SRT server and SRT forwarding Go
tests pass, as do their race checks. Native pressure was rerun; its remaining failures are recorded below.

Review reproduced malformed PPS and POC-type-2 header acceptance (four failing
regressions). Recovery now bounds PPS/slice prefix inspection to 128 bytes, checks
SPS/PPS/slice IDs and legal IDR reference/type/frame/field/POC prefix fields, while
preserving startup behavior. Valid POC-type-2 and interlaced recovery headers pass;
truncated/mismatched recovery headers fail. The generated fixture now uses legal I
slice headers. Review approves the scoped recovery implementation.

The cumulative vendor patch cleanly applies to the pinned archive, matches every
tested touched/added source byte, reverses cleanly, and restores 15 pinned original
files with all eight added files absent. See `ingest-recovery-provenance-final.json`.
Unified patch context has intentional marker-space-before-tab and blank context
lines; whitespace checks pass on actual Go source and other repository changes.
The separate image/binary version is `recovery-v1`; clock-v2 remains available.


The first new-image clock run (`relay-clock-Wglefu`) preserved all 180 acquired
pictures and their decoder timestamps, but correctly failed its unchanged warning
gate: normal startup waiting was logged as lost timing. The integrated writer test
reproduced the misleading startup warning/recovery pair; logging now requires
previously established video. Actual damage still emits exactly one loss/recovery
pair. No media or warning qualification gate was relaxed. The corrected build
passes all three relay-clock cases in `relay-clock-lBv5J8`: zero origin (180
pictures), nonzero origin (181), late reader (121), each with the expected −9000
tick relay offset and production-decoder timestamp preservation.

Both ARM64 and AMD64 images build, report the separate recovery version, and
leave no probe containers. AMD64 executes under Docker emulation, not on qualified
native AMD64 hardware. Exact immutable image IDs are in
`ingest-recovery-images.json`. The actual adaptive pressure run uses the final
ARM64 image with unchanged 240-second hold and qualification gates; its artifact
is `native-app-JD0l78`, with an exact pre-run changed-source snapshot.


## Native pressure follow-up

`native-app-JD0l78` reaches the prior failure condition. Sanitized ingest evidence
records publisher PES warnings at 13:17:06–07 UTC, reader timing loss at 13:17:08
and recovery at 13:17:10 without closing that reader. Later, the publisher and
reader close at 13:17:46. The quality owner records the pressure-driven 1080→540
change at 61.54 seconds and receiver evidence of healthy 540p windows, then a
higher-profile trial recommendation at 100.91 seconds and `native-change-failed`
about 310 ms later. This is progress on the reader failure, not adaptive success.

The next causal lead is the remaining recommendation deadline: policy source sets
`validUntil = window.end + 2`, leaving only 227 ms at this trial's evaluation.
Earlier native transitions measured 340–430 ms. The arithmetic and event timing
are retained in `trial-deadline-correlation.json`; the underlying native error is
not captured, so deadline exhaustion remains a hypothesis pending reproduction.
Do not extend telemetry freshness or acknowledge a late/failed native change merely
to pass. Reproduce separately and distinguish fresh-advice admission from bounded
native execution. The UI workflow remains failed.

Independent archive verification passes: all 9824 consecutive 1080p/30 frames
(327.47 seconds), every source barcode from 0 through 9823, all 163 A/V markers,
zero archive rejected/dropped samples, 0.0209 ms maximum marker offset and 20 ms
A/V end offset. Finalization stopped recording and exported normally after live
failed. The recorder and all owned native-run processes have joined.

Receiver telemetry contains one five-second window with only 28 fresh frames
(5.6 fps), so the 24 fps gate is still unmet even before the later failed trial.
The one worker accepts 2865 decoded frames and emits the same output count, with
101 input decode-error diagnostics around damaged input and an input I/O error at
closure. Its zero exit code alone does not establish stream health. The uplink
schedule also fails its unchanged recovery-traffic coverage check because the
publisher closed before that phase; same-reader recovery is not full recovery
qualification. No reconnect behavior was tested by this one-worker run.


The retained live MP4 also decodes completely with FFmpeg `-xerror`, but decode
success does not remove its gaps or qualify its frame rate. Final source and
terminal artifact hashes are recorded in
`artifacts/qa/ingest-recovery-final-verification.json`. This checkpoint changes
the qualification ingest image only; production automatic adaptation remains
disabled. Next reproduce the trial deadline failure, then qualify timely pressure
response and recovery before treating native adaptive streaming as complete.

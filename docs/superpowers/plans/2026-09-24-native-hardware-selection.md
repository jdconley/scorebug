# Observe actual native encoder selection

Status: design independently reviewed; implementation not started. Continue
autonomously in the isolated checkout after the complete passing `23f0479` native
fixture. No change to encoder selection, buffering, quality or policy authority.

## Problem and evidence

The `f35cbd0` representative 4K campaign passes two 12-second cases. The third
finishes streaming normally but encodes/delivers 350 of 360 frames, with 23 frames
in one aligned second and a maximum native conversion of 65.576 ms. All archive
frames and audio survive. The selected native encoder is not measured; requested
settings cannot establish hardware selection or hardware contention.

Apple exposes an actual selection Boolean through `VTSessionCopyProperty`:
[UsingHardwareAcceleratedVideoEncoder](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder).
The installed Xcode 26.2 `VTCompressionProperties.h` also states that hardware is
enabled by default on macOS 10.15+, and that Enable/Require preferences belong in
the creation encoder specification. This milestone only observes selection.

## Reviewed design

When a submission observer is supplied, query once after a compression session is
prepared in `VideoCodec.prepareSession`, before independent native conversion.
Keep the query on the owning actor. Do not query for decompression or when the
observer is absent. Scope native access to macOS initially, using the existing
property key; other platforms report intentional omission.

Add optional immutable scalar evidence to `VideoEncoderSubmission`, with distinct
outcomes: hardware, software, read failure with native status, missing value,
invalid native type, and not queried on platform. Nil means diagnostics disabled.
Check nonzero status first, then nil, then exact `CFBooleanGetTypeID()` identity.
A numeric NSNumber(0/1) is not Boolean evidence; a Boolean-backed NSNumber is valid
when its CF type is Boolean. Every outcome is nonfatal. Do not retry or infer
software from unavailable evidence.

Cache one `(encoder revision, classification)` pair. Clear on session assignment;
validate revision before and after querying. Retain the cached value across a
same-session bitrate update. Capture only the scalar in `VideoSubmission`, so late
observations remain tied to their original session. Describe it as selection
queried after preparation, not a fresh per-frame measurement or utilization rate.

`DualOutputSmoke` serializes it after stop inside the existing bounded 512-row
submission trace. Campaign diagnostics join/group exact session IDs and require
stable cached classification per session. Hardware selection is never a stream
success gate and never grants health, capacity or upgrade authority. All existing
frame, decode, archive, audio and cleanup gates remain intact.

## Execution and verification

- [ ] Add failing native tests for true/false, exact CF type, nonzero status with
      and without a value, missing value and platform omission.
- [ ] Implement the optional selection snapshot. Verify zero reads when disabled,
      one read across many submissions, same-session bitrate retention, replacement
      requery, notification/close revision fencing and no decompression access.
- [ ] Export bounded diagnostic JSON from the native file sender and cover the
      export/join contract without granting streaming authority.
- [ ] Independently review implementation. Regenerate and round-trip the maintained
      vendor patch/provenance. Run meaningful vendor and clean consumer tests/builds;
      public Swift struct changes require clean dependent builds.
- [ ] Freeze source hashes. Run a capped serial representative 4K campaign through
      the portable proxy, preserving every attempt and stopping on the first failed
      gate. Verify clean archive, full decode, frame counts/cadence, audio and cleanup.
- [ ] Record observed encoder classification and timings. Unknown remains unknown;
      hardware=true alone does not establish contention. Choose the next fix from
      evidence and update the main plan.

No original match video is changed or uploaded. Physical phone/watch, long thermal
runs, impaired networks and remote hosts remain separate qualification work.

# Observe actual native encoder selection

Status: diagnostic milestone complete. Implementation/review/tests and a frozen
representative campaign establish actual native hardware selection, while one 4K
hardware-proxy case still drops frames. Two separately declared CPU-proxy controls
pass. Sustainable 4K remains unqualified. No encoder preference, buffer limit,
quality threshold or policy authority changed.

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

- [x] Add failing native tests for true/false, exact CF type, nonzero status with
      and without a value, missing value and platform omission.
- [x] Implement the optional selection snapshot. Verify zero reads when disabled,
      one read across many submissions, same-session bitrate retention, replacement
      requery, notification/close revision fencing and no decompression access.
- [x] Export bounded diagnostic JSON from the native file sender and cover the
      export/join contract without granting streaming authority.
- [x] Independently review implementation. Regenerate and round-trip the maintained
      vendor patch/provenance. Run meaningful vendor and clean consumer tests/builds;
      public Swift struct changes require clean dependent builds.
- [x] Freeze source hashes. Run a capped serial representative 4K campaign through
      the portable proxy, preserving every attempt and stopping on the first failed
      gate. Verify clean archive, full decode, frame counts/cadence, audio and cleanup.
- [x] Record observed encoder classification and timings. Unknown remains unknown;
      hardware=true alone does not establish contention. Choose the next fix from
      evidence and update the main plan.

## Implementation verification

`VideoEncoderSubmission.selectionQueriedAfterPreparation` captures a typed,
optional selection outcome under its encoder revision. The query is macOS-only
and observer-enabled; both missing and failed reads remain cached and nonfatal.
The native tests cover exact CF type/status precedence, one read per session,
same-session bitrate updates, notification/replacement/stop/restart ownership,
disabled diagnostics and decompression. Non-macOS omission is compiled in the
clean arm64 simulator build; its conditional vendor test is not executed on macOS.

All 312 vendor tests, 12 clean SDKProbe tests, 170 clean Streaming tests and 3,434
tooling tests pass. The fresh simulator derived-data build passes. Vendor patch
verification reproduces all 162 original hashes and an exact round trip. The first
SDK build/clean commands raced for SwiftPM's build lock; that test is not counted
as clean evidence. Both were joined, executable absence after clean was verified,
then `hardware-selection-sdk-clean2` built/tested successfully from that state.

The campaign join accepts hardware, software and each explicit unavailable outcome;
it rejects changed classification inside one session or corrupt diagnostic fields.
Its output grants only diagnostic identity, never media success or capacity.
The capped six-case real 4K runner preserves attempts and stops on the first failed
gate. Its failed second case is retained below.

## Frozen representative evidence (`bd7accb`)

All four native sessions below report hardware selection after preparation. That
is a cached session property, not per-frame utilization or proof of contention.

| Proxy / case          | Live frames | Archive frames | Median native call | Outcome              |
| --------------------- | ----------- | -------------- | ------------------ | -------------------- |
| VideoToolbox 1        | 360         | 360            | 0.194 ms           | Pass                 |
| VideoToolbox 2        | 348         | 360            | 33.444 ms          | Fail; campaign stops |
| CPU/libx264 control 1 | 360         | 360            | 0.215 ms           | Pass                 |
| CPU/libx264 control 2 | 360         | 360            | 0.225 ms           | Pass                 |

The failed case misses source frames 94, 98, 102, 105, 108, 112, 116, 120, 124,
128, 239 and 296. Aligned seconds contain 30, 30, 30, 23, 27, 30, 30, 29, 30,
29, 30 and 30 frames. Native calls peak at 65.667 ms; callback latency rises
sharply around source second two. Both hardware-proxy sessions finish normally,
so successful shutdown alone cannot qualify the stream. Cases 3–6 are not run.

The separate CPU comparison was declared before execution, capped at two cases,
and changed only proxy encoder choice plus output namespace/case cap. Both pass.
This supports further investigation of shared hardware pressure; time ordering,
background work and resource scheduling are not controlled, so causality is not
established. Do not force hardware preferences or enlarge publishing queues.

Every archive retains 360 frames and 576,000 audio samples, with zero rejection.
All eight MP4s fully decode. Real-audio correlation at 1/5/9 seconds passes in
every output (minimum correlation 0.9856, maximum lag 67.25 ms, no measured drift).
All eight owned SRT/RTMP ports are released and sender/proxy processes are joined.
All 1,167 tracked files and both native executable hashes remain unchanged.

Evidence under `artifacts/qa/match-footage-n6n1f13m/`:
`native-hardware-selection-assessment.json`, `native-hardware-selection-timing.json`,
the selection and CPU-control postmedia/audio summaries, plus every original case.
`artifacts/qa/hardware-selection-source-verification-final.json` records the freeze.

Use the measured CPU proxy path for further local integration; retain the failed
co-located 4K hardware-proxy route as unqualified. Next return to the outstanding
paired-Watch simulator integration, while longer representative replay and eventual
separate-host GPU tests remain in the main plan. None of these short runs qualifies
automatic 4K adaptation, original HDR/60 fps, camera capture, thermal endurance,
relay acquisition, physical devices, network impairment or remote deployment.

No original match video is changed or uploaded. Physical phone/watch, long thermal
runs, impaired networks and remote hosts remain separate qualification work.

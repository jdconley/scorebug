# Native app profile transitions

Continue the stream-lifecycle gate from `a01651b` under the existing autonomous
implementation authorization. Use inline TDD and the existing read-only reviewer.

## Design

Carry a typed live profile and a validated historical format receipt through the
streaming adapter and PublishingSession. Profiles belong to ScorebugMedia (plain
values); the HaishinKit settings mapping remains in ScorebugStreaming. Preserve the
existing ScorebugStreaming type spelling for source compatibility. The receipt
contains requested profile, actual dimensions, old/new encoder IDs and source PTS,
publication generation, raw queue eviction count, and adapter acknowledgment time.
It does not attest achieved bitrate, worker output or current readiness forever.

Use one mutation admission slot for bitrate and profile changes. Both remain
independent of capture and the archive, reject overlapping mutation, and participate
in terminal shutdown. Deadlines and cancellation retire the live attempt after
possible native mutation; shutdown must join the underlying native replacement
before persistence or observation closure. A profile receipt clears the previous
bitrate receipt, which belongs to the replaced encoder.

After typed lifecycle tests pass, add an explicit DEBUG simulator transition fixture
that requests 1080p→540p→1080p at fixed elapsed/source boundaries. It must retain
bounded per-phase actual compressed-format/session/source evidence and the two
receipts after joined stop. Do not reuse the fixed-profile accumulator, which
correctly rejects mixed formats. Production automatic selection stays disabled.

Qualify that fixture through the local worker and direct recorder while the local
archive stays 1080p. Match actual native intervals, source identities, receipt
boundaries, frame loss and output gaps; require complete decode, >=24-fps sustained
coverage, A/V sync and a normally finalized independent archive. Worker output
scaling must not stand in for proof of phone encoder format. Retain failed media
and diagnostics rather than weaken the gates. Then test constrained uplink recovery.

## Work

- [x] Add typed profile/receipt values and constructor tests, preserving profile
  settings and default1080 behavior.
- [x] Add adapter profile mutation with cancellation/stop ownership and mutual
  exclusion with bitrate; test rejected state, late native results and error privacy.
- [x] Add PublishingSession profile admission, two-second deadline, receipt/scope
  validation and joined shutdown; preserve existing bitrate tests.
- [x] Add the controlled app fixture and runner/verifier options with strict flag
  prerequisites, real phase receipts and bounded scalar evidence.
- [x] Run Mac packages and app-model tests, unsigned iPhone/Watch build, then the
  owned simulator full-pipeline experiment sequentially. Inspect actual decoded
  output and archive evidence before claiming the transition qualified.
- [x] Review, record terminal evidence hashes and commit this controlled transition slice.
- [ ] Continue into pressure, recovery and remaining physical/device/other-host gates.

## Typed API checkpoint

`PublishingVideoProfile` now belongs to ScorebugMedia, with a source-compatible
ScorebugStreaming type alias and the native settings mapping left in Streaming.
The new receipt validates dimensions, ordered numeric source PTS, different encoder
IDs, publication generation and acknowledgment clock. It carries actual pre-mux
format evidence only, never an achieved bitrate or receiver-delivery claim.

PublishingSession owns one shared admission/task/deadline for bitrate and profile
mutations. The two-second admission cap is preserved; overlap is rejected before
native dispatch. A profile receipt clears the old bitrate receipt. Cross-kind
checks reject source rewind, missing post-profile bitrate source, and reuse of
known retired or previously observed encoder IDs. They do not assume that every
native encoder recreation is observable in the receipt history. Cancellation,
deadline, bad receipts and native failures retire the attempt, join the owned
operation, and preserve only committed historical evidence.

Both streaming adapter layers join native profile work during shielded stop.
Review exposed an existing-startup interaction with the newly cached native stop:
a late unowned connect could reopen after stop. SRTPublisher now owns startup,
rejects stopped/cancelled/duplicate admission before native dispatch, joins it and
closes again after late completion. Configure also rejects a stopped attempt.

Retained red tests demonstrate the initial missing APIs, cross-kind source rewind,
stopped native startup/configure admission, and retained encoder-ID reuse before
the fixes. Source review approved the corrected startup/stop ownership and receipt
checks. The app continues to select fixed profiles until the separate controlled
transition fixture and decoded downstream qualification are implemented.

Validation for this API checkpoint: 186 media XCTest tests plus 66 Swift Testing
tests, 61 streaming tests, 183 app-model tests, and unsigned combined iPhone/Watch
Release build pass with Xcode 26.2. Test/build processes ran sequentially and were
joined before hashing evidence. No SDK sources changed in this slice. Evidence is
recorded in `artifacts/qa/app-profile-final-verification.json`.

The remaining checkboxes above are deliberately open: this checkpoint exposes the
API but does not yet wire the paced app fixture, run decoded worker transitions,
or qualify automatic resolution adaptation. The next slice adds an explicitly
selected DEBUG simulator fixture with bounded three-phase format evidence and two
validated receipts, runs it through the direct local recorder, and checks the
independent 1080p archive before pressure/recovery work.

## Controlled app experiment and worker format changes

The explicit `SCOREBUG_TEST_PROFILE_TRANSITIONS=1` runner mode requires streaming,
processing/publication evidence, direct recorder, blocks16 motion, and a 90–600 second
hold. It rejects fixed540, automatic bitrate, confirmation and uplink modes. The
DEBUG simulator factory alone creates the wrapper. The schedule changes the live
profile after 20 seconds, then restores 1080p 40 seconds after that receipt. This
is a controlled experiment, not an adaptive policy. The production default remains
1080p and the archive configuration stays independent.

Evidence version 2 contains bounded three-phase actual compressed format intervals,
three independently observed native encoder sessions, and two validated receipts.
Every encoder ID/source interval/count must match the compressed-format phase and
receipt. Native completion and compressed-output observation clocks are separate;
receipts cannot precede the first completion or observed new output. Export waits
for schedule cancellation, PublishingSession stop, and all native callbacks. No
media buffers are retained by these observers. The verifier checks decoded identities
through every phase, native phase tails, complete coverage and the existing A/V,
archive, worker and scoring gates. Source-time cadence is not wall-clock delivery
latency; measured callback/output pauses are reported separately.

The first complete simulator attempt, `native-app-FRYHoE`, preserved a finalized
1080p archive with all 3750 frame identities (0–3749), approximately 30 fps and decoded
audio. Native output contained 3379 consecutive frames in 600/1214/1565-frame
1080/540/1080 phases; both receipts reported zero raw evictions. Qualification still
failed: FFmpeg rebuilt the filter graph on input format changes, resetting its
filter-local frame ordinal. The worker's strict decoder telemetry rejected that
reset after 540 accepted frames. This run is retained as failed evidence.

The worker now preserves the graph only when it has an explicit fixed output
canvas, keeping metadata ordinals and the frame-selector time anchor intact. The
profile-less path retains its previous behavior. Padding evaluates dimensions per
frame: a separate changing-shape probe demonstrated stale left alignment with the
old padding, and the regression now requires centered barcodes and black bars.
No parser ordinal or PTS integrity check was relaxed.

The existing worker processing harness accepts `--transitions` and
`--transitions-aspect` after encoder and source fps. Both require a 60fps source and
switch at source indices 61 and 121, exposing selector-anchor resets. The aspect
fixture uses square pixels and independently checks 640×360→320×240→640×360 input
geometry. Both software and VideoToolbox must retain all 180 decoded inputs, precisely
90 even-numbered output source identities, fixed 640×360 output, original source
clock alignment, complete encoder telemetry and A/V coverage. Full phone simulator
A/V markers and scoring overlay remain the integration test.

Reproduce the experiments on this machine with Xcode 26.2 selected:

```sh
pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-worker-processing.mjs software 60 --transitions-aspect
pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-worker-processing.mjs videotoolbox 60 --transitions-aspect
SCOREBUG_TEST_RELAY_PUBLICATION=1 SCOREBUG_TEST_WORKER_PROCESSING=1 SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_MOTION_FIXTURE=blocks16 SCOREBUG_TEST_STREAM_HOLD_SECONDS=90 SCOREBUG_TEST_PROFILE_TRANSITIONS=1 pnpm test:native-streaming
```

## Full-pipeline result

`native-app-HCtRdN` passes on the iPhone 14 / iOS 17.5 simulator with the real native
SRT encoder, local worker and direct recorder. All owning processes and cleanup
completed before evidence hashing. The three actual native phases contain
600/1214/1564 frames (3378 total), with boundaries 758→759 and 1972→1973. Independent
native callback IDs match both receipts and all phase source intervals. There are
zero raw evictions and no source discontinuities. The recorder contains every frame
219–3536 (3318 frames, 110.6 seconds), with 60 initial acquisition frames explicitly
excluded and no encoded tail missing. Each phase sustains 30 source fps; decoded
output averages approximately 30 fps with zero qualified source loss.

The independent archive contains all 3720 frames 0–3719 at 1920×1080, approximately
30 fps, and normal finalization/export. All 61 archive and 55 live audio markers match.
Live A/V offset is approximately 65.25 ms with negligible measured drift. Scoring
changes the live overlay, while source/publication/processing/ingress/archive and
saved-tail checks all pass.

The measured native completion gaps are 353.6/425.8 ms. The separate compressed-output
arrival gaps are 338.7/419.0 ms. These are real pauses, despite complete source-frame
preservation; they are not measurements of receiver wall-clock playback stalls.
Do not label this seamless switching, automatic adaptation or pressure recovery.

Current validation passes 191 app-model tests, 334 serialized worker tests, 919 tooling
tests, worker type checking, software and VideoToolbox aspect/cap probes, the full
simulator pipeline, and unsigned combined iPhone/Watch Release build. Source review
approved ownership, independent identity/clock proof and the fixed-canvas worker
change. `artifacts/qa/profile-fixture-final-verification.json` records terminal
source/evidence hashes. Earlier media/streaming package API evidence remains in
`13d25fb`; no package or SDK source changed in this slice.

Next qualify controlled reduction/recovery under uplink pressure and the newer iOS
runtime before enabling automatic resolution selection. Longer soaks, actual camera
thermal/storage pressure, physical phone/Watch and other-host qualification remain
open. Existing native phone/watch scoring requirements are unchanged.

## Newer-runtime qualification

The same controlled experiment also passes on iPhone 14 / iOS 26.2 in
`native-app-yITrxX`, run at source commit `3d0a478` with
`SCOREBUG_IOS_RUNTIME=26.2` and the same explicit transition flags above. The three
native phases contain 600/1214/1647 frames, with boundaries 751→752 and 1965→1966.
Independent native session IDs match both receipts, with zero raw queue evictions.
All 3401 acquired live frames 212–3612 arrive, including the final encoded frame;
the initial 60 acquisition frames remain explicitly excluded. All three phases
sustain 30 source fps with zero qualified source loss.

The clean 1080p archive normally finalizes and exports all 3821 frames 0–3820 at
approximately 30 fps. All 63 archive and 57 expected live A/V markers match; live
offset is approximately 65.58 ms with negligible measured drift. The scoring overlay
changes, and the existing worker/publication/source/ingress/archive/tail gates pass.
Compressed-output arrival pauses are 340.0/428.8 ms; native completion pauses are
340.0/433.5 ms. These still do not establish seamless receiver wall-clock playback,
automatic adaptation, or recovery under congestion. All fixture owners and cleanup
completed successfully before evidence hashing.

The next implementation prerequisite is the
[quality-owner profile binding](2026-09-16-quality-profile-binding.md), preserving
one policy revision across native resolution replacement and verified bitrate.
Its tests are separate evidence from this controlled simulator experiment.

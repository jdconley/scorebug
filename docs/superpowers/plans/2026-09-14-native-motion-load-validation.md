# Native motion and bitrate workload validation

Use brainstorming and writing-plans before implementation, then bounded
subagent-driven implementation with independent specification and quality reviews.
This is the next local workload after the snapshot-isolation native repeat passes.
If that repeat fails, diagnose it before proceeding with this plan.

## Why the current fixture is insufficient

The barcode fixture is mostly flat black, sixteen large barcode bands and one
small moving square. Its archive and live containers average about 0.13/0.10 Mbps,
far below the configured 12/6 Mbps video rates. It establishes source identity,
ordering, clean recording, scoring and transport behavior at low encoded payload
rates. It does not establish encoder/storage/network behavior at sports-video
payload rates or qualify physical camera, thermal load, cellular or adaptive quality.

## Design to explore and measure

Add an explicit DEBUG-simulator-only motion workload while retaining the existing
fixture as the default. Prefer a small bounded set of deterministic textured frame
backgrounds, prepared before the capture clock begins, over expensive random-pixel
generation on every callback. Allocate a fresh pixel buffer for each emitted frame;
never mutate a buffer after offering it to capture consumers. Include texture and
color changes across a substantial central image area, with a documented fixed
memory budget and seed. This is a synthetic encoding stress case, not a claim to
represent real volleyball footage.

Preserve the exact source barcode and audio marker clock. Keep the entire score
comparison crop's background static: otherwise moving background pixels could
falsely satisfy the existing overlay-change test. Preserve source formats, PTS,
callback order, cancellation/join behavior, diagnostic hooks and production source
selection. No capture pacing, queue limits, encoder profiles or quality budgets
change in this slice.

Two options are available: seeded texture buffers with cheap per-frame copying,
or decoded prerecorded motion. Choose the first for an initial reproducible local
experiment: it avoids external assets, licensing dependencies and an additional
live decoder competing with the recording pipeline. Actual camera footage remains
a separate physical-device gate.

## Ordered work

- [x] Define an explicit trusted opt-in fixture option and its memory/content
  contract. Reject malformed settings before starting owned resources. Plumb it
  through the runner, Xcode test environment, native UI launch and DEBUG simulator
  source selection; absent options preserve the old source. Record selected
  workload in the artifact configuration.
- [x] TDD the deterministic source: stable seeded initialization, changing central
  image area, unchanged identity bands/static overlay crop, immutable published
  frames, correct NV12 layout/PTS/audio, bounded retained data and joined stop.
  Include scaled test profiles, while actual workload qualification uses 1080p30.
- [x] Measure actual encoded video payload rates from packet sizes and media
  timestamps in both finalized outputs. Keep audio/container overhead separate.
  Exclude acquisition/partial boundaries explicitly; report steady-window rates
  and retain exact measurement scope. Unit-test packet accounting, invalid/empty
  intervals, mixed streams and timestamp handling. Never treat configured bitrate
  as measured throughput.
- [ ] Run a short isolated calibration experiment, keeping all current frame,
  A/V, scoring, archive and delivery gates. Target sustained video payload rates
  near the existing 12/6 Mbps configuration; initially assess whether at least 6/3 Mbps
  is achievable without the generator missing its own deadlines. These are workload
  calibration targets, not product quality guarantees. If payload stays low or
  generation stalls, inspect the measured cause before selecting a workload.
- [ ] Freeze and review the measured workload and acceptance criteria. Run a
  three-minute hold, then 600 seconds if it passes. Full decode, complete archive
  identities, live terminal delivery, zero recording rejections/drops, clock/age
  integrity and unchanged cadence gates remain required. Preserve all failures.
- [ ] Record exact revision, selected workload, encoded payload rates, retained
  pressure evidence and limitations. Do not enable automatic quality changes or
  higher device profiles on this evidence alone. Continue to actual camera and
  Watch/phone testing when hardware is reachable.

The conditional prerequisite now passes in `native-app-6o9S2U` at `a49408c`.
Independent design, specification and quality reviews approve the implemented workload.
Native calibration is the next gate.

## Implementation contract

Choose `SCOREBUG_TEST_MOTION_FIXTURE=1` as the only enabled spelling; absent means
barcode. Other values fail runner validation before resource creation. Motion mode
requires streaming and the direct receiver. Record `fixtureWorkload` (`barcode` or
`motion`) in configuration and results. Pass only the validated flag through
`ios/Project.yml` and `NativeStreamingTests` to the DEBUG simulator app. Release and
physical source selection remain unchanged. Native-side malformed nonempty values
must also fail instead of selecting a different workload silently.

Swift source work: `ios/Sources/Scorebug/Capture/FixtureCameraSource.swift`, a focused
`FixtureMotionPattern.swift` helper if useful, `ios/FilmModelTests/FixtureCameraSourceTests.swift`,
`ios/Sources/Scorebug/App.swift`, `ios/AppUITests/NativeStreamingTests.swift`, and
`ios/Project.yml`. Prepare eight deterministic tightly packed NV12 texture frames,
using one fixed seed and legal video-range luma/chroma. Bound their combined
retained bytes to 32 MiB, checking dimensions and multiplication before allocation.
Reject an oversized motion profile; do not alter production profile validation.
Only the central vertical region from one-third through five-sixths of the image
may change. At 1080p this leaves the complete barcode and 750×120 scoring crop at
(0,930) unchanged. Preserve default barcode fixture pixels exactly. Copy texture
rows into newly allocated pixel buffers, respecting actual plane strides. Generate
textures during prepare, before the pump's capture clock begins; no per-frame noise
generator or mutable shared output buffers. Content is an encoding stress case.

Tooling work: add `nativeFixtureWorkload({streaming,environment})` to
`scripts/native-streaming-options.mjs`, its tests in
`scripts/test/native-streaming-options.test.mjs`, and wire the result in
`scripts/test-native-app.mjs`. Add `scripts/video-payload-rate.mjs` and
`scripts/test/video-payload-rate.test.mjs` for `measureVideoPayloadRate({streams,packets})`.
Use ffprobe stream index/type/time_base and packet stream_index/pts/duration/size,
with strict finite safe-integer/rational validation and exactly one video stream.
Audio packet bytes never count. Reject empty video, missing/invalid timestamps,
nonpositive size/duration, duplicate/regressed video PTS, and no complete window.

Report per-window packet-start attribution: a packet's entire payload belongs to
the five-second interval containing its PTS. Use a common absolute media timeline,
not independently reset audio/video times. Only intervals fully covered from first
video PTS through last video PTS+duration are measured. Partial leading/trailing
intervals are excluded and their packet/byte counts reported explicitly. Preserve
gaps as low/zero payload windows rather than filling or silently skipping them.
Bound output to 128 windows and reject larger ranges. Report selected video stream,
timebase, coverage, excluded boundary counts, per-window bytes/packets/Mbps and
aggregate/min/max measured rates. These are encoded media payload rates, not wire
throughput or image-quality scores. Existing frame/cadence gates remain separate.

TDD examples: audio size changes never alter video rates;150 video packets×1000bytes
at 30 fps form one 5-second window at 0.24 Mbps; a late first PTS excludes its partial
window; an internal gap remains present; invalid data and 129 windows fail. Source
tests compare repeated seeds and central-frame differences, exact default barcode
pixels, all static crop pixels, prior emitted buffer content after later callbacks,
PTS/audio order and stop join. Run source red/green, full Film tests, focused/full
tools, Release build and independent specification/quality reviews before any
isolated native calibration. Coordinate builds/tests to avoid concurrent media
qualification. Start with default short hold; keep 6/3 Mbps as calibration observations
until actual measured demand and generator timing are reviewed.

## Implementation verification

The source and tooling slices are implemented. Motion textures retain 24,883,200
bytes at 1080p (checked 32 MiB ceiling); tests cover stride-padded 322×242 buffers and
the entire 1080p barcode/scoring crop, reproducibility, legal ranges and independent
published buffers. The default image remains unchanged. Joined stop releases the
prepared textures. The native source validates its flag during prepare; the runner
validates before any owned resources.

Focused source tests pass 10 and full Film tests pass 83. Source red evidence contains
38 expected assertions across 5 cases; its Xcode driver later stalled finalizing the
already-completed test result and required termination of that owned driver (143).
This is recorded separately in `motion-source-red-finalization.log`; both green
runs completed normally. Options/payload tests pass 65 and full tools pass 336.
The unsigned generic iOS Release build (including Watch) passes. Logs are retained
under `artifacts/qa/motion-*.log` and `video-payload-rate-*.log`.

Both slices pass specification review and independent quality review, with no findings.
A real ffprobe metadata smoke check against `native-app-OCNlMh` succeeds:
40 complete archive seconds measure 0.103861 Mbps video payload; 25 live seconds
measure 0.076717 Mbps. These exclude audio/container overhead and are not wire rates.
Metadata and calculations are retained in `artifacts/qa/motion-payload-baseline/`.
The first native motion calibration failed; it is not qualified. See the evidence below.


## First native motion calibration: failed

`native-app-24AFo1` at `879404d` used the iPhone 14/iOS 17.5 simulator, direct receiver
and default short hold. The actual runner exited 1 after Xcode 65. The app reached
publishing/worker output, scored a point and completed the hold, then failed the
second worker-producing-output check. Worker pipeline 1 reported 616 decoded frames
and natural encoder exit 0; it subsequently attempted restarts (pipeline 2 had zero
frames/exit 195). The receiver ended naturally 0. Worker evidence omitted 89 events,
so it is incomplete; do not use this run as a terminal-delivery qualification.

The saved receiver video fully decodes through FFmpeg but has visibly corrupted
static barcode regions and nonconsecutive decoded source IDs. Successful downstream
decode alone does not establish intact upstream images. Three complete five-second
windows measure 46.277673 Mbps video payload (44.108987–48.157326 Mbps), against the
requested worker 6 Mbps. This is an observation, not a confirmed cause of interruption.

Archive preservation itself failed during simulator teardown: zero files were
copied, and the manifest is explicitly incomplete. See the reviewed
[failure-evidence plan](2026-09-14-motion-failure-evidence.md) for the bounded state
transition repair before repeating this workload. The original failed artifact and
manifest remain unchanged. Retained findings, packet probes/rates, decoded barcode
IDs and a diagnostic frame are in the same artifact directory.

A bounded local replay re-encoded the already-corrupted saved clip through
VideoToolbox, with no live transport. With a 10-second input cutoff, the complete
five-second measured window contained 145 video packets. Existing average-rate
settings produced 45.928024 Mbps. An experimental 9 Mbps maximum produced 33.714190 Mbps;
experimental 6 Mbps constant-rate produced 33.742722 Mbps. These alternatives are not
production changes or qualified fixes. A separate -r 30/VFR invocation was rejected
by FFmpeg before encoding as contradictory; no output/result is claimed for it.
All replay evidence is under `native-app-24AFo1/rate-replay/`. The source is synthetic
pixel noise, and encoder behavior on it must not be generalized to real sports
footage. Repeat with archive/QA evidence before selecting changes to the workload,
transport or encoder. Three-/ten-minute motion holds remain pending.

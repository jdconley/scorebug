# Native Candidate Sampling Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the isolated reusable measurement controller, followed by spec and quality reviews. Parent owns the native wrapper, independent evidence validator, all heavy builds/runs, provenance and commit. The autonomous goal authorizes implementation without another approval round.

**Goal:** Sample the current scene at a proposed quality while the phone continues independent recording and fixed-profile publishing, and qualify that behavior through the local native media pipeline.

**Architecture:** Reuse raw samples already admitted through PublishingSession's bounded mailbox, offering them to the candidate only after primary publisher append returns. A reusable single-use Streaming measurement owner gates synchronous offers, automatically closes a finite source window, and joins the candidate encoder. A simulator-only app wrapper schedules one opt-in measurement, cancels it on local pressure or ownership changes, and exports bounded scalar evidence after joined shutdown. It never changes the live profile or archive.

**Tech Stack:** Swift 6/CoreMedia, existing PublishingCandidateEncoder/MediaPublisher, Swift Testing/XCTest, Node independent JSON verification, Xcode 26.2, local SRT/FFmpeg/MediaMTX qualification.

## Reusable measurement owner

Files: `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/PublishingCandidateMeasurement.swift` and corresponding tests.

- [x] Tests first, intentional failing stub verified before implementation.
- [x] Implement immutable `id`, `scope`, `profile`; explicit async `start`; synchronous `offer(CapturedMediaSample)` and `cancel(reason:)`; async shared `result()` that joins all startup/deadline/native work. No per-frame task or extra raw queue. Audio is ignored.
- [x] Close at the first source span of at least four seconds, with at least 97 admitted inputs, no more than 121 and the SDK's 4.25-second source bound. Hitting the frame limit before four seconds is incomplete. Reject late admission at five monotonic seconds even if the timer is delayed; an on-time close may drain native work later.
- [x] Cancellation immediately revokes raw offers and signals one owned terminal operation. Partial, rejected, expired or incomplete windows never report completed. A completed result also requires successful exact SDK reconciliation. Distinct reasons preserve pressure, owner replacement, publisher stop and encoder failure.
- [x] Test source-time/count boundaries, idle/late timer expiry, pre-start and startup cancellation, simultaneous result waiters, gated native joins, malformed/rejected input and actual encoding. Public owner release must request cancellation without a task retain cycle.

## Native integration

Files: new `ios/Sources/Scorebug/Capture/NativeCandidateFixture.swift`, corresponding `ios/FilmModelTests` tests; `CaptureStreamingModel.swift`, `ios/Project.yml` and native UI test environment forwarding.

- [x] Add a DEBUG wrapper around the selected primary MediaPublisher. Forward primary video/audio before optional video-only sampling. Preserve startup evidence, clock/statistics, profile/bitrate mutation and probe observation behavior.
- [x] Schedule one measurement after twenty seconds; close sampling on append/health failure, new publishing queue drops/rejections, serious/critical or unavailable thermal evidence, encoder mutations, stop or cancellation. A 100-ms optional monitor reads the current session diagnostics; normal primary media errors remain primary errors, candidate errors remain optional.
- [x] Scope stays fixed to the recording/match/broadcast/attempt/applied revision. Joined stop releases the primary publisher and joins optional tasks before exporting at most 256 KiB of evidence. No export claims completion after a cancelled or obsolete owner.
- [x] Require exact simulator opt-in `SCOREBUG_TEST_CANDIDATE_PROFILE` with a fixed reduced live profile, structured-motion source, video observations and at least 90 seconds of qualification. Reject conflicting live-profile transitions/adaptation. Normal production startup remains unchanged.
- [x] Test forwarding/order, all cancellation paths, pressure deltas, delayed start/stop races, concurrent stop joining, diagnostics absence and strict fixture flags using bounded injected operations.

## Independent qualification

Files: new `scripts/native-candidate-measurement.mjs` and tests; `scripts/test-native-app.mjs` and failure artifact preservation where needed.

- [x] Validate opt-in before launching infrastructure. Copy the bounded app result and independently verify exact expected scope/profile/identity, successful finite window, one session, increasing rational PTS, actual H.264 dimensions/positive bounded bytes, startup keyframe, time ordering, at least 24 source fps, and unchanged publisher pressure counters. Reject malformed, partial, stale-owner and contradictory evidence. Actual byte totals remain video payload only.
- [ ] Run one fresh local structured-motion qualification with independent 1080p archive, minimum 240p live output and a higher candidate profile. Require complete archive/live source-frame and audio-marker verification; retain failed evidence if any stage fails. Do not infer candidate pixel-decode quality, network headroom or thermal/device safety from scalar codec metadata.
- [x] Run affected Streaming/native-model/tooling suites and simulator/unsigned phone-Watch builds sequentially. Spec then quality review; verify patch provenance and unchanged frozen evidence, hash source/runtime/evidence, update the main plan and commit.

## Design tradeoffs and remaining gates

A new raw tap inside capture would add lifecycle and dependency coupling to the archive boundary. Sampling after the existing primary publisher append reuses established admission and keeps optional work out of that critical section. Upstream dropping can make candidate evidence incomplete, which is a rejection condition rather than permission to claim a clean window.

This step measures a finite current-scene video window and its concurrent local effect. Complete freshness/admission policy, audio/mux/transport costs, repeated receiver headroom, minimum-first upward trials, long-session campaigns, real phone/Watch thermal/radio routes and remote workers remain separate gates. Production automatic quality increases stay disabled.

## Review corrections and first native result

Spec review found two gaps, each reproduced before its fix. The wrapper now owns
and joins primary startup after requesting primary shutdown and before exporting
closed evidence. The qualifier reconstructs submitted-but-not-dequeued occupancy
and rejects traces that exceed the SDK's four-input bound. A post-await model
ownership check prevents an obsolete attempt from attaching after diagnostics setup.
Controller and corrected integration passed separate spec and quality reviews.

The first 540p candidate run, `native-app-LSgfgH` (iPhone 14/iOS 17.5 simulator),
failed qualification correctly: four inputs were admitted, the fifth encountered
`unresolvedInputLimit`, and cancellation drained all four outputs. Nominal thermal
samples and unchanged publishing drop/rejection counters were retained. The source
recipe and four-input limit were preserved; this is not measured candidate capacity.
Independent replay verifies the 1080p archive's 3,720 consecutive frames and 61
matched audio markers, plus the 240p live recording's 3,314 consecutive frames and
55 matched markers. Neither recording lost source frames. Failure data and original
runtime hashes are retained and frozen separately.

The next run tests the immediate 240p-to-360p step with the corrected integration.
If the finite measurement still cannot fill, investigate native buffering before
changing any bound or enabling upgrades. Apple's
[MaxFrameDelayCount](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxframedelaycount)
property limits frames held by the compressor; the installed Xcode 26.2 SDK header
specifies an unlimited default. Any experiment with this setting must verify native
acceptance/readback and preserve matching candidate/live recipes. Merely increasing
an application buffer or changing only the candidate recipe cannot establish the
cost of the live encoder being proposed. The observed failure does not by itself
identify startup delay versus sustained buffering, or establish physical-device behavior.

## Final native result and remaining qualification

The corrected 360p run `native-app-v5ASvA` repeats the same finite-measurement
failure: four admitted inputs, `unresolvedInputLimit`, and four joined outputs.
The 1080p archive has 3,691 consecutive frames and 61 matched audio markers; the
240p live recording has 3,317 consecutive frames and 55 matched markers, both
with zero source loss. These are preserved negative candidate trials with separately
verified A/V, **not successful candidate-cost or complete positive pipeline qualifications**.

Implementation and failure isolation are reviewable; the positive native measurement
gate above remains open. Next reproduce native buffering in a bounded diagnostic
with the actual 1080p structured source, then test an explicitly verified frame-delay
setting without loosening input bounds. A successful change must use a matching
live/candidate encoder recipe and repeat the full native media qualification.
Do not enable production candidate admission or automatic increases from these runs.

Final verification: 123 Streaming tests, 308 native model tests, 1,613 tooling tests,
actual simulator app workflows, unsigned combined phone/Watch Release (arm64_32
and arm64 Watch slices), exact SDK patch provenance and reviewed corrections.
No SDK source changed in this step. All 1,826 previous frozen evidence files and
both negative native runs are retained unchanged. Manifest:
`artifacts/qa/candidate-sampling-final-verification.json`.

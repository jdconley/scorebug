# Bounded Candidate Encoder Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the isolated SDK encoder and spec/quality reviews. Parent owns the Streaming adapter, package builds, native qualification, provenance and commit. The active autonomous goal authorizes these implementation choices.

**Goal:** Encode a finite sample of the current scene at a proposed live profile using the actual publishing codec, without changing live publication or the archive.

**Architecture:** A single-use SDK owner wraps the existing VideoCodec and its settings recipe. Synchronous bounded raw ingress feeds one serial consumer; native callback metadata is reconciled with bounded compressed output. Completion closes admission, drains input, joins native completion off the owner actor, drains output and invalidates the codec. A Streaming adapter binds the result to a publishing attempt and proposed profile. This is actual candidate video cost, not yet audio/mux/network capacity admission.

**Tech Stack:** Swift 6, CoreMedia/VideoToolbox, HaishinKit VideoCodec, Swift Testing/XCTest, SDK patch provenance.

## SDK encoder

Files: new `vendor/HaishinKit/HaishinKit/Sources/Codec/VideoCandidateEncoder.swift`, new `vendor/HaishinKit/ScorebugPatchTests/VideoCandidateEncoderTests.swift`.

- [x] Add a single-use public `VideoCandidateEncoder` with immutable requested `VideoCodecSettings`, candidate UUID, explicit startup, synchronous nonblocking `offer(CMSampleBuffer)`, and joined async `finish`/`cancel`. Do not create a Task per offered frame. Internal actor/serial ownership may implement the public thread-safe handle.
- [x] Hard bounds: at most 121 accepted frames, source span at most 4.25 seconds, total measurement admission at most eight monotonic seconds, raw samples at most 16 MiB each, at most four retained/unresolved inputs, and the existing eight compressed outputs at 2 MiB each. Deadline revokes admission and marks evidence unusable; do not promise a hard completion deadline for native VideoToolbox. All tasks remain owned and joined.
- [x] Explicitly accept only ready raw video with an image buffer, valid nonnegative epoch-zero PTS, strictly increasing rational times and immutable input format. Reject audio/compressed/decompression input. Use the existing codec/settings path; do not copy VideoToolbox settings into a second implementation.
- [x] Reconcile exactly one source submission, native callback and compressed H.264 output for every accepted input. Require one encoder-session identity, matching source/output PTS, actual expected dimensions, finite ordered submit/completion/dequeue times, positive bounded bytes and keyframe metadata. Preserve startup-keyframe cost. Reject missing/duplicate callbacks, dropped output, queue overflow and session replacement. Callbacks alone cannot prove output delivery.
- [x] Return immutable bounded scalar result: candidate UUID, requested settings, terminal outcome/native failure, encoder-session UUID, input/output counts, and frames with source/output PTS, native times, byte count, dimensions and sync status. Successful results require all accepted frames reconciled after joined shutdown. Cancellation cannot yield successful partial evidence. Requested settings are not a native property-readback claim.
- [x] Use injected VideoCodec sessionFactory and gated fake sessions for deterministic failure/lifecycle tests. Include finish/cancel races, delayed callback bursts, queue and outstanding limits, malformed inputs, incomplete joins, and multiple terminal callers. Run red before implementation and green after. A small actual H.264/scaling test must use the real codec and validate compressed output metadata; native decoding may use a test-only bounded sample sink.

## Streaming integration

Files: new `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/PublishingCandidateEncoder.swift`, new corresponding tests.

- [x] Add a profile/attempt-bound adapter using `PublishingVideoProfile.settings`, so candidate and publisher use the exact same H.264 recipe. Capture recording/match/broadcast/publishing-attempt/applied-revision identity and a unique measurement identity. Do not configure or retain a live publisher, capture session or archive.
- [x] Forward bounded raw offers and joined finish/cancel. Return a result retaining explicit terminal failure and requested profile, never relabel requested bitrate as actual cost. Test profile settings, scope preservation, cancellation and fresh instance identity using the SDK primitive.
- [x] Record the remaining integration boundary: capture fan-out, fresh complete-window/keyframe qualification, actual or conservatively bounded audio/mux/transport cost, pressure cancellation and receiver headroom admission must be connected before enabling upgrades. No automatic production increases in this step.

## Verification and provenance

- [x] Parent runs focused SDK/Streaming tests, then full affected suites sequentially under Xcode 26.2. Keep heavy jobs serialized. Preserve red/green evidence under `artifacts/qa/candidate-encoder-*`.
- [x] Spec review then quality review. Resolve findings with regressions and rerun affected checks.
- [x] Add new SDK source to the maintained patch/provenance inventory; reverse/forward patch must reproduce every upstream hash and current source exactly.
- [x] Build the simulator and unsigned phone/Watch product after integration. Confirm no existing frozen artifact changed; hash runtime/source/evidence, update the main plan and commit.

## Design choices

A separate direct VideoToolbox implementation would risk differing encoder/scaling behavior. A controlled live profile change before cost measurement would put the video path at risk before admission. The bounded parallel encoder reuses the actual codec while keeping optional work separately cancellable. Its resource impact still needs qualification alongside filming and live publishing before production use.

## Verification results

- Full SDK: 240 tests across 34 suites pass. Streaming: 105 tests pass.
- Real native H.264 tests cover scaling, initial sync output and the publishing
  426×240 High-profile recipe. These are bounded codec tests, not a simultaneous
  recording/publishing/candidate resource or complete-scene qualification.
- Simulator build-for-testing and unsigned combined phone/Watch Release pass.
  The embedded release Watch product contains arm64 and arm64_32 slices.
- SDK patch reverse/forward verification preserves all 162 upstream hashes.
  Spec and quality reviews approved; the delayed-timer/late-finish regression was
  observed failing before its fix. Closing admission on time still permits a late
  native completion, and cancellation joins the same terminal operation.
- A final SDK repeat exposed an existing close/republication test failure. Twelve
  isolated and eight instrumented full-suite repetitions did not reproduce its
  exact diagnostic trace. A controlled test confirms that cancelling an entered
  media send intentionally closes the socket/connection. The original close-owner
  test now requires positive probe acceptance (after all media sends return) and
  joins its probe scheduler before testing the blocked close. A separate permanent
  test covers in-flight send cancellation. The final full SDK suite passes; no
  production close/transport behavior was changed.
- Evidence: `artifacts/qa/candidate-encoder-final-verification.json`. Failed and
  intermediate runs remain preserved. All 1,775 prior frozen evidence files were
  checked unchanged. New source, runtime inventory and evidence are hashed.

Next: connect optional capture fan-out with pressure cancellation, qualify a fresh
complete candidate window including initial keyframes, add audio/mux/transport cost,
and combine it with receiver headroom before enabling upward trials. Physical
phone/Watch, simultaneous encoder contention and remote worker qualification remain
separate gates.

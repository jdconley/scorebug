# Delivery source windows implementation plan

> Execute inline using the executing-plans and test-driven-development skills under the approved progressive streaming design. Request independent review before completing this checkpoint.

**Goal:** Prove the complete set of captured frames in a one- or two-second window and project them into decoder PTS coordinates without losing locally unencoded frames.

**Architecture:** Add `PublishingDeliverySourceWindow` to ScorebugStreaming, using the SDK's exact rational MPEG-TS projection. Require retained capture and encoder brackets, a stable verified encoder receipt, and an actual decoded anchor that matches an encoded source frame. Keep authenticated publication/freshness ownership in the app adapter; the source helper cannot establish it. Preserve all captured frames, including those never encoded. Missing brackets, mixed settings, retired history, ambiguous timestamps, or unsafe arithmetic return unknown.

**Tech stack:** Swift, CoreMedia, ScorebugMedia, SRTHaishinKit TransportClock; native macOS model tests and iOS simulator/unsigned Release builds.

- [x] Add `ios/FilmModelTests/PublishingDeliverySourceWindowTests.swift` covering exact half-open windows, local omissions, ring retirement, pending completions, mixed/missing configuration, receipt boundaries, fractional timestamps, decoder wrap, malformed clocks and encoded provenance. Run the focused model test expecting the missing implementation to fail compilation.
- [x] Implement `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/PublishingDeliverySourceWindow.swift`. Capture brackets must precede start and reach end; encoded brackets must precede the first included source and reach the right capture boundary. Validate every encoded frame in the source interval against a capture frame and the receipt. Find a unique modular anchor and project by checked signed differences; require all coordinates within the protocol's safe integer range and less than half a wrap from the anchor.
- [x] Add native integration tests feeding projected windows into `DeliveryDeadlineClassifier`, proving late versus locally missing frames and unknown clock uncertainty. These use explicit synthetic authenticated-binding assumptions; they do not qualify real phone deadlines.
- [x] Run focused and complete native model tests, Core tests, simulator build-for-testing and unsigned iPhone/Watch Release build. Preserve new logs with `delivery-source-` prefix and rehash all previous frozen evidence.
- [x] Obtain independent review, fix actionable findings with regressions, update the main plan, freeze source/evidence hashes and commit. Automatic adaptation remains gated pending scheduling in the capture loop and a real native/relay deadline experiment.

## Implemented behavior

`PublishingDeliverySourceWindow` requires retained capture brackets around the entire
half-open window and encoder completion coverage through its right boundary. Each
included encoded frame has exact captured provenance and verified configuration.
Locally unencoded captures remain in the expected set with `wasEncoded == false`.
Checked rational MPEG-TS projection and an actual decoded anchor establish the
unwrapped coordinate, including negative decoder timestamps and 33-bit wrap.

`PublishingDeliveryObservation` binds the source matcher to authenticated delivery
freshness, current recording/attempt/game/generation, native clock and encoder receipt.
Changed settings, stale delivery, closed scopes, future local observations and decoded
arrivals for explicitly unencoded captures are rejected. Uncertain arrival timing
cannot supply an on-time FPS or a complete failure fraction. The adapter requires
explicit latency/sample-age limits and the caller's current tracker proof. It does
not yet schedule windows or activate controller decisions.

Independent review found that an encoded-only timestamp just beyond the right
boundary could incorrectly prove completion. The exact 90.5-frame counterexample
failed before the fix and passes after requiring capture membership for the first
right-side completion. Re-review found no remaining actionable issues.

## Verification checkpoint

All 12 new source-window/adapter tests pass within the full 265-test native model
suite. All 372 Core tests pass. ARM64 simulator build-for-testing and unsigned
combined iPhone/Watch Release builds pass. The initial missing matcher/adapter
compilation failures, two intermediate compiler fixes, and review regression are
retained with the green runs. All child processes are joined. The 789-file runtime
inventory matches the verified source, and all 24 frozen evidence files from the
previous native-delivery checkpoint are unchanged. New evidence is frozen in
`artifacts/qa/delivery-source-final-verification.json`.

Next schedule nonoverlapping one/two-second source windows against the current
tracker proof in the native capture loop. Qualify decoder deadlines with actual
simulator capture and relay delivery before connecting controller loss/floor
responses. Candidate actual-cost/headroom, recovery, reconnect, physical iPhone/Watch
and remote CPU/GPU/cloud qualification remain open.

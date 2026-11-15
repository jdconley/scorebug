# Candidate transport cost implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded implementation and separate spec/quality reviews. The parent owns Apple builds, evidence and commits.

**Goal:** Measure actual finite candidate A/V MPEG-TS packaging without a socket or retained output stream, preparing complete cost evidence for adaptive admission.

**Architecture:** Reuse the production TSWriter with an internal synchronous output sink. A public lock-owned CandidateTransportMeasurement accepts compressed H.264 and AAC, invokes the same muxer, and retains only scalar counts. VideoCandidateEncoder gains an optional synchronous compressed-output consumer for validated frames. Audio-window selection and admission integration follow this foundation; ordinary publishing and automatic upgrades remain unchanged.

**Tech stack:** Swift 6, CoreMedia, AVFoundation, VideoToolbox, vendored HaishinKit/SRTHaishinKit, Swift Testing.

## Design and boundaries

Reusing the actual muxer captures ADTS, Annex-B conversion, SPS/PPS, PES, PCR, PAT/PMT and 188-byte packet padding. A guessed overhead percentage could undercount; a second approximate packetizer would duplicate the production algorithm. Sending candidates over a socket would consume the capacity being assessed. The synchronous sink therefore provides exact off-network application-payload counts using the existing muxer.

The measurement reports encoded input bytes, emitted transport bytes, and the number of 1,316-byte SRT payload chunks that the current socket would submit (round up each mux write independently). These are not observed network delivery, IP/UDP/SRT control overhead, retransmissions, or spare bandwidth. No success result qualifies an upgrade on its own.

The owner requires both audio and video, permits at most 121 video and 512 audio inputs, at most 32 MiB total compressed input, at most 4.25 seconds across all input presentation timestamps, strictly increasing timestamps per track and fixed formats per track. Per-input limits are 2 MiB video and 8,184 bytes AAC. Audio must contain exactly one AAC packet. Malformed input, changed formats, mux failure and limits fail closed. Mux startup retains at most its existing 256 packets / 8 MiB / 2 seconds; output is synchronously counted then discarded. Finish/cancel are terminal and idempotent; no task, timer, socket or unbounded queue is added. Cancellation is distinct from completion. Complete does not imply minimum duration/cadence, which belongs to the consuming qualifier.

Video preflight also requires an initial keyframe with an IDR slice, an H.264 format with four-byte
NAL lengths, no more than 64 KiB of parameter-set bytes, and complete nonzero NAL
units. Every video input must contain a VCL slice. Validation precedes the shared Annex-B converter so malformed length
prefixes cannot make its conversion loop stall. AAC packet-description size must
match the supplied bytes; AAC-LC, 1,024 frames per packet and an exact supported
sample rate are required. These checks make startup packaging part of every
successful measurement. They validate transport structure, not decoded media
quality or complete scene/audio coverage.

The candidate callback is optional, synchronous, Sendable, called only after compressed output validation, and may return false to fail that optional measurement. It must neither mutate nor retain the sample nor reenter the encoder. Native completion and all existing tasks remain joined. Cancellation serializes with consumption under the candidate state lock, and no new consumption claim may succeed once native failure is latched. A callback already claimed while healthy may finish if native failure arrives afterward; the overall result still fails. Existing count/raw-byte/output bounds remain in force.

## Tasks

- [x]   1. Add failing SDK tests for exact mux totals compared to ordinary TSWriter output, per-write SRT chunk rounding, real audio/video headers, initial and repeated program tables, malformed input, independent resource limits, out-of-order tracks, format changes, finish/cancel and overflow failure. Use finite representative fixtures, including packet-boundary sizes and keyframes. Public API: `CandidateTransportMeasurement()`, `appendVideo(_:) -> Bool`, `appendAudio(_:when:) -> Bool`, `finish() -> Result`, `cancel() -> Result`; result exposes outcome/failure, input counts/bytes, first/last PTS and emitted transport bytes/message count.
- [x]   2. Run red tests with Xcode 26.2 selected; preserve output under `artifacts/qa/candidate-transport-cost-*`. Implement the owner in `vendor/HaishinKit/SRTHaishinKit/Sources/TS/CandidateTransportMeasurement.swift` and internal optional synchronous sink in `TSWriter.swift`. Sink rejection must fail the writer. Default async output remains unchanged and bounded.
- [x]   3. Add failing lifecycle tests for the optional `compressedOutputConsumer: (@Sendable (CMSampleBuffer) -> Bool)?` initializer argument in `VideoCandidateEncoder`. Verify validated delivery, consumer rejection, invalid output exclusion, cancellation and joined completion. Implement only that hook, with no additional tasks or sample retention.
- [x]   4. Run focused tests, full SDK and clean Streaming suites. Refresh `scorebug.patch` from upstream receipts plus added files and verify all 162 upstream hashes and patch round trip. Update vendored README and publishing-bounds docs with exact scope/limits.
- [x]   5. Obtain independent spec then quality review, resolve findings and run relevant regressions. Parent runs simulator build-for-testing and unsigned combined phone/Watch Release builds with Xcode 26.2, preserving logs. No new native-media qualification claim until the new owner is connected to a fresh aligned A/V capture window.
- [x]   6. Hash changed sources, current runtime inventory and all new evidence; verify all 3,562 prior frozen files unchanged. Record check outcomes, limitations and next integration step in the main plan and final manifest, then commit this foundation.

## Verification commands

Run sequential Apple work with `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:

```sh
swift test --package-path vendor/HaishinKit --filter CandidateTransportMeasurementTests
swift test --package-path vendor/HaishinKit --filter VideoCandidateEncoderTests
swift test --package-path vendor/HaishinKit
swift package --package-path ios/Packages/ScorebugStreaming clean
swift test --package-path ios/Packages/ScorebugStreaming
python3 vendor/HaishinKit/verify-scorebug-patch.py
git diff --check
```

All final checks must pass. Preserve failing red/regression logs, and use new filenames for corrections. Reuse the existing isolated `codex/local-validation` worktree. The next integration must align live AAC observations to candidate source timestamps, invalidate on live-owner changes and pressure, independently verify the serialized accounting, and combine it with repeated fresh headroom before enabling upward trials.

## Completed verification

The finite mux owner and validated video-consumer hook are implemented. Red tests
proved missing accounting/consumer behavior, invalid AAC profile/rate/frame count,
the native failure-forwarding race, and mislabeled/non-VCL startup frames. Final
focused tests pass 34, SDK 259, Streaming 123, native model 309, and tooling 1,795.
Clean simulator and unsigned combined phone/Watch Release builds pass, with both
Watch architectures. Spec and quality reviews approve the final code. The patch
round trip verifies all 162 upstream hashes; a patch-generator whitespace issue
was corrected without changing source behavior. Initial and final logs remain
separate.

All 3,562 prior frozen evidence files are preserved. The final source/runtime and
evidence hashes are recorded in
`artifacts/qa/candidate-transport-cost-final-verification.json`. This component is
not yet connected to a fresh concurrent native A/V window or bandwidth admission.
The real VideoToolbox unit integration uses structural AAC fixtures; it does not
qualify captured audio decoding, media delivery, or production automatic upgrades.

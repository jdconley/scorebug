# Stream-owned video profile replacement

Continue the explicit encoder lifetime gate in `4158f37`. Implement inline using
executing-plans and TDD under the existing autonomous-work authorization.

## Contract and choices

An unchecked settings write cannot establish either a safe lifetime or an applied
profile. Restarting the entire publication would also interrupt audio and discard
transport state. Instead, keep the publication alive and pause its single raw-video
consumer while a captured native encoder drains off the actor. Leave compressed
video, audio and transport consumers running. Use the existing bounded newest-frame
raw queue (plus its one consumer-held frame); count raw queue evictions during the
change rather than promising lossless ingress under overload.

The API accepts current publication generation and target H.264 settings with no
frame reordering. A single owned operation stages new settings after drain and
waits for the first new encoder submission to produce a valid compressed sync sample
with the requested dimensions. Its receipt contains publication and encoder IDs,
old last-submitted and new first-submitted source PTS, observed dimensions, and raw
queue eviction count. This proves pre-mux format transition, not bitrate convergence,
receiver decoding, visual quality or archive independence.

One deadline covers drain and first new output. Cancellation, close, finish, native
failure or mismatched output aborts the live change explicitly. Close invalidates
immediately; replacement caller and finish join its native task before returning.
Publish stays unavailable until that operation and its deadline join. Native calls
cannot be forcibly interrupted: the deadline requests invalidation, not a guarantee
that a wedged platform call returns by a particular wall-clock time. Local recording
is a separate pipeline and must be exercised in later integration runs.

## Steps

- [x] Add a native SRT test with 64→32 dimensions that first fails against a
      not-encoding API stub. Require a receipt only after actual new output, all submitted
      frames reaching pre-mux observation, and finish retaining the final frame.
- [x] Expose the codec's immutable drain handle and last valid submission snapshot
      through OutgoingStream. Implement actor-owned raw pause, receipt and deadline.
- [x] Add deterministic lifecycle tests using finite gated native-session completion
      for timeout/cancel/finish/close and restart exclusion; test conflicting settings,
      bitrate and compressed input, stale generation, native failure, missing output,
      and bounded ingress under pressure. Preserve red results before fixes.
- [x] Run the entire vendored SDK suite sequentially, then streaming package tests
      and the unsigned combined Apple Release build. Review the lifecycle and receipts.
- [x] Regenerate the maintained SDK patch from hash-verified upstream bytes, verify
      exact round trip, document observed limits, and commit with terminal evidence.
- [ ] Expose the qualified API to the app's publisher and run paced down/up changes
      through worker decoding with independent full-resolution local recording; qualify
      pressure and recovery before enabling automatic profile selection.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer` and
`swift test --package-path vendor/HaishinKit --filter SRTVideoReplacementTests`,
then the full suite. Heavy tests/builds run sequentially; no external streaming.

## Implemented checkpoint

The stream-owned API now uses one immutable native drain task, one paused raw input
consumer, and one receipt continuation. The default raw bound remains two queued
frames plus the consumer-held frame. No extra media queue or per-frame task was
introduced. A receipt names the old last submitted source PTS and new first source
PTS, both encoder identities, actual observed dimensions, publication generation
and raw queue eviction count. Requested bitrate is not an achieved-rate receipt.
The first output must be a valid compressed sync sample at the target dimensions;
its exact source PTS must match the new encoder's first successful raw submission.
The encoder revision must still be current at output and at final return.

Ten new SDK tests cover real native 64→32 output with final-frame preservation,
bounded burst ingress and counted evictions, continued AAC transport while native
video completion is gated, conflicting mutations, compressed passthrough, stale
requests, unsafe dimensions, missing first output, drain/creation/format failure,
close/cancel/deadline/finish, and return-boundary generation and revision races.
The deliberate 31-frame burst keeps only the consumer-held frame plus two queued
frames during drainage; the receipt and actual outputs account for every eviction.
This is a bounded-pressure test, not a claim of lossless or 24-fps delivery during
an arbitrary native stall.

Review found and fixed two return-boundary races. Final acceptance now rejects
close/restart or failed publication after the owning task joins, and cancelled
callers retire only the captured generation. Finish returns after joining its
interrupted change so it cannot fall through and shut down a newer publication.
A further review found stale encoder revisions within the same publication. The
new delayed-output regression submits a real native-encoded fixture through a
controlled session, invalidates the revision after raw submission but before its
first compressed output, then releases output. The old code incorrectly mux-observed
that output and kept the stream live; the corrected gate rejects it before muxing.
The final-return regression separately reproduces pending settings invalidation.
All red results are retained. Review approved the corrected source without running
competing workloads.

The first full-suite attempt exposed a test assumption, not a weakened transport
policy: closing a stream during an in-flight socket send can retire that connection.
A bounded diagnostic reproduced `transportWriteFailed` on the connection while
stream and muxer errors remained nil. The reuse-specific tests now deliberately
hold TS startup on a missing expected audio track, ensuring no socket send exists
when exercising native lifetime and same-connection reuse. Other tests exercise
normal video transport and continued real AAC output. No timeout was relaxed and
terminal socket cancellation behavior was preserved.

Validation: 155 SDK tests, 55 streaming-package tests, and unsigned combined iPhone/
Watch Release build pass on the selected Xcode 26.2 toolchain. Native SDK tests run
on this Mac; this checkpoint does not claim new iOS runtime or physical-device
qualification. The documented SDK patch reconstructs from `4158f37`, verifies all
162 original upstream hashes, and applies forward byte-for-byte to current sources.
Test/build processes are sequential and joined before the evidence manifest.

The app still uses fixed profiles. Next expose this API through its publisher,
exercise paced down/up changes through worker decoding while independent 1080p
recording continues, then qualify network pressure/recovery and longer soaks before
enabling automatic selection. The earlier 348–417 ms isolated encoder delivery gaps
remain a limitation to measure through that full pipeline. Physical phone/Watch and
other-host qualification remain open.

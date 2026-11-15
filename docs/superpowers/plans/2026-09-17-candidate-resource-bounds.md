# Candidate Resource Bounds Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. SDK implementer owns codec/tests/README only; parent owns native evidence and independent Node qualification. Parent alone runs heavy tests and regenerates provenance patch. Spec and quality reviews follow. Autonomous goal authorizes implementation.

**Goal:** Allow the measured 14-input native startup buffering within explicit independent count and raw-byte bounds, then qualify concurrent recording/live/candidate video measurement.

**Architecture:** Keep raw ingress queue4, per-input16MiB, total121frames, source span4.25s and admission8s. Replace four total unresolved inputs with16 plus an aggregate64MiB outstanding raw-payload limit, reserved synchronously before enqueue and released only by validated compressed output dequeue. Capture admission time and actual raw byte count in every completed frame; no new tasks/queues/encoder recipe changes. DEBUG native evidence moves to version2. Independent verifier preserves historical v1 semantics, while v2 requires admission-to-dequeue count/byte reconciliation. Fresh live harness explicitly requires v2, preventing legacy evidence from satisfying the new gate.

**Tech Stack:** Swift6, HaishinKit vendored patch, XCTest/Testing, Node, Xcode26.2, native iPhone14/iOS17.5 simulator, pinned local relay/worker pipeline.

## SDK task (independent agent)

Files: `vendor/HaishinKit/HaishinKit/Sources/Codec/VideoCandidateEncoder.swift`, `vendor/HaishinKit/ScorebugPatchTests/VideoCandidateEncoderTests.swift`, `vendor/HaishinKit/README.md`.

- [x] TDD count16 acceptance/17 rejection while native outputs withheld and input queue drains; independent64MiB rejection below16 with actual large CVPixelBuffers; credit recycling after validated output; callback without output does not release bytes/count; ingress queue4 remains bounded; exact frame admission and raw-byte evidence; existing deadline/cancel/native-failure/join coverage unchanged. Parent runs red then green Apple tests, agent prepares tests first and waits.
- [x] Frame fields `public let admittedAt: Double`, `public let rawByteCount: Int`. Record holds both from accepted offer. State counter outstandingRawBytes starts0, reject `unresolvedInputLimit` when unresolved>=16, `unresolvedRawByteLimit` when rawBytes>64MiB-outstandingRawBytes; reserve count/bytes before yield, failure remains terminal. Decrement both only after complete output validation alongside frame creation. Completed result requires zero outstanding raw bytes as well as all existing joins. Cancellation/native failure do not invent success or silently release reservations early. Keep raw stream bufferingOldest(4).
- [x] README explains separate raw ingress/unresolved count/aggregate bytes, native allocation exclusion, finite video-only cost. Do not edit patch or upstream-files; parent regenerates patch from verified unchanged upstream.

## Parent integration task

Files: `docs/sdk-publishing-bounds.md`; `ios/Sources/Scorebug/Capture/NativeCandidateFixture.swift`, `ios/FilmModelTests/NativeCandidateFixtureTests.swift` as needed; `scripts/native-candidate-measurement.mjs`, `scripts/test/native-candidate-measurement.test.mjs`, `scripts/test-native-app.mjs`.

- [x] Node TDD v2 acceptance of14-frame startup backlog/16boundary within64MiB; reject17unresolved, aggregate overflow, missing/invalid raw bytes/admission times, admissions before measurement or after native submission, non-increasing admissions, fake total resource declarations, v1 at fresh gate. Preserve v1 historical verifier contract and4bound.
- [x] New v2 evidence root adds `resourceLimits:{rawQueueCount:4,unresolvedInputCount:16,unresolvedRawBytes:67108864,rawBytesPerInput:16777216}` and frame admittedAt/rawByteCount. Reconstruct occupancy from admission through compressed dequeue using chronological release-before-admission ties (empty intervals consume no time); no false callbacks releasing raw bytes. Return maximumUnresolvedInputs/maximumUnresolvedRawBytes for v2. Keep existing121source inputs/4s/24fps/latency1.5s/pressure/session/keyframe checks. Fresh harness passes requiredFormatVersion:2; optional API default1 preserves historical callers while v2 detected strictly byproof.formatVersion.
- [x] Native fixture export version2 and resourceLimits; serialize SDK frame admission/raw bytes. Add native fixture export regression to verify contract. Do not change normal production adaptation factory.

## Verification and evidence

- [x] Classify previous turn progress; verify and freeze prior evidence.
- [x] SDK focused red then green, full SDK tests; Streaming and native model tests; full tooling; simulator build-for-testing and unsigned combined phone/Watch Release (both Watch slices); exact upstream162hash/patch round trip.
- [x] Spec then quality review. Freeze runtime/source before any native run. Run fixed240p live +360p candidate +1080p archive structured-motion for90seconds with existing full pipeline; require actual fresh candidate v2, complete archive/live source continuity/audio checks. Preserve all failures and immutable artifacts. If it qualifies, consider540p/1080p candidate follow-ups when the question of resolution-dependent resource cost warrants them; don't claim completeA/Vcost or headroom admission.
- [x] Record results in main plan, source/evidence hashes, previous frozen evidence check, reviews, and commit.

The native diagnostic showed14unresolved frames/43,606,080rawbytes.16/64MiB is a measured bounded model with margin, not a guarantee on other devices. If candidate load causes drop/pressure, optional measurement fails and recording/live retain priority. Automatic upgrades remain disabled pending completeA/Vcost and repeated fresh headroom admission.

## Verified implementation and native results

The SDK retains the four-entry ingress queue and admits at most sixteen total
unresolved inputs with an independent 64 MiB actual raw-payload cap. Reservations
are released only after validated compressed dequeue. Version 2 native evidence
records admission time and raw bytes; the independent verifier reconstructs both
bounds from admission through dequeue. Historical version 1 rules remain intact.
Fresh full-pipeline runs explicitly require version 2.

The focused SDK suite (18 tests), full SDK suite (243), Streaming (123), native
model (309), and tooling (1,795) passed. Clean simulator build-for-testing and
unsigned phone/Watch Release passed, with both arm64_32 and arm64 Watch slices.
The first incremental Streaming run showed stale consumer struct-layout reads
after the SDK Frame shape changed; a clean rebuild passed with unchanged sources.
The failed log and object hashes are retained alongside the clean result. SDK
provenance verifies all 162 original source hashes and exact patch round trip.
Spec and quality reviews approved after updating `docs/sdk-publishing-bounds.md`.

Three iPhone 14/iOS 17.5 simulator trials qualified simultaneous 1080p recording,
240p live publishing, and a four-second candidate window:

| Candidate | Run                 | Candidate frames | Video payload bytes | Measured video Mbps | Peak unresolved inputs / raw bytes | Archive / live frames |
| --------- | ------------------- | ---------------: | ------------------: | ------------------: | ---------------------------------- | --------------------- |
| 360p      | `native-app-JwRgq3` |              121 |           1,860,688 |            3.721376 | 14 / 43,606,080                    | 3,716 / 3,341         |
| 540p      | `native-app-LuJaB0` |              121 |           1,834,208 |            3.668416 | 14 / 43,606,080                    | 3,717 / 3,341         |
| 1080p     | `native-app-HhSwCB` |              121 |           3,437,688 |            6.879798 | 14 / 43,606,080                    | 3,716 / 3,341         |

All archive and received-live saved ranges had zero source loss at approximately
30 fps. Each archive matched 61 expected audio markers; each live recording
matched 55. Maximum live A/V marker offset was below 66 ms. Receiver acquisition
is separately accounted; this is not a claim that every captured frame was sent.
Candidate maximum encode/dequeue latency remained below 451 ms. Pressure stayed
nominal, with no added drops or rejections during each candidate window. Raw
reports, media, independent replays and immutable hashes are preserved in
`artifacts/qa/candidate-resource-bounds-final-verification.json`.

No automatic quality increase is enabled. Candidate video payload still excludes
audio, MPEG-TS, SRT/IP overhead, retransmissions and required bandwidth margin.
Nominal configured bitrate is not used as measured cost. Next implement complete
fresh cost and headroom admission, then qualify upward trials and recovery.
Long-session impairment/thermal campaigns, physical phone/Watch routes and remote
workers remain separate open gates.

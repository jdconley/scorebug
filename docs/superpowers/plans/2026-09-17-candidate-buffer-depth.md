# Candidate Buffer Depth Diagnostic Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent verifier and spec/quality review. The parent owns native implementation and all heavy runs. Existing autonomous authorization covers this diagnostic.

**Goal:** Measure default native startup buffering with the shared 360p recipe, before designing any change to production candidate resource bounds.

**Architecture:** A test-only direct VideoCodec owner submits finite sequences of 4, 8, 16, 20 and repeated 4 inputs at 30 Hz. Each fresh session uses PublishingCandidateEncoder.requestedSettings and the original 1080p blocks16 fixture starting at frame758. One fixed output consumer records scalar metadata, then a joined native completion drains each case. No codec settings or production code changes. Before each raw allocation reserve 4 MiB against a conservative 64 MiB cumulative allocated-payload budget, require actual CVPixelBuffer data size <=4 MiB and debit actual size; never reclaim that cumulative budget during the case. Native opaque allocations and the fixture texture are separate from raw payload accounting.

**Tech Stack:** Swift/XCTest, VideoToolbox/HaishinKit internal test seam, Node independent evidence verifier, Xcode26.2 iPhone14 iOS17.5 simulator.

## Contract and files

Create `ios/EncoderQualificationTests/EncoderBufferDepthTests.swift`, test `testDefaultCandidateBufferDepth`; existing target discovers source files automatically. Use unchanged VideoCodec output limit8x2MiB. MainActor owns all codec operations; one detached output consumer and one joined detached completion per case. No raw queue or per-frame task. Check admission elapsed <8 seconds before and after each synchronous append; use 30Hz deadlines with minimum 1/60 second after prior return. After last append returns, idle one second, atomically snapshot output count/time, then finish and join even on error. Bound scalar records/errors to20/8.

Create `scripts/encoder-buffer-depth-qualification.mjs` exporting `qualifyEncoderBufferDepth(report)` and `scripts/test/encoder-buffer-depth-qualification.test.mjs`. Create `scripts/test-encoder-buffer-depth.mjs` following the existing owned simulator runner, exact selector/attachment identity and <=512KiB raw payload; retain failed workflow attachment, require native success plus independent validation. Attachment name `EncoderBufferDepth`, artifact prefix `encoder-buffer-depth-`, file `encoder-buffer-depth.json`.

JSON version1 top: experiment `candidate-buffer-depth`, platform `iOS Simulator`, workload `motion-blocks16`, inputWidth1920/inputHeight1080, profile `360p30`, firstSourceFrame758, rawByteBudget67108864, allocationReservation4194304, runs in order default4/default8/default16/default20/defaultRepeat4.

Run fields: name, id UUID, count4/8/16/20/4, startedAt, beforeFinishAt, beforeFinishOutputs, endedAt, rawBytesAllocated, errors string array, nativeFailure null/string, requested (width640,height360,bitRate600000,profileLevel H264_High_AutoLevel,expectedFrameRate30,maxKeyFrameIntervalDuration2,allowFrameReorderingfalse), inputs and frames.

Inputs: frame, offeredAt, returnedAt, rawBytes, encoderSessionID UUID, sourcePTS. Frames: frame, sourcePTS, outputPTS, encoderSessionID, submittedAt, completedAt, dequeuedAt, byteCount, width640,height360,isSync Bool. CMTimes contain decimal-string value/epoch and integer timescale/flags, exact rational fixture identity from origin7395/60 plus frame/30. All timestamps are finite monotonic uptime. Inputs record native lastSubmission after append; callbacks record SDK submittedAt and completedAt, compressed outputs record dequeue inside the checkpoint lock. Require exact one-to-one input/callback/output join, no duplicates, one unique session per case, first keyframe, output bytes1..2MiB, time started <= offered <= submitted <= returned <= beforeFinish and submitted<=completed<=dequeued<=ended (completed may precede append return). All raw sizes1..4MiB, cumulative total<=64MiB and reservation fits before every input. Require >=1 second between last returnedAt and checkpoint, beforeFinish-started<8, and beforeFinishOutputs equals dequeues <= checkpoint. Native failures/errors reject. No required output threshold: valid negative results are diagnostic evidence, not a remedy.

Verifier returns compact per-case counts, totalRawBytes, beforeFinishOutputs, firstOutputAfterInputCount (number of native submissions <= earliest completedAt), peakUnresolvedInputs (submitted until dequeued), peakUnresolvedRawBytes (same intervals weighted by input rawBytes). Compute with chronological events, releases before admissions at equal times; no impossible negative occupancy. First output threshold is observed under this pacing, not an exact hardware queue capacity. Report smallestCaseWithOutputBeforeFinish or null, and remedyQualified:false.

## Steps

- [x] Freeze previous evidence, classify preceding turn as progress, inspect codec lifecycle and fixture payload format.
- [x] Verifier TDD: well-formed drained-only and early-output cases; malformed recipe/order/identity/PTS/session/timestamps/bytes/counts, stale/duplicate output, false snapshot counts, incomplete join, impossible budget, violated one-second idle or admission window. Save red/green logs under candidate-buffer-depth-\*.
- [x] Implement finite native XCTest and isolated runner; output bounded evidence before assertions and always join native work.
- [x] Run native diagnostic, independently interpret output threshold and byte accounting; preserve all raw artifacts. Do not infer physical behavior or complete candidate cost.
- [x] Spec then quality review; tooling tests, simulator build and unchanged SDK provenance; verify frozen evidence, record source/runtime inventories, update main plan and commit.

## Follow-through

Use observed retention and raw-byte accounting to propose a bounded production owner only if evidence supports one. Preserve production four-input bound until then. A changed owner must pass cancellation/deadline/pressure tests and simultaneous local archive/live/candidate qualification before quality admission. Full A/V overhead, network headroom, thermal behavior and physical phone/Watch validation remain separate gates.

## Native result

The iPhone 14/iOS 17.5 run `encoder-buffer-depth-oICaqc` completed all five cases
with exact input/callback/output reconciliation and no native errors. Each input
contained 3,114,720 raw bytes. Both the 16-input and 20-input cases first produced
output after the 14th native submission, peaking at 14 unresolved inputs and
43,606,080 raw bytes (about 41.6 MiB). They delivered three and seven outputs,
respectively, before finish. Four-input, eight-input and repeated four-input
controls delivered no output before finish, then drained every frame. Idle times
after the last append returned ranged from 1.009 to 1.034 seconds.

The largest case allocated 62,294,400 raw bytes cumulatively, within the 64 MiB
budget including the required reservation before every allocation. This establishes
an observed startup threshold for this simulator and pacing, not an exact native
queue capacity or physical-device behavior. The independent result deliberately
retains `remedyQualified:false`.

Next implement an explicitly revised candidate resource model: keep the ingress
queue at four while bounding total unresolved inputs and their aggregate raw
payload. A proposed 16-input/64 MiB bound covers this observed 14-input depth with
a small margin; reject a sample before enqueue when either limit would be exceeded,
and release both reservations only on reconciled compressed dequeue. Keep current
frame-count, source-span and admission-deadline limits. Verify failure, cancellation,
pressure and shutdown semantics, expose raw-byte evidence, then repeat the full
concurrent archive/live/candidate workload before enabling any quality admission.

This diagnostic changes no production encoding or adaptation. Complete audio/mux/
transport cost, fresh headroom admission, physical phone/Watch routes and remote
worker qualification remain open.

Verification completed: all 74 focused and 1,772 tooling tests passed, along with
simulator build-for-testing, the native diagnostic, unchanged 162-file SDK
provenance/patch round trip, and independent spec and quality reviews. The native
raw report replays identically through the final verifier. Source/runtime and
frozen evidence hashes are recorded in
`artifacts/qa/candidate-buffer-depth-final-verification.json`.

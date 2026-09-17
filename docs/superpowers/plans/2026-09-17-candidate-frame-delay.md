# Candidate Frame Delay Diagnostic Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent Node verifier; parent implements the native diagnostic/runner and owns heavy runs. Spec and quality reviews follow. The autonomous goal authorizes this bounded experiment without another approval round.

**Goal:** Determine whether native frame buffering causes the four-input candidate rejection, then select the next implementation from measured evidence.

**Architecture:** A test-only session factory changes only MaxFrameDelayCount and verifies the native write/readback before first input. Use the exact PublishingCandidateEncoder requested settings for 360p and the existing 1080p blocks16 source. Run default-idle, limited-idle, limited-continuous and repeated-default-idle in one isolated simulator workflow. Each idle case submits four frames at30Hz, waits one second, snapshots output count and joins native finish. Continuous submits121frames over4s. The committed SDK's four-unresolved-input bound is unchanged. No archive, live publisher or production settings change in this experiment.

**Tech Stack:** Swift/XCTest, VideoToolbox, existing candidate encoder and camera fixture; Node strict evidence validation; Xcode26.2/iPhone14/iOS17.5 simulator.

## Files and contract

- Create `ios/EncoderQualificationTests/EncoderFrameDelayTests.swift`; add ScorebugStreaming dependency only to `ScorebugEncoderQualificationTests` in `ios/Project.yml`. Obtain settings from `PublishingCandidateEncoder(scope:profile:.low360).requestedSettings`.
- Create `scripts/encoder-frame-delay-qualification.mjs` and `scripts/test/encoder-frame-delay-qualification.test.mjs` for independent validation.
- Create `scripts/test-encoder-frame-delay.mjs`, using existing owned-command/simulator helpers. Export exactly the test's attachment even when XCTest fails, retain raw evidence, qualify separately and always join/delete only the owned simulator.

JSON version1: `experiment:"candidate-frame-delay"`, `platform:"iOS Simulator"`, `workload:"motion-blocks16"`, `inputWidth:1920`, `inputHeight:1080`, `profile:"360p30"`, `firstSourceFrame:758`, `runs:[...]` in order `defaultIdle`,`limitedIdle`,`limitedContinuous`,`defaultRepeat`. Each run has `name`, `id` UUID, `requestedMaxFrameDelayCount` null/3, `propertySetStatus` null/0, `propertyCopyStatus` OSStatus, `propertyValue` integer(-1 or nonnegative) for successful copy; null for unavailable baseline copy (limited cases require status0/value3), `propertyObservedAt` nonnegative uptime, `startedAt`,`beforeFinishAt`,`endedAt`, `beforeFinishOutputs` integer, `acceptedInputCount`,`outputCount`, `outcome`,`failure`,`nativeFailure`, `encoderSessionID` UUID, `requested` settings(width640,height360,bitRate600000,profileLevelH264_High_AutoLevel,expectedFrameRate30,maxKeyFrameIntervalDuration2,allowFrameReorderingfalse), `inputs` array({frame,offeredAt,accepted}), `frames` array({sourcePTS,outputPTS,encoderSessionID,submittedAt,completedAt,dequeuedAt,observedAt,byteCount,width,height,isSync}). CMTime fields are value/epoch decimal strings,timescaleinteger,flagsinteger; reuse fixtureFrameID for exact rational identity.

## Steps

- [x] Freeze previous evidence/runtime and classify preceding turn as progress.
- [x] Verifier tests first: good four-case fixture; malformed/missing/extra/crossed cases; property write/readback failures; old/mismatched sessions; incomplete outputs; invalidPTS/time/bytes/dimensions; impossible>4unresolved traces; default callbacks before drain; limited idle with no output; continuous cadence below24fps. Run red then implement and green. Export `qualifyEncoderFrameDelay(report)` returning compact case counts/timings/payload and interpretation. All failure outcomes reject; observed default retention is required for this specific simulator reproduction.
- [x] Implement bounded native experiment with output observer protected by NSLock, fixed tasks, source allocation before paced deadlines and autoreleasepool per sample. Default factories read property without writing; limited factory uses `mode.makeSession(codec)` then set/copy `.maxFrameDelayCount` before returning the session for first append. Do not invent a readback when unsupported. Keep first failure and always attach joined results. Assert full reconciliation and requested limited property; independent verifier owns causal interpretation.
- [x] Add isolated runner with owned process cancellation/timeouts and attachment identity/size checks; use a fresh artifact prefix per run. Native XCTest selectors exact, architecturearm64, no signing. Require successful workflow and independent qualification for a diagnostic pass.
- [x] Run simulator diagnostic; retain all failures. If limit3 releases frames within four-input budget and both default controls retain them until drain, buffering hypothesis is supported for this simulator. If not, inspect evidence and revise hypothesis without changing production guards.
- [x] Review spec then quality, run affected tooling tests and simulator build, verify unchanged SDK provenance and all previous frozen artifacts; update main plan, hash sources/runtime/evidence and commit.

## Follow-through gate

A passing isolated experiment only identifies a candidate remedy. Production integration must add a verified settings path shared by live and candidate encoders, preserve unsupported-property failure behavior and existing defaults until fully qualified, then repeat simultaneous native recording/live/candidate qualification. It must not equate requested settings, successful set calls or this isolated cost with spare uplink capacity, complete A/V overhead, thermal safety or physical-device support.

Existing native snapshots from `encoder-half-resolution-Y3ImPf` show default
MaxFrameDelayCount readback unavailable (-12900). Preserve that evidence rather
than aborting or inventing a baseline value. The unchanged control still encodes;
the limited case must prove both successful set and exact readback3 or fail.

## Observed result and next step

Native run `encoder-frame-delay-hwLLBB` completed and retained its raw attachment
and failed XCTest result. Both unchanged controls accepted and eventually emitted
four frames, with zero outputs before finish despite 1.009 and 1.011 seconds of
native submission idle time. Their first callbacks arrived about 8.5 ms after the
finish checkpoint. Both limited cases rejected MaxFrameDelayCount with OSStatus
-12900 (`kVTPropertyNotSupportedErr`); no frame-delay remedy is qualified. Default
readback was also unavailable and remains explicitly unknown.

The final independent verifier reports the unsupported native property before
secondary missing-session metadata. Review regressions additionally require a
full second of native submission idle time and closure within the SDK admission
window. Those verifier-only corrections were replayed against the unchanged raw
native evidence; the native test and runner did not change after execution.

Verification: 85 focused verifier tests, 1,698 full tooling tests, simulator
build-for-testing, exact 162-file SDK provenance and patch round trip, and spec
and quality reviews passed. Frozen evidence is recorded in
`artifacts/qa/candidate-frame-delay-final-verification.json`. The native diagnostic
failed its remedy gate as intended for an unsupported property; this is not a
successful streaming or candidate-cost qualification.

Next measure default native buffering depth using a finite test-only sequence
and an explicit aggregate raw-byte budget. Preserve the production candidate's
four-unresolved-input bound until the required depth and a revised resource model
are supported by evidence. Then repeat concurrent archive/live/candidate testing.
Production automatic upgrades, complete A/V cost and network-headroom admission
remain unqualified.

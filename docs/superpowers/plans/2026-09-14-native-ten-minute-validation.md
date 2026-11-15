# Ten-minute native validation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent bounded core-observer change and specification/quality reviews. Reuse existing agents only when session capacity prevents fresh agents.

**Goal:** Qualify a 600-second simultaneous native recording and streaming hold on this Mac, preserving full video-window evidence and every existing media/delivery gate.

**Architecture:** Keep the production observer default at eight windows. Extend its explicit configurable ceiling from 64 to 128, and select 128 only for DEBUG simulator holds over 180 seconds. The test-only API evidence collector also accepts an explicit 128-window bound. This avoids adding periodic file I/O to the archive-pressure workload. Existing short and three-minute configurations remain unchanged.

**Tech stack:** Swift bounded observation accumulator, XCTest/UI tests, Node test runner, existing local native publishing/recording and VideoToolbox worker/direct RTMP receiver.

## Design decision and scope

The previous goal turn made verified progress: the 180-second hold passed with complete archive/live video, 39 steady 30 fps windows and no archive rejection/drop. It does not complete the ten-minute requirement or resolve the prior archive overflow.

Two approaches were considered: an incremental snapshot journal with periodic I/O, or a modest larger bounded observation capacity. Choose 128 windows: 120 cover the requested ten minutes, leaving eight for startup/drain. If startup overruns that capacity, zero-eviction checks still fail; no history is silently discarded. This changes the accepted optional core capacity, but default production runtime behavior, five-second windows, media queues, recording, encoding and adaptive policy remain unchanged. Test capacities are trusted configuration inputs, not supplied by an artifact.

The 600-second hold exceeds the old 600-second outer command deadline. Long holds therefore use a workflow deadline of `600000 + (holdSeconds - 180) * 1000` ms and explicit XCTest allowance `holdSeconds + 180` seconds; existing holds retain their existing outer deadline and XCTest settings. Current export and per-media-operation limits remain unchanged unless actual timing evidence requires adjustment. All children remain owned and joined; no external systems or broadcasts are touched.

## Task 1: Core bounded history

Files: `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/VideoFrameObservation.swift` and `Tests/ScorebugMediaTests/VideoFrameObservationTests.swift`.

- [x] Add failing tests: an explicit 128-window accumulator retains 600 seconds of five-second windows without eviction, then evicts deterministically at its bound with accurate omitted count/time; the default still retains eight; zero and 129+ are rejected. Observe actual samples so coalesced empty gaps cannot stand in for history.
- [x] Change only the constructor's supported range from `1...64` to `1...128`. Run focused red/green tests and the complete Media suite. Parent performs both reviews and Release checks. Do not modify cadence, counters, rotation, scope or core defaults.

## Task 2: Ten-minute fixture wiring

Files: `scripts/native-streaming-options.mjs` and tests; `scripts/native-streaming-fixture.mjs` and `scripts/test/native-decoded-evidence.test.mjs`; `scripts/video-observation-qualification.mjs` and tests; `scripts/test-native-app.mjs`; `ios/AppUITests/NativeStreamingTests.swift`; `ios/Sources/Scorebug/Capture/VideoObservationFixture.swift`; `ios/FilmModelTests/VideoObservationFixtureTests.swift`.

- [x] Fail-first options tests extend canonical holds to 12..600. Absent remains hold12/history8; explicit holds through180 retain64; 181..600 choose128; 601 and malformed/nonstreaming/non-direct inputs fail. `qualifyNativeStreamingHold` accepts the same bounded duration and still requires at least hold\*30 saved source frames.
- [x] Add `nativeStreamingTestBudget(holdSeconds)` returning `{workflowTimeoutMs, testExecutionAllowanceSeconds}`: 12..180 =>600000/null, 181..600 =>600000+(hold-180)\*1000 / hold+180. Validate canonical numeric bounds; test default, boundaries and invalid values. Runner uses the outer deadline and, for nonnull allowance, Xcode's documented test-timeout flags. Persist budgets with configuration/results before resources.
- [x] Extend Swift UI parsing and explicit DEBUG history selection to600, retaining64 through180 and using128 above. Preserve strict finite duration baseline, monotonic elapsed hold, active recording/publisher/worker checks and post-stream archive continuation. Add fixture history tests for full600-second retention.
- [x] Extend JS observation qualification's trusted allowed limits to8/64/128, preserving all zero-eviction, scope, continuity and cadence checks. Add a >64-window fixture that fails without128, passes with128, and still rejects a missing middle frame/window or eviction.
- [x] Add `decodedWindowLimit = 64` argument to the native proxy fixture and collector. Only64/128 are accepted before resources; pass128 only for the validated long hold. Tests prove default bound64, explicit128 capacity and failure at129, including immutable reuse and invalid telemetry checks at the larger bound. Do not change the production API/status history.
- [x] Run focused/full tools, Film tests and Media tests, generic iOS Release build and arm64 simulator UI build. Complete specification and independent quality review; commit the reviewed revision before media qualification.

## Task 3: Isolated ten-minute pressure run

- [x] Run one owned iPhone 14/iOS 17.5 native fixture with direct receiver and `SCOREBUG_TEST_STREAM_HOLD_SECONDS=600`. No concurrent builds/tests/media work. Wait on the actual live session; retain failures and cleanup all owned resources.
- [x] Inspect actual results: >=600 seconds monotonic hold and source coverage, all archive frames, complete live decoded/encoded tail, all five-second observation windows, A/V markers/end coverage, scoring/export, scope and age proofs. Inspect archive first failure and lifetime queue counts plus retained timing/omission limits; distinguish actual worker and receiver exits.
- [x] Save exact revision, configuration and measured result. A pass is this synthetic local simulator configuration only; real camera/Watch routes, earlier overflow attribution, adaptive quality and other worker hosts remain open. If it fails, use retained artifacts to determine the next corrective action without weakening a gate.

## Implementation verification

Both specification and independent quality reviews approve Tasks 1/2 with no remaining
findings. The core focused suite passes 21 tests and full Media suite passes 133;
Film model tests pass 77; the full tool suite passes 268. Generic iOS Release build
(including Watch app) and arm64 simulator UI build-for-testing pass. Red/green and
build logs are retained as `artifacts/qa/native-ten-minute-*.log`. The fixture's old
history failed the new ten-minute retention regression (112 evictions); its revised
bounded selection passes without eviction. No quality thresholds were weakened.

The isolated 600-second attempt `native-app-GyuAnW` at `a2ac272` failed with archive
queue overflow at 616.840 seconds of recording. Failure artifacts are complete.
Recovery yields 616 seconds of consecutive 30 fps archive video; live retains every
worker frame, but the intended hold/stop/continuation workflow did not complete.
Task 3 is executed and analyzed, not passed. See the [overflow evidence and next
regression](2026-09-14-native-archive-overflow-diagnosis.md#ten-minute-reproduction-with-recoverable-evidence).
No ten-minute reliability or physical-device qualification is claimed.

## Final repeat

The subsequent complete run `native-app-6o9S2U` at `a49408c` passes the 600-second
workflow after the independently reproduced writer snapshot lock dependency and
separate report-age collector bound were corrected. Archive 18947 and live 18532
frames are consecutive at 30 fps; no archive rejection/drop occurs, the complete
encoded live tail is saved, and native scoring/export/A/V/observation/age checks
pass. See the [snapshot isolation evidence](2026-09-14-archive-snapshot-isolation.md#complete-ten-minute-repeat-pass)
for exact scope, precursor failures, counters and remaining workload limitations.

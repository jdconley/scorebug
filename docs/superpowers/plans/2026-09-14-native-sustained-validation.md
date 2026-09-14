# Sustained native validation implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for independent delivery qualification and specification/quality review. Existing reviewer agents may be reused when session capacity prevents fresh agents.

**Goal:** Exercise reliable clean native recording while streaming for a three-minute hold, with complete bounded diagnostic evidence and explicit stream-tail assertions.

**Architecture:** Extend only the explicit simulator test fixture. Keep the default short run and production eight-window observer unchanged. An optional hold of 12–180 seconds uses the observer's already-supported 64 completed windows; no core bound or media/queue/quality policy changes. This is an intermediate pressure test before ten-minute qualification, which will need additional bounded evidence collection.

**Tech stack:** Node test harness, Swift/XCTest, existing native capture/recording/streaming, local VideoToolbox worker and qualified direct RTMP receiver.

## Design and alternatives

The previous goal turn made verified progress: the independent recorder now preserves all worker frames through the native encoded tail in a passing short iPhone 14/iOS 17.5 run. Archive overflow remains unexplained. Extending recording alone while streaming briefly would not stress simultaneous output, so extend their overlap. Replacing the observer's eight-window production bound or accepting missing history would change runtime behavior or weaken evidence; instead select its existing 64-window capacity only in the explicit DEBUG simulator fixture. Start at a three-minute hold; a ten-minute run remains required later and is not represented as complete.

No intervention is needed for these local reversible test changes under the approved autonomous plan. Keep source-frame continuity, >=24 fps steady windows, A/V sync/coverage, full archive sequence, scoring, export, scope and age-proof assertions. Collect failure artifacts on any failure. Do not alter queue limits or source pacing absent pressure evidence.

## Task 1: Maintained direct receiver delivery gate

Files: create `scripts/direct-recorder-qualification.mjs` and its tool test. Parent integrates it into `scripts/test-native-app.mjs` after video observation qualification, only when the direct receiver is selected.

- [x] Write failing behavioral tests for `qualifyDirectRecorderDelivery({ recorder, workerEvidence, videoObservation, live })`: a valid qualified observation plus a single matching worker pipeline and natural recorder exit passes; missing tail/interior frames, mismatched scope, multiple attempts, missing/invalid/omitted/incomplete evidence, decoder duplicates/reordering, missing EOF, failed/forced recorder exit and pipeline KILL fail.
- [x] Require native scoped observation and one live file, exact decoded fresh/accepted/output-progress counts equal saved live frames, final saved source ID equal final encoded source ID and `uncompared.encodedTail === null`. Acquisition remains explicit. Validate real worker terminal/exit agreement; code 255 is permitted only with matching recorded SIGTERM, and report it without claiming natural worker EOF. Worker wrapper must exit 0 and evidence must be joined. Return a small JSON qualification summary without raw logs or secrets.
- [x] Run focused red/green tests, integrate reading `direct-rtmp-recorder.json` and `worker-terminal-evidence.json`, write summary into results, and obtain specification then quality review.

## Task 2: Bounded native hold and observation history

Files: create `scripts/native-streaming-options.mjs` and tests; modify `scripts/test-native-app.mjs`, `scripts/video-observation-qualification.mjs` and tests, `ios/Project.yml`, `ios/AppUITests/NativeStreamingTests.swift`, `ios/Sources/Scorebug/Capture/VideoObservationFixture.swift`, `CaptureStreamingModel.swift`, `ios/FilmModelTests/VideoObservationFixtureTests.swift`.

- [x] Fail-first tests for `nativeStreamingOptions({ streaming, environment })`: absent hold gives `{ holdSeconds: 12, completedWindowLimit: 8, extended: false }`. Exact decimal `SCOREBUG_TEST_STREAM_HOLD_SECONDS` in 12..180 requires streaming plus `SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1` and gives limit64/extendedtrue. Reject blank, whitespace, leading zero, fractions, exponent, out-of-range and nonstreaming overrides before creating resources.
- [x] Pass the optional validated hold through the Xcode scheme to the UI test; parse strictly, forward to the launched app, and wait for film duration to advance by that hold after native scoring. Poll with the existing XCTest predicate, using hold+23 seconds timeout; verify recording remains active and publishing/worker status remain healthy at the end. Record configuration in results. Keep default 12-second hold.
- [x] Add DEBUG fixture `completedWindowLimit(environment:)`: exact observation flag plus canonical valid hold chooses64; otherwise8. The simulator's default observation factory uses it; release and nonfixture paths remain8. Tests cover gating/bounds and actual retained history beyond eight windows. No changes to core observer bound64.
- [x] Add trusted `completedWindowLimit = 8` input to JS observation qualification, allowing only8 or64. The runner supplies its validated choice. Longer histories must still have zero eviction and pass every existing contiguous-window, source-count, steady-cadence and scope assertion. Tests demonstrate a valid >8-window fixture fails by default, passes with64, and corruption still fails.
- [x] Run focused Swift/tool checks, full relevant Film model suite, combined release build and specification/quality reviews. Commit before media qualification.

## Task 3: Isolated pressure qualification

- [ ] Run a single maintained iPhone 14/iOS 17.5 native fixture with direct recorder and `SCOREBUG_TEST_STREAM_HOLD_SECONDS=180`. No other builds/tests/media jobs run concurrently. Keep owned-resource cleanup and failure preservation.
- [ ] Inspect actual outcome: full archive/source coverage, live frame tail and worker terminal evidence, A/V end/markers, all complete five-second windows, native scoring/export and age proofs. Inspect archive pressure first failure and terminal counters, retained timings and omitted history; never infer early behavior from a retained tail.
- [ ] Save exact revision/configuration/results and update main plan. If overflow recurs, diagnose it from preserved samples and timings before fixing. If it passes, retain the earlier overflow as unresolved and plan ten-minute evidence collection plus physical-device/Watch and portable-host work.


## Implementation checks before native qualification

Task 2 focused JavaScript tests pass (48), and all 76 Film model tests pass,
including actual three-minute history retention. The full tool suite passes 261
checks, including the 54 direct-delivery regressions. Logs are
`artifacts/qa/native-sustained-{options-red,history-red,tools-focused,swift-red,swift-green,tools}.log`
and `direct-delivery-{red,green,artifact}.log`. Specification review cleared Task2;
final reviews are pending for the complete adapter.

The maintained generic iOS Release build (including Watch app) passes in
`native-sustained-release-device.log`. An extra generic iOS Simulator release build
failed linking x86_64 SRT symbols (`native-sustained-release.log`); this was a broader
destination than the existing device-release check. The current host uses arm64
simulators; Intel simulator linkage is not qualified by the successful device build.
No native pressure run has occurred for these changes yet.


Quality review found that the existing UI duration baseline defaulted to zero when
accessibility was unavailable, which could shorten the requested hold. Both initial
and post-stop baselines now require finite nonnegative values. The hold additionally
requires its full monotonic elapsed time, and a fail-first saved-source coverage
check requires at least holdSeconds*30 continuously received source frames after
delivery qualification. This prevents a successful result with less requested media
coverage; source coverage is reported separately from wall-clock hold duration.

Both specification and independent quality reviews now approve Tasks1/2. Final
checks:262 tool tests,76 Film tests, device Release build and arm64 simulator UI
build-for-testing pass. Configuration is written before owned resources are created
so failed runs retain the exact hold/history choice. No media gates were relaxed.

# Fixture catch-up cadence implementation plan

> Execute inline with the applied debugging, planning, test-driven-development and verification skills. Existing autonomous authorization covers source fixes and local tests.

**Goal:** Prevent a late synthetic producer from emitting its backlog as an unbounded raw-video burst into the unchanged archive queue.

**Evidence:** Pressure attempt `native-app-2jcK34` failed archive queue capacity before probe admission. Frames 635–666 arrived in 129.8 ms; the first retained callback was 1.487 s behind its nominal deadline. The source uses an absolute frame deadline and immediately generates every overdue frame. The initiating stall is not established.

**Design:** Preserve all frame indices, continuous source A/V timestamps and the original nominal deadline recorded separately by diagnostics. The existing `deadline` still denotes the actual scheduled wake; additive optional `nominalDeadline` exposes the original source deadline. Keep ordinary jitter phase-locked to the 30 fps wake schedule. If generation begins at least one whole frame late, advance only the wake schedule by that observed lateness so subsequent frames resume at 30 fps instead of draining missed deadlines. A stall during rendering/callback can leave at most one immediate following frame; it cannot release the entire overdue backlog. The source does not change archive queue capacity, live quality gates or physical camera policy. Actual generation/callback times still reveal lateness and low wall-clock cadence. Source time can lag wall time after a host stall, which remains visible; this synthetic fixture is not evidence that a physical camera preserved frames during such a stall.

**Alternatives considered:** Increasing the archive buffer would only tolerate a larger catch-up burst and increase retained raw memory. Skipping overdue source frames would alter the fixture's continuous video/audio identities. Pacing generation addresses the observed burst at its producer while retaining measurement truth.

**Files:** `ArchivePressureDiagnostics.swift` and its Swift/Node schema tests retain both clock values; `ios/Sources/Scorebug/Capture/FixtureCameraSource.swift`, `ios/FilmModelTests/FixtureCameraSourceTests.swift`, qualification docs and ignored terminal evidence.

- [x] Add a delayed-callback regression that records producer spans and rejects an accumulated burst of generation starts; retain its failure on the original loop.
- [x] Add the missed-wake reset and deterministic normal-jitter/long-stall cadence tests while retaining original nominal diagnostic deadlines. Verify complete paired samples, frame indices/PTS and visible lateness after the injected stall.
- [x] Exercise the delayed source through the real segmented archive writer, preserving every generated video frame and matching audio coverage with unchanged queue limits.
- [x] Run app model tests, ARM64 simulator test build and unsigned iPhone/Watch Release build; review the source/time semantics.
- [x] Repeat the scheduled 4 Mbps native probe run on the fixed source. Preserve any new failure as evidence; do not lower archive, live-cadence or acceptance gates.

**Limits:** This fix does not identify the original host stall or qualify physical capture reliability. The previously failed recording remains failed. Receiver-attributed headroom, candidate-cost admission, adaptive quality, native Watch routes and portable-host qualification remain open.

## Verification

The original source fails the bounded-burst regression (`fixture-cadence-burst-red.log`): up to six generation starts occur in a 10 ms window after a delayed callback. The corrected source passes all seven focused fixture tests. With a deliberate 1.5-second callback stall, the real 1080p segmented writer exports all 90 video frames and matching audio, accepts/writes all 180 samples, and rejects/drops none at its unchanged 24 MiB queue limit. The initial native regression had a missing temporary parent directory; that setup error was corrected before its passing run.

All 222 app-model tests and 254 media package tests pass (188 XCTest plus 66 Swift Testing). Normal jitter and long-stall scheduling have deterministic clock coverage; both scheduled and nominal deadlines remain validated. These results establish the synthetic source repair, not physical-camera reliability or a successful network pressure trial.

All 1,112 tooling tests, the ARM64 simulator test build and unsigned combined iPhone/Watch Release build pass. The reviewed runtime source inventory is `artifacts/qa/fixture-cadence-runtime-source.json`; the scheduled 4 Mbps/180-second trial is `native-app-MefG1k`. Its independently checked result follows.

## Native pressure result

`native-app-MefG1k` passes the native UI/scoring/export workflow and all diagnostic media gates, with parent exit 0 and joined teardown. The probe renews 397 times and accepts 3,691 messages (4,857,356 payload bytes) over 40.513851 seconds: **0.959150 Mbps payload / 0.991219 Mbps accounted** against the requested 1 Mbps. It withdraws with `transportPressure`; the last acceptance precedes the final lease deadline by 248.871 ms. Media continues another 140.312 seconds. The reason snapshot does not prove the precise native threshold that triggered withdrawal.

The independent clean archive preserves all 6,366 consecutive 1080p30 identities and 105 expected audio markers, with +1.333 ms A/V end coverage. Fixed540p live preserves all 5,990 consecutive retained identities (192–6181), 99 audio markers and +20.236 ms end coverage. Its 35 startup acquisition frames remain separately accounted. Every reported receiver window meets 30 fps; both full MP4 decode logs are empty.

The 4 Mbps phase lasts 59,998.551 ms and forwards 29,154,464 wire bytes within its ceiling; traffic continues at least 60 seconds after the limit is removed. Proxy totals reconcile exactly with timeline bins: zero drops/errors/foreign peers/pending packets, with 101.311 ms maximum forward residence. Worker, recorder, collector and proxy all terminate cleanly. The archive finishes without a first failure.

The final retained producer has equal scheduled and nominal deadlines, so this successful run does **not** reproduce the original scheduling stall. The causal delayed-callback regression supplies that coverage; the actual trial establishes that the revised source also passes the native pressure/media path. The original initiating stall remains unidentified, and the earlier failed recording remains failed evidence.

`verify-fixture-cadence-native.py` checks runtime source hashes, decodes barcode identities independently, validates renewal/lease bounds, actual scheduled traffic, receiver cadence, A/V coverage, proxy conservation and owner termination. The unchanged control passes; eight damaged copies are rejected (archive identity, live identity, receiver cadence, conserved packet drop, A/V coverage, accepted-rate underdelivery, removed pressure phase, and normal completion substituted for pressure withdrawal). Final review found no source blockers. Its pressure-withdrawal verifier gap was reproduced by the eighth mutation, then closed with an explicit `withdrawn`/`transportPressure` requirement. Source and terminal evidence hashes are recorded in `artifacts/qa/fixture-cadence-final-verification.json`.

**Next:** authenticated receiver accounting for probe delivery and measured candidate-profile cost before admitting quality upgrades. This finite fixed-profile simulator scenario does not establish maximum sustainable quality, physical recording reliability, native Watch network handoffs, remote-host portability or long-soak performance.

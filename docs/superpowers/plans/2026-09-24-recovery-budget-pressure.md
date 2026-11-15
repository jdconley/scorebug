# Recovery-budget pressure implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` in the existing isolated
> worktree. Autonomous implementation is authorized; preserve the broader streaming
> and Watch goal. Run heavy checks serially and reuse installed tools/runtimes.

**Goal:** Distinguish recovered SRT retransmissions from failed delivery in the
local and source-aligned pressure classifier, with independent raw-evidence replay.

**Architecture:** Introduce an explicit transport-pressure policy in the existing
Swift telemetry adapter and JavaScript replay. Preserve both historical fixed
thresholds and the current sender-delay policy. Add `recovery-budget-v1` with known
positive same-collection delay, RTT no higher than min(caller ceiling, delay/4),
backlog no higher than min(caller ceiling, delay/2), and no actual drop increments.
Recovered retransmissions alone do not mark pressure elevated. Missing delay is
unknown; independent known pressure still wins. These gauges do not prove capacity
or received video. All receiver, frame-rate, source, freshness and queue gates stay.

**Tech stack:** Swift/XCTest, existing raw SRT statistics history, Node test runner.

## Decision and boundary

The last retained impaired run has 25 local-pressure decisions caused solely by
short-window retry fractions of 1.1–8.5%, while its 157 receiver windows delivered
30fps on time. Raising the percentage or averaging it over a longer arbitrary
window would still classify recovered packets as loss. The selected policy uses
actual recovery room, consistent with the native probe policy added in27cbf1c.
The half-delay backlog ceiling is a conservative project reserve, not an SRT
standard. The research links and native ownership limits are in the
[probe plan](2026-09-24-recovery-budget-probe.md).

No existing audit schema may silently acquire the new semantics. Current format4
exports, driver configuration and all historical qualification callers retain
`sender-delay-v1`. This batch exposes and tests the new classifier/replayer only;
select it in the app only with the subsequent explicit versioned probe/audit
integration. Full impaired video qualification remains outstanding.

## Tasks

- [x] In `ios/Sources/Scorebug/Capture/PublishingQualityTelemetry.swift`, introduce
      `TransportLimits.Policy: String` with `legacy-threshold-v1`, `sender-delay-v1`,
      and `recovery-budget-v1`. Replace the internal Boolean initializer parameter with
      `policy: Policy = .legacyThreshold`; update the two existing call sites to
      `.senderDelay` so their semantics are unchanged. Add the API while retaining old
      classification first.
- [x] Add tests in `ios/FilmModelTests/PublishingQualityTelemetryTests.swift` for
      recovered retries at65ms RTT/67ms backlog/400ms delay (nominal source and no local
      pressure), known drops/RTT/backlog over reserve (elevated), exact limits, unknown
      delay, and preservation of legacy retry pressure. Observe behavioral red with:
      `xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination platform=macOS,arch=arm64 -derivedDataPath ios/DerivedData/FileCapture -collect-test-diagnostics never -only-testing:ScorebugFilmModelTests/PublishingQualityTelemetryTests test`.
- [x] Implement only the policy-specific differences: apply retry fraction only
      outside `.recoveryBudget`; compare each enclosing sample's RTT and backlog with
      that same sample's delay; return unknown when positive delay is absent and no
      independent pressure exists. Run the focused tests green.
- [x] In `scripts/native-quality-pressure.mjs`, replace the replay Boolean with
      `transportPolicy`, default `legacy-threshold-v1`; validate the three exact policy
      strings. Keep quarter-second windows required for both delay-aware policies.
      Update existing callers in `native-quality-qualification.mjs`,
      `measured-trial-policy.mjs`, `measured-recovery-policy.mjs`, and
      `repeated-measured-policy.mjs` to name `sender-delay-v1` where they previously
      passed true. Introduce the API first, then add behavioral-red tests in
      `scripts/test/recovery-budget-pressure.test.mjs`, then implement identical
      recovery-budget classification. Use raw counter/gauge fixtures with truthful
      claimed pressure and reject mismatched claims, unknown policy, stale/quarantined
      histories and malformed counter deltas.
- [x] Run focused Node tests, all tooling tests and all app-model tests. Independently
      replay the25 preserved retry-only rows as legacy elevated and recovery-budget
      nominal (a diagnostic comparison, not retroactive run qualification). Review,
      record results and commit. Keep current app format4 and production selection
      unchanged until explicit admission/audit integration is ready.

## Evidence checkpoint

The classifier and independent replay are implemented without selecting the new
policy in the app. The existing driver and format4/measured qualification paths
explicitly select `sender-delay-v1`, preserving the prior retry threshold and RTT
behavior. All three policy names are exact; the old JavaScript Boolean option now
fails explicitly so forgotten callers cannot silently select the wrong policy.

Joined logs and exit records use
`artifacts/qa/repeated-live-checkpoint-recovery-pressure-*`:

- `swift-red`:42 tests,12 expected behavioral failures (retry-only pressure,
  missing-delay interpretation and the new backlog reserve).
- `swift-green`:42 passing telemetry tests.
- `node-red`:18 tests,8 expected behavioral failures.
- `node-green`:171 passing focused/new and historical qualification tests.
- `tools-full`:3,675 passing tooling tests.

`artifacts/qa/native-app-0DZ6v4/recovery-budget-pressure-comparison.json` compares all
25 preserved retry-only local-pressure rows. Original raw rows still replay as
historical elevated pressure. A separately cloned claim with the new policy
replays as nominal transport, and the new local classifier finds no eligible
unhealthy endpoint. Both input hashes remain unchanged. This is counterfactual
classification, not a new native run, full controller replay or retroactive pass.
The first comparison records pre-format replay source; a final-source comparison
is retained separately after formatting.

Independent review found no code blockers and confirmed historical policy selection.
It noted the comparison-source hash changed after formatting; preserve both reports
and use the final-source record for the checkpoint. App admission/audit versioning,
bounded pressure export and the full impaired match run remain required.

### Intermittent admission test

The first full app-model run (`app-models`) failed1/525 at
`CaptureStreamingModelTests.testMeasuredProviderBindsLaterRevisionAndV3CampaignWithoutReusingInitialRevision`:
its candidate admission was nil. Isolated `admission-repro` reproduced it. The test
installs a nil quality-driver factory and does not invoke the pressure classifier.
This identifies a separate path, but does not by itself establish root cause.

Temporary failure-only diagnostics in candidate admission and the model then
passed one isolated run plus five repetitions (`admission-diagnostic` and
`admission-diagnostic-repeat`), without emitting a rejection location. Both source
files were restored byte-for-byte before the final full run. No admission limit,
lease, clock constraint or test assertion was weakened. Retain the failures as an
intermittent verification issue; passing repetitions are not a claimed fix.

### Controlled fixture correction

Review identified a concrete timing weakness: the first status sample normally
occurs near start+2.05 after a400ms delay, and the next fixed report at+3.15 leaves
only100ms slack above the receiver tracker's one-second interval minimum. The
actual cause of the two original failures was not captured, so this remains a
plausible explanation of those runs rather than a proven attribution.

A new test adds250ms to the first status delay and reproduces nil admission with
unchanged production code (`admission-spacing-red`, exit65). The test helper now
schedules each subsequent report from the later of its original target and the
previous actual receiver observation+1.1s. It asserts at least one second of actual
observation separation and that each subsequent report produces an interval.
All3 relevant tests pass (`admission-spacing-green`, exit0), and narrow review found
no weakened assertion. Runtime admission/model files have no diff. This repairs
the demonstrated fixture failure without claiming all real-time flakiness solved.

The unmodified full rerun before that fixture correction passed525 tests
(`app-models-confirm`). The final full run after the fixture correction is recorded
separately. `final-node` passes171 tests after formatting. `final-comparison` joins
successfully and writes
`artifacts/qa/native-app-0DZ6v4/recovery-budget-pressure-comparison-final.json`
against the exact final replay source. Both original input hashes still match.

Final verification: `final-app-models` passes all526 tests with exit0; `final-node`
passes171; the complete tooling run passed3,675 before whitespace-only formatting.
Final comparison hashes were rechecked against both unchanged original inputs and
the current replay source. `git diff --check` passes. No simulator was created,
reinstalled or removed for this work. Existing compiler/runtime diagnostics remain
in logs; these are passing checks, not warning-free builds.

Next: explicit policy identity and raw admission evidence across the app probe,
candidate and audit/host verifier paths; bounded pressure-history export; a fresh
real-match impaired route. Keep production adaptation gated and the broad portable
streaming/Watch goal active.

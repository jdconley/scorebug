# Current native trial diagnostic implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development; independent specification then quality review before committing.

**Goal:** Let the ordinary recovery test distinguish native settings application from successful trial confirmation without changing policy behavior.

**Architecture:** A computed Core diagnostic exposes actual pending/application/trial/reset state. The existing DEBUG current diagnostic publishes it with a deterministic owner fingerprint and accepted source-window identity. The test will later prove confirmation by observing probation followed by settlement under the same owner; a standalone absent trial never means confirmed.

**Tech stack:** Swift Core policy, native session/driver, existing bounded DEBUG accessibility diagnostics, XCTest on macOS.

## Contract

- Add an immutable `Equatable, Sendable` computed diagnostic next to `candidateMeasurementDiagnostic` in `QualityController.swift`. Include applied settings/revision, actual Core pending recommendation/application kinds and targets, active trial, its contiguous healthy duration and rollback requirement, and minimum-reset requirement. Reads have no state changes, clock advancement, effects or authority.
- Do not use `PublishingQualitySession.snapshot.application` as current in-flight state: the session retains its last admitted application after acknowledgment. Use the actual Core fields.
- Add compact fields through the existing DEBUG `currentDiagnostic()` dictionary. Include current Core state only while open. Publish an owner key only when policy, acknowledged receipt and current source ownership are coherently present.
- The owner key is a canonical deterministic digest of the session attempt, applied revision/settings, acknowledged receipt (publishing generation/configuration/acceptedAt/sourcePTS), profile receipt identity where present, and all fields of the existing `SourceScope` equality (observation scope, transport clock, game/generation, worker/epoch/attempt, publication, processing scope). Use sorted serialization and a stable digest such as SHA256; never Swift `hashValue`. Reuse existing exact serializers where suitable, with no new credentials or authority. Source sequence/window end are separate current fields, not part of the stable owner key.
- Source-window metadata must correspond to the accepted current source scope; omit the owner key if that scope is invalidated or cannot be coherently bound. Closed sessions omit owner/trial fields even though internal receipts remain retained. Do not add confirmation history, caches or a remembered success flag.
- Keep the existing 4096-byte serialization bound and callback ownership guards. Current retained run14 diagnostics are603–2225bytes; verify the complete populated object fits rather than relying on empty/minimal cases. Stop/replacement must still clear diagnostics and reject stale callbacks. Keep fields out of the Release UI.
- Future confirmation gate: observe acknowledged360 in active probation, then no trial at the identical owner/receipt/revision/source scope, with no pending recommendation/application/reset/rollback and a newer accepted source sequence. Only that transition can establish confirmation. This slice adds observations, not the test gate or network trigger.

## Files and steps

Primary files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`, `ios/Sources/Scorebug/Capture/PublishingQualitySession.swift`; existing driver/model only if needed for safe bounded serialization. Tests: Core `QualityTrialTests.swift`; `ios/FilmModelTests/PublishingQualitySessionTests.swift`, existing driver/model diagnostic tests. Avoid unrelated UI/policy changes.

- [ ] Extend real session trial fixtures with dictionary assertions that fail behaviorally before adding the diagnostic. Existing methods `testAcknowledgedTrialKeepsSameDeliveryAuthorityWithoutResettingProbation` and `testOwnedApplicationOutlivesCandidateAuthorityAndConfirmsTrial` already exercise actual admission/acknowledgment/confirmation.
- [ ] Implement the pure diagnostic and coherent owner serialization above. Preserve all freshness,10second trial coverage, timeout, reset, backoff, candidate costs and native operation limits.
- [ ] Verify before advice, pending/application, after acknowledgment, after5seconds and10seconds of actual accepted healthy coverage. Repeated reads must not change policy decisions or native-call counts. A settled snapshot never contains a synthetic confirmed flag.
- [ ] Verify source/telemetry invalidation and timeout cannot look like confirmation; owner changes for each scope/receipt/revision change, accepted source sequence changes independently, minimum reset/fallback revision is visible, and closed diagnostic omits owner/trial data. Verify same source/revision determinism.
- [ ] Verify complete populated diagnostic serialization remains within4096bytes and existing stopped/replaced callback guards still pass. If a proposed field causes overflow, reduce diagnostic representation without dropping required owner components or increasing the limit.
- [ ] Run focused session/driver/model tests and Core trial tests, then relevant related suites; build Debug UI and Release arm64 app. Retain exact commands/exits/counts and source/log hashes under `artifacts/qa/current-trial-diagnostic-validation/`. No live capture alongside builds or tests.
- [ ] Independent specification and quality review, resolve findings, verify final blobs, commit source/tests, and update current plan/session evidence.

Representative pre-implementation behavioral assertion uses the existing diagnostic API:

```swift
let diagnostic = await fixture.owner.currentDiagnostic()
XCTAssertEqual(diagnostic["policyTrialActive"], "true")
XCTAssertNotNil(diagnostic["trialOwnerKey"])
```

The actual fixture must have acknowledged a real trial, not injected a diagnostic
boolean. Add the source-binding fixture setup where the existing test uses only
unscoped Core windows; absence of a coherent source must omit the owner key.

Mac test invocation pattern:
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination 'platform=macOS,arch=arm64' -derivedDataPath ios/DerivedData/FilmModel test -only-testing:ScorebugFilmModelTests/PublishingQualitySessionTests`.
Use the installed toolchain/runtime; no device, signing or simulator changes are required for model tests.

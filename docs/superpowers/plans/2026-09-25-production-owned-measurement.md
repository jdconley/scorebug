# Production owned measurement implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development with specification and quality reviews. Existing user authorization covers autonomous implementation of the agreed native progressive-streaming system.

**Goal:** Make the owned candidate lifecycle available to Release builds and reusable throughout a match, independent of finite laboratory audit retention.

**Architecture:** Promote the existing one-owner lifecycle and neutral candidate snapshot/pressure types into runtime code. Select continuous versus laboratory measurement construction explicitly; continuous mode retains current ownership/settlement and policy cooldown only, while the laboratory retains its16attempt cap and complete bounded audit. Keep test selectors, fixture scheduling and QA export behind their existing diagnostic boundary.

**Tech stack:** Swift concurrency, existing ScorebugCore/Media/Streaming APIs, FilmModel XCTest and arm64 Release simulator build.

## Scope and invariants

- Reuse NativeCandidateAttempt, NativeOwnedCandidatePublisher, PublishingOwnedMeasurementLease and the session/driver ownership paths. Do not duplicate the control loop.
- Extract neutral snapshot/pressure values currently nested in debug NativeCandidatePublisher; legacy fixture may use type aliases to preserve behavior.
- No runtime control branch may depend on a diagnostic audit existing or accepting another row. Avoid constructing JSON histories on the continuous path; bounded diagnostics are optional and cannot grant authority.
- Continuous mode has no lifetime16attempt stop or ever-growing attempt history. Exactly one active measurement, exact retirement before reuse, retained predecessor receipt and existing healthy holds/backoff remain mandatory. Laboratory mode keeps16attempts/4096events and existing exported fields.
- Production construction is explicit. Do not silently select the lab500k→2M→12M probe ladder in a Release build. Accept a validated bounded stage plan for runtime construction, preserving existing stage replacement, source-coverage wait before final binding, immutable final binding,300mslease and native pressure policy. Keep the current lab plan unchanged under its fixture constructor. Deriving next-rung rates and production network costing are separate tasks.
- Promote every relevant session/driver cancellation, transfer, acknowledgement, rejection and stop branch, not merely type declarations. Preserve joins and revocation across late native completions. Test-only selectors/export helpers remain test-only.
- Do not enable the ordinary camera factory in this slice; its wiring still needs the network cost contract and selected supported ladder/backend limits. No timing thresholds, buffer sizes or recording behavior changes.

## Files

Primary: `ios/Sources/Scorebug/Capture/NativeCandidateAttempt.swift`, `NativeOwnedCandidatePublisher.swift`, `PublishingOwnedMeasurementLease.swift`, `PublishingQualitySession.swift`, `PublishingQualityDriver.swift`, `NativeCandidateFixture.swift`, and audit/neutral helper files as necessary. Tests: existing owned/session/driver tests under `ios/FilmModelTests`, with a focused runtime configuration/retry suite if useful. Keep generated Xcode source membership coherent.

## Tasks

- [x] Add failing tests for explicit continuous configuration, more than16settled failed/retried attempts with fresh healthy holds, and laboratory16attempt exhaustion. Use actual session policy and owned lifecycle; repeating a fake admission flag is insufficient.
- [x] Add stage-plan validation/binding tests: positive staged rates up to the native12Mbps cap, bounded stage count/holds, final settling at least0.5s, final stage identity, cancellation and source wait before final binding. Preserve original lab plan assertions and whole-history evidence.
- [x] Extract neutral runtime values, promote lifecycle types and session/driver branches, and make audit observation optional/lazy without unbounded retained history. Runtime construction must compile with DEBUG absent.
- [x] Separate continuous attempt lifetime from diagnostic limits. Verify no retry before prior cleanup joins; exercise stop/replacement with held startup, probe allocation, application and late completion using existing regressions.
- [x] Run focused tests then full FilmModel suite. Build the actual Scorebug Release app for arm64 simulator without fixture selectors; do not infer release availability from Debug tests.
- [x] Commit and complete independent specification then quality review; fix findings and record exact validation in the session log.

Use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.

```sh
xcodebuild test -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests \
  -destination 'platform=macOS' -derivedDataPath ios/DerivedData/FilmModel \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData/ProductionMeasurement \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

Focused tests select the changed suites with `-only-testing`. Use unique logs and join all processes. This component does not qualify residual live audio loss, complete recovery, physical paired scoring or production camera adaptation by itself.

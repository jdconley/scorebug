# Recovery-driven candidate measurement implementation plan

> **For agentic workers:** Use one bounded Core readiness implementer while the parent integrates the native request context. Parent runs all heavy verification sequentially, followed by independent review. Continue into repeated campaign scheduling; readiness alone does not complete that feature.

**Goal:** Request fresh candidate/probe work from the existing recovery policy after each fallback, with native work bound to the currently acknowledged publication and encoder settings.

**Architecture:** Expose a nonmutating advisory readiness snapshot from QualityController. The native quality-session actor joins it to its current verified encoder receipt and authenticated source context. The repeated scheduler will reread this context before starting/restarting a v3 campaign and before beginning candidate measurement; final quality increases still require the existing exact admission and probation checks.

**Tech stack:** Swift Core policy, native actor, deterministic Core/FilmModel tests, existing v3 probe transport and paired candidate owner.

## Decision

The last commit d2abe81 passed the complete measured simulator recovery route.
The next missing boundary is policy readiness: recovery duration and cooldown are
private, and duplicating them in a native timer could diverge after repeated failures.
A native receipt from initial startup is also historical after profile replacement.
Use a current policy query and acknowledged session receipt instead. No new threshold
or automatic production activation is part of this interface.

A generic repeating timer is unsuitable because it could start expensive encoder
measurements while disconnected or during pending fallback. Resetting existing
single-use measurement objects would reopen retired authority. Keep fresh paired
objects and explicit joined retirement from the existing campaign owner.

## Core contract

Add immutable Sendable/Equatable `QualityController.CandidateMeasurementReadiness`
with `attemptID`, `appliedRevision`, `baseline`, `settings`, `healthSequence`,
`healthySince`, `healthyThrough`, and `validUntil` fields. Expose:

```swift
public func candidateMeasurementReadiness(at now: Double) -> CandidateMeasurementReadiness?
```

Return nil unless measured-candidate/progressive policy, finite ordered time
(`lastNow <= now <= 1e12`), no application/trial/pending advice/minimum reset,
current strong receiver health, required existing continuous recovery duration,
existing cooldown elapsed, and an exact next setting exists. Health and receiver
must not be in the future or older than two seconds. `validUntil` is the earlier
of health-end+2 and receiver-observed+2. Reading must not advance time, consume a
candidate/sequence, add recovery credit, change settings or authorize a write.
Use existing `higherSettings`, `requiredHealthyDuration` and `trialCooldownUntil`.
Candidate admission retains its existing independently checked overlap/headroom rules.

## Native contract

Inside PublishingQualitySession add a Sendable `CandidateMeasurementContext` with
`readiness`, `applied` (including verified receipt and acknowledgment), `scope` and
`clock`. Expose a non-writing query:

```swift
func candidateMeasurementContext(diagnostics: PublishingQualityTelemetry.Diagnostics) -> CandidateMeasurementContext?
```

It returns nil while closed, busy, cancelled, not publishing, unbootstrapped,
unready, or without authenticated `candidateHealthSource`. Query the current uptime
without renewing evidence. Require exact equality between session receipt and
native diagnostics, current generation/clock, open ingress bound to the same
attempt/match/broadcast, correct receipt bitrate and valid acknowledgment time.
Copy the source recording scope as observed, rather than guessing its observation
revision from policy revision. This is a scheduling snapshot, not cached authority:
future scheduler work must reread after each suspension and final candidate
admission must still revalidate current ownership and measurements.

## Tasks

- [x] Core failing-first tests: startup/unknown/stale/future/time reversal, readiness
      at exact healthy boundary, next bitrate/profile/top profile, no pending/trial/
      application/reset work, invalidation and gap, unchanged policy state/advice,
      post-reset recovery/cooldown and repeated failures. Parent RED, implement, GREEN.
- [x] Native failing-first tests in PublishingQualitySessionTests: real authenticated
      source yields current context; raw policy-only health does not; changed receipt,
      generation, ingress owner, stopped/closed/busy and stale health reject. Show
      reads perform no native write and cannot replace a consumed admission.
- [x] Implement query in PublishingQualitySession using exact current receipt
      comparison and existing Core readiness. Run Core and FilmModel regressions,
      independent review and unsigned iPhone/Watch build; preserve frozen evidence.
- [ ] Wire recovery-ready requests into a versioned repeating v3 probe/candidate
      coordinator. Join prior campaign and measurement before allocating replacements;
      stamp every suspended callback with its campaign and current applied revision.
      Preserve per-campaign audit rather than overwriting the original single-run files.
- [ ] Extend independent replay and native fixture to verify at least two complete
      ramp/reset/recovery cycles. Then qualify physical devices and additional proxy
      hosts before changing production activation.

## Verification

Parent uses licensed Xcode 26.2, the existing local-validation worktree, and unique
`artifacts/qa/candidate-readiness-*` logs. Test commands:

```sh
swift test --package-path ios/Packages/ScorebugCore
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination platform=macOS -derivedDataPath ios/DerivedData -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
```

The user's existing autonomous instruction covers implementation and local tests.
The full portable streaming/Watch objective remains active through these steps.

## Readiness checkpoint

Core readiness and the native current-receipt context are implemented. All 458
Core tests and 412 FilmModel tests pass. A supplemental authenticated-source test
first applies a fallback to a new encoder, then proves that readiness refers to
that acknowledged encoder while the startup receipt remains historical. Other
coverage rejects changed recording/observation scope and transport origin, stale
health, cancellation, pending advice, an in-flight native write and a stopped owner.
A new recording's authenticated source begins its own recovery credit.

The first FilmModel run failed because the extended test fixture rounded the
current time upward when producing pressure samples, making them future evidence.
The fixture now rounds down; production freshness rules were unchanged. Original
failed logs remain preserved. The read-only code review found no production issues.

This context is advisory and is not yet connected to a repeated native scheduler.
The next integration must consume it before allocating candidate work and reread
it after asynchronous native startup. Compare exact publication, source scope,
clock, acknowledged receipt, baseline/target and applied revision; do not replace
that check with the initial videoStartup receipt or reuse retired measurement
objects. A fresh healthy observation may renew scheduling readiness, but cannot
reuse an old candidate result or bypass final candidate admission/probation.

Then add an explicit repeated v3 probe route: start campaign 1, join cancellation
and terminal state, restart a newer campaign with a fresh paired measurement and
fresh authority, preserving separate bounded diagnostics for each campaign. The
existing one-campaign native fixture remains the baseline, not proof of repetition.
Production upgrades remain disabled. Physical devices and other proxy hosts remain
part of the full goal after repeated-cycle qualification.

## Checked native startup integration

The next step uses the real existing measured simulator route before introducing
repetition. Add a checked NativeCandidateAttempt factory whose begin operation
receives the current CandidateMeasurementContext, starts the paired owner with its
acknowledged publishing generation, then rereads the provider. Scope, clock,
receipt, acknowledgment, policy attempt/revision, baseline/target and recovery start
must match; a later fresh health sequence may advance. If cancellation, missing
readiness or changed ownership occurs after allocation, synchronously cancel that
exact id and await its retirement before throwing. Legacy diagnostic routes retain
their existing startup-based factory. No quality-setting operation is added.

Use a one-install NativeCandidateContextReader with synchronous close and no cached
context. It copies the provider under a short lock, awaits outside the lock and
checks closure after return. The actual measured NativeCandidatePublisher owns the
reader, uses it while waiting for the final probe stage, and closes it before stop.
Readiness delay must not turn an earlier probe snapshot into current authority:
after awaiting readiness, recheck time and the probe's live authority before pinning.

CaptureStreamingModel installs the provider after creating PublishingQualityDriver.
The provider checks the active recording/session/attempt and driver before and after
awaiting the quality owner's query. Driver stop and cancellation return nil. The
existing measured flag explicitly selects the checked constructor; missing provider
fails closed rather than falling back to startup metadata.

- [x] Bounded NativeCandidateAttempt implementer: test first for missing/changed
      contexts before and after begin, forwarding current context to begin, newer healthy
      sequence on the same configuration, and cancellation/changed-owner retirement joins.
      Add reader tests for one install, missing provider, close during await and no cache.
      Parent owns RED/GREEN and all heavy checks.
- [x] Parent: wire reader into measured NativeCandidatePublisher, expose guarded
      query forwarding on PublishingQualityDriver, install current provider in capture.
      Add targeted routing/driver tests and keep nonmeasured diagnostic routes unchanged.
- [x] Independent review, complete affected regressions, Release build and a fresh
      full native measured recovery pass. Preserve prior raw media and failed runs.
- [ ] Then implement the versioned repeating v3 campaign scheduler and repeated
      native-cycle verifier from the remaining tasks above.

## Checked startup checkpoint

The actual measured simulator route now installs a current capture-owned provider,
waits for fresh readiness, and checks the same configuration and recovery start
again after native allocation. Missing or changed context retires the exact newly
allocated owner before startup returns. Stop closes the one-install reader before
awaiting teardown. The final probe snapshot must still have live authority and an
unexpired lease after waiting for readiness. Legacy diagnostic startup is unchanged.

Verification: 76 focused tests, all 424 FilmModel tests, all 458 Core tests, and the
combined unsigned iPhone/Watch Release build pass. Independent specification and
code-quality reviews approved. Direct replacement-session/driver integration
coverage remains a nonblocking test gap; component tests cover cancellation and
closure, and the full simulator run verifies the real provider wiring. Two earlier
full test runs were interrupted and retained: new test fakes needed their captured
lease to actually expire and their result stream explicitly finished on rejection.
These were test-harness corrections; production freshness limits were unchanged.

Fresh full native evidence is `artifacts/qa/native-app-ceM4Yc` (original harness
exit 0, with unchanged runtime source hashes). iPhone 14/iOS 17.5 simulator,
240p startup and a measured 360p candidate, controlled decoder stall, 90-second
hold, direct RTMP recorder, local archive and native scoring/export all pass.
The 1080p archive has 3,675 consecutive frames from 0 through 3,674 at 30 fps,
zero source loss and all 61 audio markers. The 360p live recording has 3,299
consecutive frames from 192 through 3,490 at 30 fps, zero saved source loss and
55 matched expected markers, with about 65 ms A/V offset. Archive terminal is
finished with no queue drops/rejections and valid diagnostic timing.

The independent replay qualifies the measured upgrade, controlled fault, fallback
and 14.9986 seconds of shared healthy recovery. It reconstructs all 140 delivery
rows from 1,111 reports, with no unknown or uncertain rows. Two rows fell below
24 fps during the fault; all post-reset rows have zero late/missing frames. This
uses the existing 1.5-second deadline and 250 ms report freshness. It establishes
one recovery cycle; repeatedRampUpQualified, networkLossRecoveryQualified and
productionUpgradeAuthorized remain false.

Next: implement the versioned repeated v3 probe/candidate coordinator, preserving
per-campaign evidence and fresh authority; require two complete native cycles.
Physical phone/Watch and additional proxy-host qualification remain outstanding.

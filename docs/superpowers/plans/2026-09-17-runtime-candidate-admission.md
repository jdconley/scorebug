# Runtime candidate admission implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded implementation and spec/quality review. The parent owns integration, native runs and final evidence. The user's active autonomous goal authorizes proceeding without another approval gate.

**Goal:** Authorize a reversible live quality trial from fresh measured candidate A/V cost, repeatedly delivered probe traffic and current qualified media health.

**Architecture:** Add a measured-only recovery strategy and a separate candidate admission event. Health windows accumulate recovery independently; an absent candidate never creates permission or erases valid healthy coverage. A typed app adapter joins native measurement, current baseline receipt, revocable probe authority and receiver chronology. The existing owned application, acknowledgment, probation and minimum-profile reset handle the resulting trial.

**Tech stack:** Swift Core policy, CoreMedia/VideoToolbox typed candidate results, native SRT probe authority, authenticated receiver tracker, simulator qualification and independent Node replay.

## Decisions and constraints

Reusing `usableVideoCapacity` would confuse nominal video rate with actual whole-stream cost. Reusing receiver-validated trials would retain a capacity-missing bypass. Use a distinct measured strategy. The laboratory overhead convention remains explicit IPv4; unknown mobile/IPv6 routes receive no implicit qualification.

The current observation scope identifies the publishing attempt, not the current policy revision. Bind candidate evidence to the acknowledged baseline settings, revision and exact native receipt separately. Bootstrap must finish before that binding: the old fixture treats every bitrate write as revocation. Native writes intentionally retire the probe after application admission; expiry after that point must not retroactively invalidate the owned two-second application or ten-second trial confirmation.

Candidate freshness is two seconds; source windows are approximately five seconds and leases about 300 ms. Admit against the latest still-fresh healthy window, without reconsuming it or inventing additional healthy duration. Require overlap with candidate measurement. Candidate admission is independent of source-window arrival; no full extra window is required after candidate completion.

## Task 1 — measured-only policy event

Files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`, new `QualityCandidateAdmission.swift` if separation helps, and `Tests/ScorebugCoreTests/QualityCandidateAdmissionTests.swift`.

Add `RecoveryStrategy.measuredCandidateTrials` (requires progressive behavior), and immutable candidate input with this public contract:

```swift
public struct CandidateAdmission: Sendable {
    public let id: UUID
    public let attemptID: UUID
    public let appliedRevision: UInt64
    public let baseline: Settings
    public let settings: Settings
    public let measuredStart: Double
    public let measuredEnd: Double
    public let evaluatedAt: Double
    public let validUntil: Double
    public let candidateTransportBitsPerSecond: Double
    public let deliveredPaddingBitsPerSecond: Double
}
public mutating func evaluateCandidate(_ admission: CandidateAdmission, at now: Double) throws -> Decision
```

- [x] Write focused failing tests: healthy windows alone never increase; missing candidate preserves four-second recovery credit; valid exact-next admission yields a trial without adding healthy credit; actual cost uses a 25% margin; insufficient padding never implies a downshift; wrong attempt/revision/baseline/target, nonfinite times/cost, future/stale cost, stale/nonoverlapping health and replay cannot authorize. Ordinary capacity cannot bypass measured admission.
- [x] Run `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugCore --filter QualityCandidateAdmissionTests` and retain the failing log.
- [x] Implement immutable input, exact proposed-settings validation, bounded one-time chronological candidate consumption, and pending advice bound to candidate identity. Admission expiry is at most the input deadline and latest health/receiver deadline. Preserve existing application deadline, confirmation coverage, timeout, resets and cooldowns.
- [x] Test supersession by source/local/deadline evidence, invalidation, application admission/acknowledgment, trial confirmation after candidate/probe expiry, and rollback. Run the complete Core suite; request spec then quality review.

## Task 2 — typed cost and receiver chronology

Files: new `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/PublishingCandidateCost.swift` and matching tests; `WorkerReceiverProbeTracker.swift` and tracker tests; new app `PublishingCandidateAdmission.swift` and FilmModel tests.

- [x] Convert only a joined successful `PublishingCandidateMeasurement.Result` to immutable actual-cost evidence. Verify identity/profile/scope/generation, requested dimensions/rate, complete mux/audio, finite ordered source/admission/submission/completion times, >=24 measured fps, <=1.5-second per-frame latency and bounded payload/counts. Preserve exact bytes/messages and source/submission durations; never infer actual cost from settings.
- [x] Expose receiver start/end conservative `ContinuousClock` bounds from the tracker's reconciled offset. Retain latest two distinct contiguous intervals in a bounded admission observer. Missing evidence breaks pair coverage, contradictions preserve quarantine, and stage/publication changes cannot splice intervals.
- [x] Build the app adapter using actual native result, current baseline receipt/settings/revision, same-probe binding/current authority and receiver intervals. Compare `1.25 * 8 * (bytes + 44 * messages) / min(sourceDuration, submissionDuration)` with minimum delivered padding payload rate. Require current lease, candidate age <=2s, receiver and last-delivery age <=1.5s, causal coverage/overlap, and newest receiver lower endpoint after candidate completion.
- [x] Add mutation tests for cost, identity, generation, stage, chronology, authority, latest-pair selection, lost coverage, insufficient load and expiry. No JSON parsing in runtime admission; JSON remains independent audit output.

## Task 3 — owned live application and explicit simulator route

Files: `PublishingQualitySession.swift`, `PublishingQualityDriver.swift`, `CaptureStreamingModel.swift`, candidate/probe fixtures, associated FilmModel/UI tests, `ios/Project.yml`, native harness/verifiers.

- [x] Add session candidate evaluation and bind pending advice to its typed authority. Recheck exact current receipt, revision, publication, probe identity and fresh authority immediately before `beginApplication`. Stale advice must dispatch no native writes and must leave recording/live publishing intact.
- [ ] Read candidate input after actor awaits, using a current provider like the delivery input provider. Evaluate after downward/deadline checks. Retain bounded typed candidate results through export; bind only after bootstrap acknowledgment. Normal production routes remain disabled until qualified.
- [ ] Add one explicit simulator measured-trial route: baseline240, selected next candidate, current health, actual native profile and bitrate acknowledgment, ten seconds of post-change receiver health, and reset to240 on unhealthy/unknown evidence or timeout. Preserve independent recording and join all owners.
- [ ] Run local native sufficient-load trial and controlled insufficient-load/withdrawal/rollback cases. Independently decode archive/live, verify source identities/audio, actual candidate accounting, admission timing, native receipts and trial outcomes. Preserve unsuccessful runs without modifying their evidence.

## Task 4 — verification and continuation

- [ ] Obtain spec and quality reviews, run affected Swift/Node/API checks, clean simulator and unsigned phone/Watch builds, provenance and source/runtime/evidence hashes. Recheck all 5,450 prior frozen files. Update main plan and commit only reviewed, verified work.
- [ ] Continue through repeated upward recovery, long sessions, phone/Watch networking and portable proxy deployment. Do not mark the full goal complete from a local fixture or partial contract.

Worktree `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, base `693f962`. Prior goal turn: progress. New evidence prefix `runtime-candidate-admission-`. Heavy Apple/native/Docker/Go jobs are sequential; the parent grants the slot explicitly. No external broadcasts, deployments or license acceptance.

## Integration notes from contract verification

The current control loop already polls every 100 ms when a quality driver or probe fixture is present; its receiver/probe owner still must be read and revalidated after asynchronous candidate retrieval. A cached 300 ms lease cannot be refreshed by relabeling its observation time. Publication and recording identity need a model-owned revocation token when the provider is installed.

The old delivery-failure fixture intentionally disables positive source-health evaluation. A measured route must explicitly permit qualified source-health windows while retaining delivery, cadence and local-pressure priority. A healthy source event without an action must continue to candidate admission in that same cycle.

Keep the existing fixed-profile headroom route and its evidence contracts intact. The live-trial route needs its own opt-in and independent verifier: it must distinguish expected probe/candidate retirement caused by an admitted configuration change from pre-admission withdrawal, and collect native format evidence across the baseline and new encoder. A successful contract test with controlled native operations does not qualify an actual simulator stream or physical device.

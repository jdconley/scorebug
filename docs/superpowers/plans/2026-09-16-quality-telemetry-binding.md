# Quality telemetry binding implementation plan

> **For agentic workers:** Use executing-plans inline with red/green tests and bounded
> independent source review. Run parent-owned Apple builds sequentially.

**Goal:** Convert current, matched native/worker source intervals into quality-policy
windows with verified configuration revisions and explicitly qualified pressure limits.

**Architecture:** An app-layer pure adapter joins source observations to the current
quality-owner receipt and current PublishingSession diagnostics. It rejects identity,
time and applied-boundary mismatches; missing pressure stays unknown. The quality
owner exposes an overload that forms and evaluates the window synchronously within
its actor, preserving atomic revision/receipt ownership. Capture runtime activation
and native impairment trial qualification remain the next required integration step.

**Tech stack:** Swift Core policy, Media bounded diagnostics, Streaming source matching,
FilmModel tests, Xcode 26.2 combined build.

## Contract and choices

Use existing raw bounded histories and exact source capture endpoints. Do not map the
fixed observation `appliedProfileRevision=1` to policy revision zero or infer a current
configuration from report arrival. Require uniform verified encoding coverage equal
to the owner's latest native receipt, same publication generation/attempt, and an
exclusive source anchor at or after the receipt's last-submitted PTS. Require interval
start at or after policy acknowledgment uptime, which can be later than native receipt.
Mixed/old/startup intervals are unavailable, without clipping endpoints or frame counts.

Require current publishing state and receipt identity, valid source duration 1–5.25s,
source end no more than two seconds old, and decoder age upper bound no more than two
seconds under its original report lease. Derive receiver observation time from the
conservative age bound, never from new HTTP receipt time. The local source end and
remote decoder completion are different events. Their causal ordering establishes
completion at or after capture of the matched endpoint. Use the greater of source
end and the age-derived earliest completion as the conservative observation time;
the independent two-second age and source-end gates still apply. Carry native capture,
encoded and worker decoded counts separately; source loss includes capture-to-encoder
and encoder-to-worker losses. Worker output omissions are pressure evidence, not
silently added to these ingress source-loss counts.

Queue pressure is integrated over the source endpoints from the matching open ingress
snapshot. Thermal and transport require open, unquarantined, fresh snapshots with
retained brackets. Transport must match native publishing generation. A currently
publishing session establishes local connectivity only; receiver data separately
establishes worker ingress. No capacity estimate is manufactured.

Pressure limits are explicit caller-supplied qualification data, not production
defaults or auto-detected device capacity. A worker limit names its exact encoder
backend and positive finite maximum observed filter/completion durations. Complete,
nonzero, fully selected processing within limits is nominal current-load evidence;
omissions or known excessive timing are elevated; pending/unknown timing, wrong
backend or absent qualification stays unknown. Validate the report again against the
exact source interval because Swift wire models are mutable. Transport qualification
specifies positive finite maximum enclosing sender-buffer duration and RTT plus a
retransmitted-byte fraction in [0,1). Any enclosing packet drop or excessive gauge/
ratio is elevated; zero enclosing sent bytes is unknown. Unknown transport limits
remain unknown. Sampled thermal nominal maps nominal; fair maps unknown; serious or
critical map elevated. These choices do not prove spare capacity or absence of events
between samples.

Owner snapshots expose acknowledgment uptime; the actor binds its immutable attempt ID internally. Invalid outer
telemetry clears pending recovery/advice and makes a trial rollback-required, without
mutating applied settings. The owner assigns increasing policy ordinals independently of worker decoder sequence.
Duplicate or regressed sequences within one worker scope reject and invalidate advice.
Changed worker epoch/attempt/publication/processing scope resets recovery and makes
an active trial require rollback, even when source intervals remain contiguous.
Pending processing can be resampled before evaluation and before the two-second
source deadline. No runtime task, archive mutation or new polling loop in this slice.

## Steps

- [x] Add `PublishingQualityTelemetry.swift` with a compiled unavailable stub and
      `PublishingQualityTelemetryTests.swift`. Build real source histories, matched worker
      responses, thermal/transport trackers and ingress accumulators in tests. Prove a
      valid source window fails to form before implementation.
- [x] Implement exact ownership, freshness, configuration and acknowledgment boundary
      validation; map measured counts/loss/queue with nil capacity. Test old/mixed/missing
      configurations, crossed generation/attempt, stale/future clocks and source spans.
- [x] Implement explicit worker/transport qualification values and conservative thermal
      mapping. Test missing/closed/gapped/quarantined histories, backend mismatch, pending,
      zero/omitted/contradictory counts, duration limits, transport drops/retransmissions,
      and strict threshold boundaries. No nominal fallback for missing observations.
- [x] Retain acknowledgment uptime in the owner snapshot and bind attempt internally and bind adapter
      evaluation inside the actor. Regression-test rejected external telemetry invalidating
      advice and active trial rollback without dispatching a native mutation.
- [x] Run full FilmModel/Core suites, watchOS10 Core and combined unsigned Release,
      independent source review, format/diff checks, evidence hashes; document and commit.

Commands: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild
-project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination
'platform=macOS' test`; `swift test --package-path ios/Packages/ScorebugCore`;
watch Core build and unsigned combined Release follow the processing report plan.

## Verification checkpoint

Seventeen new adapter/owner tests pass within the complete 158-test FilmModel suite.
All 279 Core tests, arm64_32 watchOS 10 Core compilation and combined unsigned
phone/Watch Release pass using Xcode 26.2. Independent source review approves the
adapter and atomic owner binding.

Behavioral red evidence includes the unavailable adapter stub, missing owner binding
and acknowledgment uptime, restart sequence reuse (`outOfOrder`), and delayed clock
sampling that incorrectly admitted expired decoder evidence. The latter now samples
uptime before ContinuousClock; a 2.1-second delayed uptime read is counted against the
original decoder age. The source review's initially suspected trailing-newline regex
issue did not reproduce with Foundation's String.range API; canonical byte length is
nevertheless explicit and the regression rejects the malformed value.

The tests construct actual source histories, native configuration coverage, matched
worker reports, ingress accumulators and transport/thermal trackers. Six consecutive
qualified windows produce a trial; a subsequent valid new-worker window requires
rollback. Duplicate input cannot issue fresh policy evidence or retain prior advice.
Threshold boundary, missing timing, closed/gapped/quarantined and wrong-generation
history cases remain conservative. No real capture runtime activation occurs here,
so this checkpoint does not claim automatic native adaptation or qualified production
pressure limits. Follow with an opt-in native integration/impairment fixture before
enabling normal capture use.

Source and verification evidence hashes are retained in
`artifacts/qa/quality-binding-final-verification.json`.

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
remote decoder completion are different events: require the normalized completion
bound not precede source end; otherwise evidence is unavailable. Carry native capture,
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

Owner snapshots expose immutable attempt ID and acknowledgment uptime. Invalid outer
telemetry clears pending recovery/advice and makes a trial rollback-required, without
mutating applied settings. Repeated windows remain the caller's responsibility to
coalesce before evaluation; the policy rejects duplicate/out-of-order sequences.
Pending processing can be resampled before evaluation and before the two-second
source deadline. No runtime task, archive mutation or new polling loop in this slice.

## Steps

- [ ] Add `PublishingQualityTelemetry.swift` with a compiled unavailable stub and
  `PublishingQualityTelemetryTests.swift`. Build real source histories, matched worker
  responses, thermal/transport trackers and ingress accumulators in tests. Prove a
  valid source window fails to form before implementation.
- [ ] Implement exact ownership, freshness, configuration and acknowledgment boundary
  validation; map measured counts/loss/queue with nil capacity. Test old/mixed/missing
  configurations, crossed generation/attempt, stale/future clocks and source spans.
- [ ] Implement explicit worker/transport qualification values and conservative thermal
  mapping. Test missing/closed/gapped/quarantined histories, backend mismatch, pending,
  zero/omitted/contradictory counts, duration limits, transport drops/retransmissions,
  and strict threshold boundaries. No nominal fallback for missing observations.
- [ ] Expose acknowledgment uptime/attempt in the owner snapshot and bind adapter
  evaluation inside the actor. Regression-test rejected external telemetry invalidating
  advice and active trial rollback without dispatching a native mutation.
- [ ] Run full FilmModel/Core suites, watchOS10 Core and combined unsigned Release,
  independent source review, format/diff checks, evidence hashes; document and commit.

Commands: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild
-project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination
'platform=macOS' test`; `swift test --package-path ios/Packages/ScorebugCore`;
watch Core build and unsigned combined Release follow the processing report plan.

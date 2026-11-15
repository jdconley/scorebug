# Propagate worker decoded-video status

Add optional `decodedVideo` to worker observations after the decoder collector's
public shape is fixed. This task carries evidence through the existing authenticated
status path; it does not enable adaptive control.

- Define the closed invalid-reason enum and snapshot/window types in the shared
  protocol. Completed windows have sequence, 5000 ms duration, age, fresh/duplicate/
  reordered counts, nullable first/last fresh PTS (ticks at 1/90000), and validity.
  Snapshot includes latest completed window or null, a latched invalid reason or
  null, and terminal ended state. Legacy observations omit the optional field.
- Validate strict bounded numeric/enum/structural values before accepting reports.
  Match/generation/worker/session/attempt checks remain authoritative. Within an
  attempt, completed sequences and source ranges cannot regress; a completed
  window's counts/range cannot change; invalidity and ended state cannot recover.
  An omitted field must not erase anti-regression history.
- Store and return deep snapshots so nested caller mutation cannot rewrite evidence.
  Add monotonic server residence time to completed age on each read; exact report
  retries must not refresh it. This age is a lower bound excluding unmeasured
  worker-to-server transit, and must not yet be treated as a complete quality-policy
  freshness proof.
- The supervisor reads the optional pipeline collector when constructing an
  observation; collectors are scoped to one worker attempt. The bounded reporter
  copies nested telemetry before asynchronous registration. Preserve its single
  in-flight operation and transport deadline.
- Add optional Swift Codable types with Int64 wire counters/timestamps for 32-bit
  Watch compatibility. Missing telemetry is nil and remains omitted when encoding
  legacy fixtures. Preserve explicit nulls within the new snapshot/window shape.
- Test legacy compatibility, malformed/nested/raw values, same-window conflicts,
  omitted-field replay, restart/reset, age/retry/clock behavior, nested ownership,
  and Swift shared fixture round trips. Build watchOS 10 and run protocol/server/
  worker/Core regressions. Obtain independent spec review then quality review.

Runtime A/V tests qualify the collector separately. No new status field may be
presented as viewer delivery, nominal output FPS as freshness, or archived video
loss. Complete cross-machine observation freshness and capacity estimation remain
required before adaptive increases can use this evidence.

## Completion

Implemented with independent specification and quality approval. Final API, worker,
tool, protocol, and Swift Core regressions pass; type checking, watchOS 10 arm64_32
compilation, and the Release iPhone build pass. Native iPhone 14/iOS 17.5 streaming
confirmed completed decoder windows reach the API alongside recording and scoring.
The qualification sampler now rejects later invalidation of an already sampled
window, with behavioral red/green regression evidence.

Adaptive enablement remains outside this task. See [qualification details](../../worker-decoded-video.md).

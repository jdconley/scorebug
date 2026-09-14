# Worker decoded-video observations

Implement the receiver-side measurement required by milestone 4. Existing FFmpeg
output progress stays separate and retains its current health semantics. This task
adds measurements; it does not enable adaptive control or claim viewer delivery.

## Worker instrumentation

- Observe decoded video before frame capping, scaling, overlay, and output encoding.
  Split an observation branch and normalize only its timebase to 1/90000,
  preserving presentation time within half a tick. Keep the live branch timebase unchanged. A fixed metadata marker and the metadata print filter write only numeric
  frame headers and that marker to a dedicated descriptor. Remove any incoming marker
  before adding the constant marker, and strip it after printing. Keep credentialed
  stderr discarded. Do not parse general diagnostics or expose media URLs.
- Pass a distinct telemetry descriptor through the existing guardian while preserving
  its IPC channel, parent-loss cleanup, encoder reaping, and independent progress
  descriptor. Always drain telemetry, including when no observer is installed.
- Add a bounded parser for complete header/marker pairs: nonnegative consecutive frame
  ordinals, signed safe-integer PTS ticks, the exact constant marker, and finite values.
  Ignore no malformed frame evidence silently: latch an invalid observation, discard
  oversized lines safely, and resume bounded draining. Keep at most one bounded line
  and one pending header. Callback exceptions must not stop draining or leak raw text.
- Count strictly advancing decoded PTS as fresh frames. Count repeated or regressing
  timestamps separately, without inflating freshness. Do not interpret missing PTS
  ticks as lost source frames until input cadence is known and qualified.
- Aggregate fixed five-second windows using an injected monotonic clock, starting at
  the first valid observation. Retain only the active and latest completed window.
  Snapshots advance elapsed windows even with no new frames, so outages produce zero
  progress rather than stale healthy counts. Long gaps must advance in constant time,
  not loop once per missing interval. Sequence, duration, age, first/last source PTS,
  fresh/repeated/regressing counts, and validity remain explicit.
- Scope observations to one pipeline instance; a new worker attempt gets a fresh
  collector. A final partial window is not a completed healthy window. Monotonic
  reversal, count overflow, malformed framing, or missing records invalidate evidence.

## Verification

1. Behavioral red/green tests for chunk splitting, duplicate/reordered PTS, ordinal
   gaps, nonnumeric/overflow input, oversized/no-newline input, marker injection,
   callback failure, exact window boundaries, long outages, clock reversal, and reset.
2. Guardian process tests prove descriptor routing, terminal drain, parent-loss
   cleanup, and no credential text in public observations/logs.
3. Real FFmpeg fixtures on the host and current CPU container compare telemetry
   counts/timestamps against known decoded frames, including 30/60/25 fps and a
   source gap. Re-run existing worker timestamp qualification with instrumentation
   enabled to prove unchanged output cadence and A/V coverage.
4. Independent spec review, then quality review. Update protocol/server/native status
   propagation as the next task, with backward-compatible optional telemetry and
   strict attempt/freshness validation, before connecting this to the quality policy.

The observation point is worker decoder/filter ingress. Distinct source timestamps
are a cadence measurement, not image-content analysis, output encoding completion,
or confirmation that a remote viewer received a frame. The current worker process
and archive reliability gates remain unchanged.

## Completion

Implemented and independently approved in specification and quality reviews.
All three encoder environments passed the five unchanged media fixtures; worker
recovery qualification also passed. The strict numeric grammar and combined-count
overflow guard have regression coverage. See [measured behavior and evidence](../../worker-decoded-video.md).

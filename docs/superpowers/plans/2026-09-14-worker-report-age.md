# Worker report age implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement
> this plan checkpoint by checkpoint, with specification then quality review.

**Goal:** Bound the age of worker decoder windows through reporting, API residence,
and native status delivery without comparing clocks on different machines.

**Architecture:** The API issues opaque timing tokens whose issuance time stays on
its monotonic clock. The worker samples its observation after receiving a token and
echoes that token. The API adds the entire token round trip to the sampled age as a
conservative upper bound; Swift adds the entire status request and local residence.
Existing lower-bound ages and process-status TTL retain their distinct meanings.

**Tech stack:** TypeScript, Hono/Zod, Node HTTP, Swift ContinuousClock, XCTest/Vitest.

This extends the approved adaptive-telemetry contract. Fixed 1080p30 remains active;
the change does not establish source-range correlation, usable capacity, viewer
delivery, or adaptive profile application.

## Design and invariants

Comparing worker/server wall timestamps would assume synchronized clocks. A worker
HTTP timeout does not bound server receipt: an abandoned request may arrive later.
Instead use the causal ordering `token issue <= snapshot sample <= API receipt`.
Then `sampledAge + receipt - tokenIssue` bounds age at receipt conservatively.
Round up calculated bounds to whole milliseconds; arithmetic overflow is unknown,
never a clamped finite bound. Overflow remains unknown for that window even if a
later report supplies a smaller candidate. These are bounds on decoder-window age, not source
capture time or viewer latency.

Preserve conservative rounding before arithmetic: upper elapsed time comes from
`ceil(end) - floor(start)` on validated ordered clock endpoints (equal endpoints
can yield zero). Subtracting fractional floating timestamps first can round down
near the safe-integer limit. Add separately rounded age and elapsed only after a
checked integer overflow guard. Apply this to token transit and all later residence.

Add optional `timingToken` to worker session/report responses and report requests.
The token uses the existing bounded identifier format. Keep only current and
previous token plus immutable issuance times per current session. Registration
returns current unchanged. A new accepted report echoing current rotates it to
previous and returns a new current token. Reports echoing previous, missing, or
unknown tokens return current without rotating. Exact retries return current
without changing stored evidence, age, or receipt time. Old sessions cannot supply
timing evidence for a replacement session. No token appears in phone status.

Add server-derived optional `decodedVideoAgeUpperBoundMs` to `WorkerMediaStatus`,
outside the worker-provided observation. Do not accept this field from workers.
For a completed window with recognized token, store its calculated upper bound.
For the same attempt/window, preserve the maximum of a new candidate and previous
bound plus residence. Omission/unknown tokens may preserve an already proven bound
for that same window, but cannot invent one. New windows/attempts start independently.
If the retained lower age exceeds either a prior proven upper bound advanced to
receipt or a newly proven candidate, latch the upper bound unknown for that window
before merging. A larger candidate must not hide contradictory earlier evidence.
Retain age provenance across temporarily omitted telemetry without exposing the
omitted observation. Legacy status shapes remain unchanged when no bound exists.

Use one checked monotonic sample per API operation. Invalid, throwing, nonfinite,
negative, or reversed monotonic clocks latch timing unavailable for that API
instance. Existing process TTL also fails stale in this condition. Telemetry
requests may still be acknowledged and must never mutate broadcast or recording.
Wall-clock changes do not change elapsed ages. No unbounded token history or timer.

Change reporter input to a synchronous observation supplier. Invoke it only after
registration/token receipt; copy its result before serializing. On session_unknown,
register again and resample with a new report sequence. Never tag a previously
sampled object with a newly received token. Null observations send no report.
Coalescing, one total timeout, credential filtering, and legacy APIs remain supported.
Update every production and fixture caller to supply observations at call time.
Check the publish operation's monotonic elapsed deadline after the supplier returns
as well as the abort signal: a blocked event loop can delay delivery of the abort.
This prevents a late POST; it does not claim to preempt synchronous supplier code.

Swift preserves the optional server field and provides an immutable
`WorkerDecodedVideoFreshness` value from a scoped status response and local request
timing. It adds full nonnegative request duration at receipt and ContinuousClock
residence on reads. Invalid/absent age, invalid/ended windows, scope mismatch,
non-producing status, expired process TTL, negative time, or overflow returns nil.
The immutable value retains its game/generation/worker/attempt/window identity and
completed window alongside the timing anchor. Expose the latest value in the Film
model, replace only through existing epoch/scope guards, and clear it wherever
worker status clears or expires. Guard failed worker-status replies by the same
epoch as successful replies, so a late failure cannot clear evidence or stop a
replacement publisher. No policy activation.

Use exact `Duration` arithmetic for native additions after validating the whole-ms
server bound. Check remaining numeric budget before adding request duration or
residence; summing large Doubles first can hide overflow. Reject read instants
before receipt. Require both status and observation to be producing output, and
reject an upper bound below the response's lower-bound window age. Keep zero-frame
valid windows distinct from missing evidence: an age bound does not mean progress.
For Film expiry tests, allow a supplied instant on the existing health-poll method
with a production `.now` default; do not add another timer or sleep-based gate.

## Checkpoint 1: API timing provenance

**Files:** `packages/protocol/src/worker-status.ts`,
`apps/control-plane/src/worker-observations.ts`,
`apps/control-plane/src/routes/media.ts`, new
`apps/control-plane/test/worker-report-age.test.ts`.

- [x] Write failing deterministic API/HTTP tests. Example: issue at 100 ms, sample
  age 50 ms, receive at 400 ms, status at 600 ms => upper bound 550 ms. Change wall
  time independently and require identical elapsed age.
- [x] Cover current/previous rotation, repeated lost acknowledgments, exact retry,
  unknown token, legacy omission, same-window/new-sequence no rejuvenation, omitted
  telemetry, new windows/attempts, retired sessions, restart, malformed token,
  rejected reports not rotating, caller/read mutation, clock faults and overflow.
- [x] Run `pnpm --filter @scorebug/control-plane test -- test/worker-report-age.test.ts`
  and retain a failing log, then implement the bounded protocol and server logic.
- [x] Run the focused tests, full control-plane suite, protocol build and typecheck;
  obtain specification then quality review before committing this checkpoint.

Checkpoint 1 passes 33 focused tests and 240 total API tests. Protocol build and
API/protocol type checking pass. Both reviews approve the final implementation,
including per-candidate contradiction checks and conservative endpoint rounding.
The complete HTTP result matches `packages/protocol/fixtures/worker-report-age-v1.json`.
Logs: `artifacts/qa/worker-report-age-api-{red,green,suite,protocol-build,typecheck,protocol-typecheck}.log`.

## Checkpoint 2: Worker sampling order

**Files:** `apps/home-daemon/src/worker-reporter.ts`, `apps/home-daemon/src/index.ts`,
`apps/home-daemon/test/worker-reporter.test.ts`, and callers found by
`rg 'reporter\.report|\.report\(.*observation' scripts apps`.

- [x] Add failing tests with HTTP registration held until the fixture changes;
  the report must contain the later observation sampled after token receipt.
- [x] Cover missing-session resampling/new sequence, lost ACK token recovery,
  legacy responses, null/supplier failure, coalescing and nested-copy ownership.
- [x] Implement supplier-based reporting with optional tokens and preserved total
  timeout. Run focused/full worker tests and TypeScript checking. Review and commit.

Checkpoint 2 passes 25 reporter tests and 132 total worker tests, with worker and
protocol type checking. Both reviews approve the implementation. The production
worker now samples inside the reporter's callback after registration/token receipt;
API restart resamples with a new sequence. Null observations send no report and
cannot log a reporting recovery. All asynchronous waits share one timeout, and
the monotonic deadline also prevents a late POST after a slow synchronous sample.
Logs: `artifacts/qa/worker-report-age-sampling-*`.

## Checkpoint 3: Native age and local integration evidence

**Files:** `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerStatus.swift`, new
`WorkerDecodedVideoFreshness.swift` and corresponding Core tests,
`ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`, Film model tests,
shared protocol fixtures and their Swift copies, `scripts/native-streaming-fixture.mjs`.

- [ ] Add shared wire round-trip and deterministic native age tests. Server bound
  550 ms + 200 ms request + 300 ms residence => 1050 ms, independent of wall time.
- [ ] Test invalid/legacy/stale/mismatched evidence, monotonic reversal at read,
  overflow, epoch changes in Film model (late success and failure), expiration of
  previously valid evidence, and no extension from repeated reads.
- [ ] Implement optional wire field, native age value, and scoped model ownership.
- [ ] Require bounded-age evidence in the maintained native fixture while preserving
  all current media gates. Run Core/Film regressions, tools/type checks, unsigned
  iPhone/Watch Release build, then one isolated native streaming qualification.
- [ ] Record exact outcomes and remaining adaptive gates in the telemetry contract,
  worker decoder documentation, and parent plan. Review and commit.

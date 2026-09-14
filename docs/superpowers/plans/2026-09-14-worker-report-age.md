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

The current `startStreaming` guard already prevents replacement while `controlBusy`
holds an older request. Preserve that guard. Exercise the reachable regression:
a delayed worker-status failure after Stop must not restore an error or invalidate
cleared evidence; restart remains blocked while pending, then succeeds after the
old request completes. Do not add a test-only bypass to manufacture overlap.

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

## Checkpoint 3: Native age and model ownership

**Files:** `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerStatus.swift`, new
`WorkerDecodedVideoFreshness.swift` and corresponding Core tests,
`ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`, Film model tests,
the shared protocol fixture's Swift copy.

- [x] Add shared wire round-trip and deterministic native age tests. Server bound
  550 ms + 200 ms request + 300 ms residence => 1050 ms, independent of wall time.
- [x] Test invalid/legacy/stale/mismatched evidence, monotonic reversal at read,
  overflow, epoch changes in Film model (late success and failure), expiration of
  previously valid evidence, and no extension from repeated reads.
- [x] Implement optional wire field, native age value, and scoped model ownership.
- [x] Run Core/Film regressions, build Core for arm64_32 watchOS 10 and the combined
  unsigned iPhone/Watch Release target. Review and commit this native boundary.

Checkpoint 3 passes 119 Core tests and 50 Film model tests, the arm64_32 watchOS 10
Core build, and the combined unsigned iPhone/Watch Release build. Specification
and code-quality reviews approve. Behavioral red tests demonstrate the missing
wire field and the late status failure overwriting the post-Stop message before
the changes. Logs: `artifacts/qa/native-worker-report-age-*`. Running-app proof
remains checkpoint 4; automatic quality selection remains disabled.

## Checkpoint 4: Native report-age qualification

**Files:** DEBUG simulator qualification exporter/model hooks,
`scripts/native-streaming-fixture.mjs`, native observation validator and focused tests.

Reuse `SCOREBUG_TEST_VIDEO_OBSERVATIONS=1` under DEBUG simulator compilation. At
each scoped status poll, evaluate the actual native helper once at one monotonic
instant. Save its result, the response's server upper bound, original request
duration, residence since receipt, immutable completed window, and full remote
game/generation/worker/attempt identity. Bind each proof to the current local
recording and publishing-attempt UUID; require an active matching diagnostic
attempt. A proof describes evaluation at that poll, not freshness at export.

Keep at most two proofs for distinct window sequences, oldest first. Replace the
newest proof within the same window; shift only when sequence advances. Reset on
sequence rewind, any local/remote scope change, unusable current helper, worker
clear or TTL expiry. This allows the independent API collector to match the
previous window when the latest window arrives immediately before Stop. Capture
the immutable array before clearing worker state in detach, and pass it through
the existing awaited shutdown export after drain and identity checks. No timer,
per-frame I/O, credentials, media, new UI, or Release behavior. Omit the optional
proof field when empty so existing version-1 fixture serialization stays valid.

Serialize request, residence and actual helper result using Duration components
as decimal strings: `{seconds, attoseconds}`. Require canonical nonnegative
components (seconds within signed Int64, attoseconds in 0..<10^18), parse with
BigInt in JavaScript, and reject total ages above MAX_SAFE_INTEGER milliseconds.
The server bound is a whole nonnegative safe integer. Require exact equality:
`helper = serverUpperMs * 10^15 + request + residence` in attoseconds. Do not use
floating millisecond tolerances that could hide a missing sub-millisecond term.

Independent API evidence retains game and worker IDs plus the optional upper bound.
Prefer a later bounded sample over an unbounded first sample for the same window;
reject changed immutable content under a reused identity. Preserve the existing
invalid-decoder checks, including invalid later samples. Validate both native
proofs, but require at least one match to an independently collected bounded API
window with full remote identity and identical immutable window content. Ages
from separate API reads need not be equal; each upper must separately bound its
lower age. Report an unmatched latest boundary proof explicitly. Missing both
matches fails qualification. This fixture owns one worker run; its attempt number
does not establish a globally unique identity across future worker process runs.

Test omitted request/residence terms, exact sub-millisecond residence, malformed
and overflowing components, missing proofs, local/remote scope mismatches, changed
window content, two-proof replacement/advance/rewind/reset, unusable latest status
and lifecycle clearing, unbounded-to-bounded collector upgrades, differing valid
ages, one unmatched latest proof, and no independent matches. Prefer a separate
`worker-report-age-qualification.mjs` validator so existing frame gates stay intact.

- [x] Export bounded, credential-free evidence that the actual native helper accepts
  a scoped server upper bound and adds request/residence time. Reuse the explicit
  DEBUG simulator flag and joined shutdown export; no per-frame I/O or new UI.
- [x] Require bounded-age evidence in the maintained native fixture while preserving
  all current media gates. Run focused regressions and relevant builds before one
  isolated native streaming qualification, with no concurrent media/build jobs.
- [x] Record exact outcomes and remaining adaptive gates in the telemetry contract,
  worker decoder documentation, and parent plan. Review and commit.

Checkpoint 4 source passes 58 Film model tests, all 135 tooling tests (including
41 focused age-qualification cases), the combined unsigned iPhone/Watch Release
build, and specification/quality reviews. Release excludes fixture markers.
Both stream-stop and recording-stop preserve the old attempt's proof array before
clearing, and restart remains blocked until export joins. Logs use
`artifacts/qa/native-worker-report-age-proof-*`.

The first isolated native run, `artifacts/qa/native-app-mIqwM3`, failed before
qualification: the archive queue overflowed at 34.90 seconds, clearing capture and
publishing. The UI then timed out looking for Stop Streaming. Native scoring had
reached the worker, but stop/export, full media decode and report-age qualification
did not run. The failure screenshot and app diagnostics establish the overflow;
they do not distinguish encoder backpressure from a simulator scheduling burst.
The unchanged 24 MiB queue bounds roughly a quarter-second of 1080p NV12 backlog.
No queue/profile limits changed in response. Preserve failed recordings and bounded
queue/timing evidence before another qualification attempt. This checkpoint's
running-app gate remains open; the source commit does not mark it complete.
Continue with the [archive overflow diagnosis plan](2026-09-14-native-archive-overflow-diagnosis.md)
before another native qualification attempt.

Checkpoint 4's maintained native gate now passes in `artifacts/qa/native-app-yCntsf`
at `9679081` (iPhone 14/iOS 17.5, local Mac VideoToolbox worker). Both exported helper
proofs match independent API windows with full identity and immutable content:
sequence 3 has native/independent server upper bounds 5,090/2,065 ms, and sequence 4
has 2,120/2,080 ms. Different poll ages are expected; exact request/residence addition
and each individual bound are validated. All unchanged media gates passed, with
1,225 archive frames and 799 acquired live frames at 30 fps. Runner exit was 0.

The intervening `native-app-9V41qA` run passed independent age checks but failed its
live A/V tail gate; it remains failed. A deterministic local control-stop race was
then fixed and reviewed, with 74 Film and 119 Core tests and combined Release build
passing. Its relationship to that native failure is not established. The final
passing run still reports 13 encoded terminal frames absent from the sink. Complete
end delivery, the earlier archive overflow, production source correlation, qualified
capacity/queue inputs, profile transitions, impairment and sustained hardware tests
remain open. Report-age qualification alone does not enable adaptive settings.

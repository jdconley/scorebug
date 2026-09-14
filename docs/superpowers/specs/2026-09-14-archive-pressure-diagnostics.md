# Archive pressure diagnostics

## Purpose

The isolated native run `native-app-mIqwM3` stopped recording after an archive queue
overflow at 34.90 seconds. We need to distinguish a delayed simulator source that
catches up, delayed archive readiness, a blocking append, and synchronous segment
persistence. This specification adds observations for the next controlled run. It
does not change queue size, archive admission, source pacing, retry deadlines,
encoding profiles, or any media acceptance gate, and it does not choose a cause.

Periodic snapshots can miss a stall that ended before overflow. Full per-frame logs
add I/O and unbounded history. Use a recording-scoped DEBUG observer with bounded
completed operation spans, current operations, and an immutable first-failure view.
This internal diagnostic work is within the authorized autonomous implementation
and local qualification scope.

## Owner, clock, and bounds

Add a DEBUG-only `ArchivePressureDiagnostics` owner and immutable snapshot types in
ScorebugMedia. Film creates one after `RecordingLibrary.begin` returns its draft ID.
Attach it, before startup, to the same recording session, fixture source and native
segmented writer/receiver. Prepared-only, one-owner attachment returns success;
record separate coverage flags. Missing/custom instrumentation is unobserved, not
evidence that its contribution was zero. Keep existing factories and public media
protocols intact. Do not store media, buffer references, paths, credentials, or raw
error messages in observations.

Enable automatically only under DEBUG simulator compilation and the existing exact
`SCOREBUG_TEST_VIDEO_OBSERVATIONS=1` flag. Mac tests may explicitly inject an owner,
clock and writer. Release excludes the types, hooks and exporter. An absent owner
performs no diagnostic clock reads or exports. Existing retry and source clocks
retain their policy role; diagnostics never control their deadlines.

Use one owner-relative ContinuousClock anchor and an injectable, non-reentrant
`@Sendable () -> ContinuousClock.Instant` reader. Read event/freeze stamps inside
the diagnostic lock so cross-thread arrival cannot create false global reversal.
The source passes its actual ContinuousClock deadline, translated against the same
anchor. Export elapsed seconds as finite Double values within `0...1e12`; retain
source PTS separately as rational CoreMedia scalar values. Reversal or out-of-range
time latches timing invalidity; it must not throw into media code. Failure evidence
still retains available queue/state data with unknown timing. Repeated instants and
zero-duration operations are valid. No diagnostic lock survives an external call.

Keep at most 32 completed producer spans, 64 completed consumer spans, 32 completed
persistence spans, one active producer, one active consumer, and four active
persistence operations. Use fixed-size/bounded scalar storage. Each completed ring
reports its oldest retained time and saturated omitted count. This is a count
bound, not a guaranteed wall-time horizon: a burst can evict earlier causes. Use
checked/saturating counters and explicit invalidity on overflow. Serialize wide
integer counters and PTS value/epoch as decimal strings.

## Producer operation

One span describes one existing fixture frame/audio pair. Preserve frame index,
actual scheduled deadline, generation start, generation end, callback-pair start
and end. Deadline lateness and generation duration are separate values. Record
generation completion before invoking the video callback, because that callback
can overflow. An active producer therefore survives in the failure snapshot even
when the callback pair never completes. Preserve frame indices, PTS, callback order
and the existing absolute-deadline catch-up behavior. Source failures/late teardown
leave unfinished spans explicit; they do not fabricate completion.

## Recording admission and consumer operation

Keep audio/video admission counts separate. Record retained-byte counts and existing
queue limits/counters. Add a narrow DEBUG `Admission.rejectionStatistics` snapshot
to BoundedMailbox, populated by its existing locked rejection helper after the
rejection counter increments. It must represent occupancy at that rejected offer,
before a concurrent `next()` or cancellation can empty the queue. It adds no callback
and does not change admission results. Factor the existing statistics construction
if needed, avoiding another lock acquisition from inside the mailbox lock.

On first recording failure, RecordingCore latches diagnostics while holding its
existing state lock, before mailbox cancellation. For overflow, include the exact
admission reason, rejected kind/bytes/PTS, atomic rejection statistics and written
sample count. The failure stamp describes detection; queue statistics describe the
atomic admission event. Keep this frozen view separate from later shutdown counters,
which may include cancellation discards. Other failures use a finite reason code;
do not export the arbitrary string inside `captureFailed`.

One consumer span covers one dequeued sample and all its append attempts. Retain
kind/PTS/bytes, start/end, current phase and its start, attempt/false-return counts,
total and maximum synchronous append duration, and first observed non-ready time.
Start append timing immediately before the existing `sink.append`; end on true,
false or throw. Preserve active append timing when overflow happens during a call.
Mark successful write completion consistently with RecordingCore's written counter.

`readinessSince` starts at the first false return; its wall duration may include
later append attempts. `retryWaitElapsed` sums only intervals from a false return
until the next attempt (including scheduler delay). At failure/close, retain an
unfinished wait or append explicitly. These timings overlap in defined ways and
must not be summed as independent costs. Do not create per-retry history entries
or change sleep/cancellation/deadline checks.

## Persistence operation

Instrument immediately around the existing `SegmentReceiver` call to `store.append`.
Retain segment kind, byte count, begin/end, and success/failure code. The span covers
store-lock wait, hashing, writes, fsync and manifest work together; it is not a pure
disk-latency measurement and may overlap synchronous append timing.

Use unique completion tokens for up to four active operations. A fifth operation
increments a saturated omitted-active count and marks coverage incomplete, without
replacing a live span or altering storage. Out-of-order completion and slot reuse
must not end the wrong span. Unknown/duplicate tokens are diagnostic invalidity,
never media errors. No completion after close may mutate the frozen result.

## Failure, shutdown and export

The immutable first-failure view contains recording identity, detection reason/time,
available rejection details, component coverage, timing validity, recent completed
spans, and active spans at that one freeze stamp. Subsequent callbacks, writes and
cancellation counters cannot amend it. Final diagnostics separately include terminal
session state/failure, final queue counters, and operations observed through close.

Joined source/session shutdown does not establish delegate quiescence after cancel.
Close the diagnostic owner once after `recorder.stop()` resolves, retaining any
unfinished persistence operation as partial. Ignore subsequent diagnostic calls;
do not wait longer or cancel additional media work to make observations complete.

Film's existing stop task captures that recording's immutable snapshot and performs
one awaited utility export to `QA/archive-diagnostics.json` before clearing its
diagnostic ownership and allowing another recording. Write atomically. Check draft
identity and preserve the original recording outcome if export fails. No per-frame
I/O, new timer, or UI. A repeated stop joins the same work; an old export cannot
overwrite a newer recording's diagnostics. The failure-preservation runner already
copies QA on failure. Passing collection should also preserve this file and validate
its identity, bounded shape, closure and coverage, without inventing a performance
threshold or a root-cause verdict.

## Verification

- Deterministic owner tests distinguish overdue deadlines/fast generation from
  slow generation. Preserve source indices, PTS and callback ordering in hook tests.
- Block an in-flight append, fill a two-item queue, and reject one more sample.
  Assert exact rejection occupancy/reason before cancellation and final drop counts.
  Release the append and advance time; the first-failure value remains unchanged.
- Controlled false returns and retry sleep prove same-sample/order/deadline behavior,
  independent append-call and retry-wait timing, and an active readiness episode.
  A blocked append with no false returns must show active append and no readiness.
- Gate actual segment storage through the existing failure-injection seam. Preserve
  active persistence at overflow independently of append/readiness, and its partial
  status when cancellation closes diagnostics before delegate completion.
- Complete a stall, then process fast samples before overflow. Retain the earlier
  completed span until normal bounded eviction; test burst eviction and omission
  counts without promising a fixed time horizon.
- Test four active persistence spans, an unobserved fifth, out-of-order completions,
  duplicate/unknown tokens and slot reuse. Test clock reversal, simultaneous calls,
  counter bounds, close idempotence and no reads/mutations after close.
- Film tests cover correct draft scope, default-disabled behavior, unsupported
  component coverage, both successful and failed recording shutdown, repeated stop,
  joined export/restart ordering, and exporter failure preserving recording outcome.
- Run relevant full Media/Film/tooling suites, unsigned combined iPhone/Watch Release
  build, and confirm DEBUG fixture markers are absent from Release. Obtain spec and
  quality review before one isolated native reproduction. Preserve failed files and
  inspect recovered media if it recurs. Keep every existing media gate unchanged.

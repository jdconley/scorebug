# Isolate native video submission from the stream actor

Status: reviewed design; implementation pending. Autonomous continuation is authorized.

## Evidence and scope

Source `582a339` fixes measured transport starvation but the 4K real-match case
fails at the 64-item audio codec queue. Conversion occupies about 98% of the final
four seconds. The archive preserves all 360 frames and 576,000 audio samples;
the proxy receives 253 frames. Hardware encoder selection is not established.

Prepare one immutable native video operation on the stream actor, run only its
conversion outside that actor, and commit bookkeeping back on the actor. Audio and
transport can then drain during slow video conversion. Do not move mutable
`VideoCodec` or `OutgoingStream` into an unchecked background closure. Preserve
synchronous codec callers used by other adapters and candidate measurements.

## Operation and output ordering

Preparation owns session creation, current revision, frame selection and capture
of the retained sample, native session, output queue, old failure latch, source PTS,
configuration identity and immutable observers. Allow one in-flight operation plus
the existing bounded raw queue. Native conversion records its actual submission
clock immediately before the call. Submission return and callback completion remain
separate observations. Session creation stays actor-owned initially.

The independent worker must never await the stream, close or a blocking output
consumer. It returns a scalar outcome and retains only its captured publication
owners. Cancellation cannot forcibly interrupt a native call. Errors and callbacks
must never adopt a later publication or configuration.

Use one idempotent actor commit helper for the input consumer, encoded-output
consumer and mutation waiter. Validate operation identity, publication generation
and codec revision. Commit successful `lastSubmittedSourcePTS`, presentation time
and `replacement.first` exactly once. Retain an actor-owned committed/result marker
so a later waiter can distinguish completed work from obsolete work after the next
operation starts. Failed conversion must not commit success bookkeeping.

Conversion may synchronously yield encoded output before returning. The video
consumer snapshots the active operation once, awaits that worker, commits, then
rechecks generation/cancellation/failure before replacement interpretation or mux.
Do not loop waiting for an empty active slot: a subsequent raw operation could
starve output. This retains at most one consumer-held sample in addition to the
existing bounded encoded queue. Audio does not use this barrier.

## Mutation and lifecycle ownership

Reserve mutation ownership before awaiting the active operation so raw submissions
cannot overtake a settings or bitrate request. Join and commit before changing
native properties or producing a receipt. Revalidate generation after every wait.
Keep mutation waiters bounded; reject conflicting ownership explicitly.

`StreamConvertible.setVideoSettings` currently has a synchronous actor requirement.
Change the requirement to async so SRT can wait without blocking; other synchronous
witnesses may remain synchronous. Audit all adopters and clean dependent builds.
Route verified bitrate writes through the same gate. Replacement must read the
actual last old submission after joining conversion, not before. Release raw
admission after `commitVideoReplacement` stages the next encoder, before awaiting
its first-new-output receipt; retaining the gate through that receipt deadlocks.

Finish ends ingress, drains accepted raw input through the existing single consumer,
then completes the native session and drains encoded output. Configuration writes
cannot reopen admission during finish.

Close revokes generation/admission immediately, cancels consumers and releases raw
or mutation waiters. Its existing shared `closeTask` retains retirement ownership:
await only the independent conversion worker before `outgoing.stopRunning()` can
invalidate the session. Do not join input, video, error or transport consumers in
close. The transport's separate retirement rule remains because its error path may
itself call close. Settings and re-publication must respect `closeTask` even while
ready state is idle. Close completion may await native return; document that limit.
Notification-driven invalidation marks the locked revision and revokes stale commits
without destroying an in-use session on the notification callback path.

## Required evidence

Use bounded injected gates, with explicit release and cleanup, to prove:

- Audio PES reaches transport while synchronous video conversion is blocked.
- Only one conversion runs; raw buffering remains bounded with counted evictions.
- A pending mutation prevents another old-configuration submission from overtaking
  it, and its receipt identifies the actual last old frame.
- Replacement output yielded synchronously before conversion returns cannot produce
  a receipt prematurely. Successful return commits once; yield-then-throw and close
  before return cannot publish success or contaminate a later generation.
- Replacement releases raw admission before awaiting its first new sync output.
- Finish preserves accepted tail; close/re-publish joins retirement without a
  self-wait, overlapping sessions or stale receipts. Cancellation is covered.

Preserve queue sizes, deadlines, SRT datagrams, probe authority and independent
recording. Verify maintained vendor provenance and review lifecycle changes before
real media. A scheduling repair does not establish sustainable 4K, physical-device
thermal performance or production automatic upgrades.

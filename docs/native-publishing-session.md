# Native publishing lifecycle

`ScorebugMedia.PublishingSession` owns one injected `MediaPublisher` independently
of `RecordingSession`. The publisher captures its destination configuration; the
session exposes only constant error cases, without transport URLs or credentials.
Create a fresh publisher/session for each reconnect.

`start()` waits for the publisher to complete startup and report healthy readiness.
Until then, `offer(_:)` rejects samples. Readiness creates one media consumer and
one health monitor. The monitor checks every 250 ms by default and detects a failed
publisher even when capture has stopped delivering samples. Startup, append, and
health failures close publishing ingress and schedule teardown automatically.
They never call the archive or capture source.

The synchronous capture branch has a bounded FIFO: eight queued items and 12 MiB
of estimated retained payload by default. Both limits apply independently. When
full, the oldest queued samples are evicted until the new sample fits, so the
publisher favors current media over stale queued frames. An oversized sample is
rejected without evicting valid queued media. The snapshot exposes successful publisher append returns as `sentSamples`; this
counter does not measure encoded frames, network delivery, or remote playback. It
also exposes queue item/byte occupancy and peaks, admissions, rejections, and drops. Drop counts
include queued samples discarded by shutdown. Rejection before readiness or after
shutdown does not enter the mailbox and is not included in its counters.

These are raw payload budgets. One in-flight sample can retain up to another
12 MiB, and metadata, capture pools, archive retention, encoder allocations, and
SDK queues are separate. The capture callback does no disk/network work and creates
no per-sample task or asynchronous stream.

`stop()` atomically closes admission and discards pending media. It cancels the
startup, consumer, and monitor tasks, invokes `publisher.stop()` to unblock any
suspended operation, and then joins all three tasks. Concurrent stop waiters join
that same operation; cancelling a waiter does not abandon cleanup. Normal stop
during startup makes the startup waiter throw `cancelled`, while the session ends
`stopped`. Explicit `cancel()` latches a failed/cancelled snapshot. Transport failures
remain failed after cleanup. Sessions are one-use, including stop before start.
The public owner's deinitializer schedules cleanup; tasks retain a separate core,
so an idle consumer cannot retain the public session indefinitely.

The injected publisher must make `stop()` terminal, safe concurrently with suspended
startup/append/health calls, and capable of unblocking them. Startup must not restore
publication after stop. Operations must finish in bounded time or cooperate with
cancellation. The session cannot impose a hard deadline on arbitrary uncooperative
publisher code. `stop()` returns no error; inspect `snapshot.failure` for the latched
reason after joining cleanup.

## Attaching to a recording

Create one fresh `PublishingTap` per `CaptureRecording` and pass it as
`publishingTap:`. Recording can start with no publisher attached. After publishing
readiness, call `tap.attach(session)`; after live stop, call `tap.detach(session)`.
Detach checks object identity, so late teardown from an old attempt cannot clear a
new attachment. Attachment replacement does not stop the previous session: retain
it through an explicit awaited `stop()`.

The recorder first offers each immutable captured sample to its archive. Only a
successful archive admission is then offered to the tap. Publishing rejection,
failure, detach, or stop does not change archive state. Capture shutdown permanently
closes its own tap while preserving the archive's existing source-quiescence and
finalization ordering. It does not own publishing stop policy. A closed tap rejects
late attachment and callbacks; do not share it between recordings.

## Verification

The shared media package passes 89 tests: 78 XCTest and 11 Swift Testing tests.
Eighteen added tests cover publishing readiness/failures, idle health loss, exact
default queue budgets, oldest-sample eviction, oversize rejection, startup/append
shutdown races, suspended health-query teardown, cancelled concurrent stop waiters, explicit cancellation, owner
release, late attachment/stale detach, and archive independence. The pre-existing
71 media tests also pass. Run with:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  swift test --package-path ios/Packages/ScorebugMedia
```

These deterministic tests use injected publishers and capture sources. Real SRT,
encoder, Simulator/device linking, complete decoded media, and hardware behavior
require the separate native integration/qualification checks.

## Production SRT bridge

`ScorebugStreaming.SRTMediaPublisher` adapts the shared `SRTPublisher` to this
protocol. Each attempt configures 1080p30 H.264/AAC and accepts the immutable
sample wrapper; PCM conversion preserves the common media clock. Errors are
constant typed cases rather than SDK messages containing credentialed URLs.

The bridge tracks startup separately from the caller. Shutdown closes the SDK
first to unblock suspended operations, joins startup, then closes again if startup
was in flight. The second close matters because the reusable SDK can reopen on a
late actor hop after the initial close. A regression reproduced that leaked
transport before the fix. Repeated or cancelled stop waiters share one shielded
shutdown; a new stream requires a fresh bridge.

## Bounded downstream drain

`SRTMediaPublisher(url:stopPolicy:)` forwards an optional `SRTStopPolicy` to the
adapter. The default total budget is three seconds, starting before readiness is
queried. The remaining budget is passed to SDK finish. After codec/muxer/libSRT
acceptance, fresh socket observations must show an empty sender buffer; shutdown
then allows negotiated peer latency plus 500 ms for the downstream relay/worker.
Refilled buffers restart that interval. Invalid statistics, connection failure,
cancellation, or deadline expiry close the transport without claiming success.

The allowance is configurable per deployment. Empty sender occupancy can include
dropped overdue packets, and elapsed allowance does not prove remote delivery.
The budget bounds intentional waiting, while native VideoToolbox completion and
socket close still require their platform calls to return. Cleanup is joined on
every path; it does not hold the capture or archive queues. Thirteen bridge and
stop-policy tests cover these lifecycle, timing, health, and cancellation contracts.

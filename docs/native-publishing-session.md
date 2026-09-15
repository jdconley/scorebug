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

## Publishing-attempt identity

The filming model sends its existing lifecycle/diagnostics UUID as
`publishingAttemptId` when requesting `/media/publish`. The API first checks the
selected capture, recording and broadcast generation. It signs the canonical
lowercase UUID and existing generation-specific path using the installation secret:

```text
streamid=publish:<path>:sbp1=<UUID>.<HMAC-SHA256>
HMAC input = JSON.stringify(['scorebug-publish-attempt-v1', path, UUID])
```

The base path and encryption capabilities do not change between attempts. The API
echoes the requested UUID; the native client requires that exact echo and one fully
validated stream ID containing the same UUID before constructing the publisher.
The native client checks syntax/identity; it cannot verify the server's HMAC secret.
The relay's private connection API retains the query, and the server-side verifier
can return the authenticated UUID without disclosing its proof. Diagnostics retain
the existing local UUID rather than the credentialed URL or private query.

Requests that omit the optional UUID keep their previous response and URL shape.
New filming clients require an API that supports attempt grants; they do not silently
accept legacy access as proof of a requested attempt. Invalid, delayed or failed
grant responses cannot start an obsolete publisher or stop the independent recording.

This is an identity attestation, not fresh receipt evidence or one-use authorization.
A holder can reuse its valid URL, so the actual SRT publisher UUID still identifies
each relay connection. The next integration must bind a worker's actual reader to
that publication and to its reporting epoch. A lookup of the current path publisher
does not prove the source of a previously opened worker reader. Automatic quality
adaptation remains disabled until these associations and interval measurements exist.

Qualification on 2026-09-15 (`artifacts/qa/native-app-PO8n7D`) uses the real API,
stock MediaMTX 1.21.0, native SRT publisher and Mac worker on the iPhone 14/iOS 17.5
simulator. The private relay query verifies against the independently derived path
and fixture installation secret; its attempt UUID equals the exported native scope.
Only publication UUID/path/match/generation/recording/attempt scalars are persisted.
The fixture bounds and joins the observer, rejects malformed/tampered proof, and
requires actual relay evidence rather than accepting an empty collection.

The clean archive contains all 1,843 pictures (0–1842, 61.433 seconds at 30 fps).
Live output retains all 1,431 acquired pictures (228–1658, 47.7 seconds at 30 fps);
the 60 encoded startup pictures before acquisition remain explicit, and no encoded
tail is missing. Scoring changes the overlay, and recording continues after live
stop. Both files fully decode. Maximum A/V marker errors are 0.021 ms archive and
64.917 ms live; track-end separations are 5.333 and 17.771 ms. Worker, encoder and
recorder terminal exits are 0, with owned simulator/container cleanup complete.
This finite simulator fixture does not qualify physical cameras, radio handoffs,
arbitrary reconnect histories or worker-reader provenance.

Core tests pass 244, Film model tests 97, API tests 292 and tooling tests 572.
The combined unsigned iPhone/Watch Release build and arm64_32 watchOS 10 Core build
pass. Independent specification and quality reviews approve the changes. Commands,
red/green logs, source hashes and evidence are retained in
`artifacts/qa/native-attempt-final-verification.json`.

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

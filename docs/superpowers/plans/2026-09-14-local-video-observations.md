# Local capture and encoder observations

Continue milestone 4 of the portable streaming plan with truthful local video
measurements. The existing quality policy remains disconnected from live settings
until its remaining inputs and transitions are qualified.

## Observation contract

Create immutable attempt scope containing recording ID, match ID, broadcast
generation, publishing-attempt UUID, and applied-profile revision. Do not invent a
worker-attempt identity before one is known. A replacement attempt gets a new owner;
callbacks retained by the prior encoder can update only that prior owner.

Keep capture video and encoder completion as separate stages. Count valid, strictly
advancing source presentation timestamps. Retain the timestamp high-water mark
across window rotation; equal timestamps with different timescales are duplicates.
Preserve CMTime epoch and rational comparison. Nonnumeric timestamps are invalid;
an epoch change is an explicit discontinuity, never ordinary advancing freshness.
This is timestamp freshness, not proof of changing image content or delivery.

Use constant-size aggregates: callbacks, advancing timestamps, duplicate/reordered/
invalid counts, first/last source timestamps, monotonic interval boundaries, last
observation time, and partial/invalid/closed status. Counter overflow saturates and
invalidates the observation. Do not retain samples or unbounded frame identities.
Assign callbacks to fixed half-open windows using their own monotonic observation
time; rotate before counting a callback at or beyond a boundary. The existing health
poll advances idle windows and reads snapshots, rather than determining which
window owns a frame. Preserve empty intervals, startup delay, and polling gaps.
The pure accumulator accepts explicit ordered times for deterministic tests. Its
runtime lock owner samples a concrete monotonic clock inside the critical section
for observation, polling, and closure. Caller-sampled timestamps from concurrent
producers could otherwise acquire the lock out of order and falsely report a clock
reversal. Do not invoke arbitrary clock closures while holding the owner lock.
Bound the retained completed-window
history and expose missing intervals explicitly. A first-to-last-frame duration
must not replace the full interval when calculating cadence.

Capture and encoded counts do not establish loss until their source-time intervals
can be aligned. Keep source loss, usable capacity, worker freshness, and receiver
receipt unknown when unmeasured. Keep the existing append-return `sentSamples`
counter under its current name and meaning.

## Implementation checkpoints

1. Add a pure accumulator and bounded synchronized observation owner in
   `ScorebugMedia/VideoFrameObservation.swift`. Test zero/equivalent timestamps,
   duplicates across rotation, invalid/nonnumeric and reordered input, epoch
   discontinuities, saturation, monotonic
   clock reversal, idle windows, long gaps, delayed polls with callbacks on both
   sides of a boundary, exact-boundary ownership, and closed/replaced owners. Review this
   contract before connecting it to capture or the encoder.
   Test concurrent owner callbacks and polling without false clock invalidation.
2. Observe video at the capture callback before archive admission in
   `CaptureRecording.swift`. The existing publishing tap runs after admission and
   cannot stand in for capture observations. Attach an optional observer independently
   of publisher readiness, with identity-guarded detach. Test mixed audio/video,
   archive rejection, and unchanged archive failure/stop ordering with and without
   telemetry. No per-frame tasks, network waits, or changes to archive configuration.
   Resolve one immutable attempt attachment for each callback before observation:
   a concurrent publisher replacement must not count capture under the old owner
   and route that same callback to the new publisher. An old attachment may reject
   admission during teardown; preserve that boundary as a gap. Test replacement
   between observation and archive admission without moving the archive branch.
3. Add an optional synchronous callback at successful VideoToolbox compression
   completion in the pinned HaishinKit patch. Capture original input PTS immutably
   and validate output PTS. Plumb through codec/session and SRT construction without
   treating decompression, passthrough, append success, or downstream consumption as
   encoder completion. Test delayed output, nil/error/dropped output, and successful
   compression followed by downstream queue rejection as distinct cases.
4. Wire the scoped observer through `SRTPublisher`, `SRTMediaPublisher`, and
   `CaptureStreamingModel`. Read snapshots through existing polling; reject stale
   asynchronous results after attempt replacement. Final drain callbacks belong to
   the closing attempt. Document lock ordering and retain only scalar metadata in
   callbacks. Keep SDK patch provenance current in `vendor/HaishinKit/scorebug.patch`.
5. Qualify a local fixed-profile run after builds finish. Compare stage observations
   with fixture identities and fully decoded archive/live output; preserve startup
   and drain intervals. Confirm telemetry does not alter archive admission or
   continuity. Obtain specification and quality reviews at each integration boundary.

## Encoder callback boundary

The SDK hook is optional and synchronous, supplied at stream construction and
captured strongly with the scalar input PTS for each conversion. A fresh publisher
and stream remain required for each attempt. The native completion callback may
run before encoding returns or later on another thread. It must never read a
replacement observer from mutable codec state or retain the raw input sample.

Notify only for successful, non-dropped compression with a ready, single-sample
compressed video buffer containing nonempty compressed data. Both input and output
PTS must be numeric with positive timescales, share an epoch, and compare equal
rationally. Ready zero-data marker buffers are not completed video frames.
These checks govern diagnostics only; retain the existing media queue and failure
behavior. Invoke the observer before downstream queue admission, so an encoded
frame subsequently rejected by that queue still counts as encoded.

The encoded-stage callback count therefore counts qualifying completion
notifications, not every native callback or every rejected notification. Neither
decompression nor compressed passthrough notifies this observer. Keep frame
reordering disabled: native callbacks arrive in decode order, and changing that
setting requires separate qualification of advancing-PTS interpretation.

## Runtime ownership and qualification

After access validation and the existing attempt check, create the optional owner
and publisher, store their ownership, and attach before awaiting publisher startup.
This local interval includes encoder/transport startup, but starts after earlier
broadcast/access requests. Revision 1 identifies the fixed profile; a starting
snapshot is not evidence that configuration or readiness has succeeded.
Unavailable observation construction must leave publishing usable with no owner.
If publisher construction fails after owner creation, close that owner explicitly.

Poll the directly owned observer synchronously in the existing local health loop;
do not introduce an asynchronous snapshot getter or another polling task. Detach
immediately on stop, retain the old owner while joining session shutdown, and close
it only afterward. Publish its final bounded snapshot only if its diagnostic
attempt and teardown identity are still current. Diagnostic identity is separate
from the control epoch, because a normal stop invalidates that epoch before drain.
A new start clears prior diagnostics even if it fails before receiving access.

Model tests must exercise a real capture callback during gated publisher startup,
capture stop during startup, delayed encoding during gated shutdown, fresh owners
after restart, closed-tap and factory-failure cleanup, and absent observations.
For native qualification, a separately gated DEBUG fixture exporter can serialize
one closed snapshot after teardown without changing the production UI or writing
on capture callbacks. Preserve rational PTS and scope; omit URLs and credentials.
Compare those bounded windows to the existing fully decoded barcode/audio fixture,
including startup and drain intervals, without inferring loss from unaligned stage
counts.

## Remaining work after this slice

Source-range correlation, full report-transit age, time-weighted live queue pressure,
qualified usable video capacity, bitrate/profile application, impaired-network
measurements, and sustained recording/streaming still precede adaptive enablement.
The phone continues using fixed 1080p30 throughout this observation-only slice.

## First checkpoint evidence

The isolated accumulator and synchronized owner are implemented. All 18 focused
tests and all 107 Media package tests pass, including boundary, gap, discontinuity,
overflow, invalid clock, malformed timescale, and concurrent owner coverage. See
[the telemetry contract](../../adaptive-telemetry.md) for exact bounds and evidence.
The unsigned combined iPhone/Watch Release build passes, and independent
specification and quality reviews approve checkpoint 1.

## Capture integration evidence

Checkpoint 2 connects the optional observer before archive admission and retains
one attempt attachment across the callback. Replacement, detach, and closure
invalidate old publication admission while keeping the old owner available for
encoder drain. Eight new integration tests pass, including deterministic callback
interleavings; all 115 Media package tests and the unsigned combined iPhone/Watch
Release build pass. Logs are under `artifacts/qa/capture-video-observation-*`.
Existing app calls supply no observer yet.

## Encoder integration evidence

Checkpoint 3 adds the immutable optional observer through SRT construction to the
actual native compression callback, with the diagnostic-only validation described
above. All 76 SDK tests pass, including actual encode/decode, SRT final drain,
passthrough exclusion, and queue-rejection ordering. The unsigned combined
iPhone/Watch Release build passes. The SDK patch preserves all 162 original hashes
and an exact reverse/forward round trip. Logs are under
`artifacts/qa/encoder-completion-observation-*`. App/controller wiring and local
fixed-profile measurement qualification remain open.

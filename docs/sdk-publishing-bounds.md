# Bounded SDK publishing contract

The maintained HaishinKit 2.2.5 patch preserves startup audio, the shared audio/video
clock, composition offsets, and a valid first video PTS of zero. It adds finite
compressed publishing queues and terminal, observable failure. The initial profile
is 1080p30 at 6 Mbps; higher profiles require separate qualification against these
limits. This is a contract for named queues, not a claim that framework allocations
or process RSS have a mathematical upper bound.

## Named retained payload limits

| Boundary | Buffered items | Maximum logical bytes per item | Retained payload ceiling |
| --- | ---: | ---: | ---: |
| VideoCodec compressed output | 8 | 2 MiB | 16 MiB |
| AudioCodec output | 64 | 64 KiB | 4 MiB |
| TSWriter output | 32 | 2 MiB + 64 KiB | 66 MiB |
| SRTSocket pending transport buffers | 8 | 2 MiB + 64 KiB | 16.5 MiB |
| TSWriter startup PES collection | 256 | Also subject to the 2 MiB payload preflight | 8 MiB aggregate |

The sum of these retained logical payload ceilings is **110.5 MiB**. Startup also
has the existing two-second media-span limit. A 2 MiB compressed video item leaves
more than two seconds of nominal 6 Mbps data for an individual keyframe. The extra
64 KiB at the transport boundaries allows MPEG-TS packet/header expansion. This is
a conservative admission ceiling, not an estimate of normal occupancy.

Each consumer can additionally hold one dequeued item. The TS writer constructs
bounded-size PES/TS arrays and copies before yielding. Socket sending copies only
one 1,316-byte datagram at a time, preserving order, and yields between datagrams.
It no longer eagerly creates an array of every datagram for an input buffer.

CMSampleBuffer/AVAudioBuffer object overhead and backing capacity, codec internals,
framework pools, raw video, operating-system buffers, libSRT queues, producer-owned
input, array metadata, and other application allocations are outside these numbers.
The compressed video byte check does not apply to decompressed playback images.

The SRT publishing raw-video input uses the caller's positive frame bound, or a
default of two when previously unbounded. Dropping a stale raw frame before encoding
remains allowed. Compressed media is never silently discarded while a session is
healthy: an exceeded count or per-item cap terminates the publishing session.

## Failure and ownership

`PublishingQueue` uses `bufferingOldest` plus a pre-yield byte check and inspects
all yield results. An overflow keeps already accepted byte order, rejects the new
item, finishes that queue, and synchronously records the first `PublishingError`.
A stopped queue ignores late callbacks. Every new publish creates fresh queues and
a fresh lock-backed failure latch, so callbacks retaining an old queue cannot write
into the new session.

The latch has one bounded event stream and no per-output task creation. Its first
failure wins. One owned failure observer on the stream terminates publishing for
codec/muxer errors; one owned connection observer handles asynchronous socket
failure independently of later input. `SRTStream.publishingError` and
`SRTConnection.publishingError` expose the terminal error. Stream failure remains
available after close until the next publish; connection failure remains until the
next connect attempt. The older `muxerError` property retains its reset-on-close
behavior. Connect failures also remain ordinary thrown connection errors.

The TS writer preflights payload size both before and after the common origin is
known, before allocating PES copies. AAC payloads also obey the ADTS 13-bit frame
length limit (8,184 payload bytes). This prevents the previously reproducible
oversized post-start audio integer-conversion trap. Invalid timestamps, startup
limit violations, codec creation/conversion errors, and missing/failed compressed
VideoToolbox callback output fail explicitly.

SRTStream owns its four media consumers and its failure observer. SRTConnection
owns its socket observer, monitor, and receive task. Closing cancels owned tasks and
invalidates their generation before awaits. Connection send/failure operations
also carry a connection generation token. Old consumers cannot send into a new
connection, and compressed appends after close cannot repopulate the cleared muxer.
Raw pre-publish append remains available for discovering input formats.

The SDK's general MediaMixer callback API still schedules a task for each input;
it is outside this bounded direct-ingest contract. Scorebug's production adapter
uses the separately bounded publishing access path rather than those callbacks.

## Finite network operations and idle failures

Caller connection timeout is capped at 3,000 ms. Send and receive timeouts are capped
at 500 ms. Smaller positive configured timeouts are preserved; URL options cannot
restore an infinite timeout. Application attempts to set a larger/infinite timeout
through the socket API are rejected. The caps apply to the libSRT operations, not
to a hard end-to-end wall-clock deadline for actor scheduling, DNS, listener accept,
or all close cleanup. Listener accept runs off the socket actor and is interrupted
by closing the listener.

One finite synchronous send can occupy the socket actor. Yielding between
individual sends lets close interleave with a large transport item instead of
waiting behind every datagram in that item. A failed/partial send records a terminal
error immediately. The existing owned monitor samples once per second and detects
broken/closed/nonexistent sockets or a failed statistics read while logically
running, so idle peer failure becomes observable without another media append.
Detection starts when libSRT exposes that terminal state; its own peer timeout is
separate. Intentional stop first marks the socket stopped and is not an error.

libSRT initialization is process-scoped. Per-connection `srt_cleanup()` was proven
to invalidate another connection's socket; it is no longer called when one
connection is released. Individual socket deinitialization still closes its own
descriptor. Process termination releases the library runtime.

## Regression evidence

Run the SDK suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  swift test --package-path vendor/HaishinKit
```

Deterministic tests cover tiny count/byte caps, accepted order, first-failure
latching, stopped queues versus fresh sessions, real VideoToolbox output limits,
AAC output limits, nil audio converter creation, post-origin payload rejection,
shorter timeout preservation, lazy datagram byte order, asynchronous write failure,
idle failure through the actual owned monitor, stale generation sends, late append
after close, and releasing an old connection while a fresh socket remains valid.
Transport seams replace the native send/status functions in those focused tests;
they do not broadcast externally. Existing startup/timestamp regression tests remain.

Red/green and provenance reconstruction logs are under `artifacts/qa/sdk-*.log`.
The real-media five-case conformance harness and native device/simulator links are
separate qualification checks. The final run at
`artifacts/qa/dual-output-ZCjJBF/results.json` passes offline, normal, nonzero-clock,
stalled-receiver, and absent-receiver scenarios. All archives retain frames 0–419
and complete audio; both normal streams retain all 420 frames at 30 fresh fps.
Maximum measured live A/V offset is 65.38 ms; peak process RSS is 95.81 MiB.
Original 100 ms coverage/synchronization, 24 fps floor, source-loss, queue, and
bitrate-change gates remain unchanged. Full ARM64 Simulator and unsigned iPhone
links pass with iOS 17 deployment (`sdk-bounded-*-final-build.log`).

The SDK suite passes 57 tests and the shared adapter passes three PCM clock tests.
Spec and code-quality reviews approve this scope. Remaining targeted race tests
include saturated socket admission, closing during a deliberately delayed finite
send, and restarting while old codec output is queued. These are separate from
the passing generic queue, stale-generation, and live overload checks.

Original upstream provenance is recorded in `vendor/HaishinKit/upstream-files.json`;
`scorebug.patch` includes every changed upstream source/test plus the new queue
primitive. Added regression tests are maintained alongside it.

Verify the patch independently of repository HEAD with
`python3 vendor/HaishinKit/verify-scorebug-patch.py`. The verifier reverses the
maintained patch in a temporary copy, checks all 162 original hashes, reapplies
it, and checks every copied source/test byte against the current vendor tree.

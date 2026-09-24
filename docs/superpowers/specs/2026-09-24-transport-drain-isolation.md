# Transport drain isolation

Status: implemented in `582a339`; deterministic transport isolation, vendor,
Streaming, SDKProbe, model and simulator checks pass. The real 4K regression shows
transport draining within bounds but fails later at the audio codec queue. The
repeated adaptive regression times out before campaign two. See the
[investigation results](../plans/2026-09-24-4k-muxer-pressure.md).
Autonomous continuation is authorized.

## Measured problem

The native 4K match fixture intermittently exhausts the 32-payload transport muxer
queue. The independent archive completes despite publishing failure. Frozen source
`a8099bf` reproduces this in
`artifacts/qa/match-footage-n6n1f13m/network-native-submission-trace-1-4k-videotoolbox/`.
All 1,151 tracked source hashes remain unchanged. The attempt reports 102 synchronous
compression submissions, 220 complete four-phase transport observations, no trace
overflow and no unmatched transport attempt. The proxy receives 81 frames; the
archive retains all 360 frames and 576,000 audio samples, with no archive rejection.

The longest synchronous `session.convert` wrapper takes 49.371 ms. One 50.357 ms
socket-return-to-stream-resumption gap overlaps 49.301 ms of that conversion; its
socket-call bracket takes only 0.014 ms. The stream actor performs this conversion
and also resumes the transport consumer. That shared execution context prevents
the consumer from draining already-muxed data during slow submissions. This is
measured actor contention, not evidence of slow network writes. Whether hardware
selection, shared encoder resources or another native condition causes the slow
conversion remains a separate question.

The wrapper includes synchronous callback work and excludes session creation and
asynchronous output completion. Apple documents output callbacks separately from
submission in its [VideoToolbox encode API](https://developer.apple.com/documentation/videotoolbox/vtcompressionsessionencodeframe(_:imagebuffer:presentationtimestamp:duration:frameproperties:infoflagsout:outputhandler:)).
Do not infer hardware selection from the API name: Apple exposes a separate
[hardware-encoder property](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder).

## Design

Move only the serial transport consumer off `SRTStream`'s actor. A detached worker
owns exactly one iterator for that publication's existing bounded output queue.
Capture the old output, old `TransportOutputAccounting`, failure latch, connection,
connection session, stream generation and immutable observer. The worker must
neither access `writer` nor await `SRTStream` while draining media or considering
padding. Keep the 32-payload limit, payload byte bound, 1316-byte datagrams, native
send timeout, FIFO ordering and per-datagram cooperative yield unchanged.

Check the worker's cancellation and captured failure latch before dequeuing, after
awaiting a dequeue, and after sending. Decrement the captured accounting directly;
never reach through the mutable writer after an await. An accounting underflow
must still latch terminal failure. Timing observers retain their captured
publication identities. After this change, the outer return timestamp measures
worker resumption, so new reports must not call it stream-actor resumption.

Store the installed optional bandwidth probe in a small lock-protected holder
belonging to the output generation. `TransportOutputAccounting` is an existing
generation-owned place for that pointer; its media count remains authoritative.
Read the pointer under the lock, then release the lock before calling probe or
connection methods. Preserve the existing probe's locked revocation, eligibility
and socket-side `whileEmpty` admission. The stream revokes an old probe before
replacing its pointer. Finishing revokes probe authority while draining media.
New publication gets new accounting and an empty holder. No extra padding worker
or competing media iterator is permitted.

## Retirement and re-publication

Keep `close()` nonjoining for transport: a worker can be inside
`connection.send → failPublishing → connection.close → stream.close`. Joining that
same worker there would deadlock. Instead, preserve the cancelled worker handle
when clearing active publishing tasks. There can be at most one retired worker.

Before the next non-nil `publish`, await retirement, then recheck stream generation,
idle state, close/finish/replacement/probe-start ownership and a fresh connection
session. A close or competing publish while this await is pending invalidates the
attempt. Connection generation alone is insufficient because stream close and
re-publication may use the same connection. A retired send must finish unwinding
before a new worker can start. Normal `finish()` continues to join its current
worker and drain accepted output. Close must preserve an already-retired handle
when there is no active transport task to replace it.

## Decisive regression and checks

Add a deterministic vendor test with injected socket and video conversion gates:

1. Publish video, block the first transport send, and queue three small compressed
   video samples. PAT/PMT plus those samples provide multiple complete payloads.
2. Submit a raw frame to an injected codec whose synchronous conversion blocks.
   Observe gate entry through thread-safe state, without querying the stream actor.
3. Release the socket gate from the test while leaving conversion blocked.
4. Require further prequeued payloads to reach the injected sender before releasing
   conversion. The current actor-bound consumer must fail this assertion.
5. Release both gates in cleanup, join finish/close, and verify no unexpected failure.

Use finite gate deadlines; a gate timing out does not count as successful isolation.
Do not use native hardware timing as the unit-test trigger. Existing raw/encoded
sample constructors and injected `VTSessionConvertible` patterns are available in
`SRTHaishinKit/Tests/SRT/SRTVideoReplacementTests.swift` and
`SRTHaishinKit/Tests/TS/TSWriterStartupTests.swift`.

Also verify same-connection close/re-publish cannot overlap an old worker; failed
send shutdown cannot self-deadlock; close while publish awaits retirement cannot
resurrect publishing; and normal finish preserves the accepted tail. Run the existing
probe replacement, cancellation, wake ownership, priority and budget suites. Retired
probe identities may remain diagnostic history but may never send again.

Relevant implementation files are `SRTStream.swift`, `TransportOutputAccounting.swift`
and a focused `SRTTransportPump.swift` if extraction makes ownership clearer, all in
the vendored SRT module. Preserve the maintained upstream patch and original-hash
verification. Keep the native encoder and archive implementations unchanged.

After failing-first and full vendor tests, clean Swift consumers to avoid stale
public enum layouts, then run Streaming, SDKProbe, native model tests and the
simulator build serially. Freeze source hashes and run a new capped real-match
batch that stops at its first failure. Compare conversion durations with worker
progress, retain every failure and verify the independent archive. A fixed queue
starvation defect does not itself qualify sustainable 4K frame rate or production
automatic upgrades. Follow with the repeated adaptive fixture only if transport
or probe behavior changed and the focused checks pass.

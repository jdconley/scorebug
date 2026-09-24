# 4K muxer pressure investigation plan

> **For agentic workers:** Use `superpowers:executing-plans`, with failing-first tests and serial heavy verification. Autonomous continuation is authorized.

**Goal:** Identify and repair the cause of intermittent transport-muxer queue overflow during representative native 4K streaming while preserving independent clean recording.

**Architecture:** Observe the existing muxer-output consumer before changing transport behavior. An immutable optional observer emits scalar send-start/return events, scoped by stream generation and FIFO sequence. The file-driven harness retains at most 4096 events and seals a bounded prefix at the tool stop boundary. This is not proof that every transport callback has joined. Normal publishing has no observer; this is diagnostic evidence, not quality-policy authority or receiver delivery proof.

**Tech stack:** Swift6, the pinned vendored SRT/HaishinKit adapter, native macOS 4K H.264/AAC archive/publisher, direct local SRT and FFmpeg VideoToolbox proxy.

## Current evidence

The preceding turn was progress: explicit 4K paths, tests, and health diagnostics are committed. A bounded six-case identical VideoToolbox series on `dc468f9` stopped at its first failure. All 1148 tracked files stayed unchanged. Case `network-native-series-1-4k-videotoolbox` captured the first unhealthy state: stream and connection both report `queueCapacityExceeded(boundary: "transport muxer")`; connection is closed and stream no longer publishing. The proxy decoded 82 frames and exited ~4.545 seconds after its spawn. The native process completed its independent archive with all360 frames and no archive rejection; live counters7dropped/283rejected. Source lag maximum3.265ms. Host samples show no obvious exhausted free memory; coarse CPU samples are not proof of absence of scheduling stalls. The series stops here; do not run remaining cases or infer a fix from later passes.

The writer holds at most32 complete muxed payloads, each bounded2MiB+64KiB. A single consumer awaits each connection send. The socket subdivides payloads into1316-byte datagrams and cooperatively yields after every datagram. We have not yet measured whether a large payload/send delay or producer burst fills the queue. Do not enlarge queues or change pacing without evidence.

## Diagnostic design

Add `SRTStream.TransportSendObservation` with generation, FIFO sequence, phase (`started`/`returned`), byteCount, pendingPacketCount and monotonic observedAt. Emit `started` immediately after dequeue/accounting, then `returned` after `await connection.send` even if the attempt failed or closed. Return does not assert socket acceptance; health retains failure authority. Observer is synchronous, bounded, has no I/O/waits/tasks, and never contains media or URLs. It is immutable for the stream, inherited by the public adapter and only enabled in DualOutputSmoke. Keep the current yield behavior, queue limits, deadlines and cancellation unchanged.

## Tasks

- [x] Add failing tests alongside TSWriterStartupTests using the existing native compressed fixture and injected socket. Verify start/return FIFO pairing, byte count, nonnegative pending count, monotonic brackets, and generation isolation across two publish/drain cycles. Verify a failed write still exposes return timing without changing the failure. Run focused vendor tests and preserve RED evidence.
- [x] Implement the optional typed observer through SRTStream, SRTPublisher and SRTMediaPublisher. Add a bounded tool collector, include its sealed prefix in both publisher success and failure events. Explicitly include cutoff time and unmatched generation/sequence IDs; ignore late callbacks after sealing and test that behavior. Run focused/full vendor tests, Streaming tests and clean SDKProbe build as needed. Regenerate maintained vendor patch from verified original hashes and verify its exact round trip.
- [x] Run one new owned 4K VideoToolbox experiment with trace and host samples, stopping at the first failure. Reconcile last dequeued payload duration, pending count and the latched failure; keep earlier runs untouched.
- [ ] Use measured evidence to select the smallest transport fix and a deterministic regression. Validate independent recording, native unit/build checks and new real-match runs; document unresolved scope honestly.


Review identified that unhealthy SRT close cancels/discards the transport task without joining it; the health-failed stop policy skips finish. Therefore the tool collector deliberately exposes a sealed prefix, not a complete trace. An unmatched start cannot prove a stalled send. Tests exercise late return after seal, generation matching, idempotence and bounded overflow. The existing failed-write stream test exercises finish, not the unhealthy-close join path. No shutdown behavior is changed.

Diagnostic verification: focused RED failed on missing observer API; focused GREEN and all 291 vendor tests passed. A clean Streaming rebuild passed all 170 tests. Collector RED failed on the missing type, then all nine SDKProbe tests passed and tools built. The maintained vendor patch verifies all162 original hashes and an exact round trip. Independent review approves the sealed-prefix design. Native reproduction and final simulator validation follow.


### Transport trace reproduction

On frozen `9f108d4` (all1151 tracked hashes unchanged), the first three trace cases
passed. A separately capped six-case reproduction batch stopped at case3 after
cases1/2 passed; cases4–6 never ran. Failed artifact:
`network-native-pressure-trace-3-4k-videotoolbox`. The native terminal event again
reports transport-muxer capacity overflow. Its448 trace rows form224 complete outer
send pairs, no overflow or unmatched starts. Tiny376/564-byte payload brackets grow
to36–50ms while pending rises to32.104 encoded callbacks were retained. Clean archive
still has360 frames and576000 audio samples, zero archive rejection; live5 dropped /
288 rejected. The runner fails its expected8Mbps-change assertion because publishing
already failed before that scheduled write; preserve the underlying terminal event.
These intervals include actor waits and do not establish slow native socket calls.

Read-only review identifies synchronous video submission (including native encoding),
audio conversion and packetization on the same stream actor that resumes transport.
No lost-wake defect is evident. Next add two optional phases around the connection's
awaited socket.send, before error/close handling. Four phases share the same immutable
generation/sequence; the inner pair may be absent on early guards. Only outer returned
closes the collector attempt. This distinguishes socket-send wait from stream-actor
resumption. It is diagnostic only; keep queues, pacing and cancellation unchanged.
Use failing vendor tests, collector tests, maintained-patch verification and a new
bounded reproduction. Do not call a long inner interval a native syscall measurement.


The four-phase diagnostic is implemented and independently reviewed. Failing-first
vendor tests rejected the absent phases; then all292 vendor tests and all10 SDKProbe
tests passed. Early disconnected/stale guards omit the inner pair, failed writes
still report inner return before close, and collector closure remains outer-only.
The maintained patch verifies162 upstream hashes and exact round trip. The failed
case above delivered83 proxy-decoded frames; all six owned ports were released.
Next run the reviewed diagnostic on a new frozen source; final native model and
simulator checks remain required before closing this diagnostic checkpoint.


### Inner call localizes actor resumption

The initial incremental-tool run has invalid phase labels (old two-case enum
layout in a stale dependent object); it is preserved and excluded from timing
inference. After a clean tool build, all10 tests pass. A fresh bounded batch on
`4a89c98` stops at case3 after two passes; all1151 tracked hashes remain unchanged.
`network-native-clean-inner-trace-3-4k-videotoolbox` has220 complete four-phase sends,
no overflow/unmatched attempt. Maximum inner socket-call interval is1.363ms; maximum
socket-return→stream-resumption delay is51.144ms. Pending reaches32.81 frames reach
the proxy; the archive completes360frames/576000audio samples with0rejections.
This isolates the long bracket to stream-actor resumption, not the socket call.

Next bracket synchronous raw `session.convert` in VideoCodec with an immutable,
optional submission observer. Include sourcePTS, sessionID, start/return monotonic
clocks and native error status on success/throw; skip compressed passthrough and
nil-observer clocks. This measures the synchronous conversion wrapper (containing
VTCompressionSessionEncodeFrame), not asynchronous completion or delivery. Retain
at most512 rows in the existing tool encoder evidence. Preserve the actual media,
queue, lifecycle and failure behavior. Tests verify timing encloses the injected
conversion, failure status remains latched and compressed inputs are excluded.
Clean consumers after the public Swift API change, then use one bounded reproduction.


Submission diagnostics passed failing-first tests, then all294 vendor tests and a
clean build of all10 SDKProbe tests. Maintained vendor provenance verifies162
upstream hashes and exact patch round trip. Independent review approves the change.
Submission observations are emitted on return; absent rows do not prove a native
call is still blocked. The measured wrapper includes synchronous callback work.


### Measured cause and implementation

On frozen `a8099bf`, `network-native-submission-trace-1-4k-videotoolbox` failed:
102 synchronous submissions, maximum49.371ms; a50.357ms transport resumption gap
contains49.301ms of conversion work while its socket call takes0.014ms. All1151
hashes are unchanged. The archive retains360frames/576000audio samples with0rejection;
the proxy receives81frames. All10 owned ports across recent diagnostic cases were
released. This establishes the shared stream actor as the drain bottleneck.
Hardware encoder selection/contention is not established.

The [transport-isolation design](../specs/2026-09-24-transport-drain-isolation.md)
extracts a sole detached FIFO worker with captured per-publication accounting,
failure and probe ownership. Close cancels and retains the worker; the next publish
joins retirement and rechecks generation/state/connection. No queue limits, socket
timeouts or datagram yielding changed. Outer timing now measures worker resumption.

Two regressions failed against the old implementation: prequeued media could not
drain during blocked synchronous conversion, and re-publication returned before
old transport retired. Both pass with isolation. A further gated successful-return
test proves healthy same-connection re-publication and rejection after an intervening
close. Full vendor testing exposed a probe publication race: the new worker can
advance probe time before install returns a historical timestamp snapshot. Capture
that initial receipt before publishing its pointer; keep monotonic validation strict.
The initial failing suite is preserved. After this fix all297 vendor tests pass,
as do all10 tests from a clean SDKProbe build. Independent review approves the change;
the maintained patch verifies162 upstream hashes and exact round trip.

The runtime source `582a339` also passes 170 Streaming and 499 native model tests
plus the simulator build. All commands joined; the clean SDKProbe suite has ten
passing tests. The runtime source was frozen for both regressions below.

### Real-match and repeated-route regressions

`network-native-pump-1-4k-videotoolbox` fails at the audio codec queue after 260
submissions/completions and 253 proxy-decoded frames. The cap was six cases, but
cases 2–6 did not run after this first failure. All 1,153 tracked hashes remain
unchanged. The full archive retains 360 frames / 576,000 audio samples in eight
segments with no rejection; live drops 13 samples and rejects 69. Both owned
SRT/RTMP ports are released. Preserve the failed artifact.

Its 2,476 trace rows form 619 complete four-phase sends with no overflow or
unmatched attempts. Maximum outer send time is 0.908333 ms, inner socket interval
0.899542 ms, and maximum observed pending payload count is two. The longest
synchronous conversion is 64.748792 ms. Summed conversion intersections occupy
98.14%, 98.14% and 98.02% of the final 1/2/4-second windows. The audio output task
still needs the same stream actor. Transport isolation resolves the measured
transport starvation, while sustainable 4K publishing remains unqualified.

Next design: prepare one immutable native video operation on the stream actor,
run only conversion outside it, and commit bookkeeping under matching session and
generation ownership. Keep one in-flight operation and the existing bounded raw
queue. Configuration writes must close admission before awaiting that operation;
finish drains it, and close retains retirement ownership. Do not move the mutable
codec off actor, increase audio queue limits or add timing sleeps as a substitute.
Require deterministic audio-drain, mutation-order, finish and lifetime regressions
before real media verification.

The complete repeated adaptive regression `native-app-gN2v2o` also fails (joined
harness exit 1). UI recording/scoring/stop passes in 260.326 seconds. First admission,
fault and minimum reset occur, but the second probe campaign never starts:
`native-bandwidth-probe.json` reports `readinessUnavailable`, the owned-fault
scheduler times out, and only 240p → 360p → 240p phases exist. Its closed candidate
wait trace is valid and bounded (1,790 events, no omissions/overflow); the second
candidate operation never starts. Source quality remains healthy at revision 2,
but source health alone is insufficient to authorize a new probe. The exact
rejected shared-readiness condition is now identified: lossless 29/59-frame buckets
clear coverage under the strict 30 fps bucket rule, despite continuous 30 fps source
PTS. The [readiness correction](2026-09-24-shared-delivery-readiness.md) retains strong
Core source health and permits only one frame of short-bucket boundary tolerance. All 1,153 source hashes
remain unchanged. Worker and recorder exit zero; simulator deletion completes.
The harness also reports a secondary cleanup failure related to its failed owned
fault task. Do not claim full cleanup success or a complete media pass from UI
success. Preserve the earlier complete `89926f4` qualification separately.

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

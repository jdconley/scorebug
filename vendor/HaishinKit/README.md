# Scorebug's HaishinKit source subset

This directory contains the HaishinKit and SRTHaishinKit source modules from
[upstream 2.2.5](https://github.com/HaishinKit/HaishinKit.swift/tree/2.2.5), revision
`dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd`. The original BSD-3-Clause notice is in
`LICENSE.md`. `upstream-files.json` records the SHA-256 of every copied source/test
file before Scorebug modifications.
`scorebug.patch` is the diff against that revision for the 18 modified upstream
files and nineteen added publishing/bitrate/clock/replacement/probe/candidate source primitives. Original upstream hashes
remain unchanged. Added regression tests live alongside the SRT tests and in
`ScorebugPatchTests`. The patch was reconstructed from those original hashes,
then applied to a clean reconstructed baseline and compared byte for byte.

The local manifest includes only the modules used by Scorebug. Logboard remains
pinned to 2.6.0 and the original libsrt 1.5.4 binary URL/checksum is unchanged.
The C++ runtime is explicitly linked. Upstream RTMP, RTC, MoQT, examples, doc
plugins, and the large base-module test assets are omitted. SRT protocol tests
are retained except the upstream connection tests that launch unjoined tasks
on fixed ports. Scorebug's real network tests own and clean up their endpoints.

The native app also exposed an SRT URL parser defect: percent-encoded stream IDs
were sent literally and rejected by the relay. Query items now decode exactly
once through URLComponents; an encoded delimiter/passphrase regression covers it.

The local copy corrects the experimentally demonstrated startup media loss in
the TS writer and bounds the compressed publishing queues. Overflow, codec, and
transport failures terminate publishing explicitly. See
[the boundary contract](../../docs/sdk-publishing-bounds.md) for exact limits,
failure observation, task ownership, and qualification scope. The same upstream source on `main` at
`d8e71aa5f27cd2dbab90efcb5fb5909a6f800c3b` still contains the defect. See
[the evidence](../../docs/native-dual-output.md). Keep local changes small and
review them against the original hashes when updating the SDK.

`SRTStream(connection:encoderCompletionObserver:)` optionally accepts a synchronous
`@Sendable (CMTime, CMTime) -> Void` observer. Construction fixes the observer for
the stream and final drain; each compression submission captures only its input
PTS, observer, and output queue. Qualifying native callbacks notify before queue
admission, so later count/byte rejection does not erase encoding completion.
Only successful, non-dropped, ready single-sample compressed video with nonempty
data and numeric, positive-timescale, equal-epoch, rationally equal input/output
PTS qualifies. Diagnostic rejection preserves normal media delivery and failure
behavior. Decompression and compressed SRT passthrough never notify. Observers
must do bounded synchronous work, without per-frame tasks, I/O, or waits.

Verify the maintained patch without a network checkout:

```sh
python3 vendor/HaishinKit/verify-scorebug-patch.py
```

This reverses the patch in a temporary copy, verifies all 162 original SHA-256
hashes, reapplies it, and requires an exact byte-for-byte round trip.

Run focused protocol tests with Swift 6:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  swift test --package-path vendor/HaishinKit
```

When a compression submission observer is explicitly enabled, the codec reads
macOS VideoToolbox's actual hardware-selection property once after preparing each
encoder session. `VideoEncoderSubmission.selectionQueriedAfterPreparation` carries
that cached result with the original encoder-session UUID. Hardware, software,
native read failure, missing value, invalid native type and intentional platform
omission remain distinct. All outcomes are nonfatal diagnostics. Disabled observers
and decompression cause no property read; other platforms report `notQueriedOnPlatform`.
The result is not per-frame hardware utilization, achieved capacity or streaming
health. Bitrate updates retain it; session replacement clears and requeries it.

The internal `SRTProbeMessage.encodeStage` helper adds the `SBUGPRB2` wire
foundation for repeated bandwidth measurements. Every null TS packet includes a
1...32 stage ordinal after its existing UUID, generation, message sequence, rate
and packet ordinal. Input validation precedes integer conversion. The legacy
encoder and default probe entry point still emit `SBUGPRB1`. Explicit staged
native probes now use v2; receiver matching includes stage plus UUID. See the
[staged wire plan](../../docs/superpowers/plans/2026-09-17-staged-probe-wire.md).

The local deployment floor is iOS 17/macOS 13. The inherited libsrt binary still
does not link an Intel simulator executable; this Mac uses the ARM64 slice.

`VideoCandidateEncoder` owns one finite raw-video measurement using the existing
`VideoCodec` settings and native encoder. Explicit startup precedes synchronous
bounded admission. `finish` and `cancel` close admission and join input consumption,
native completion and output consumption before returning scalar results. Limits
are 121 frames, 4.25 seconds of source time, eight seconds of admission time,
16 MiB per raw sample, a four-input raw ingress queue, sixteen unresolved inputs,
64 MiB of aggregate outstanding raw payload and the existing 8 × 2 MiB compressed
queue. Count and actual pixel-buffer payload bytes are reserved before enqueue and
released only after validated compressed-output dequeue, not at native callback.
Each output frame records its admission time and raw payload bytes. These payload
bounds exclude opaque native encoder allocations and are not a process memory
limit. The admission deadline cannot impose a hard timeout on a native completion
call; shutdown retains ownership until that call returns.

Successful measurement reconciles every accepted input with a native completion
and actual compressed H.264 output from one encoder session, including startup
keyframe bytes. The requested settings are not native property readback. Results
measure video payload only; audio, mux, transport cost and available network
capacity require separate qualification. This primitive does not alter a live
publisher or an archive, and concurrent resource contention still needs validation
before production quality increases are enabled.

`CandidateTransportMeasurement` reuses the actual `TSWriter` through an internal
synchronous sink that counts and discards each output write. It requires both
compressed H.264 video and one-packet AAC-LC audio, fixed formats and increasing
per-track timestamps. Limits are 121 video inputs, 512 audio inputs, 32 MiB of
combined compressed input and 4.25 seconds across both tracks; each video input
is at most 2 MiB and each AAC packet at most 8,184 bytes. Video starts with a
sync-marked sample containing an IDR NAL header; every sample contains a VCL NAL
header. Four-byte NAL lengths and at most 64 KiB of SPS/PPS metadata are validated.
These checks do not decode slices or establish picture quality. AAC uses a
standard representable sample rate, 1,024 frames per packet
and supported channel configuration. Existing mux startup bounds remain
256 packets, 8 MiB and two seconds. Finish/cancel are synchronous and terminal;
no socket, task, timer or additional output queue is created.

Each result also contains at most 633 scalar input receipts in accepted append
order: media, source/decode timestamps, encoded byte count, sync flag and emitted
parameter-set bytes (including four-byte prefixes on sync video). Audio receipts
have invalid DTS, sync true and no parameter-set bytes. Receipts retain no buffers.

Results separate encoded video/audio input bytes from actual MPEG-TS bytes,
including ADTS, Annex-B headers, SPS/PPS, PES, PCR, program tables and packet
padding. Message counts round each mux write up independently to 1,316-byte
payload chunks, matching socket application-payload submission. These are not
delivery, IP/UDP/SRT control traffic, retransmission cost or headroom evidence.
The optional `VideoCandidateEncoder.compressedOutputConsumer` receives only
validated output synchronously, may reject the measurement, and must not mutate
or retain samples or reenter the encoder. Cancellation serializes with an
in-flight callback. The consumption claim synchronously checks the native failure
latch, so an already latched failure prevents a new claim even before async error
forwarding. A healthy claim may finish if native failure arrives afterward;
native cleanup remains joined.
Aligning fresh audio/video windows and qualifying concurrent resource cost remain
separate integration gates before any quality admission.

The optional `SRTStream.compressedAudioObserver` copies at most 8,184 actual AAC
bytes only after the live mux accepts a packet and remains healthy. Native AAC
output, including final drain, is marked `wasEncoded`; direct compressed input
is marked passthrough. The snapshot binds the publication generation, observation
uptime, original host-clock tick, source PTS and AAC format. Its original host tick
reconstructs the same mux PTS without a seconds roundtrip. Only one AAC-LC packet
with 1,024 frames, a supported exact rate/channel configuration and valid packet
metadata has `valid = true`; invalid snapshots have empty payload. The payload is
an owned copy and cannot change when codec buffers are reused. Nil observers create
no snapshot. The synchronous callback must remain bounded, with no I/O, waits or
task creation. Existing actor/generation guards exclude output after stop; this
observation does not alter publishing or enable quality upgrades.

Verified live average-bitrate changes use `SRTStream.setVerifiedVideoBitRate` with
an active publishing-generation token. They require a ready raw-video encoder,
check native writes and readback of bitrate plus effective data-rate limits, and
commit settings only after verification. Uncertain native application fails live
publishing explicitly. A lock-protected invalidation revision preserves notifications
that overlap session creation or property writes. The ordinary settings acknowledgment does not prove achieved bitrate/capacity.
`SRTStream.verifiedVideoBitRateReceipt` returns the existing verified write paired
with its current healthy publishing generation, only while the raw encoder remains
current and no video mutation, replacement, finish, or close is pending. Encoder
invalidation and failure revoke this view. Reading it performs no native write or
property readback; its timestamp and source PTS remain historical configuration
evidence, not fresh delivery, achieved rate, or capacity proof.
The optional configuration observer and receipt described below identify native
submission boundaries. See the
[implementation plan](../../docs/superpowers/plans/2026-09-15-verified-live-bitrate.md).

Native transport timestamps now share an exact rational `TransportClock` projection:
source delta is floored to 90 kHz, with a checked 9,000-tick lead for both PTS and
DTS and no lead for PCR. Invalid or unrepresentable timestamps fail before emission.
The bit serializer preserves the 33-bit clock modulus without changing PES prefix
bits; the decoder reads all seven low bits correctly. PCR cadence uses relative
ticks, avoiding precision loss at large absolute source clocks.
`SRTStream.transportClockSnapshot` exposes the muxer-selected origin with its current
publishing generation, only after startup and before finishing/failure/close.
The snapshot is an immutable mapping, not a receipt, loss or profile-transition claim.


SRT performance data now includes optional `sampledAt` system uptime from the start
of a successful native statistics call. Repeated cached reads preserve this time;
failed calls and socket stop clear availability. Native errors cannot commit partially
updated counters. The default monitor retains its one-second collection cadence.
The app retains exact transport counters separately from video capacity or receipt.

`setVerifiedVideoBitRateWithReceipt` additionally returns an immutable configuration
UUID, encoder-session UUID, acceptance uptime and last successful raw submission
PTS before the write. The optional `encoderConfigurationObserver` captures this
identity at submission and delivers it only for qualifying native completions.
Initial/legacy unchecked settings are explicitly unverified. Delayed completions
retain their historical identity across later writes, recreation and stop. This
does not assert instantaneous rate convergence. See
[the frame-boundary contract](../../docs/encoder-configuration-boundaries.md).


`SRTStream` also accepts an optional immutable `compressedVideoObserver`. Before
muxing, it copies actual compressed sample dimensions, codec, PTS, validity, byte count,
CoreMedia sync metadata and publishing generation into a scalar value. Sync reads
the NotSync attachment value (absent/false means sync); invalid samples have no
sync evidence. This does not parse the H.264 bitstream or prove receiver delivery. Raw-encoder output and compressed
passthrough remain distinguishable. The observer runs synchronously, including
final drain, and must perform no I/O or waits; it cannot alter media delivery.
This is pre-worker format evidence, not receiver delivery or rate-control proof.


The internal `VideoCodec` replacement primitive separates prepare, off-actor drain
and commit. Its immutable once-only handle retains the old native session; commit
requires the same codec revision and a successful completed drain before old-session
invalidation. The output queue and source timestamp ordering survive the change.
Pending replacement rejects concurrent settings/input/terminal-finish work, and a
previously captured terminal completion excludes replacement. Stop clears ownership;
stale or failed completions cannot commit into a restarted codec. The stream owner
now supplies an ingress pause policy, deadline and joined cancellation through
`SRTStream.replaceVideoSettings`. The app does not yet select profiles automatically. See [lifetime validation](../../docs/superpowers/plans/2026-09-16-encoder-replacement-lifetime.md).
The provenance verifier also rejects source files omitted from its inventory.


`SRTStream.replaceVideoSettings` pauses its single raw-video consumer while the old
encoder drains off the actor. Audio, compressed video and transport consumers remain
active. It retains the existing bounded newest-frame ingress queue and counts raw
queue evictions during the change. A receipt requires a first sync compressed sample
at the requested H.264 dimensions from the new, still-current encoder revision; it
includes old/new source boundaries, session identities and eviction count. Both
output and return gates reject obsolete revisions and publication generations.
This is pre-mux format evidence, not achieved bitrate or downstream decoding proof.

Only one change may run. Competing settings/bitrate changes are rejected; crossing
into compressed passthrough fails the live operation. Cancellation, deadline, close
or finish prevents stale commit and receipt. Replacement callers and finish join
the native drain; publish cannot reuse the stream before it joins. The deadline
requests invalidation but cannot forcibly interrupt a wedged native platform call.
Immediate socket-send cancellation remains terminal and can require a fresh
connection. The app's independent archive and native scoring are unaffected by this
SDK API addition; dynamic app/worker/archive qualification is still required.
See [stream replacement validation](../../docs/superpowers/plans/2026-09-16-stream-profile-replacement.md).


`SRTConnection.samplePerformanceData()` explicitly collects current statistics on
the socket actor without clearing libSRT interval counters (`clear=0`). Cached
`performanceData` remains a cache read. The existing one-second bandwidth monitor
still clears its own interval (`clear=1`) and computes byte rates at its original
cadence. The app requests demand samples from its existing 250 ms health loop;
no additional timer/task is introduced. Native collection failures invalidate
freshness, and connection close, replacement or cancellation rejects a late result.
Statistics remain observations, not usable video capacity or receiver delivery.
See [fresh statistics validation](../../docs/superpowers/plans/2026-09-16-fresh-transport-statistics.md).


An optional immutable `pacesEncodedVideo` setting schedules native encoded video
through the existing owned consumer. `SourceCadenceClock` anchors the first dequeue
uptime to its exact source PTS and keeps that mapping through encoder replacement;
late frames receive no further delay. Nonmonotonic/invalid clocks or source lead
above one second fail publication. The consumer rechecks cancellation, generation
and failure after suspension. Audio and transport consumers remain independent;
finish joins pacing under the existing deadline and close cancels pending waits.
Compressed passthrough does not claim encoded-video pacing.

Opt-in pacing selects a 16-frame compressed encoder output queue, retaining the
2 MiB per-frame limit and terminal overflow failure. The ordinary default remains
eight frames and unpaced output; transport queues are unchanged. A dequeued sample
held by the consumer is additional to the bounded queue. The scalar observer copies
`dequeuedAt` before the pacing wait and `sourceCadencePaced` from the executed path;
these are distinct from encoder completion and post-pacing observation times.
This experimental mode is not evidence of sustainable bitrate or receiver delivery.

`SRTStream` accepts immutable `allowsBandwidthProbes: false` by default. When
explicitly enabled, a generation/UUID-scoped attempt may submit seven-packet
MPEG-TS null messages between media writes. Queue admission and the optional native
write share synchronized accounting, so media queued during an actor hop wins.
The socket temporarily uses nonblocking sends and restores its original mode.
Backpressure stops only the probe; native or option-restoration errors retain the
existing terminal publishing failure behavior, including accepted-byte evidence.

The probe has a 300 ms renewable lease, 60-second/16 MiB bounds, a maximum 2 Mbps
legacy or 12 Mbps staged accounted target and no initial or catch-up burst. Fresh native statistics must
show RTT and send buffer at most 50 ms with no new retransmission/drop counts.
Missing statistics, pressure, finish, close or configuration changes revoke it.
Configuration revision checks reject starts that overlap a settings change.
One coalesced wake signal drives the existing transport consumer, which drains
queued media before offering one optional message. An admitted probe owns a strict
dispatch timer that only signals this consumer; it cannot send or bank messages.
Its deadline follows token availability with a 2 ms legacy or 0.5 ms staged minimum
and 50 ms maximum. The staged timer permits at most 2,000 callbacks per second;
one-message token capacity and coalesced signals still prevent banking a burst.
Finish and close revoke the permit, cancel the owner and join the dispatch
cancellation handler, including an already entered callback. Timer precision is
best-effort; opportunities can still underdeliver. Snapshots prove local acceptance
only, never receiver delivery or usable capacity. Finite renewal and scheduled-pressure
simulator runs reach ~0.990 Mbps accounted against a 1 Mbps target with intact
archive/live gates. The initially failed pressure recording remains retained; a
synthetic catch-up pacing fix and dedicated stalled-source regression precede the
subsequent passing pressure run. Physical recording reliability remains open.
See [opportunity scheduling](../../docs/superpowers/plans/2026-09-16-probe-opportunity-scheduling.md).
See [native probe validation](../../docs/superpowers/plans/2026-09-16-native-padding-probe.md).

Each legacy optional message carries `SBUGPRB1`, its probe UUID, publishing generation,
accepted-message sequence, requested rate and packet ordinal inside each null
packet payload. Encoding occurs inside the existing synchronized offer; failed
sends do not advance the accepted sequence. This marker is attribution, not a
credential. The pre-demux receiver must bind it to its authenticated publication;
remultiplexed null counts cannot establish delivery. See the
[receiver accounting design](../../docs/superpowers/specs/2026-09-16-receiver-probe-accounting-design.md).


Native probe snapshots now carry a readonly `SRTBandwidthProbeAuthority` reference.
Every terminal native probe path revokes it synchronously. `permits` checks exact
UUID, generation and optional stage; it does not extend a lease or prove freshness,
delivery or capacity. The streaming adapter retains this same authority, and app
observations validate it after async reads and during local health polling. A copy
of old scalar values cannot keep a cancelled owner current. The default entry point
has no stage and emits v1.

`beginBandwidthProbe(bitRate:publishingGeneration:staged: true)` explicitly starts a
v2 qualification campaign at stage 1. `replaceBandwidthProbe(id:publishingGeneration:stage:bitRate:)`
requires the exact current staged identity and chooses the next ordinal. It revokes
the old permit under the native-send lock, then cancels and joins its wake owner.
After joining and sampling fresh statistics it checks publication, cancellation and
configuration again. Delayed old opportunities cannot send; a failed replacement
leaves its current identity retired and available for an explicit retry. Old
identities cannot replace a newer successful stage. Close, finish and configuration
changes revoke the owner, and new publication waits for a pending probe admission
to return.

`retireBandwidthProbe(id:publishingGeneration:)` is the exact-owner cleanup
barrier. It revokes sends under the existing native-send lock and joins the
captured wake task, including a wake that ignores cancellation. Duplicate callers
share that join; canceling a waiter does not abandon cleanup. The captured terminal
snapshot preserves the first stop reason, and completion cannot clear a newer
stage or publication. Cleanup also works during finish or failure and can join
the close task that already captured the exact retained probe's wake. The existing
`cancelBandwidthProbe` remains nonjoining. Retirement alone grants no retry or
quality-increase authority.

Every stage retains the first campaign start and prior accepted payload. The
campaign stops admitting after 32 stages, 16 MiB cumulative payload or 60 seconds
from the first stage; replacing or renewing never grants a fresh campaign budget.
Per-stage sequences restart at zero. Snapshots expose optional `campaignStartedAt`
and `totalAcceptedPayloadBytes` diagnostics, including accepted writes whose socket
mode restoration failed. Legacy snapshots omit these fields.

This opt-in SDK path has native lifecycle/wire/budget tests. Publisher adapters,
the DEBUG repeated scheduler, real staged relay/media recording, measured candidate
cost and automatic recovery still require integration and qualification. These
finite campaign limits are not the final long-session recovery policy. See the
[native staged probe plan](../../docs/superpowers/plans/2026-09-17-native-staged-probes.md).

`SRTStream` optionally accepts an immutable `transportSendObserver`. It records
scalar FIFO send observations with outer start/return and inner socket-call
start/return phases: publishing generation, sequence,
byte count, pending muxed-payload count and monotonic time. A returned call may
have failed or closed the connection; it is not proof of acceptance or delivery.
The inner bracket includes socket-actor scheduling and datagram yields; it does
not measure only native calls. Its return precedes error handling; early stale or
disconnected guards omit the inner pair. Outer return still closes the attempt.
Observers must do bounded synchronous work without I/O, waits or tasks. Nil adds
no timestamps or callback work. The current media queue limits, socket yielding,
shutdown and failure decisions are unchanged by observation.


An optional immutable `encoderSubmissionObserver` brackets synchronous raw-video
`session.convert` calls with session ID, source PTS, monotonic start/return and
status. Native compression uses `VTCompressionSessionEncodeFrame` inside that
wrapper. Session creation and asynchronous output completion are outside this
bracket. Both successful and throwing calls report; compressed conversion does
not. Nil avoids clock reads and callback work. This diagnostic neither moves
encoding off its actor nor changes media admission, errors or lifecycle.


The sole mux-output consumer now runs outside the stream actor, so synchronous
video submissions cannot prevent already-muxed payloads from draining. Queue,
byte, timeout and datagram-yield limits remain unchanged. The worker captures its
publication's accounting and failure latch; its optional probe pointer is copied
under a separate short lock, with existing revocation and empty-queue admission
still authoritative. Close cancels and retains its worker without self-joining;
re-publication joins retirement and rechecks stream/connection state. Normal finish
still joins the current worker. Outer send timing now measures worker resumption,
not stream-actor resumption.

Format changes within one publication retain the audio/video PID continuity
counters. Byte-level regression tests cover video resolution and audio sample-rate
changes, modulo-16 wraparound and the intentional new-publication reset in
`TSWriter.clear()`. This repairs invalid MPEG-TS continuity; it does not establish
that a particular impaired-network GOP loss was caused by the muxer. The maintained
patch also includes the previously implemented `SRTProbeTransportGuard`; all 162
original upstream hashes and the complete current source round trip are verified.

Guarded native admission is available explicitly through
`SRTStream.setVerifiedVideoBitRateWithReceipt(_:expecting:)` and
`replaceVideoSettings(_:publishingGeneration:expecting:timeout:)`. A verified
selector compares the actual configuration and encoder IDs, bitrate, acceptance
time and exact source `CMTime` representation before reservation, after joining
pending submission and at the codec's native admission boundary. Selectors are
values, not retained authority. `VideoMutationAdmissionError.stale` is emitted
only before this operation makes an encoder mutation; native write, cancellation
and replacement-drain uncertainty retain their existing errors and failure paths.

A replacement receipt selects one retained private continuation, minted by the
actual replacement and first successful new submission. Its historical source
boundary survives ordinary later submissions. A configuration write, settings
assignment, new replacement, finish, close or notification invalidation makes it
unusable; successful follow-up consumes it once. Notification callbacks only
advance the lock-protected scalar revision. Legacy mutation APIs remain available,
and no application quality-upgrade route is enabled by this SDK capability.

`validateVideoMutationExpectation(_:)` supplies read-only preflight for publisher
adapters before local reservation or probe revocation. It checks the actual
native verified receipt or retained replacement continuation, including lifecycle
and competing mutation guards. It neither consumes the continuation nor changes
encoder properties. This point-in-time read is not a mutation permit; guarded
setters still perform their own final checks.

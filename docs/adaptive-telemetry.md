# Telemetry required before automatic quality control

The [pure quality policy](adaptive-quality-policy.md) is implemented separately from runtime enablement.
Existing diagnostics establish useful local facts, but they do not yet provide a
complete fresh-frame/capacity window for safe upward adaptation.
The [local observation implementation slice](superpowers/plans/2026-09-14-local-video-observations.md)
now connects capture and actual encoder-completion measurements while retaining fixed live settings.

Current checkpoint: production worker status now has
[authenticated publication and actual reader/source association](worker-publication-association.md).
The [matched-source interval integration](matched-source-intervals.md) now connects
bounded native timestamp history and exact same-interval counting to worker status,
including leading losses between decoder windows and scoped freshness sequencing.
Usable video capacity, pressure, policy-window alignment and profile-boundary
qualification remain open. Historical interval counts do not enable quality changes.
The [timestamped transport statistics path](native-transport-statistics.md) now supplies
actual collection uptime, exact sent/retransmitted counters and sender-buffer
readings through the publishing session. Freshness and counter consistency are
explicit; these observations still require capacity/overhead qualification. The
[local network impairment fixture](local-network-impairment.md) now exercises actual
bidirectional loss and bandwidth ceilings with the native sender and clean archive.
Recoverable loss preserves all live frames; deliberate overload corrupts live output
while recording stays complete. The [bounded transport windows](transport-pressure-windows.md)
now carry exact counter deltas and time-weighted sampled buffering/RTT through the
publishing session, with actual collection endpoints and explicit gaps/freshness.
Capacity estimation, thermal/worker pressure and automatic control remain open.

| Existing observation                                                                  | What it measures                                                                                                                                | Missing evidence                                                                                                        |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `PublishingSessionSnapshot.sentSamples`                                               | Successful publisher append returns, including audio and video                                                                                  | Video encoding completion, unique frames, transport receipt, playback                                                   |
| `CaptureStreamingModel.videoObservation`                                              | Attempt-scoped capture callbacks and qualifying native encoding completions, with advancing-PTS counts and full monotonic windows               | Production source-range correlation, image-content uniqueness, usable capacity, and remote receipt                      |
| `CaptureStreamingModel.workerSourceInterval`                                          | Historical capture/encoder/decoder counts over the same source interval, scoped to native/worker attempt, profile and authenticated publication | Usable video capacity, pressure, monotonic policy alignment, applied-profile transitions and viewer receipt             |
| `CaptureStreamingModel.ingressObservation`                                            | Time-weighted live mailbox item/byte/max pressure, phase and per-kind disposition/PTS summaries                                                 | In-flight/SDK buffering, production source-loss denominator and transport capacity                                      |
| `CaptureStreamingModel.publishingClockObservation`                                    | Historical session mapping bound to recording, match, broadcast generation, publishing attempt and profile scope; closure marks detach          | Relay publication association, matched source intervals, remote delivery/loss and applied-profile transition boundaries |
| `SRTPublisher.metrics()`                                                              | RTT, cumulative SRT packet drops, cumulative transmitted bytes                                                                                  | Unique video delivery and usable video capacity; transmitted bytes include retransmissions                              |
| SDK `SRTPerformanceData`                                                              | Socket counters, estimated bandwidth, sender occupancy and buffering                                                                            | A qualified capacity estimator and receiver/worker frame timing                                                         |
| `WorkerObservation.frame/outTimeUs`                                                   | FFmpeg output progress within a worker attempt                                                                                                  | Proof of unique source frames or destination receipt                                                                    |
| `WorkerObservation.decodedVideo`                                                      | Five-second decoder/filter-ingress windows, strictly advancing PTS, duplicate/reordered counts and invalidity                                   | Image-content uniqueness, viewer receipt, full report-transit age, correlation with capture and encoding                |
| SDK `SRTStream.transportClockSnapshot` and `PublishingSessionSnapshot.transportClock` | Actual exact source-to-90kHz mapping and native generation; the session retains accepted historical evidence and quarantines contradictions     | App/worker scope correlation, matching source intervals, delivery/loss and applied profile boundaries                   |
| Native test barcode/audio analysis                                                    | Offline decoded identities and A/V alignment in the owned sink                                                                                  | A production runtime observation channel                                                                                |
| Archive export validation                                                             | Fully decoded completed/recovered local segments                                                                                                | Live congestion; archive health is an independent signal                                                                |

## Integration contract

1. Scope every window to match/broadcast generation, publishing attempt, public worker epoch and worker attempt,
   and applied profile revision. Local policy time is monotonic. Translate remote
   freshness using server-relative lifetime and measured request duration; never
   compare unrelated device wall clocks or silently join windows across reconnects.
2. Instrument capture video and encoded video separately using monotonic source PTS
   and bounded aggregate counters. Capture callbacks may update constant-size state;
   they must not create a task per sample, wait on network I/O, or keep an unbounded
   frame history. Duplicate/reordered PTS must not inflate a fresh-frame count.
3. The [worker decoder observation](worker-decoded-video.md) now measures decoded source cadence at the worker with a bounded parser/aggregation
   path. Carry a source-time interval and observation age with every count. FFmpeg
   output progress alone cannot be relabeled as source freshness. Specify whether
   each observation is worker ingress, worker output, or destination receipt.
4. Correlate source-loss counts over the same source-time range. Keep acquisition
   and restart gaps visible as gaps; do not compare unrelated windows or exclude
   outage time from reports. Archive losses remain separate from live losses.
   The SDK transport writer rebases PTS against its common A/V startup origin and
   quantizes the exact rational delta to 90 kHz, then adds a 9,000-tick lead. Local
   source PTS and worker decoder PTS therefore need an explicit, attempt-scoped clock mapping, including
   qualification of demux normalization and timestamp wrap. Numeric equality or
   the first frame observed by a worker that joined later cannot establish it.
   The [transport clock calibration](superpowers/plans/2026-09-15-transport-clock-calibration.md)
   now finds a finite-fixture-compatible worker path on Mac FFmpeg 8.1.2 and Linux
   FFmpeg 5.1.9: preserve input timestamps, retain the explicit frame-rate cap,
   use timestamp passthrough and normalize only at the output muxer. Plain `-copyts`
   loses frames around timestamp wrap under the current VFR output path. The
   successful candidate preserves exact wire correspondence modulo 2^33 and all
   frame identities in six full/late input cases. The
   [production worker now uses that path](superpowers/plans/2026-09-15-production-worker-clock.md);
   native serialization and an attempt-scoped SDK anchor are implemented in the
   [native clock slice](superpowers/plans/2026-09-15-native-transport-clock.md).
   The [native publishing observation](superpowers/plans/2026-09-15-native-clock-observation.md)
   now carries that actual SDK origin through the publisher and session lifecycle.
   A nil read preserves accepted history, while a contradictory mapping permanently
   clears that session's diagnostic mapping without stopping media. The native
   dual-output fixture verifies exact origins 0 and 123.25 seconds, full local/live
   frame preservation, and unavailable adapter evidence after joined stop.
   The app now binds accepted history to its full observation scope, clears it on
   a new attempt, and guards joined teardown from replacing another attempt's
   diagnostics. Closed scalar fixture export preserves the exact rational origin
   and native generation as decimal strings and rejects scope/closure mismatches.
   This is historical mapping evidence, not proof of current readiness or receipt.
   The [public worker epoch](superpowers/plans/2026-09-15-public-worker-epoch.md)
   now distinguishes reporting sessions through native status decoding; worker
   attempt 1 can recur after process/session replacement. It is an independent
   opaque identifier, not a private reporting token or freshness assertion.
   Publisher/relay association and matching source-interval counts remain required.
   The full native app fixture also exposes a remaining end-to-end correspondence
   gap: the worker decoder endpoints are each 10,919 ticks (about 121.322 ms)
   below the projected native endpoints through the owned SRT relay path. The
   endpoint shifts and spans match; intermediate-frame shifts are not yet measured.
   Frame identity, cadence, A/V and scoped export checks pass, but direct clock
   equality across that path is not established. The subsequent
   [raw relay comparison](relay-clock-correspondence.md) locates a clock change
   between native input and MediaMTX output: every retained VCL picture matches,
   while its PTS shifts and the worker preserves that shifted input. The pinned
   relay source rebases against its first accepted media callback, which may be
   audio. Production needs that actual, publication-scoped mapping; do not subtract
   a fixture constant or infer it from the first late-joined video frame.
5. Derive usable video capacity from a qualified transport estimator. Reserve audio,
   muxing, retransmission, and other overhead before applying the policy's video
   headroom. SRT's estimated bandwidth and successful send rate alone are not proof
   that a proposed higher bitrate is sustainable. Unknown capacity prohibits confirmed
   capacity-based increases. The revised [receiver-validated trial strategy](adaptive-quality-policy.md#receiver-validated-trial-strategy)
   permits an explicitly provisional <=10% same-profile bitrate experiment only after
   strong matched receiver and nominal transport/thermal/worker evidence, with a
   fixed deadline, confirmation period and sticky rollback. It does not manufacture
   capacity or change archive settings. Actual runtime boundaries/alignment and
   impaired-media trials must be qualified before enabling that strategy.
6. Aggregate live queue occupancy over the complete window and include queue budget
   and drops. A single empty-queue snapshot cannot stand in for a healthy interval.
   Carry thermal and worker pressure explicitly rather than interpreting every
   output slowdown as venue bandwidth loss.
7. Apply recommendations only to the live encoder. Serialize and verify changes;
   acknowledge actual applied settings/revision back to the policy. Rejected or
   stale recommendations must not change policy truth. Resolution changes also need
   keyframe/codec and destination-canvas qualification; bitrate support alone is
   insufficient.

The [verified live bitrate implementation](superpowers/plans/2026-09-15-verified-live-bitrate.md)
now provides a dedicated average-rate update with checked native writes/readback,
matching burst limits, lifecycle guards and explicit failure on uncertain application.
The previous generic SDK setter still cannot act as an acknowledgment; the app uses
the dedicated path. Real small-encoder fixtures verify accepted settings and continued
frame output. The five-scenario Mac dual-output run at `48155ea` also passes:
normal live packet rates decrease from 6.135 to 1.982 Mbps and 6.068 to 2.016 Mbps,
with all 420 source frames retained in each live output. Every archive remains
complete, including stalled/absent receivers. This establishes achieved rates for
these short fixtures, but does not identify the first frame affected by the setting,
establish available link capacity or authorize relabeling queued completions with a
new profile revision. Those transition and telemetry boundaries remain required before
runtime policy activation.

Tests should inject complete windows, stale/duplicate reports, counter resets,
clock changes, reconnects, invalid values, and absent metrics. Then replay measured
impairment traces and compare recommendations with fully decoded output. Until those
checks pass, the app retains its fixed 1080p30 live profile. Qualification is
workload-specific: the low-complexity ten-minute fixture passes, while sustained
structured motion and the pixel-noise overload failures remain under investigation
in the [motion calibration plan](superpowers/plans/2026-09-14-structured-motion-calibration.md).

The latest structured-motion checkpoint adds a complete instrumented ten-minute
pass at fixed 1080p30, with temporary export tracing removed afterward. The earlier
intermittent export timeout remains unexplained; see the
[measured results](superpowers/plans/2026-09-15-structured-motion-edges.md#complete-instrumented-ten-minute-pass).
The next diagnostic-only slice measures
[time-weighted live ingress pressure](superpowers/plans/2026-09-15-live-ingress-pressure.md).

That slice now connects the scalar accumulator, optional mailbox instrumentation,
publishing-session lifecycle and app snapshots. Full Media passes 162 tests and full
FilmModels passes 87; the combined iPhone/Watch Release build passes. Invalid clocks
preserve actual mailbox operation while making the affected time unknown. Terminal
queue cancellation freezes observations before encoder shutdown completes. The
default archive mailbox performs no extra clock or metadata work.

The native fixture now exports and strictly qualifies the frozen ingress evidence;
all 89 Film model and 400 tooling tests and the combined Release build pass, with
independent review. The complete ten-minute native run now passes at `11247df` without temporary export
tracing (`native-app-FhHkaM`): 19,018 archive and 18,620 acquired live frames at 30 fps,
zero source loss and no missing encoded tail. All 124 complete ingress windows plus
the terminal partial qualify; 18,680 audio and video buffers each admit/dequeue with
no evictions/discards/rejections. Mean maximum pressure is 0.009745% of queue budget.
All prior media gates pass. This does not establish physical camera performance,
useful link capacity, viewer receipt or safe quality increases. The earlier export
timeout and pixel-noise overload remain unresolved. See the linked plan for evidence
and the [completed verified-bitrate primitive](superpowers/plans/2026-09-15-verified-live-bitrate.md).

## Exact native transport clock

The [native clock implementation](superpowers/plans/2026-09-15-native-transport-clock.md)
now fixes timestamp bit encoding/decoding and shares exact rational projection
between PES, PCR and the SDK snapshot. PTS and DTS receive the same checked lead;
PCR cadence uses relative ticks. Invalid or unrepresentable values fail before
payload emission. Snapshot availability follows startup, publishing generation,
failure, finishing and close; a retained old snapshot cannot represent a new attempt.

All 124 SDK and 21 Streaming adapter tests pass, as do the unsigned combined
Apple device Release and arm64 simulator Debug builds and patch provenance checks.
The five-scenario native run `dual-output-yKe5LJ` passes with all 420 archive frames
in every case and all 420 live frames in both normal cases at 30 fps. Stalled and
absent receivers leave complete local recordings. Live packet bitrate decreases
from 5.992/6.068 Mbps to 1.982/2.016 Mbps; live A/V marker error stays below 65.364 ms.
These results verify the repair in this short Mac fixture. The production worker
now preserves the decoder transport clock and passes full/late/wrap fixtures on
Mac and Linux CPU, plus acquisition/cadence tests on Mac software/VideoToolbox and
Linux CPU. Its local software-worker recovery and native scoring workflow also
passes. See the [production clock results](superpowers/plans/2026-09-15-production-worker-clock.md).
Worker clock conventions are now explicitly negotiated and decoded by native
clients; absent/unknown labels remain unsuitable for source matching. The
[native anchor integration and matched interval work](superpowers/plans/2026-09-15-worker-clock-convention.md)
still remain, together with profile/capacity qualification. Automatic quality
changes remain disabled.

## Local observation accumulator

`ScorebugMedia/VideoFrameObservation.swift` now implements the isolated first
checkpoint: immutable attempt/profile scope, separate capture and encoded stage
aggregates, rational source-PTS comparison, and fixed half-open monotonic windows.
Its bounded history coalesces empty gaps and reports evicted intervals. Counters
saturate rather than wrap; epoch changes quarantine timestamp freshness until a
new owner is created. Malformed timestamp evidence is local to its interval, while
the snapshot retains lifetime invalidity evidence even after history eviction.

The runtime owner samples system uptime inside its lock. The pure accumulator takes
ordered caller times for deterministic tests. Clock seconds are bounded to
`0...1e12`, window duration to `1/1024...86400` seconds, and completed history to
`1...64` entries. Defaults are five-second windows and eight retained entries.
Closure is explicit and terminal; the caller must close only after desired encoder
drain. Old owner references never redirect observations to a new attempt.

The 18 focused tests and all 107 Media package tests pass. Evidence is under
`artifacts/qa/local-video-observation-*`, including behavioral red/green coverage for
malformed CoreMedia timescales and concurrency-safe clock admission. The unsigned
combined iPhone/Watch Release build also passes; its log is
`artifacts/qa/local-video-observation-ios-release.log`. Independent specification
and quality reviews approved this isolated checkpoint.

## Capture callback integration

Capture now resolves an immutable publishing attachment and observes ready video
before archive admission. A rejected archive sample remains visible to the capture
counter. Audio and direct publishing-tap offers do not count as capture video.
An owner can attach while its publisher is still prepared or starting; observation
rejection never gates either media branch.

Replacement, detach, and tap closure synchronously invalidate the old attachment's
publication admission. A callback already observed under the old owner cannot be
rerouted to a new publisher. The old owner stays open for encoder drain, and the
controller remains responsible for closing it afterward. The caller retains each
publishing session through its awaited stop, as required by the publishing lifecycle.

Eight new integration tests cover mixed audio/video, blocked startup, archive
rejection and teardown parity, invalid/closed observers, source quiescence, and
replacement/detach/close interleavings. All 115 Media tests and the unsigned combined
iPhone/Watch Release build pass; evidence is under
`artifacts/qa/capture-video-observation-*`.

## Native encoder completion hook

The pinned HaishinKit patch now accepts an optional immutable observer at SRT stream
construction. Each conversion retains its scalar input PTS and that observer through
the actual VideoToolbox completion callback. It notifies before downstream queue
admission; subsequent queue rejection does not erase a successful encoding event.

Only successful, non-dropped, ready single-frame compressed video with nonempty
data and valid, rationally matching input/output PTS qualifies. Decompression and
compressed passthrough do not notify. These diagnostic checks preserve the existing
media delivery/failure path. Encoded-stage callback counts will mean qualifying
notifications, not all native callbacks or all diagnostic rejections. The current
profile disables frame reordering; any change needs separate qualification.

All 76 SDK tests and the unsigned combined iPhone/Watch Release build pass.
Tests cover actual encoding/decompression, SRT construction and drain, passthrough,
delayed observer isolation, invalid outputs, and notification before queue failure.
The maintained patch verifies all 162 original upstream hashes and an exact round
trip. Evidence is under `artifacts/qa/encoder-completion-observation-*`.

## Runtime attempt ownership

The app now constructs one optional observation owner after validated publish access
and attaches it before awaiting publisher startup. The same owner reaches the native
encoder callback through `SRTMediaPublisher` and `SRTPublisher`. Its interval includes
encoder/transport startup, but not earlier broadcast/access requests. Fixed profile
revision 1 identifies the existing configuration; a starting snapshot does not prove
that configuration or readiness has succeeded.

`CaptureStreamingModel.videoObservation` updates synchronously in the existing local
health loop and retains one bounded closed snapshot after shutdown. Detach is
immediate; closure follows joined publisher shutdown so delayed encoder output stays
with the closing attempt. A separate diagnostic identity prevents an old final
snapshot from replacing a newer attempt's measurements. A new start clears prior
diagnostics, including when it fails before access. Unavailable diagnostics leave
publishing usable; failed publisher construction closes its orphaned owner.

All 44 Film model tests, 16 Streaming package tests, and the unsigned combined
iPhone/Watch Release build pass. Evidence is under
`artifacts/qa/runtime-video-observation-*`, including a retention regression that
fails when SDK observer forwarding is removed. These tests establish lifecycle and
ownership; the native fixture evidence below covers end-to-end media results.
Automatic quality changes remain disabled.

## Fixed-profile native observation qualification

`artifacts/qa/native-app-PzWmTp` passes the complete iPhone 14/iOS 17.5 native
workflow with the Mac VideoToolbox worker. The explicitly enabled DEBUG simulator
export writes one bounded, closed, credential-free observation snapshot after
publisher shutdown. Exact decimal counters and rational PTS survive JSON export.
The runner checks recording/match/generation scope against independently collected
workflow evidence and aligns source ranges using the fixture's encoded frame IDs.

Capture and encoder each observed 953 consecutive source frames (165–1117).
Five fully active five-second windows measured 30 capture fps and 29.8–30.2 encoded
fps. Their 750 encoded frames match the fully decoded live frame IDs exactly.
Startup and shutdown windows retain their complete elapsed time; the explicit
capture-detach time prevents shutdown duration from being treated as a capture
stall. The final partial window remains reported, including its 22.27 capture fps.

The archive has all 1,300 frames (0–1299). Acquired live output has 891 consecutive
frames (225–1115), approximately 30 fresh fps, maximum steady A/V offset 65.58 ms,
and a 3.69 ms tail offset. Sixty early encoded frames precede live acquisition;
two encoded tail frames are absent from the sink. These are reported separately,
not hidden by the aligned-window comparison. The archive extends 184 frames beyond
live output, including 182 beyond the observation interval.

All 46 Film model tests, 32 focused qualification/decoder-evidence JavaScript tests,
and the unsigned combined iPhone/Watch Release build pass. Specification and quality
reviews approve the fixture integration. Evidence logs are under
`artifacts/qa/video-observation-qualification-*`; the native run's `results.json`
contains all window phases, counts, ranges, and comparison exclusions.

This fixture-specific offline alignment does not supply a production source-clock
mapping or loss estimator. Report-transit age, qualified capacity and queue pressure,
verified profile application, impairment, and sustained hardware testing remain
required before adaptive enablement.

## Server report-age provenance

The [report-age slice](superpowers/plans/2026-09-14-worker-report-age.md) adds the API
foundation for a conservative decoder-window age upper bound. Opaque session timing
tokens retain server monotonic issuance times. Reports with recognized tokens can
prove transit-inclusive age once the worker samples after token reception. Status
adds API residence; retries, omissions, clock failures, contradictory bounds, and
numeric overflow cannot manufacture fresh evidence. This optional upper bound is
separate from the existing lower-bound `completed.ageMs`.

All 33 focused and 240 total API tests pass, including the shared HTTP golden
fixture. Protocol build and type checking pass. The worker now samples after
registration/token receipt and resamples after session renewal; all 25 reporter
tests and 132 total worker tests pass. Both API and worker checkpoints have passed
specification and quality review. Swift now adds the full status request and local
ContinuousClock residence with exact checked Duration arithmetic, preserving
immutable window scope and process TTL. Unusable bounds remain unknown, and old
status failures cannot overwrite post-Stop state. All 119 Core and 50 Film model
tests pass, together with the arm64_32 watchOS 10 Core and combined unsigned
iPhone/Watch Release builds. Both native reviews approve. Running-app qualification
is the remaining report-age checkpoint; automatic quality changes remain disabled.

The DEBUG native proof exporter and independent API comparator now pass 58 Film
model and 135 tooling tests, the combined unsigned iPhone/Watch Release build,
and both reviews. Proof durations are compared exactly using decimal Duration
components and BigInt; different API poll ages are not assumed equal. The first
isolated native attempt (`native-app-mIqwM3`) encountered an archive queue overflow
at 34.90 seconds, before stop/export and qualification completed. The run remains
failed. Queue/timing diagnosis takes precedence over claiming a complete age path;
no queue limit, quality policy, or media acceptance gate has been relaxed.

The complete report-age native fixture now passes at `9679081` in
`artifacts/qa/native-app-yCntsf` (iPhone 14/iOS 17.5, local Mac VideoToolbox worker).
Two actual helper proof windows match independent bounded API readings; exact
request/residence arithmetic and immutable remote/local identity checks pass along
with every existing media gate. The archive has 1,225 consecutive frames and live
has 799 consecutive acquired frames at 30 fps. Four steady capture/encoder windows
match 600 decoded frames. Live marker offset is at most 65.25 ms; tail alignment
is −17.567 ms against the unchanged 100 ms budget.

This follows a reviewed fix for a deterministic periodic-poll race that could send
the owned stop command before bounded publisher finish settled. Final checks pass
74 Film and 119 Core tests and the combined unsigned iPhone/Watch Release build.
The previous live-tail failure and archive overflow remain recorded separately.
The passing fixture still excludes 60 acquisition frames and 13 terminal encoded
frames absent from the sink. Passing A/V alignment cannot prove complete end
delivery when both tracks truncate together. Terminal delivery, production source
mapping, qualified capacity/queue inputs, profile transitions, impairment and
sustained hardware qualification remain required; adaptation remains disabled.

## Encoder configuration at submission

The [configuration boundary contract](encoder-configuration-boundaries.md) now
provides native per-frame session/configuration identity and a verified write receipt
with its prior raw submission boundary. Historical callbacks retain their original
identity. These scalars prepare source-window partitioning; they do not by themselves
make a receiver window entirely post-application or prove bitrate convergence.
Automatic adaptation remains disabled until runtime alignment and media trials pass.

The [configuration-associated source interval slice](superpowers/plans/2026-09-15-configuration-source-intervals.md)
now carries each immutable encoder submission identity through the production source
history. Matched intervals report unavailable, unverified, mixed, or uniformly
verified configurations. The exclusive prior endpoint is excluded, while every
included native frame—including receiver losses—participates. Counts remain available
when configuration metadata is absent. This is configuration association, not policy
window freshness or proof of rate convergence; runtime acknowledgment and pressure
alignment remain outstanding.

The [owned bitrate update slice](superpowers/plans/2026-09-15-owned-bitrate-updates.md)
adds a typed, validated native receipt to PublishingSession. The session owns its
mutation and deadline tasks, joins them on terminal shutdown, and rejects stale or
contradictory application evidence. Successful receipts remain historical after stop.
This completes mutation ownership; binding receipts to policy acknowledgments and
aligning source/pressure windows are still required before automatic control.

The [quality application owner](superpowers/plans/2026-09-15-quality-application-owner.md)
now binds verified receipts to initial settings and policy revisions, and rejects
stale advice or pre-acknowledgment telemetry. Outer evidence/clock rejection resets
policy recovery and preserves rollback intent. Its deterministic trial-to-rollback
sequence passes, but the capture model does not invoke this owner yet. The next
integration must build complete, configuration-matched source/pressure windows and
qualify receiver freshness before actual automatic media trials.

## Source-aligned ingress pressure

The ingress accumulator retains up to 4,096 scalar queue-depth/phase transitions in
an O(1) ring. Only state changes consume capacity; equal-time changes retain the final
state. Clock-only mailbox operations advance coverage without copying snapshots.
Actual diagnostic reads copy bounded history. No sample buffers or per-frame tasks
are added. This history is present only when ingress observation is configured.

A snapshot query integrates item occupancy, byte occupancy and their instantaneous
maximum over exact [start,end) uptime boundaries. It requires complete retained
coverage in the admitting phase. It never derives partial occupancy from five-second
aggregate means. Eviction makes older coverage unavailable. Invalid depth or clock
quarantines the history for the attempt; unrelated disposition PTS invalidity does
not fabricate a queue-depth error. Close freezes history and prevents extrapolation.

`PublishingSourceInterval.ingressPressure(in:)` checks immutable observation scope
and uses its actual capture boundary uptimes. Closed history can answer historical
queries; neither this association nor a complete mean proves present health,
receiver freshness, transport pressure or configuration/revision eligibility. Future
policy integration must check those independently.

The native dual-output fixture enables this production mailbox observation and
exports bounded scalar capture/queue history after completion. An independent Node
oracle joins probe PTS to capture times and integrates every intersecting raw state.
It requires the post-write interval to have complete admission coverage, while an
interval overlapping startup remains unknown. Existing native configuration, decoded
video, A/V, cadence, memory and clean archive checks remain separate gates.

The source-aligned queue checkpoint passes 224 Media, 54 Streaming and 769 tooling
tests, independent review and the combined unsigned iPhone/Watch Release build.
Evidence is `artifacts/qa/dual-output-zFS9sf` and `artifacts/qa/dual-output-1Y9Lmx`;
all eight archives remain complete. Each of five successful publishers has two
independently replayed pressure intervals and one startup-overlapping unknown interval.
These are declared finite-fixture source probes, not production receiver windows.

Measured nominal five-second capture intervals sometimes exceed five seconds by a
few milliseconds. The current policy rejects those durations. Alignment must account
for measured elapsed time with a specified input-duration contract; clipping times
to fit existing tests would invent evidence. The separate rolling-five-second output
quality gate remains unchanged.

## Source-aligned sampled transport gauges

`PublishingTransportStatisticsSnapshot.samples` exposes at most 64 retained validated
native collections. `interval(from:to:)` requires collections bracketing both requested
uptime boundaries and integrates preceding sampled buffer/RTT gauges over the exact
interval. It never extrapolates past a collection. Ring eviction and gaps over two
seconds remove older coverage; quarantine rejects queries. Closed snapshots remain
queryable as history while their fresh accessors still reject closed state.

The result separately reports `enclosingStart` and `enclosingEnd`. Wide sent,
retransmitted and drop deltas, and gauge maxima, belong to that enclosing collection
range. They are not interpolated into invented exact-interval counters. Gauge means
represent the preceding-sample assumption and cannot detect unsampled instantaneous
pressure. These values establish neither bandwidth capacity nor a nominal/elevated
policy classification. The future app adapter must independently bind attempt,
configuration/revision, acknowledgment and freshness.

The native monitor now retains its validated tracker in a synchronized scalar owner,
closes it after the monitor joins, and exports actual retained samples and typed
per-source-probe intervals. Independent reconstruction first qualifies original
native collections and source/capture correspondence, then checks retention,
bracketing, normalized gauge integration and exact enclosing counters. Source probes
remain declared finite-fixture endpoints, not production worker reports.

## Session-owned thermal samples

`PublishingSessionSnapshot.thermalObservation` now retains at most 64 timestamped
raw `ProcessInfo.thermalState` readings, collected at readiness and by the existing
health monitor (default 250 ms). The read occurs outside the session lock and away
from capture callbacks. A suspended publisher read delays future collections rather
than extending nominal coverage. Invalid clocks quarantine only these diagnostics;
healthy publication can continue. Stop closes history before joining workers, and
late monitor completion cannot mutate it.

The history exposes actual nominal/fair/serious/critical/unknown readings. Its
historical interval query requires retained samples at/before and at/after requested
capture boundaries, with no gaps larger than two seconds. It returns explicitly
enclosing bounds and the maximum reported state; any unknown enclosed reading makes
that aggregate unknown. Raw readings remain available, including any known elevated
readings in such a mixed interval. Duplicate samples do not extend coverage, and
conflicting/reversed timestamps quarantine history. Closed snapshots can answer
historical queries but never claim a fresh current reading.

This is sampled OS state, not continuous thermal coverage, temperature, or physical
phone qualification. Future policy wiring must bind the owning session and apply
explicit thresholds without turning missing or unknown evidence into nominal. See
[Apple's state definitions](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)
and the [thermal history plan](superpowers/plans/2026-09-15-publishing-thermal-history.md).

## Optional worker encoder timing

`startPipeline(..., {encoderTiming: true})` adds a separate FFmpeg pre/post encoder
statistics pipe. `snapshotEncoderTiming()` exposes at most 256 timestamp-correlated
submissions, their reader-observed completion times, current pending count/age and
historical interval queries. Correlation uses exact rational PTS, independent of
FFmpeg's optional input-frame identity (unavailable in the real VideoToolbox probe).
Reordered packets are allowed when they match unique submitted timestamps; malformed,
missing, contradictory, oversized or clock-invalid evidence becomes unavailable.

A separate pipe drain isolates this observer from existing decoder evidence. Pipe
errors and premature closure quarantine only timing diagnostics. Completed frames can
be evicted; an outstanding oldest frame is never silently evicted. EOF freezes ages
and history, potentially with incomplete submissions after an interrupted encode.

These observed durations include scheduling/pipe delays and omit decode/filter work.
They are not processor utilization, network capacity, viewer delivery or proof of
nominal overall worker pressure. Real CPU and VideoToolbox probes show that normal
pending depth differs by backend. Standalone pipeline callers still opt in explicitly.
Worker startup now checks option availability as described below; older FFmpeg builds
keep publishing without these optional diagnostics. Negotiated source reports are now available as described below; policy
classification still requires further integration.
The source correlation below adds observations after decode. See the
[worker timing plan](superpowers/plans/2026-09-15-worker-encoder-timing.md) and
[FFmpeg's statistics documentation](https://ffmpeg.org/ffmpeg.html).

## Source-correlated worker processing

The same opt-in now exposes `snapshotProcessing()`: a shared pipeline scope containing
up to 512 decoder PTS/reader-time records and the existing 256 encoder records.
`workerProcessingInterval(snapshot, start, end)` joins exact 90k source coordinates
over `(start, end]`, requiring retained decoder anchors and encoder brackets. Every
bracketing submission must exist in decoder history. Fractional, colliding, missing
or mismatched coordinates remain unavailable. Decoder pipe errors and premature close
invalidate evidence without changing publication ownership.

The result separates decoded, submitted, completed, pending and omitted-before-encoder
counts. Omissions can include deliberate frame-rate reduction; they are not automatically
accidental loss. Reader-observed decoded-to-submission and decoded-to-completion
durations are available only when every included timestamp yields a nonnegative
duration. Cross-pipe delivery order can leave either duration unknown while source
counts remain valid. These values exclude decode execution itself and do not establish
viewer delivery, spare capacity, fresh live reports or nominal worker pressure.

`pnpm test:worker-processing software 60` runs the actual pipeline, independently
probes input timestamps, checks expected frame selection against saved video barcodes,
fully decodes output A/V and replays the raw timing aggregates. CPU 25/30/60 fps and
VideoToolbox 30/60 fps pass locally. These are three-second finite fixtures, not paced
capacity or sustained-load qualification. NVENC remains unqualified. See the
[processing plan](superpowers/plans/2026-09-15-worker-processing-correlation.md).

## Live worker processing windows and startup availability

`WorkerProcessingWindows`, exposed by `snapshotProcessingWindow()`, joins adjacent
completed decoder windows over `(previous.lastPTS, current.lastPTS]`. It checks source
counts and the current first PTS against retained history. Acquisition, skipped or
empty windows, missing brackets and zero selected submissions cannot become frozen
healthy completion. Pending work can complete on another read of the same window.
Once all selected submissions complete, a copied result stays stable across history
eviction; a superseding decoder window discards it. Invalid histories, changed window
contents, rewinds, scope changes and closure cannot retain valid current evidence.
Report freshness and publication/configuration ownership remain separate requirements.

Worker startup defaults to an owned three-second, 4 MiB FFmpeg help query for all four
encoder-statistics options. Unsupported probes disable optional diagnostics while
normal streaming continues; `WORKER_PROCESSING=off` skips the query. POSIX process-group
cleanup includes wrapper descendants and shutdown joins the cancelled probe. Native
Windows currently returns `unsupported_platform` without starting this optional probe;
WSL follows POSIX behavior. Actual encoder/profile qualification is still required.

The paced fixture (`pnpm test:worker-processing software 30 --paced`) now sends a
24-second source over an owned loopback HTTP connection, samples real windows and
independently reconstructs their counts and timing from retained raw collections.
The oracle rejects stale frozen sequences and requires two completed live windows.
Input analysis consumes about five seconds in the local fixture, so the original
18-second attempt correctly failed that gate. No startup coverage was invented to
make it pass. These observations now travel through negotiated API/native reports as described
below; they are not yet inputs to automatic adaptation. See the
[live processing plan](superpowers/plans/2026-09-15-live-worker-processing-windows.md).

## Negotiated processing evidence in the native app

`snapshotVideoEvidence()` samples decoder and processing evidence atomically. The
worker advertises only current, owned processing after exact protocol/clock/read-identity
negotiation. API progression guards preserve immutable pipeline/backend/assignment
ownership through omissions. Pending completion updates retain the decoder window's
existing age proof; missing metadata stays missing in public status.

Swift validates optional reports without letting malformed additions invalidate older
status fields. Native source matching checks the same publication, epoch, attempt,
sequences, exclusive anchor, first/end timestamps and decoded count. Debug fixtures
retain these matched historical reports for independent API/output-frame comparison.
This supplies source-correlated measurements; backend/load thresholds, configuration
revision mapping and automatic quality trials remain separate unqualified work.
See [worker status](worker-status.md#optional-source-processing-reports) and the
[implementation evidence](superpowers/plans/2026-09-15-worker-processing-reports.md).

The [quality telemetry binding](adaptive-quality-policy.md#bound-telemetry-evaluation)
now maps matched source intervals and current verified receipts to policy revisions,
with aligned ingress/thermal/transport histories and explicit caller-qualified
pressure limits. It retains unknown evidence and nil capacity. The actor binds this
conversion atomically and prevents worker restarts from extending prior recovery.
Capture runtime activation and actual adaptive media/impairment qualification remain
open; deterministic binding tests do not establish physical or remote-host thresholds.

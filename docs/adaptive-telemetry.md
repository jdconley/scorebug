# Telemetry required before automatic quality control

The [pure quality policy](adaptive-quality-policy.md) is implemented separately from runtime enablement.
Existing diagnostics establish useful local facts, but they do not yet provide a
complete fresh-frame/capacity window for safe upward adaptation.
The [local observation implementation slice](superpowers/plans/2026-09-14-local-video-observations.md)
now connects capture and actual encoder-completion measurements while retaining fixed live settings.

| Existing observation                    | What it measures                                                                                              | Missing evidence                                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `PublishingSessionSnapshot.sentSamples` | Successful publisher append returns, including audio and video                                                | Video encoding completion, unique frames, transport receipt, playback                                    |
| `CaptureStreamingModel.videoObservation` | Attempt-scoped capture callbacks and qualifying native encoding completions, with advancing-PTS counts and full monotonic windows | Production source-range correlation, image-content uniqueness, usable capacity, and remote receipt |
| `CaptureStreamingModel.ingressObservation` | Time-weighted live mailbox item/byte/max pressure, phase and per-kind disposition/PTS summaries | In-flight/SDK buffering, production source-loss denominator and transport capacity |
| `SRTPublisher.metrics()`                | RTT, cumulative SRT packet drops, cumulative transmitted bytes                                                | Unique video delivery and usable video capacity; transmitted bytes include retransmissions               |
| SDK `SRTPerformanceData`                | Socket counters, estimated bandwidth, sender occupancy and buffering                                          | A qualified capacity estimator and receiver/worker frame timing                                          |
| `WorkerObservation.frame/outTimeUs`     | FFmpeg output progress within a worker attempt                                                                | Proof of unique source frames or destination receipt                                                     |
| `WorkerObservation.decodedVideo`        | Five-second decoder/filter-ingress windows, strictly advancing PTS, duplicate/reordered counts and invalidity | Image-content uniqueness, viewer receipt, full report-transit age, correlation with capture and encoding |
| SDK `SRTStream.transportClockSnapshot` | Immutable exact source-to-90kHz projection, scoped to the active publishing generation after muxer startup | App/worker plumbing, matching source intervals, delivery/loss and applied profile boundaries |
| Native test barcode/audio analysis      | Offline decoded identities and A/V alignment in the owned sink                                                | A production runtime observation channel                                                                 |
| Archive export validation               | Fully decoded completed/recovered local segments                                                              | Live congestion; archive health is an independent signal                                                 |

## Integration contract

1. Scope every window to match/broadcast generation, publishing attempt, worker attempt,
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
   frame identities in six full/late input cases. Production flags remain unchanged;
   native serialization and an attempt-scoped SDK anchor are now implemented in the
   [native clock slice](superpowers/plans/2026-09-15-native-transport-clock.md).
   App/worker plumbing and matching source-interval counts are still required.
5. Derive usable video capacity from a qualified transport estimator. Reserve audio,
   muxing, retransmission, and other overhead before applying the policy's video
   headroom. SRT's estimated bandwidth and successful send rate alone are not proof
   that a proposed higher bitrate is sustainable. Unknown capacity prohibits increases.
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
These results verify the repair in this short Mac fixture. Production worker flags,
app/worker mapping integration, matched interval counts and profile/capacity
qualification remain separate work; automatic quality changes remain disabled.

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

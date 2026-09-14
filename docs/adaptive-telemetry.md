# Telemetry required before automatic quality control

The [pure quality policy](adaptive-quality-policy.md) is implemented separately from runtime enablement.
Existing diagnostics establish useful local facts, but they do not yet provide a
complete fresh-frame/capacity window for safe upward adaptation.
The [local observation implementation slice](superpowers/plans/2026-09-14-local-video-observations.md)
now connects capture and actual encoder-completion measurements while retaining fixed live settings.

| Existing observation                    | What it measures                                                                                              | Missing evidence                                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `PublishingSessionSnapshot.sentSamples` | Successful publisher append returns, including audio and video                                                | Video encoding completion, unique frames, transport receipt, playback                                    |
| `CaptureStreamingModel.videoObservation` | Attempt-scoped capture callbacks and qualifying native encoding completions, with advancing-PTS counts and full monotonic windows | Source-range correlation, image-content uniqueness, usable capacity, remote receipt, and local fixture qualification |
| Publishing mailbox occupancy/drops      | Bounded raw sample queue, including audio and video                                                           | Time-weighted occupancy and per-kind/source-PTS loss                                                     |
| `SRTPublisher.metrics()`                | RTT, cumulative SRT packet drops, cumulative transmitted bytes                                                | Unique video delivery and usable video capacity; transmitted bytes include retransmissions               |
| SDK `SRTPerformanceData`                | Socket counters, estimated bandwidth, sender occupancy and buffering                                          | A qualified capacity estimator and receiver/worker frame timing                                          |
| `WorkerObservation.frame/outTimeUs`     | FFmpeg output progress within a worker attempt                                                                | Proof of unique source frames or destination receipt                                                     |
| `WorkerObservation.decodedVideo`        | Five-second decoder/filter-ingress windows, strictly advancing PTS, duplicate/reordered counts and invalidity | Image-content uniqueness, viewer receipt, full report-transit age, correlation with capture and encoding |
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

Tests should inject complete windows, stale/duplicate reports, counter resets,
clock changes, reconnects, invalid values, and absent metrics. Then replay measured
impairment traces and compare recommendations with fully decoded output. Until those
checks pass, the app remains on its qualified fixed 1080p30 live profile.

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
ownership, not end-to-end media results. Fixed-profile simulator qualification is
the next checkpoint; automatic quality changes remain disabled.

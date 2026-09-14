# Telemetry required before automatic quality control

The [pure quality policy](adaptive-quality-policy.md) is implemented separately from runtime enablement.
Existing diagnostics establish useful local facts, but they do not yet provide a
complete fresh-frame/capacity window for safe upward adaptation.
The next [local observation implementation slice](superpowers/plans/2026-09-14-local-video-observations.md)
adds capture and actual encoder-completion measurements while retaining fixed live settings.

| Existing observation                    | What it measures                                                                                              | Missing evidence                                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `PublishingSessionSnapshot.sentSamples` | Successful publisher append returns, including audio and video                                                | Video encoding completion, unique frames, transport receipt, playback                                    |
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

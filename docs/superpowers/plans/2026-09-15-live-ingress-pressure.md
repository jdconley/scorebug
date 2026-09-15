# Live ingress pressure observations

Continue the approved adaptive-quality telemetry plan after the current structured
motion export diagnosis. Use bounded implementation and independent specification
and quality review; the parent owns isolated native/media execution. This slice
adds diagnostics only. Automatic adaptation remains disabled.

## Measurement boundary

`PublishingSessionSnapshot.queue` exposes instantaneous depth and cumulative counts.
Periodic polling cannot reconstruct pressure between reads. Add an optional scalar
accumulator updated inside `BoundedMailbox`'s existing lock at actual mutations and
observation reads. Do not introduce arbitrary callbacks, tasks, media retention,
disk/network work or another lock inside the mailbox lock. Existing admission,
limits, continuation resumption and element release behavior must remain intact.

Integrate the previous queue state through the trusted mutation time before changing
depth. Report separate normalized item and byte occupancy integrals, plus the
integral of their instantaneous maximum. The mean of the maximum is not the maximum
of the two means. Direct handoff has zero queued occupancy. The one in-flight sample
and all SDK/encoder/socket buffering remain outside this measurement.

Use immutable recording/match/broadcast generation, publishing-attempt and applied
profile-revision scope. Share the video observation anchor and five-second half-open
intervals. Include startup with explicit admission phase; do not imply the encoder
was ready merely because an observation owner existed. Close ingress observations
when terminal cancellation discards the queue, retaining that timestamp through
joined publisher shutdown. Empty time after closure must not dilute prior pressure.

## Disposition and clock evidence

Count admitted, dequeued, overflow-evicted, rejected and cancellation-discarded
elements separately, by audio/video/unknown kind and rejection reason where relevant.
Retain only bounded scalar kind/PTS metadata beside each existing queued entry so
evictions describe the removed sample. Audio counts are buffers, not PCM samples;
video buffer counts do not automatically establish fresh frames. Preserve rational
PTS extrema, invalidity and epoch discontinuity without claiming contiguous ranges.

These counts exclude attachment/startup rejection before mailbox admission,
in-flight append failure, downstream SDK/encoder loss and remote loss. They cannot
supply `QualityController.SourceLoss` or an expected-frame denominator. Archive
losses remain independent.

Sample system uptime inside the mailbox lock. The pure accumulator accepts ordered
caller time for deterministic tests. Equal times are valid. Reversed, nonfinite or
out-of-range clocks invalidate observation evidence without rejecting actual media
operations. After unknown timing, do not integrate a guessed old depth across the
gap. Use explicit invalidity, checked/saturating counters, bounded finite normalized
area arithmetic and bounded retained history with omitted-interval evidence.

Long unchanged intervals require bounded handling even when the queue stays full.
Do not reuse the video accumulator's empty-gap shortcut for occupied intervals.
Coalesced intervals must retain their full duration, depth integral, phase and
coverage count; they cannot masquerade as individual five-second policy windows.

## Implementation and verification sequence

1. Write analytic accumulator tests before implementation: known occupancy integrals,
   alternating item/byte pressure, exact boundaries, zero-duration operations,
   long occupied gaps, bounded history, saturation and invalid clocks. Establish
   behavioral red evidence, then focused green.
2. Add optional mailbox integration with existing behavior as the default. Test
   direct handoff, multiple evictions, mixed kind/PTS, oversize rejection without
   eviction, and cancellation discards distinct from congestion. Exercise actual
   transitions under invalid observation clocks. Compare admission, ordering,
   counters and release behavior with instrumentation disabled, including races.
3. Connect one optional owner to each publishing session. Expose its snapshot through
   the existing local health loop and attempt-guarded terminal retention. Test
   startup/failure, detach, reconnect, stale-final suppression and archive independence.
   Diagnostic construction failure leaves media operation available.
4. Run the full Media and affected Film model suites, appropriate native builds,
   and independent reviews. Qualify the fixture observation export and compare
   measured occupancy/disposition evidence with existing capture/encode/media gates
   in a single isolated native run. Do not relax recording or frame-delivery gates.

Capacity estimation, source-clock mapping, receiver proof and verified live encoder
reconfiguration remain separate work. An ingress pressure measurement alone does
not authorize enabling the controller or claiming sustainable higher quality.

## Design review

A bounded read-only review of mailbox, publishing-session and app lifecycle ownership
endorses this scope. It specifically requires separating shutdown discards, measuring
inside actual mailbox mutations, and preserving occupied gaps rather than treating
them as empty. No implementation or runtime qualification is claimed yet.

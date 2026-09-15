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

## Implemented accumulator, mailbox and app checkpoint

Steps 1–3 are implemented. `LiveIngressObservationAccumulator` keeps bounded scalar
windows and lifetime totals, with normalized item/byte/instantaneous-maximum areas,
phase occupancy, per-kind dispositions and rational PTS summaries. Invalid clocks
retain actual depth and cumulative counts but quarantine unknown elapsed time and
leave events unassigned to windows. Impossible item/byte relationships invalidate
occupancy. Half-open boundary transitions do not carry a previous depth's peak into
the new interval. Terminal closure freezes time and evidence.

`BoundedMailbox` owns optional instrumentation inside its existing lock and exposes
an atomic statistics/observation snapshot. The default path adds no clock reading or
metadata extraction. Direct handoff counts admitted/dequeued with zero queued area;
overflow and cancellation use metadata from the removed entries. Waiting-task
cancellation does not close the observation. Finish measures draining until the
last queued element is removed; cancellation closes at discard. Later terminal
rejections remain visible in legacy statistics but are outside the frozen ingress
observation. No continuations or element deinitializers are invoked under a new lock.

`PublishingSession` starts observation in startup phase, marks admission only after
readiness under its existing ownership lock, and supplies scalar sample kind/PTS
only when observations are available. Cancellation closes ingress before joined
publisher/encoder shutdown. The app copies the video scope, anchor and window
duration, publishes current/frozen ingress snapshots through its local health loop,
and guards final retention against newer attempts. Diagnostic construction failure
leaves both media branches available. Live encoder settings remain fixed.

Verification completes with actual exit 0:

- 15 accumulator tests, including behavioral red (52 issues), impossible-depth red
  (18 issues) and the independently found boundary-peak red (4 issues).
- 8 mailbox integration tests after compiled behavioral red, covering analytic
  areas, direct handoff, mixed-kind eviction/discard, drain, invalid clocks and
  concurrent atomic snapshots and cancellation conservation. The existing retained-
  element test also passes with instrumentation both disabled and enabled.
  All 18 publishing-session tests pass.
- Full Media: 107 XCTest plus 55 Swift Testing tests, 162 total.
- App integration: 40 targeted tests pass after 14 behavioral-red assertions;
  full FilmModels passes all 87 tests. The combined iPhone/Watch Release build passes.
- Independent scalar, mailbox, publishing-session and app reviews approve the
  final behavior. The scalar review's boundary finding was reproduced and fixed.

Logs are `artifacts/qa/live-ingress-{accumulator-*,consistency-*,boundary-*,mailbox-*,
publishing-*,media-full,media-final,film-*,native-release}.log`. The native fixture does not yet
export or qualify ingress data, so this checkpoint is not long-run media evidence
for the new instrumentation and does not enable adaptive quality.

## Remaining native qualification

Add the frozen ingress snapshot to the existing explicitly enabled simulator-only
`video-observation.json` export, through its joined, attempt-guarded writer. Preserve
bounded windows/totals/phases/budgets, decimal counter strings, rational PTS and
invalidity. No new runner or capacity threshold is needed.

Write focused serializer and strict JavaScript qualifier tests for malformed scope,
clock/bounds, omitted history, inconsistent areas and accounting. Require matching
video scope/anchor/window duration, terminal zero depth, finite bounded areas, no
invalid timing, and complete retained history for this fixture. Check window sums
against lifetime totals and admitted = dequeued + overflow-evicted + cancellation-
discarded for each kind; preserve shutdown discards separately. Verify ingress closes
between capture detach and video-observer closure. Compare PTS extrema with archive
bounds without asserting continuity or equating dequeues to encoded frames.

Include the qualified summary in existing native results and run the uninstrumented
600-second workflow with all current archive, frame-delivery, A/V, workload and worker
evidence gates intact. This plan has independent read-only design review; implementation
and native qualification of this remaining export slice are still pending.

## Native export and qualifier implementation

The existing simulator-only fixture now exports the frozen ingress observation
through its joined, attempt-guarded writer. An optional nested version-1 object
preserves bounded windows, phases, budgets, exact decimal counts/rational PTS and
invalidity without changing existing exports when ingress is absent. The native
streaming runner requires the new object and includes its qualified summary in
`results.json` after video identity/media qualification.

The strict qualifier checks scope/anchor/duration, terminal zero depth and close
ordering, retained history, finite normalized areas, phase/window/total accounting,
per-kind conservation, and coalesced occupied intervals. Source video extrema map
to decoded archive frame identities. Audio buffer starts use exact rational
subtraction of the fixture's 123.25-second source origin and archive audio coverage;
they are not PCM sample counts or video frame identities. Dequeue counts never
stand in for encoder completion, fresh frames, network capacity or receiver proof.

Verification has actual exit 0: all 89 Film model tests, all 400 tooling tests
(including 17 ingress qualifier tests), and the combined iPhone/Watch Release build.
Serializer tests first failed on missing ingress export; joined-writer tests then
produced 18 expected assertions with a deliberately absent ingress snapshot before
final wiring passed. The qualifier's occupied-gap test reproduced underintegration
before its check was added. Independent review also caught underintegration in
ordinary event-free windows; a failing regression now covers unchanged depth even
when rejected offers occur. The correction passes and final independent review
approves the exporter, joined writer, qualifier and runner integration. Logs are `artifacts/qa/ingress-export-*.log` and
`artifacts/qa/ingress-qualification-*.log`.

The unchanged 600-second native media workflow is the next acceptance step. No
export timeout, media threshold, queue budget or encoder setting was relaxed.

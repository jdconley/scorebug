# Adaptive quality policy

Continue milestone 4 of the approved portable streaming plan. First implement a
pure, deterministic policy in ScorebugCore; connect it to live media only after its
inputs can be measured truthfully. Archive configuration and archive failure handling
remain independent of every policy decision.

## First implementation boundary

- Accept an ordered, caller-supplied ladder of supported live profiles. Each profile
  defines dimensions, a 30 fps target, and minimum/maximum video bitrate. Validate
  identifiers, dimensions, ordering, and bitrate bounds. Do not assume a device can
  encode 4K or change resolution while publishing.
- Accept completed, timestamped telemetry windows with separately identified capture,
  encoded, and received fresh-frame counts, source-loss observations, live queue
  occupancy, usable transport capacity when measured, connectivity, and thermal/worker
  pressure. Missing received-frame evidence cannot establish healthy viewer output;
  muxed FFmpeg frame counters are not fresh-frame counts.
- Use monotonic caller time and a stream-attempt identity. Reject malformed, stale,
  reordered, duplicate, or cross-attempt windows. Reset recovery history on outages,
  missing evidence, changes of profile, and unhealthy windows.
- Decrease promptly when a complete window shows fewer than 24 fresh fps, source loss
  above one percent, sustained queue pressure, insufficient capacity headroom, or
  explicit thermal/worker pressure. Clamp every result to supported profile limits.
  Represent disconnected/stalled/unknown states explicitly; do not report a low
  profile as healthy when even its minimum cannot be sustained.
- Recover conservatively: require 30 continuous seconds of qualified healthy windows
  plus measured capacity headroom for the proposed rate before raising bitrate or
  recommending the next supported profile. No upward change from missing telemetry.
- Return recommendations and reasons, with no tasks, sleeps, networking, camera
  access, or encoder mutation. Actual application of a recommendation must be
  acknowledged separately so a failed reconfiguration cannot become policy truth.

## Tests and integration sequence

1. Write red tests for configuration validation, healthy startup, prompt reduction,
   bitrate/profile bounds, floor violation, queue pressure, thermal/worker pressure,
   minimum-profile insufficiency, outage/recovery, missing capacity/receiver evidence,
   exactly 30-second hysteresis, gaps/duplicates/time reversal, and stale attempts.
2. Implement the pure policy and pass the complete Core suite. Compile the shared
   package for watchOS 10 without importing capture, codecs, or SRT. Obtain independent
   specification and code-quality reviews before enabling policy behavior.
3. Add generation-scoped fresh-frame/capacity telemetry and replay deterministic
   traces. Keep capture/encoded/received/archive observations distinct; absent metrics
   remain unknown. Test any cross-process protocol additions independently.
4. Connect bitrate control first. Qualify resolution and keyframe transitions,
   destination canvas behavior, and failure rollback before enabling profile switches.
5. Add isolated bidirectional UDP tc/netem impairment, then run the short matrix and
   30-minute soak from the parent plan. Preserve outages and transition windows in
   reports and retain clean local video throughout network-only failures.

Only the first two steps are the initial pure-policy implementation. Thresholds are
proposed starting values from the parent plan; media impairment and physical-device
results must qualify them before claiming adaptive streaming reliability.

## Implementation checkpoint

Steps 1 and 2 are complete: `QualityController` and 20 focused tests are implemented,
all 88 Core tests pass, the package compiles for arm64_32 watchOS 10, and independent
specification/code-quality reviews approve the source. Recommendations have explicit
expiry and applied revisions; rejected input preserves the monotonic time watermark,
and bitrate arithmetic clamps before conversion on 32-bit Watch targets.
See [policy behavior and evidence](../../adaptive-quality-policy.md).

Steps 3–5 remain open. The production app still uses fixed 1080p30; no archive or
live encoder behavior changes merely because the pure policy is present.

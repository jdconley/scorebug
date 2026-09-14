# Pure adaptive quality policy

`ScorebugCore.QualityController` computes live-video recommendations from complete
telemetry windows. It has no media/framework dependencies, tasks, network access,
encoder mutation, or archive references. The native app still uses the qualified
fixed 1080p30 profile; this policy is not enabled in the capture/publishing path.

## Inputs and state

Construct one value-type controller for each publishing attempt with an explicit
UUID, monotonic start time, actual applied settings, and a low-to-high ladder of
caller-qualified profiles. Profiles have unique simple identifiers, positive even
dimensions, 30 fps targets, and bounded positive video bitrate ranges. Dimensions
and minimum/maximum bitrate cannot decrease along the ladder. The policy does not
establish whether those profiles are supported by a particular device or worker.

Each window identifies the attempt, sequence, applied revision, and a complete
1–5-second monotonic interval. It separately carries capture/encoded/received fresh
frames, receiver observation time, source-loss counts, mean live queue occupancy,
usable video capacity, connectivity, and thermal/worker pressure. Capacity is video
bits per second after reserving audio and transport costs. Send throughput is not
an interchangeable capacity measurement.

Windows cannot overlap, arrive out of order, cross applied revisions, or arrive more
than two seconds after their end. Invalid telemetry clears recovery and pending
advice and throws; callers must present unknown status instead of retaining a prior
healthy claim. A gap between accepted windows resets recovery. Missing or stale
receiver evidence, absent capacity, or other unknown required observations cannot
establish health or qualify an increase.

Every finite forward caller time advances the watermark even if later input
validation fails. Reversed, NaN, and infinite times are rejected without poisoning
that watermark. A rejected stale observation cannot make an earlier time valid again.

## Initial policy thresholds

- Any measured capture/encoded/received cadence below 24 fresh fps, source loss above
  one percent, mean live queue occupancy at least 75%, inadequate capacity headroom,
  or elevated thermal/worker pressure requests a decrease.
- Capacity headroom is 1.25 times the video bitrate. Decreases target 20% or the
  capacity-limited rate, clamped to the current profile minimum. At that minimum,
  the policy can recommend the next lower profile. Overlapping bitrate ranges never
  cause a decrease recommendation to raise the current bitrate.
- A failing minimum profile is explicitly insufficient. A zero measured frame rate
  is stalled; disconnected and unknown states remain distinct. Known bad signals
  can recommend a decrease even when missing evidence keeps overall state unknown.
- An increase needs 30 contiguous seconds of fully qualified windows: all measured
  fresh cadences at least 29.7 fps, queue occupancy below 50%, nominal pressure,
  source loss at most one percent, and capacity headroom for the proposed new rate
  in every window. Increases target 10%, capped at the profile maximum, then the next
  higher profile's minimum. Outages, gaps, unknown/bad evidence, and acknowledgments
  reset recovery history.

These are initial control thresholds for later impairment qualification, not measured
limits for arbitrary iPhones, networks, or streaming destinations. The rolling
five-second reliability gate in the parent plan remains a separate media analysis.

## Recommendation acknowledgment

Every new accepted window supersedes earlier advice. A recommendation carries the
attempt, window sequence, applied revision, settings, and a deadline two seconds
after the evidence window ends. `evaluate` never changes actual applied settings.

The caller must serialize live reconfiguration and acknowledge actual supported
settings, including platform clamping, while the recommendation is current. Success
increments the applied revision and excludes windows from before the application
time. Passing nil records a failed change without inventing applied settings. Stale,
expired, cross-attempt, or reversed-time acknowledgments fail; a failed/stale call
cannot resurrect an old proposed increase. A late external encoder change requires
caller reconciliation rather than pretending a rejected acknowledgment applied.

## Verification and next work

Twenty focused policy tests plus the existing Core suite pass (88 total).
Behavioral red evidence includes an initial compiled stub and the two subsequently
reproduced review cases: overlapping-profile bitrate increase and expired advice.
Further regressions cover clock reversal after rejected input and extreme valid
bitrate bounds. Increases clamp in floating-point before integer conversion, so
the calculation cannot exceed the 32-bit Watch integer range before its cap.
Root rerun evidence is `artifacts/qa/adaptive-policy-core-final.log`; shared Core
compilation for arm64_32 watchOS 10 passes (`adaptive-policy-watchos10-final.log`).
The unsigned iPhone Release build also passes with the new Core source included
(`adaptive-policy-release-iphone.log`). These are build checks, not device runtime
qualification; the 32-bit overflow correction was established by target integer
width, conversion ordering, and bounds tests rather than a physical Watch crash.
Independent specification and code-quality reviews approve the final source.

Next implement and qualify the [runtime telemetry contract](adaptive-telemetry.md),
then apply live bitrate changes, validate resolution/keyframe transitions and
stable destination canvas behavior, and run bidirectional UDP impairment and soak
tests. The [implementation plan](superpowers/plans/2026-09-14-adaptive-quality-policy.md)
keeps these separate from the completed pure decision logic.

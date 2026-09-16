# Pure adaptive quality policy

`ScorebugCore.QualityController` computes live-video recommendations from complete
telemetry windows. It has no media/framework dependencies, tasks, network access,
encoder mutation, or archive references. Its default recovery strategy remains
`capacityQualified`; the optional `receiverValidatedTrials` strategy adds explicitly
provisional same-profile bitrate exploration when capacity is unknown. The native app still uses the qualified
fixed 1080p30 profile; this policy is not enabled in the capture/publishing path.

## Inputs and state

Construct one value-type controller for each publishing attempt with an explicit
UUID, monotonic start time, actual applied settings, and a low-to-high ladder of
caller-qualified profiles. Profiles have unique simple identifiers, positive even
dimensions, 30 fps targets, and bounded positive video bitrate ranges. Dimensions
and minimum/maximum bitrate cannot decrease along the ladder. The policy does not
establish whether those profiles are supported by a particular device or worker.

Each window identifies the attempt, sequence, applied revision, and a complete
1–5.25-second monotonic interval. It separately carries capture/encoded/received fresh
frames, receiver observation time, source-loss counts, mean live queue occupancy,
usable video capacity, connectivity, and thermal/worker/transport pressure. Capacity is video
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

## Receiver-validated trial strategy

Real impairment traces show that SRT bandwidth estimates can substantially exceed
our known path ceilings. The revised [trial plan](superpowers/plans/2026-09-15-receiver-validated-quality-trials.md)
therefore permits bounded experiments instead of turning passive estimates into
usable capacity. This strategy is explicit and remains disabled in runtime media.

Trial acquisition needs 30 contiguous seconds of matched fresh capture/encoder/receiver
cadence at least 29.7 fps, source loss at most 1%, mean queue occupancy below 50%, connected
state, and nominal thermal, worker and transport pressure. Missing transport pressure
is explicit and prevents trials. Unknown capacity alone may permit a trial, while the
decision continues to report missing capacity and unknown overall status. Known
insufficient candidate capacity still prevents the trial. Explicitly elevated
transport pressure can request a decrease under either strategy; unknown transport
pressure preserves legacy capacity-qualified behavior.

A recommendation is labeled `trial`, with a `trialRecommended` reason. It advances
bitrate by floor(current/10), capped by remaining profile headroom before addition.
This cannot exceed 10%, overflow a 32-bit Watch integer, or force a disproportionate
one-bit step at tiny rates. It never changes resolution. Successful exact-setting
acknowledgment starts probation; it does not confirm a sustainable higher rate.

Probation requires 10 contiguous post-application seconds of the same strong receiver
and pressure evidence, before a fixed 15-second deadline. A first complete window may
start after application; subsequent gaps invalidate probation. Bad/unknown evidence,
disconnection, invalid window input or invalid deadline-poll time makes rollback
mandatory. Confirmation reports `trialConfirmed` but never claims spare capacity.
A confirmed trial starts a fresh 30-second recovery period before another experiment.

`checkTrialDeadline(at:)` must run from the existing bounded health loop even when
receiver updates stop arriving. It returns rollback advice on timeout or an already
invalidated trial, and reissues expired advice with a new two-second deadline.
Old advice cannot be acknowledged after replacement. Rollback targets the pretrial
settings; it does not prove those settings will remain adequate after a path change.
Failures keep rollback required. Successful exact rollback increments the applied
revision and prevents another trial for 60 seconds; normal decreases remain available.

Unexpected trial/rollback settings are rejected. If hardware changed despite a
rejected acknowledgment, the caller must retire or reconcile that publishing attempt.
It must serialize live reconfiguration and impose bounded application/stop behavior.
Trial state never changes archive settings. Disconnection/stall states stay explicit
alongside rollback recommendations. Profile transitions, runtime telemetry alignment,
runtime use of verified submission boundaries and impaired-media trial qualification
remain required before enabling this strategy in the native app.

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

The trial-policy checkpoint passes all 269 Core tests, including 15 focused trial
regressions, the arm64_32 watchOS 10 Core build, and the combined unsigned iPhone/Watch
Release build. Independent review approved after fixing invalid deadline-clock
rollback behavior. Behavioral red logs also cover integer rounding, required transport
pressure and explicit outage/stall states. These are policy/build checks, not physical
Watch or adaptive live-media qualification. Final evidence hashes are in
`artifacts/qa/quality-trials-final-verification.json`.

The [encoder configuration boundary contract](encoder-configuration-boundaries.md)
adds immutable per-submission configuration/session identity and a verified write
receipt naming the last previously submitted source PTS. It preserves delayed
callback history; it does not measure instantaneous rate convergence. Runtime
policy acknowledgment still needs to bind those identities to complete source and
pressure windows before automatic bitrate trials can be enabled.

Matched receiver source intervals now expose actual native configuration coverage
through the existing bounded source history. The controller integration can reject
mixed or unavailable intervals instead of assigning them the current bitrate merely
because their reports arrived later. Initial unchecked settings remain unverified;
verified startup/application acknowledgment and pressure-window alignment are still
needed before runtime control is enabled.

## Verified application owner

The opt-in app-layer `PublishingQualitySession` now binds policy state to
PublishingSession's verified native receipts. The caller supplies qualified profiles
and invokes bootstrap after an encoder exists. A successful verified initial write
establishes policy revision zero. A recommendation remains unapplied until a matching
native write returns within its deadline; acknowledgment uses current uptime, not
the receipt's earlier acceptance time. Each revision retains its corresponding
configuration receipt. Settings remain historical after terminal stop.

Only the latest advice for the same attempt and revision can dispatch. Profile
changes are rejected because this path verifies bitrate only. Evaluation/deadline
polling cannot mutate policy during a suspended application. Cancellation, terminal
stop, expired completion or contradictory receipt prevents a late acknowledgment;
dispatched failures retire live publishing independently of recording. Concurrent
stop callers join one shielded shutdown task. The production initializer delegates
native mutation deadlines and task ownership to PublishingSession.

`QualityController.invalidateTelemetry()` supports evidence rejected before a policy
window can be formed. It clears recovery and pending advice and makes active trial
rollback sticky, while preserving actual settings, applied revision and clock/order
watermarks. This also prevents an invalid outer clock from bypassing policy evidence
invalidation. It invents neither a window nor a new time value.

This owner is compiled into the app but CaptureStreamingModel does not start it yet.
Tests use deterministic application receipts and include one real PublishingSession
integration with a controlled publisher. They do not qualify actual automatic media
trials, native startup timing or aligned telemetry. Source/queue/transport/pressure
alignment and receiver freshness must be connected before enabling the runtime path.

## Measured input duration allowance

`maximumWindowDuration` is 5.25 seconds. Real 150-frame source spans have measured
5.000622 and 5.001985 seconds, so strict five-second rejection discarded otherwise
usable inputs. The 250 ms ingestion allowance is bounded by the existing native
fixture producer-lag budget; it is not a claim about all phone timing or a relaxation
of the separate rolling-five-second output gate. Endpoints are never clipped.

Every frame-rate and recovery/confirmation calculation still uses measured elapsed
time. At 5.25 seconds, 150 frames measure only 28.57 fps and cannot satisfy the 29.7
fps recovery threshold; 125 frames measure below 24 fps and trigger reduction. Input
freshness, ordering, revision checks, source loss, 30-second recovery, 10-second
confirmation and trial deadlines are unchanged. Jittered consecutive windows are
tested through both recommendation and confirmation using their actual timestamps.

## Bound telemetry evaluation

The app-layer `PublishingQualityTelemetry` adapter now forms policy windows from a
matched native/worker source interval, current PublishingSession diagnostics and the
quality owner's verified receipt. Uniform encoder coverage must match the receipt's
configuration and native generation; interval start must follow actual policy
acknowledgment. The fixed observation scope's profile revision is not relabeled as a
policy revision. Mixed, old or missing configurations stay unavailable.

The exact capture endpoints determine duration, frame cadence and queue integration.
Capture-to-worker source loss includes native encoder and ingress losses; worker
output omissions remain separate pressure evidence. Both source-end age and the
original conservative decoder age must be at most two seconds. Receiver observation
time uses the age-derived earliest completion, tightened only by the causal fact
that the matched frame was captured before being decoded. Uptime is sampled before
the continuous clock so time spent obtaining a clock reading cannot freshen evidence.

Current, bracketed thermal and same-generation transport histories contribute pressure.
Thermal nominal maps nominal, fair stays unknown, and serious/critical map elevated.
Worker/backend timing limits and transport buffer/RTT/retransmission limits must be
explicitly supplied by a caller that has qualified them. There are no production
defaults. Missing/unknown timing, wrong backend, pending completion, empty transmission
intervals, stale/closed/gapped/quarantined diagnostics cannot establish nominal load.
Known omissions, excessive valid measurements or packet drops can establish elevated
pressure. No send rate or estimated bandwidth becomes usable video capacity.

`PublishingQualitySession.evaluate(source:diagnostics:...)` binds these observations
inside the actor without suspension. It uses the actual applied receipt/revision and
acknowledgment uptime, then evaluates the policy. Invalid outer telemetry revokes
advice and makes trial rollback sticky. Policy ordinals are independent of decoder
sequences: restarted workers can repeat decoder sequence numbers, but a change in
worker epoch/attempt/publication/processing scope resets recovery and requires rollback
during a trial. Duplicate same-scope intervals reject rather than minting new evidence.
The caller must coalesce repeated reports and may wait for processing completion
within the original freshness budget before evaluation.

Seventeen adapter/owner regressions pass within the 158-test FilmModel suite. Real
bounded source histories and trackers form the inputs, including a 30-second trial
qualification followed by accepted worker-change rollback. These are deterministic
logic tests, not actual native adaptive-media qualification. The capture model still
does not construct the owner. Runtime bootstrap/coalescing/deadline polling and real
bitrate trial/rollback under impairment remain required. See the
[binding plan](superpowers/plans/2026-09-16-quality-telemetry-binding.md).

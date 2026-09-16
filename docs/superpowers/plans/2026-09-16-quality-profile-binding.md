# Quality-controller native profile binding

> Implement inline using the existing executing-plans and test-first workflow.
> This continues the authorized portable streaming plan; it does not activate
> automatic selection in the app.

**Goal:** Allow an already qualified quality recommendation to change the native
live profile without acknowledging settings that the replacement encoder has not
accepted. Capture and the clean local archive remain independent.

**Design:** Use the existing PublishingSession profile API followed by its verified
bitrate API, within one quality-owner admission and one shared two-second deadline.
Only the native profile IDs with matching dimensions and 30fps are supported.
An absent profile operation or unsupported descriptor rejects before dispatch.
Validate the format receipt, then bind the bitrate receipt to that exact new encoder,
generation, and source boundary. Commit both historical receipts and one policy
revision together after both operations succeed. Stop, cancellation, expiry or a
malformed receipt after dispatch retires the live attempt without advancing policy.

This is preferable to treating the profile's default bitrate as verified settings,
or acknowledging resolution and bitrate separately: either would expose an
intermediate revision to telemetry. Existing same-profile behavior is preserved.
The lower PublishingSession owns native operation lifetime and joined shutdown;
the quality owner prevents concurrent policy evaluation or another mutation.

## Work and validation

- [x] Add failing app-model tests for a real quality decrease from 1080 to 540,
  one combined deadline, atomic revision and exact new-encoder bitrate binding.
- [x] Cover unsupported descriptors before dispatch, invalid format and bitrate
  receipts, expiry between operations, and stop/cancellation during either write.
- [x] Add the optional profile operation and production PublishingSession binding.
  Retain the last committed format receipt in the snapshot for later diagnostics.
- [x] Run the focused tests, then all FilmModel tests and unsigned Apple Release
  build sequentially. Review receipt causality and admission/shutdown behavior.
- [x] Record the completed iOS 26.2 controlled-transition result separately from
  this unit-tested policy binding; hash terminal evidence and commit.

## Subsequent recovery gates

The prior controlled transition test now passes on iOS 17.5 and 26.2. The original
rate4m test still has no qualifying adaptive recovery result. Its rate schedule
starts at the first publisher UDP packet; the app's transition schedule starts
after publishing setup. Do not subtract those unrelated clock origins or label a
prearranged downshift as congestion detection.

Next extend the explicitly selected simulator quality fixture to qualified native
profiles, collect actual format/session evidence alongside quality decisions, and
run genuine local-pressure downshift through the existing 60s/120s rate schedule.
Choose recovery trials and settling criteria from measured output, not from the
requested bitrate (1080p bitrate-only writes did not constrain this fixture).
Correlate proxy phases with native decisions using bounded causal clock evidence
if phase latency is claimed. Continue requiring decoded source continuity, at
least 24fps sustained coverage, A/V sync, worker health, and normally finalized
independent full-resolution recording. Keep failed media and unchanged gates.
Production activation, long soaks, physical phone/Watch and other-host tests remain
separate qualifications.

## Binding checkpoint

The quality owner now supports typed 1080p30/540p30 changes when the descriptor
matches native dimensions. It validates profile identity, generation, acknowledgment
time, source ordering and known retired encoder history before dispatching the
follow-up bitrate write. That write must postdate the first operation and name its
exact replacement encoder and a source boundary at or beyond the first new frame.
One deadline bounds both operations; policy and both historical receipts become
visible together after success. Missing capabilities and unsupported descriptors
reject before native dispatch. The production initializer routes both writes through
PublishingSession; the existing simulator quality fixture still has one profile.

Retained red logs first show the missing API and then the expected unsupported-profile
behavior. The initial focused run caught a test setup using 24fps, which the core
already rejects at initialization; the corrected test checks that rejection and
uses valid 30fps descriptors with mismatched dimensions for admission checks.
Seven added tests cover valid decrease, shared deadline, missing capability,
descriptor rejection, malformed format/bitrate receipt variants, expiry, atomic
state during suspended writes, cancellation/stop at either stage, and the real
PublishingSession adapter with a deterministic publisher. All 198 app-model tests
pass. Read-only review found no blocking issues. Repeated down/up profile changes
after intervening bitrate adjustments and attempted reuse of a retired encoder
remain useful coverage for the next multi-profile recovery fixture.

The unsigned combined iPhone/Watch Release build also passes with Xcode 26.2.
All parent-owned tests, simulator/worker/recorder processes and cleanup were joined
before hashing evidence in `artifacts/qa/quality-profile-final-verification.json`.
The simulator result was generated before this policy-only change at `3d0a478`;
the new binding is covered by the app-model suite and Release build, and is not
represented as a native congestion/recovery pass. No worker, SDK or package sources
changed in this checkpoint.

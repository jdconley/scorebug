# Receiver-validated quality trials implementation plan

> **For agentic workers:** Execute inline with test-driven steps and bounded independent
> review. Parent owns all Swift, native/media and build execution.

**Goal:** Let the pure quality policy explore a higher live bitrate under bounded
probation and explicit rollback when passive capacity is unknown, without declaring
that unknown capacity healthy or changing archive behavior.

**Architecture:** Add an explicit `RecoveryStrategy.receiverValidatedTrials` option
to the existing controller. Keep `capacityQualified` as the default for compatibility.
Trial mode uses the same validation and bad-signal decreases, with an explicit
recommendation kind and a small value-type trial lifecycle. No runtime enablement yet.

**Tech stack:** Shared Foundation-only Swift policy, fake-time XCTest, arm64_32 watch
compilation, and combined unsigned iPhone/Watch Release build.

## Why the plan changes

Actual bounded proxy traces invalidate using SRT's passive estimate as spare video
capacity. On a 12 Mbps capped recoverable path, estimates exceed 600 Mbps; on a 3 Mbps
path they rise above 900 Mbps after the video rate drops. SRT derives this estimate
from receiver packet-pair arrival spacing, not a sustained offered-load experiment:
https://github.com/Haivision/srt/blob/v1.5.4/docs/API/statistics.md#mbpsbandwidth

Keeping unknown capacity as an absolute bar to every upward experiment prevents
finding the highest sustainable quality. Treat upward experiments as trials, with
measured receiver confirmation and rollback, rather than inventing capacity. Existing
capacity-qualified behavior remains available when independently qualified capacity
exists. Sender estimates and send throughput still cannot populate that field.

## Contract

- New initializer parameter `recoveryStrategy: RecoveryStrategy = .capacityQualified`.
- Recommendation `kind`: decrease, increase, trial, rollback. A recommendation is
  still not applied truth. Add probing state and trialRecommended/trialConfirmed/
  trialRollback/trialTimedOut reasons; missing capacity remains explicit.
- Trial mode requires 30 contiguous seconds of fresh, matched capture/encoder/receiver
  cadence >=29.7fps, source loss <=1%, mean queue <50%, connected state, and nominal
  thermal/worker/transport pressure. Unknown capacity alone may permit a trial; other unknowns
  cannot. Known inadequate capacity still blocks or decreases.
- A trial increases bitrate by at most 10% within the current qualified profile.
  Resolution transitions remain separate qualification work. Never jump profiles in
  this initial trial mode. The integer increment is floor(current / 10), capped by remaining profile headroom
  before addition for watchOS32. Tiny rates cannot force a +1 above 10%.
- A successful exact-setting trial acknowledgment starts probation, retains the prior
  settings and sets a deadline 15s later. A failed application does not start probation.
  Unexpected/clamped trial or rollback settings are rejected; callers must retire or
  reconcile an externally changed encoder rather than trusting old policy state.
- Confirmation requires 10 contiguous post-application seconds meeting the stronger
  cadence/queue/loss/pressure conditions. First complete post-application evidence may
  start after the acknowledgment, but must fit before the fixed deadline. Later gaps,
  bad/unknown evidence, disconnection, invalid input or timeout require rollback.
  Capacity may remain unknown; successful probation proves observed operation only,
  not future headroom or sustainable capacity under changed conditions.
- Trial windows additionally carry `transportPressure: Pressure = .unknown`; trial
  mode requires nominal transport pressure. The legacy strategy preserves behavior
  for unknown transport pressure, while explicitly elevated pressure requests decrease.
- While probing, no other upward recommendation is possible. A required rollback is
  sticky and always targets the pretrial settings. A failed rollback acknowledgment
  retains that requirement. A successful exact rollback increments applied revision,
  closes probation, and inhibits another trial for 60s. Ongoing bad conditions can
  still request further decreases after rollback.
- `checkTrialDeadline(at:) throws -> Recommendation?` advances the monotonic watermark
  and can issue/reissue rollback advice even when receiver windows stop arriving.
  Advice expires after2s; each reissue supersedes old advice. Integrators must call
  this from their existing bounded health loop and serialize rollback application.
- Invalid windows while a trial is active mark rollback required before throwing.
  A later valid call cannot rehabilitate that trial. Reversed/nonfinite caller times
  retain the existing clock rules; valid later calls recover only via rollback.
- Stop/replacement creates a new controller; no trial can cross attempts/revisions.
  All mutations remain pure recommendations; archive and encoder code stay untouched.

## Tasks

Files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`,
new `ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/QualityTrialTests.swift`,
existing policy tests and documentation.

- [x] Add fake-time tests and compile interface stubs. Verify failures before behavior.
  Cover 30s prerequisite, explicit unknown-capacity trial, no trial with any other
  missing/stale/bad input, maximum10% step, no resolution jump, exact acknowledgment,
  10s confirmation, wrong revision/attempt, gaps, deadline, no-window rollback polling,
  failed rollback retry,60s cooldown, and invalid input sticky rollback.
- [x] Implement strategy selection and recommendation kind without changing existing
  capacity-qualified decisions. Implement the small probation state and deadline API;
  validate exact trial/rollback acknowledgments before mutating applied truth.
- [x] Run all Core tests. Independently review state-machine transitions, deadlines,
  evidence freshness, rollback priority and integer limits. Add regressions for any
  reproduced review issue.
- [x] Compile shared Core for arm64_32 watchOS 10 and run the combined unsigned
  iPhone/Watch Release build. Keep model compatibility and legacy policy tests green.
- [x] Update adaptive-policy/telemetry and parent milestone plan: unknown capacity
  blocks confirmed capacity-based increases but can permit explicitly provisional
  receiver-validated trials. Record evidence/hashes and commit.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:
`swift test --package-path ios/Packages/ScorebugCore`, and
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

## Runtime continuation

This pure policy is not automatic adaptive delivery. Wire it only after actual
applied-frame boundaries, source/transport/queue/thermal/worker policy-window alignment,
and joined reconfiguration/rollback lifecycle are qualified. Then exercise bitrate
trials in the real impaired native path, include transients in measurements, and
qualify resolution/canvas transitions and sustained motion/thermal/radio behavior.
The remaining portable streaming and native Watch requirements stay unchanged.

## Verified checkpoint

All269 Core tests pass, including 15 new trial tests and the existing capacity-qualified
policy cases. The arm64_32 watchOS 10 Core compile and unsigned combined iPhone/Watch
Release build pass. Tests began with a compiled behavioral stub (12 tests, 11 failures).
Further executable red regressions preceded fixes for floor rounding, missing/bad
transport pressure, invalid deadline-clock sticky rollback, and explicit disconnected/
stalled state during rollback.

Independent source review approved after the deadline-clock mismatch was fixed and
covered before timeout. Trial recommendations use `trialRecommended` to avoid claiming
an encoder changed before acknowledgment. Runtime publishing, archive, SDK and worker
code are unchanged. Final source/evidence hashes are recorded in
`artifacts/qa/quality-trials-final-verification.json`.

Next: actual accepted-setting/first-affected-frame boundaries and policy-window
alignment, then controlled native bitrate trials under step-down/outage/recovery
impairment. This is not adaptive streaming acceptance or completion of the broader
iPhone/Watch and portable host plan.

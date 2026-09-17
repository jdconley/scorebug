# Progressive minimum-reset policy implementation plan

**Goal:** Implement the approved progressive reset/recovery state machine in the pure
controller, preserving native acknowledgment and telemetry ownership.

**Architecture:** Add explicit `.progressive` behavior to the existing controller;
legacy diagnostic callers remain unchanged until actual timing and transition
qualification permits activation. Keep product thresholds together in
`ProgressiveStreamingPolicy.swift`. Controller-owned reset intent outranks trial
rollback, survives missing telemetry and failed/expired native applications, and
is discharged only by an exact minimum acknowledgment (or already-known minimum
when no upward native application was in flight). Repeated samples in one failure
episode do not inflate backoff. A new upward application opens a new episode;
confirmed trial probation clears the backoff.

This slice consumes existing scoped `Window` contracts. It does not convert raw
arrival-cadence snapshots into on-time source delivery. Complete source windows of
at least two seconds can trigger the >5% missing/late reset; shorter loss samples
cannot. The existing independently supplied fresh-frame counts can reset below
24 fps over at least one second. Short watchdog admission and native measurement
integration remain separate gates. Pressure without a frame failure retains prompt
downward reduction; failure during a progressive trial resets to minimum.

Files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`,
new sibling `ProgressiveStreamingPolicy.swift`, new
`ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/ProgressiveQualityTests.swift`.

- [x] Write/run failing behavior tests for four-second recovery, 3/60 vs 4/60,
      24 vs 23 fps, direct minimum and unchanged-minimum handling.
- [x] Implement explicit behavior and named settings, preserving legacy callers.
- [x] Write/run failing lifecycle tests for trial/timeout/unknown reset precedence,
      failed/expired/clamped application, revoked upward application, reissued
      reset ownership, and continuous 10/20/40/60-second healthy holds.
- [x] Implement latched reset and bounded recovery episodes; confirmed trial clears
      history, missing/gapped evidence clears healthy accumulation only.
- [x] Thread explicit behavior through `PublishingQualitySession` and test native
      reset profile/bitrate receipt ownership, post-completion hold, and retirement
      of failed native resets in `PublishingQualitySessionTests.swift`.
- [x] Run full Swift Core suite, ARM64 simulator build-for-testing, and unsigned
      iPhone/Watch Release build. Review changed branches and freeze logs/hashes.
- [x] Record exact verified scope in this plan and the main plan; commit locally.

Run Swift checks with
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugCore`.
Run Apple builds sequentially using `ios/Scorebug.xcodeproj`, scheme `Scorebug`,
`CODE_SIGNING_ALLOWED=NO`; simulator Debug uses `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
and `ios/DerivedData/App`. No external streaming or device qualification is claimed.

## Verified outcome

The controller and native quality-session adapter accept explicit `.progressive`
behavior. Complete source-loss windows of at least two seconds reset at >5%; one
second or longer fresh-frame evidence resets below 24 fps. Tests distinguish 3/60
from 4/60 and 24 from 23, and reject using a shorter loss fraction either as a reset
trigger or as healthy recovery. Healthy recovery additionally retains the stricter
1% source-loss ceiling and 29.7 fps threshold. Local pressure can still reduce load
without claiming delivery failure. These counts remain adapter-supplied qualified
source evidence, not raw decoder arrival counts.

Minimum-reset intent supersedes a higher trial baseline, persists across healthy,
unknown and invalid reports, and can be reissued by the bounded health loop without
new frames. Failed, late, clamped and revoked reset applications cannot clear it.
Polling does not revoke an admitted operation merely because its original advice
expired. Revoked/expired upward operations force an exact minimum write even if the
last known applied settings were minimum, because hardware may have changed.
Already-known minimum with no uncertain upward write does not recreate the encoder.

Recovery requires four continuous healthy seconds before an initial/later increase,
or 10/20/40/60 seconds after failure. Repeated observations and reset-write retries
are one failure episode; each new upward native attempt opens another. Ten seconds
of confirmed trial probation clears the failure history. Every progressive increase,
including the capacity-qualified strategy, uses trial probation; bitrate increments
round down so they never exceed 10%. Profile-cost/headroom qualification remains a
caller responsibility and is not established by these policy tests.

Native binding tests verify the exact 1080p -> 240p request, encoder identity plus
bitrate receipt, shared execution deadline, post-completion recovery hold, and
retirement of the publishing attempt on bad/expired native receipts. Those tests use
controlled native-operation receipts; they do not prove a real media transition.
The existing native actor serializes operations and joins stop on receipt failure.
A retired connection still needs the upcoming actual minimum-profile reconnect path.

Verification: 342 Swift Core tests and 235 native model tests pass. Both ARM64
simulator build-for-testing and unsigned combined iPhone/Watch Release build pass.
Expected failing tests were observed before implementing each behavior and binding.
Runtime source inventory contains 751 paths; final source/evidence hashes and joined
parent statuses are in `artifacts/qa/progressive-reset-final-verification.json`.

Remaining: source-identity/deadline reconciliation and short-report reaction-time
qualification; standalone qualified delivery-watchdog admission; actual minimum
startup before the first encoded frame; fresh candidate cost and headroom; real
impaired-network adaptive transitions with intact archive proof. Existing callers
retain the legacy default until these activation gates are satisfied. No new
physical phone/Watch, radio, live SRT or remote-worker qualification is claimed.

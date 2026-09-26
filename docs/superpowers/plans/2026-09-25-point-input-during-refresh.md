# Reliable point input during background refresh

> Use superpowers:subagent-driven-development with specification then quality review. Implementation and verification are authorized by the user's ongoing vertical-delivery request.

**Goal:** A normal background score refresh must not disable or silently discard an otherwise valid HOME/AWAY point tap. Preserve one-command persistence, authority checks and confirmed/destructive action behavior.

**Current status:** The point-specific reservation/refresh join is implemented. Held-refresh and restored-receipt regressions were reproduced and fixed;24scoring and48relatedCoretests pass. Independent specification and quality reviews approve the final slice. DebugUI and Releasearm64builds pass; fresh native single-tap scoring and export pass, but the overall run fails adaptive and one live audio-correlation check. Those separate failures remain open. This fixes a controlled input-suppression case; it does not prove the cause of the earlier missed native point.

## Design

Keep generic `canScore`/`send` behavior for undo, set/match completion and takeover. Add point-specific eligibility/dispatch. Permit a point during an already-running background refresh only when the last installed snapshot is active and owned, the coordinator and committed scope are valid, and both published and durable pending state are empty. Otherwise preserve current rejection/disable behavior.

Reserve exactly one point slot on MainActor before the first suspension. Disable further point input and block other foreground mutations while it is reserved. Join the exact owned refresh task; no additional polling request, unbounded action queue, Core coordinator change or cancellation of the shared refresh. Keep reservation ownership distinct from refresh busy ownership so completing refresh cannot unlock a waiting point prematurely. A pending-free refresh uses the existing single GET with20second request/resource timeout; do not extend transport deadlines.

Capture coordinator identity, connection identity/committed credential/scope, match ID/revision and scorer device/epoch. After refresh and state installation complete, revalidate the same context, active/owned status, nil pending state and caller cancellation. An unchanged successful refresh permits exactly one call through the existing durable coordinator. Any failure/context change/cancellation sends no command and gives clear feedback; never silently rebase a tap to a different revision or claim an unpersisted waiting intent is saved. Cancellation may abandon the point after joining refresh, but must not cancel that shared refresh. A newer second-tap feedback message must not be silently replaced by an old receipt.

Use this point route for both HOME and AWAY buttons. Existing confirmed end-match-during-refresh rejection tests remain valid. No automatic UI retap, archive/streaming change, or new Watch behavior in this slice; paired Watch reliability remains a later qualification.

## Tasks

- [x] Add a failing held-refresh point regression that establishes eligibility, reserves one point, sends nothing before release and sends/persists exactly one command afterward. Preserve red evidence.
- [x] Implement the point-specific single reservation and exact refresh join with scoped revalidation, cancellation, explicit feedback and cleanup.
- [x] Cover second tap/foreground exclusion, changed revision/authority/status/scope, refresh failure, cancellation, pre-existing pending, and lost-response receipt recovery using the same durable command UUID. Keep generic confirmation tests passing.
- [x] Run relevant scoring/Core suites and app Debug/Release builds. Resolve independent specification and quality reviews before committing.
- [ ] Run the ordinary native vertical with one score tap and unchanged progressive/media gates; preserve failures and verify outputs. Qualify a deliberate held-refresh UI path if the model-to-button wiring cannot otherwise be demonstrated.

Unit tests prove the controlled refresh race, not the cause of an earlier unreproduced live event. Native and paired-device acceptance remain separately tracked in the delivery plan.

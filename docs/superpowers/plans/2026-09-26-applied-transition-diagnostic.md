# Applied quality transition diagnostic

**Goal:** Identify the actual cause of the ordinary recovery rollback without changing policy, timing, network impairment, or acceptance gates.

**Evidence:** The first ordinary recovery run confirms the initial increase and constrained fallback, then acknowledges a second increase followed by a rollback after 9.001 seconds. Current sampled event strings are not causally joined to that rollback. Full decoded frame/audio timestamp checks and the independent transport audit pass; recovery does not.

**Design:** Retain one bounded DEBUG-only applied-transition witness at the session that owns policy and native acknowledgments. Associate recommendation identity/from-revision, decision or telemetry-invalidation cause, relevant evaluated input interval and pressure scalars with the resulting native acknowledgment. Pending, rejected, stale, cancelled, and failed applications must never appear acknowledged. Later sampled events cannot overwrite the acknowledged transition's cause. No diagnostic awaits may be inserted into native admission or change scheduling. Clear retained state on session closure. Preserve the existing 4096-byte current-diagnostic bound and all fields required by native recovery qualification; compact obsolete historical diagnostic fields if necessary.

**Current status:** Implemented and reviewed at `1254e2d`. The instrumented ordinary recovery run passes independent native/transport checks and three-output media checks. The earlier rollback did not recur, so its exact cause and repeatability remain open.

## Tasks

- [x] Add behavioral regressions for causal association, invalidation-triggered rollback, successful native acknowledgment, rejected/stale application, later-event overwrite, closure, and populated diagnostic size.
- [x] Implement the bounded diagnostic in the existing session/driver interfaces. Keep policy decisions and timing identical in Debug and Release.
- [x] Run focused tests and Debug/Release builds; retain exact commands and source/log hashes.
- [x] Complete independent specification and code-quality reviews before committing.
- [x] Execute one new ordinary recovery run with the unchanged 750 kbps cap, production timing and finite source; join capture before media analysis.
- [ ] Use the new evidence to identify the trigger. Qualify transport, native recovery and all three media outputs separately; retain failures.

Session chronology and artifact paths belong in [the session log](../../session-logs/2026-09-26-ordinary-recovery.md).

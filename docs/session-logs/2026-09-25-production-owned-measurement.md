# Production owned measurement — September 25

## Starting point

Authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, starts atea0a3e5. Previous goal turn made progress: continuous delivery consumer60fb8bb reviewed,89focused/630full tests and arm64simulator build pass. No active root process or review carried over. The full goal remains active; ordinary camera adaptation is still disabled.

## Current work

Execute [production owned measurement](../superpowers/plans/2026-09-25-production-owned-measurement.md): Release-available candidate lifecycle, explicit bounded runtime configuration, repeated joined attempts independent of laboratory audit caps. Preserve all existing diagnostic evidence and fail-closed laboratory limits. Root independently researches the production transport-cost boundary while the implementer works; no new hardware run or unchanged native replay.

## Transport accounting research

[Source research](../research/2026-09-25-srt-transport-cost.md) verifies SRT1.5.4 statistics add a fixed44bytes per data packet, including on IPv6. Local tests against the bundled library confirm it for both loopback families:12messages,7520payload bytes,8048reported unique bytes, all received. Root process62012 joined0. Artifacts `artifacts/qa/srt-ip-accounting-20260925/` retain source/binary/library hashes and raw results. This validates counter semantics only; no wire capture or production/media qualification.

The production cost design will distinguish an explicit base-header estimate from unknown outer-link overhead and preserve measured candidate packetization, delivered same-path padding and pressure/media feedback. No runtime cost change made in this slice.

Plan clarification: native staged probes permit up to12Mbps even at stage1;2Mbps applies only to un-staged probes. The runtime stage validator should follow that actual bound rather than impose a mistaken initial2Mbps limit. Original lab rates remain unchanged.

## Implementation and checks

Implementation commit `db429947e8dd6f41f23ab1b090e85a496ecba532` promotes owned candidate lifecycle, neutral snapshot/pressure values and session/driver lifecycle branches into Release. Continuous construction requires a validated stage plan and has no lifetime attempt cap or audit history. Lab construction keeps its16attempt/4096event limits, ladder and schema. Final-stage settling remains at least0.5s to match admission's existing contract; native staged rates remain capped at12Mbps.

- Regression first: attempts17/18 failed under the original lifetime cap. Continuous mode now passes18 settled failures/retries through actual session policy with fresh healthy holds; weak references verify at most one retained native operation.
- Laboratory exhaustion still stops after16attempts with complete registered/settled audit. Held native cleanup prevents a successor, including after otherwise sufficient healthy telemetry; a fresh post-settlement hold is required.
- Custom800kbps→3Mbps plan binds immutable stage2. Temporarily restoring the old stage3 check made that regression fail. Final holds0/.499 also fail validation; lab defaults remain unchanged.
- Focused89tests pass in98.58s; fullFilmModel635tests pass in186.89s. Actual arm64 iOS simulator Release app build passes with DEBUG absent. All processes joined. Logs copied from `/tmp` into `artifacts/qa/production-owned-measurement-20260925/`, with hashes.
- Both independent reviews approve `af6fb24..db429947`. Specification review independently passes four focused retry/lab-cap/held-cleanup/plan tests. Quality review inspects the seven-file diff and surrounding joins, verifies all11 durable log hashes and test/build results; no redundant full rerun. `git diff --check` passes. Release runtime behavior on a physical device remains unqualified.

## Next work

Execute [production probe sizing and transport estimate](../superpowers/plans/2026-09-25-production-probe-cost.md), then wire ordinary camera publishing to continuous delivery feedback, candidate AAC observation and selected backend limits. Keep the residual audio discontinuity and incomplete lab audit separate from this component pass. The full end-to-end goal remains active; no new phone/Watch result is claimed.

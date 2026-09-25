# September 25 checkpoint: Guarded publisher adapter propagation

**Imported history, not a reconstructed whole session.** Extracted during plan cleanup from [guarded admission](../superpowers/plans/2026-09-25-owned-application-admission.md#media-and-publisher-adapter-checkpoint) at `b65ca7fe1d58be9ac27e88a63c67867d428f1b10`. Original session boundaries/times are unknown. Implementation commit: `8947c0f`. Results below describe that checkpoint, not a new verification run. Repository-relative artifact paths are rooted at the checkout; ignored artifacts may exist only in the original workspace.

## Recorded commands and results

- `artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-focused-20260925-exit.json`: `["swift", "test", "--package-path", "vendor/HaishinKit", "--no-parallel", "--filter", "SRTVideoReplacementTests"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-full-20260925-exit.json`: `["swift", "test", "--package-path", "vendor/HaishinKit", "--no-parallel"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-red-20260925-exit.json`: `["swift", "test", "--package-path", "vendor/HaishinKit", "--no-parallel", "--filter", "SRTVideoReplacementTests.readOnlyMutationPreflight"]`; exit `1`, joined `True`.

## Decisions, verification, failures and next work (imported)

Media now exposes explicit guarded methods with disabled defaults. Both Streaming
adapters preflight the actual native configuration before reserving a mutation or
revoking probe authority, then recheck ownership after suspension and at guarded
native admission. Exact retained replacement mappings include source-time fields
and acknowledgment-time bits; a substituted public receipt cannot recreate them.
Guarded methods work independently of opting into owned bandwidth probes.

The SDK adds a read-only mutation-expectation check for the interval between
profile replacement and its following verified bitrate write, when the ordinary
verified receipt getter is nil. Repeated reads do not consume the continuation or
revoke probe authority. Implicit native invalidation is still detected. The real
mutating call performs its own final checks.

Typed pre-write rejection preserves a healthy publication. Cancellation and stop
win over a late safe error, and malformed successful receipts or other uncertain
mutation outcomes retain joined shutdown. Internal mutation tasks do not await
shutdown that must join them. Regression tests include real lower SRT and
production-initialized upper publisher loopback routes with actual replacement
and follow-up writes. These small loopbacks establish component behavior, not
full decoded-media continuity or production quality increases.

Verification, with all processes joined:

- **16 focused / 346 full serial SDK tests** pass; the maintained patch verifies
  all **162 original hashes** and its exact round trip.
- **14 focused / 245 full Streaming tests** pass.
- **257 full Media tests** pass (191 XCTest and 66 Swift Testing).
- Independent specification and quality reviews approve this checkpoint.
  PublishingSession behavior has not yet changed.

Evidence is retained in
`artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-{focused,full}-20260925{.log,-exit.json}`,
`artifacts/qa/guarded-adapter-focused-04.log`,
`artifacts/qa/guarded-adapter-streaming-full-01.log`, and
`artifacts/qa/guarded-adapter-media-full-01.log`.
Behavioral failure evidence remains in `guarded-adapter-red-02.log`,
`guarded-adapter-red-03.log`, and `guarded-adapter-red-04.log`.

Next are exact Core settlement after a transferred application is rejected,
PublishingSession timer/reservation handling, and the broader application owner.
A successful profile mutation followed by a rejected bitrate write still requires
joined shutdown by that broader owner. No automatic retry route is enabled here.

## Current handoff

Both independent reviews approve this checkpoint. Later checkpoint counts supersede earlier counts; full app integration and fresh automatic post-restoration qualification remain open. Current immediate priority is the authorized physical vertical in [NEXT](NEXT.md).

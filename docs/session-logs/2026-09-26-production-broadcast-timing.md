# Production broadcast timing integration — September26

Start73536ea on codex/local-validation in the authoritative isolated worktree.
Previous goal turn is progress: reviewed/committed upload-budget option, actual
700ms-requested run, clean three-output initial240p media and verified strict
deadline rejection before ramp/cap. All jobs joined before this source slice.
Watch unlock remains pending; no unchanged hardware retry.

## Decision

Use existing broadcast-reliability3000-v1 for the normal app factory, sharing its
3000ms decoder/3500ms capture-evaluation budgets across session, driver and
continuous classifier. This reflects reliability-first broadcast requirements;
it is not an industry-standard number or an inserted delay. Strict1500 remains
available through explicit construction and the existing fixture benchmark.
Report freshness, stall handling, loss/fps checks, transport bounds, candidate and
advice lifetimes are unchanged. The new ordinary diagnostic protects the active
profile and both budget values under its existing4096byte limit.

## Verification

Causal red app run7803 joined65: two tests execute and fail six assertions for
missing timing fields; no unexpected failures. Logs under
`artifacts/qa/production-broadcast-timing-validation`.
Implemented factory choice, bounded diagnostic fields, profile documentation.
Root app test run41827 covers CaptureStreamingModelTests,
PublishingQualityDriverTests and PublishingDeliverySourceWindowTests. Spec review
is read-only and ongoing; no capture active.


All verification jobs joined:199app tests pass (115CaptureStreamingModel,
48DeliverySourceWindow,36Driver),8Core timing boundary tests pass, DebugUI and
Release arm64 device builds pass. Full current diagnostic stress4045bytes and
pressure4091bytes remain under4096. Source/log hashes in verification.json.
No media or recovery pass is inferred; source review is still required before run.


Spec review approved four exact source blobs without blockers; quality review
is now read-only against the same blobs. Retained strict constructor diagnostics
report1500/2000; ordinary constructor reports3000/3500. No runtime threshold or
source edits occurred after the green app/Core/build runs.

Quality review approved the same four frozen blobs. Root verified each source/log
hash; verification.json records both approvals. All pre-run jobs joined.

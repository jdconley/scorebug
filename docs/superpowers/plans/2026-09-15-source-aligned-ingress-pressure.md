# Source-aligned ingress pressure implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, with behavioral
> red/green tests and bounded independent source review. Parent owns sequential runs.

**Goal:** Measure live queue occupancy over actual source-interval uptime boundaries,
so quality telemetry need not invent partial means from fixed diagnostic windows.

**Architecture:** Retain a 4,096-entry ring of scalar depth/phase changes inside the
existing locked ingress accumulator. Each snapshot exposes immutable history and a
pure exact interval query. PublishingSourceInterval associates the query with its
capture boundary times and exact observation scope. Existing aggregate diagnostics
and queue admission semantics remain unchanged.

**Tech stack:** Swift scalar ring, existing Media/Streaming tests and native dual-output
fixture, Node independent raw-history integration oracle.

## Contract

History contains only uptime, normalized item/byte occupancy and ingress phase; no
sample buffers, source payload, tasks or per-frame logging. Append only changed
state; same-time changes replace the final state because zero-duration occupancy
contributes no area. Poll extends known coverage without adding redundant entries.
Storage never exceeds 4,096 states. Eviction makes earlier intervals unavailable;
recent fully covered intervals remain usable. Query cost is bounded by ring size.

Queries cover [start,end), require finite positive duration and full retained coverage,
and integrate the instantaneous max(item fraction,byte fraction). They never take
max of separate means. Every positive-duration segment must be admitting. Startup
or draining overlap, invalid/rewound clocks, invalid depth, or missing coverage returns
unknown. Bad clock/depth quarantines this history for the rest of its attempt. PTS
errors in disposition counters do not invent an occupancy error. Terminal close
freezes coverage; historical queries remain possible and do not imply live freshness.

`PublishingSourceInterval.ingressPressure(in:)` additionally requires equal immutable
scope and uses captureBoundaryStartTime/captureBoundaryEndTime exactly. Closed
source/queue history may support historical association; future policy wiring must
independently require active/fresh matching native configuration and acknowledgment.

## Tasks

- [x] Add `LiveIngressPressureHistory.swift` API stubs and
  `LiveIngressPressureHistoryTests.swift` in ScorebugMedia. Test fractional boundaries,
  max-before-integration, same-time state replacement, phase crossings, invalid clocks
  and depths, sticky quarantine, bounded eviction, no-change polling, frozen close,
  historical snapshot isolation, and actual BoundedMailbox admission/dequeue pressure.
  Preserve behavioral red before implementation.
- [x] Implement ring and immutable query snapshot. Integrate init/update/poll/close
  with LiveIngressObservationAccumulator. Record under its existing serialization;
  expose pressure history in LiveIngressObservationSnapshot. No global locks/tasks.
- [x] Add the scope-checked exact-boundary association to PublishingSourceInterval
  with Streaming regressions for wrong scope, partial coverage and off-grid endpoints.
- [x] Enable ingress observation in the existing dual-output fixture's bounded live
  queue. Export bounded scalar pressure history and per-source-probe integrated
  results after joined completion. Keep existing A/V/cadence/archive gates intact.
  Independently replay piecewise integration from saved raw state changes in Node;
  reject fabricated means/coverage/phase/clock records with focused oracle tests.
- [x] Run full Media/Streaming/tooling, default and impaired native suites, combined
  unsigned iPhone/Watch Release, and bounded source review. Document exact evidence,
  limitations and hashes; commit verified source.

Use Xcode 26.2 via DEVELOPER_DIR, isolated worktree commands:
`swift test --package-path ios/Packages/ScorebugMedia`;
`swift test --package-path ios/Packages/ScorebugStreaming`;
`pnpm test:tools`; `pnpm test:dual-output`; `pnpm test:native-network`;
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
New Swift source files require refreshing only owned dependent-package build sources.

Automatic quality control remains disabled. Transport/thermal/worker pressure
alignment, policy revision/configuration binding and actual automatic trials remain
necessary. This is exact queue evidence, not a claim of end-to-end alignment.


## Review findings addressed

Independent review found that the accumulator's existing `poll` API materialized a
snapshot even when mailbox callers discarded its result. A void `advanceClock(at:)`
now serves all mailbox clock-only paths, avoiding a 4,096-state copy under the lock
on each A/V admission/dequeue. Actual reads still make bounded immutable snapshots.
A direct-handoff test confirms waiting consumers do not invent queued pressure.

The first native build exposed an internal-access mismatch for the standalone
fixture's readiness marker. `beginObservedAdmission()` is now public and explicitly
documented as diagnostic only; it does not gate queue acceptance or start transport.
Standalone owners must establish readiness before calling it. The failed compile is
preserved in `artifacts/qa/aligned-pressure-native-compile.log`. Review approves both
fixes and the final production/fixture/oracle source; reviewer ran no commands.


## Verified checkpoint and next alignment constraint

Full Media tests pass 224 cases (158 XCTest + 66 Swift Testing), Streaming passes
54, and tooling passes 769 (14 new independent pressure-oracle tests). The combined
unsigned iPhone/Watch Release build passes with Xcode 26.2. Native default evidence
is `artifacts/qa/dual-output-zFS9sf`; impairment evidence is
`artifacts/qa/dual-output-1Y9Lmx`. All eight archives retain 420 frames, and all five
successful publishers retain matching native/source histories of 420 frames.

The five pressure histories retain 9, 9, 13, 13 and 11 actual transitions. Each
independent replay verifies two exact source-aligned pressure intervals and keeps
one startup-overlapping interval unknown. The finite fixture does not fill the ring;
unit tests separately qualify 20,000 transitions with bounded eviction. Normal and
recoverable live media retain 420 frames; overload fails strict decode with 389
best-effort frames and invalid source identities, so fresh-frame/loss metrics remain
unknown. Peak measured RSS is below 99 MiB, within the unchanged 512 MiB gate.
Both suites replay from complete raw events and decoded barcode files.

Actual post-write 150-frame capture intervals measure 4.998970, 5.000622, 4.999890,
5.001985 and 5.000294 seconds. Three of these would be rejected by the pure policy's
strict maximum five-second input duration despite healthy nominal 30 fps source
cadence. Upcoming policy-window integration must represent measured elapsed time and
establish an explicit timing tolerance/input-duration contract; it must not silently
clamp endpoints or change the separate rolling-five-second output acceptance gate.
This is observed evidence, not a qualified tolerance value or automatic-control pass.

The manifest `artifacts/qa/aligned-pressure-final-verification.json` hashes final
source, tests, logs and complete native media artifacts. Queue pressure alignment is
now available; transport/thermal/worker alignment, receiver freshness and policy
revision/configuration mapping remain open, followed by actual automatic trials,
resolution transitions, adaptive soak, physical phone/Watch/radio and remote hosts.

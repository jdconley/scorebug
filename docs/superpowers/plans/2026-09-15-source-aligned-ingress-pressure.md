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

- [ ] Add `LiveIngressPressureHistory.swift` API stubs and
  `LiveIngressPressureHistoryTests.swift` in ScorebugMedia. Test fractional boundaries,
  max-before-integration, same-time state replacement, phase crossings, invalid clocks
  and depths, sticky quarantine, bounded eviction, no-change polling, frozen close,
  historical snapshot isolation, and actual BoundedMailbox admission/dequeue pressure.
  Preserve behavioral red before implementation.
- [ ] Implement ring and immutable query snapshot. Integrate init/update/poll/close
  with LiveIngressObservationAccumulator. Record under its existing serialization;
  expose pressure history in LiveIngressObservationSnapshot. No global locks/tasks.
- [ ] Add the scope-checked exact-boundary association to PublishingSourceInterval
  with Streaming regressions for wrong scope, partial coverage and off-grid endpoints.
- [ ] Enable ingress observation in the existing dual-output fixture's bounded live
  queue. Export bounded scalar pressure history and per-source-probe integrated
  results after joined completion. Keep existing A/V/cadence/archive gates intact.
  Independently replay piecewise integration from saved raw state changes in Node;
  reject fabricated means/coverage/phase/clock records with focused oracle tests.
- [ ] Run full Media/Streaming/tooling, default and impaired native suites, combined
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

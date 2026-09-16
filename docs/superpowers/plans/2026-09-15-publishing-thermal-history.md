# Publishing thermal history implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline with behavioral
> red/green tests and bounded independent source review. Parent runs verification sequentially.

**Goal:** Collect real system thermal readings during a publishing attempt and query
historical pressure evidence over the exact source capture boundaries.

**Architecture:** Add a bounded scalar sample tracker in ScorebugMedia. The existing
PublishingSession readiness/health monitor collects ProcessInfo thermal state and
system uptime, outside locks and away from capture callbacks. A terminal session
closes history before joining workers; snapshots remain historical after closure.
No policy classifications, bitrate writes or archive behavior change in this slice.

**Tech stack:** Foundation ProcessInfo, Swift XCTest, existing native media publisher
and unsigned iPhone/Watch Release build.

## Contract

Store raw nominal/fair/serious/critical/unknown states, sampledAt in system uptime.
Unknown future Foundation enum cases map to unknown. Each immutable snapshot retains
at most 64 samples. Exact duplicate samples do not advance history. Conflicting
same-time samples or regressing/invalid timestamps quarantine the attempt. A gap
larger than two seconds clears old coverage; reconnect requires a new session.

An interval requires finite 0 <= start < end <= 1e12 and retained samples at/before
start and at/after end. Return requested/enclosing bounds, sample count and maximum
reported state across the enclosing samples. Any unknown enclosed reading makes
the maximum unknown, even if other readings are nominal. This is deliberately a
sampled enclosing maximum, not continuous thermal coverage or a proof no transition
occurred between polls. No extrapolation, no temperature inference. A fresh sample
requires an open, nonquarantined snapshot and a bounded caller clock/age.

Use the existing 250 ms monitor cadence. Collect once immediately after publisher
readiness and at the beginning of each monitor iteration before awaited publisher
health/diagnostic reads. A suspended monitor naturally leaves stale readings and
cannot manufacture nominal coverage. Close is terminal, and stop never waits for
another thermal reading. A synchronous injected sampler is internal test-only;
production reads only Foundation's scalar state and uptime outside the session lock.

## Tasks

- [ ] Add `PublishingThermalObservation.swift` and tests in ScorebugMedia. Begin with
  API stubs returning unknown/no coverage, then run behavioral tests red. Implement
  bounded history, gap/duplicate/quarantine handling, immutable closure and bracketed
  queries. Test nonuniform fractional boundaries, exact boundary maximum, unknown,
  missing brackets, gap, eviction after >64 samples, closed/fresh, invalid clocks,
  duplicate conflicts and Foundation state mapping.
- [ ] Integrate a `thermalObservation` field into PublishingSessionSnapshot and the
  existing monitor, with an internal deterministic sampler seam. Tests must prove
  readiness-only sampling, real monitor collection, history frozen at stop, no late
  mutation from suspended health, and failure/stop while startup is suspended.
  Add a production-default sampler test that collects actual ProcessInfo readings
  through a running PublishingSession and verifies fresh/closed accessors.
- [ ] Run full Media, Streaming and Film tests sequentially, then combined unsigned
  iPhone/Watch Release. Obtain bounded independent review, address findings with
  regressions, record evidence and hashes, update telemetry/parent docs and commit.

Commands use DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer.
`swift test --package-path ios/Packages/ScorebugMedia --filter PublishingThermal`;
`swift test --package-path ios/Packages/ScorebugMedia`;
`swift test --package-path ios/Packages/ScorebugStreaming`;
`xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination 'platform=macOS' test`;
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

No controlled tests simulate physical heating. Native fixtures using SRTMediaPublisher
directly do not exercise PublishingSession's monitor; do not claim those as thermal
qualification. Worker pressure, policy mapping/freshness and actual adaptive trials
remain the next integration requirements.

Reference: [Apple thermal states](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).

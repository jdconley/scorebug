# Publisher probe adapter implementation plan

> **For agentic workers:** Use superpowers:executing-plans in the existing worktree. Autonomous inline execution is authorized.

**Goal:** Expose the default-disabled native probe through the app's actual SRT publishing adapters, with bounded attempt ownership and terminal cleanup.

**Architecture:** `SRTPublisher` translates immutable SDK snapshots and scopes calls to its current native generation. `SRTMediaPublisher` exposes this opt-in capability without changing the general media protocol or automatic quality controller. Each adapter joins its pending start during shutdown; neither creates a renewal timer. The future DEBUG fixture will explicitly own renewals and export terminal diagnostics.

**Tech stack:** Swift 6, ScorebugStreaming, pinned native SRT SDK, XCTest, Xcode 26.2.

## Interface and ownership

Add `PublishingBandwidthProbeSnapshot` in the streaming package with immutable UUID, publishing generation, accounted target bit rate, start/lease timestamps, accepted payload bytes, last acceptance and optional terminal reason. Copy SDK values without converting them into capacity. Initializers for adapters gain `allowsBandwidthProbes: Bool = false`.

Both adapters expose `beginBandwidthProbe(bitRate:)`, `renewBandwidthProbe(id:publishingGeneration:)`, `cancelBandwidthProbe(id:publishingGeneration:)` and diagnostic `bandwidthProbeSnapshot()`. Begin is rejected while inactive or during encoder mutation. Only one pending start exists. A settings revision captured before awaiting rejects configuration changes during admission. Cancellation or invalidation after native admission revokes the returned exact identity before returning an error. Stop cancels and joins the pending start and closes again if a late operation could have reopened state. Renewal requires the exact retained identity and current generation; stop/settings/cancellation cannot produce a successful stale acknowledgment. Diagnostic reads may retain terminal evidence after stop and never renew.

## Tasks

- [x] Add adapter tests in `ios/Packages/ScorebugStreaming/Tests/ScorebugStreamingTests/SRTBandwidthProbeAdapterTests.swift`. Exercise inactive/default disabled behavior, exact identity, concurrent starts, stop during gated admission, cancelled admission, settings changes during admission/renewal, retained terminal snapshots and no diagnostic renewal. Use owned tasks and bounded gates. Run `swift test --package-path ios/Packages/ScorebugStreaming --scratch-path ios/.build/streaming --filter SRTBandwidthProbeAdapterTests` under Xcode 26.2 and retain the causal failure.
- [x] Add the scalar snapshot and implement the adapter methods and operation closures. Use `Task<PublishingBandwidthProbeSnapshot, Error>` for the single owned pending admission, with exact revocation inside that task before completion. Extend existing stop joins; do not add polling loops or modify media admission/archive behavior. Repeat focused tests to green.
- [x] Run the full streaming package suite and app-model suite, then unsigned combined iPhone/Watch Release build, sequentially in existing build directories. Review actor suspension, cancellation and finish ownership; fix demonstrated defects with regressions. Record evidence, update the main plan and commit.

## Next integration and qualification

The DEBUG local fixture must next create an explicitly enabled adapter, own bounded renewal through the same publishing attempt, export scalar evidence and join it at stop. Authenticated pre-demux receiver byte accounting must bind to the publishing connection and probe interval. Only receiver-confirmed headroom against actual candidate cost can support admission. Repeat native simultaneous archive/live media and the existing picture, 24-fps, A/V, pressure/recovery and feedback-loss gates. Production adaptation, physical phone/Watch networking, portable hosts and long soaks remain open.

## Review findings and scope

The adapters serialize both start and renewal, and shutdown joins either operation.
Failed/cancelled renewal originally left the previous lease active when it threw
before returning a snapshot. A causal regression reproduced this; revocation now
runs inside the owned task's catch before that task completes.

Review found that the lower adapter's `configure()` could change settings during
live probing without the wrapper revision changing. An owned ephemeral loopback
SRT connection reproduced live configuration being incorrectly accepted. The API
now restricts configuration to pre-start and excludes concurrent configuration or
startup. The same native connection test verifies that the default adapter rejects
probe admission as disabled. It owns and closes both listener/accepted sockets,
and joins startup and adapter shutdown on all paths. This is connection/lifecycle
qualification; it does not send or decode camera A/V or prove a sustained frame rate.

Operation-injection tests cover exact UUID/generation, concurrent starts, cancellation,
settings changes during admission/renewal, stop joins and retained diagnostics.
An initial cleanup assertion incorrectly required exactly one revocation; it now
checks that revocation completed by the time stop returned, allowing idempotent
final close. Initial listener test compilation errors were fixed before obtaining
the causal live-configuration failure. All intermediate logs are retained.

## Verified checkpoint

All 70 streaming-package tests pass, including nine new adapter tests and the
native connected default-off/live-configuration regression. All 213 app-model
tests and the unsigned combined iPhone/Watch Release build pass with Xcode 26.2.
Targeted re-review found no remaining lifecycle blockers. No SDK source changes
were needed; the previous SDK/provenance evidence remains scoped to that commit.
All parent-owned test/build sessions terminated and were joined.

Terminal logs are `artifacts/qa/probe-adapter-*`; source and evidence hashes are
recorded in `probe-adapter-final-verification.json`. The final code still leaves
probing disabled in ordinary app factories. This checkpoint provides the callable
adapter capability, not fixture scheduling, receiver capacity admission or live
A/V qualification. Those next integration gates remain as described above.

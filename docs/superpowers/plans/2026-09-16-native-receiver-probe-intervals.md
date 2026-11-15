# Native Receiver Probe Intervals Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline under the active autonomous goal.

**Goal:** Bind production status to the actual native probe owner and measure causal receiver progress in the running capture app.

**Architecture:** A shared-core tracker consumes locally matched freshness evidence and current sender acceptance. An optional app-side publisher observation interface reads the existing native owner; capture status polling feeds the tracker and independently expires it. The existing finite native fixture exports the actual tracker results for qualification.

**Tech Stack:** Swift shared core/app, XCTest, existing SRT native fixture and Node qualification harness.

## Core interval contract

- [x] Add failing tests for 1–5 second receiver-clock intervals, exact local identity,
      sender byte reconciliation, partial-message boundaries, clock-offset intersection,
      monotonic counters, immutable first-delivery time, causal new delivery, quarantine,
      evidence gaps, scope replacement, expiry, zero progress and duplicated reports.
- [x] Implement `WorkerReceiverProbeTracker.observe(evidence, acceptedPayloadBytes,
senderActive, at)` and `expire(at:)`. Keep one baseline, one high-water snapshot,
      one clock-offset intersection and one current interval. Quarantine contradictions
      until scope replacement or explicit owner reset; missing reports cannot wash them.
- [x] Require snapshot and last-delivery age <=1.5 seconds for usable progress.
      A baseline may begin with zero messages. For complete-message delta D and P
      already-seen baseline packets, conservative interval payload is `D*1316-P*188`;
      ignore incomplete end packets. This is delivered load, not spare capacity.
- [x] Retain original interval freshness when duplicate/new subsecond reports arrive;
      neither may refresh historical evidence. Intersect all native receipt envelopes
      with receiver elapsed time and reject disjoint clocks or overlapping requests.

## App owner binding

- [x] Add tests before code for optional publisher observation, locally constructed
      expectations, native-generation mismatch, late response during capture replacement,
      expiry and teardown. Recording remains independent.
- [x] Add a small app `PublishingProbeObserving` protocol and scalar observation;
      SRTMediaPublisher and the existing DEBUG probe wrapper forward current native
      snapshots. Do not move SDK-specific types into shared core/media.
- [x] Capture model holds the optional observer in its publishing tuple, reads after
      the status response to conservatively bound received bytes by sender acceptance,
      rechecks lifecycle after await, and feeds/expires the tracker. A terminated or
      expired native lease cannot provide usable intervals.

## Actual qualification and verification

- [x] Export a bounded DEBUG history of actual native tracker intervals at joined
      detach. Extend the existing probe fixture collector to retain and qualify it
      against the independently saved authenticated receiver snapshots and native probe
      identity. Missing evidence must fail this opt-in fixture.
- [x] Run core/model/harness tests, simulator test build and combined iPhone/Watch
      Release build sequentially. Review correctness and fix demonstrated gaps.
- [x] Run the finite native pressure fixture with marked probes and independently
      verify clean archive/live media, receiver attribution and native intervals.
- [x] Save source/evidence hashes and outcomes, update the main plan and commit.

The current one-probe-per-connection primitive still needs repeated/staged ownership
and measured candidate cost before automatic upgrades. Do not turn delivered probe
load alone into `usableVideoCapacity`, or enable unqualified automatic increases.

## Verification progress

The shared-core tracker, optional native owner read, bounded DEBUG export and independent
qualification are implemented. Review regressions cover expired native leases,
quarantine retention across missing/wrong-scope reports, independent publication
identity, native acceptance/lease history, and coordinated age understatement.
The qualifier additionally uses the full outer uptime span for conservative expiry.

Fresh checks pass: 317 shared-core tests, 228 capture-model tests, 1,168 tooling
tests, ARM64 simulator build-for-testing, and unsigned combined iPhone/Watch Release.
Runtime sources are frozen in `artifacts/qa/receiver-interval-runtime-source.json`.
Actual scheduled-pressure run `native-app-aNh21w` passes on iPhone 14 / iOS 17.5
Simulator. All 6,416 archive frames and 6,040 retained live frames are consecutive;
106 archive and 100 live audio markers match, full decodes are clean, and minimum
reported receiver cadence is 29.8 fps. The 4 Mbps limit lasts 59.999 seconds with
29,138,956 forward wire bytes; neither proxy direction drops traffic.

All 3,683 sender-accepted probe messages (4,846,828 payload bytes) reach the relay,
at about 0.9889 Mbps accounted against 1 Mbps. The probe withdraws on transport
pressure, with media continuing another 142.065 seconds. Actual app output contains
18 independently correlated intervals covering 36.599 receiver-read seconds and
4,377,016 conservative payload bytes. The minimum interval payload rate is 951,916
bits/second. These are delivered-load measurements, not spare-capacity estimates.

The independent Python verifier reconstructs media identities, audio coverage,
pressure accounting, receiver counters and app interval arithmetic from retained
artifacts. Its unchanged control passes and 19 damaged copies fail. All workload
owners terminate and join. Source/evidence hashes and results are recorded in
`artifacts/qa/receiver-interval-final-verification-v2.json`.

Next: measured candidate cost and bounded repeated/staged native probe ownership,
then integrate qualified admission before enabling automatic upgrades. Physical
phone/Watch routes, remote workers and long soaks remain separate open gates.

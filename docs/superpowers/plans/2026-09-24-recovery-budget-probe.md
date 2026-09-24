# Recovery-budget probe implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` in the existing isolated
> worktree. User authorization is autonomous implementation; review checkpoints do
> not require renewed permission. Keep the complete portable streaming/Watch goal.

**Goal:** Permit bounded native bandwidth probing on recoverable delayed/lossy SRT
links, while rejecting exhausted recovery budgets and preserving ownership.

**Architecture:** Add an explicit versioned policy to the existing native probe.
The local zero-loss policy remains the default. The recovery-budget policy uses
actual same-collection sender delay, RTT and backlog; retransmissions consume
transport capacity but are not alone proof of failed video delivery. Carry the
selected policy through native authority, stage replacement, campaign restart and
both publisher adapters. An old consumer that does not name the new policy must
not accept its authority. Receiver-delivered payload and healthy source/deadline
proof remain required before any actual quality increase.

**Tech stack:** Swift, SRT/HaishinKit native owner, ScorebugStreaming, Swift Testing,
XCTest, existing local SRT adapter tests and retained network evidence.

## Evidence and design choice

Previous goal turn made progress: commit85d22d2 introduced the real-file impaired
route and three joined native attempts. The slice attempt has157 on-time30fps
windows, but its probe fails before emitting an event and25 short retransmission
pressure decisions prevent stable recovery. That checkpoint was clean before this implementation.

Raising the fixed50ms limit would fit one test while retaining the wrong zero-loss
assumption. Averaging retransmissions alone would not fix RTT/backlog admission.
Choose a separate recovery-budget policy, with explicit identity so historical
zero-loss proof cannot be mistaken for this new behavior.

[Haivision's latency guidance](https://doc.haivision.com/SRT/1.5.4/Haivision/latency)
relates buffer duration to negotiated delay and recommends about4RTT for modest
loss. [SRT socket-option guidance](https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md)
reserves bandwidth for retransmission. These support using recovery headroom and
actual delivered payload; they do not specify a universal ABR threshold.

The new native admission guard requires known positive actual sender delay, finite
RTT in0...min(500,delay/4)ms, and sender backlog in0...min(500,delay/2)ms. The half-delay
backlog ceiling is a conservative project probe-reserve choice, not a claimed SRT
standard or a guarantee of receiver delivery. This reserve deliberately remains
stricter than allowing the sender queue to reach its deadline. Probes retain the
existing100ms statistic freshness,300ms lease,60s campaign,16MiB total payload,
12Mbps staged ceiling, one-datagram token cap and synchronous revocation.

Fresh network-policy samples must have nonnegative native elapsed time, sent bytes
at least retransmitted bytes, monotonic counters/time, and retransmission deltas
no larger than sent-byte deltas. Equal collection timestamps must agree on all
policy-relevant values; cached reads cannot conceal a counter or gauge change.
Any actual sender-drop increase stops the probe, as do RTT/backlog budget breaches,
missing delay, stale/unavailable statistics, cancellation and failed/backpressured
send. Network mode is staged-only. A replacement or new campaign inherits its
policy from the owned prior probe; callers cannot switch policy mid-publication.

This batch implements the native probe and adapter boundary. Next, the app's
candidate/audit/verifier path must explicitly carry this policy and its raw native
observations, and transport pressure must distinguish recovered loss from failed
delivery. Do not enable this policy in the app fixture or production until those
consumers are updated and the complete impaired run passes. The existing failed
runs remain failed; no deadline/fps/media limit is changed by this work.

## Tasks

- [x] Add `SRTBandwidthProbePolicy` and a bounded scalar transport guard in
      `vendor/HaishinKit/SRTHaishinKit/Sources/SRT/SRTProbeTransportGuard.swift`.
      Add red tests in `Tests/SRT/SRTRecoveryBudgetProbeTests.swift` for the actual
      65msRTT/67msbacklog/400msdelay case, recovered retries, exact boundaries,
      unknown delay, invalid/regressing/changed cached samples and actual drops.
      Introduce the API with old behavior first, observe behavioral failure,
      then implement the selected guard. Example desired behavior:

      ```swift
    let probe = try SRTBandwidthProbe(bitRate: 500_000, generation: 1,
        statistics: stats(10, rtt: 65, buffer: 67, delay: 400), at: 10,
        stage: 1, campaignStartedAt: 10, policy: .recoveryBudget)
    #expect(try probe.offer(statistics: stats(10.1, sent: 12000, retransmitted: 1316),
        now: { 10.1 }, send: { _ in true }))
      ```
- [x] Bind policy to `SRTBandwidthProbeAuthority` and snapshots in
      `SRTBandwidthProbe.swift`; update `SRTStream.beginBandwidthProbe` and inherit
      the prior policy in replacement/restart. Test authority-policy mismatch,
      terminal revocation and preserving time/byte/pacing bounds. Network policy
      does not alter the on-wire probe message format or grant receiver credit.
- [x] Carry the policy through `PublishingBandwidthProbeSnapshot`, `SRTPublisher`
      and `SRTMediaPublisher`. Add a policy-aware operations entry for explicit
      recovery-policy starts; old injected operations/default calls retain their
      behavior. Snapshot validation requires the requested policy on start and
      exact prior policy on renew/replace/restart. Add red/green tests for policy
      changes/replies, cancellation and actual SRT adapter lifecycle forwarding.
- [x] Run focused and full vendor/Streaming suites serially with Xcode26.2,
      existing dependency caches and installed runtimes. Use the existing
      `artifacts/qa/repeated-live-checkpoint-run-check.py` wrapper for joined logs:

      ```sh
    swift test --package-path vendor/HaishinKit --filter SRTRecoveryBudgetProbeTests
    swift test --package-path vendor/HaishinKit
    swift test --package-path ios/Packages/ScorebugStreaming
      ```
      Run the app-model suite after adapter API changes. Review the final diff,
      update plan with actual results/limitations, and commit a coherent checkpoint.
- [ ] Continue with explicit app admission/audit integration and coherent transport
      pressure behavior, independently replay new policy evidence, and rerun the
      real-match impaired route. Only then advance toward production controller
      wiring, wider profiles, causal capacity recovery, physical Watch/phone and
      portable GPU/cloud-host qualification.

## Implementation checkpoint

Native admission and both publisher adapters now carry the explicit versioned
policy. Legacy calls retain the old behavior. A local connected SRT test negotiates
400ms sender delay and verifies start, replacement, renewal, cancellation and
restart with the same recovery policy; it does not simulate packet loss or establish
receiver capacity. Failed replacement and stop revoke authority, and policy changes
in adapter replies are rejected and cancelled.

Focused red/green evidence is retained under
`artifacts/qa/repeated-live-checkpoint-recovery-probe-*` (each completed command has
an exclusive log and joined exit JSON). Native behavioral red exposed the old50ms
limit, stream red exposed missing staged-only admission and inheritance, adapter
red exposed ignored requested policies, and connected behavioral red produced six
wrong-policy/authority failures before native forwarding was implemented. Compile
failures from introducing API surfaces are recorded separately and are not the
behavioral red evidence.

Full vendor tests pass:320 tests in38 suites. Full Streaming tests pass:179 tests.
Native and adapter review found no implementation blockers. Review identified a
revocation assertion that omitted the explicit policy and therefore could pass
without proving recovery-owner revocation; the assertion now names the policy and
first establishes that the owner is permitted.

App integration remains deliberately pending: `PublishingProbeObservation` still
requests legacy authority, so it rejects a recovery owner. No app fixture or
production start selects the new policy. Next work must bind that policy through
candidate admission and exported/replayed evidence before enabling the impaired
route; recovered retransmissions and bounded pressure-history export remain open.
No new real-match impaired run has been counted as passing.

Final joined checks (all exit0):

- `recovery-probe-vendor-full`:320 native tests/38 suites.
- `recovery-probe-streaming-full`:179 Streaming tests.
- `recovery-probe-app-models`:522 app-model tests, macOS arm64/Xcode26.2.
- `recovery-probe-review-connected`:3 connected adapter tests after strengthening
  the policy-specific revocation assertion.
- `git diff --check`:clean.

Existing diagnostic compiler/runtime warnings remain in the test logs; these are
passing commands, not warning-free builds. No simulator was created or downloaded
for this batch. Installed iOS/watchOS26.2 and27 simulators remain available; the
user's removal of other simulators is expected, not a test failure.

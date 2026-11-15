# Repeated probe campaign implementation plan

> **For agentic workers:** Use the subagent-driven-development skill for the SDK task and independent spec then quality review. Parent owns adapters, sequential tests and final evidence. Work only in the local-validation worktree.

**Goal:** Permit a fresh bounded probe campaign after the current staged campaign has ended, without restarting video publication, as the prerequisite for repeated measured quality increases.

**Architecture:** Add explicit `restartBandwidthProbe(id:publishingGeneration:stage:bitRate:)` at the SDK and both adapter layers. Unlike replacement within a campaign, restart requires the exact current terminal staged owner, joins its wake task, revalidates publication/configuration ownership around every suspension, reads fresh socket statistics, and installs a new UUID at stage 1 with a fresh campaign origin and zero accepted bytes. Existing begin and replacement semantics stay unchanged. No automatic scheduler or production upgrade activation in this increment.

**Tech stack:** Swift actors, SRT transport, vendored HaishinKit and native adapter tests.

## Design decisions

Clearing the retained probe implicitly in `begin` would discard identity protection and terminal diagnostics. Reusing `replace` would exhaust the original campaign's 60-second/16-MiB budget and stage ordinal. Explicit restart preserves both contracts and makes repeated campaigns reviewable. The caller must separately qualify recovery and cooldown; transport admission is not evidence of delivered capacity. Each fresh campaign retains the existing lease, traffic, duration and queue limits. There is no accumulating history or unbounded task collection.

The user already authorized continued implementation of repeated ramp-up without intervention. This plan implements the missing transport operation first; the complete repeated-session goal remains open until its scheduler, fresh candidate owners, raw evidence replay and native sessions pass.

## SDK task

Files: `vendor/HaishinKit/SRTHaishinKit/Sources/SRT/SRTStream.swift`, `vendor/HaishinKit/SRTHaishinKit/Tests/SRT/SRTStreamPaddingTests.swift`, `vendor/HaishinKit/scorebug.patch`.

- [x] Add failing tests for terminal restart yielding a new UUID/stage 1/origin/zero counters, old authority remaining revoked, old ID replay rejection, active and legacy owner rejection, invalid generation/stage/rate, failed statistics retry, concurrent admission, cancel/settings/finish/close races during joined wake and statistics sampling. Keep media publishing healthy after optional failures.
- [x] Run `swift test --package-path vendor/HaishinKit --filter SRTStreamPaddingTests` under licensed Xcode 26.2 and preserve expected RED.
- [x] Implement the public async throwing restart with the same argument labels and snapshot type as replace. Require enabled probes, valid rate 1...12000000, active expected publication/clock/no video replacement, exact current staged identity with non-nil terminal reason and no admission in flight. Reserve probeStarting, capture configuration, cancel/join the old wake, check cancellation and all identity/configuration guards, sample current statistics, recheck guards, construct stage 1 with campaignStartedAt equal to its new startedAt and zero carry. Install using the existing single wake owner. Failed admission retains terminal identity for explicit retry.
- [x] Run GREEN then full SDK regressions; regenerate patch and verify upstream hashes/round trip.

## Adapter task

Files: `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/{SRTPublisher,SRTMediaPublisher,PublishingBandwidthProbeSnapshot}.swift` and `ios/Packages/ScorebugStreaming/Tests/ScorebugStreamingTests/SRTProbeRestartAdapterTests.swift`.

- [x] Add failing tests using injected operations for restart after cancellation, exact local identity rejection, default-disabled operation, repeated restart, malformed returned UUID/generation/stage/origin/counters/rate/terminal reason/timestamp/lease, retry and cancellation/settings/stop/unhealthy races. Use the existing joined operation and race test patterns.
- [x] Add `restartProbe` to injected operations with disabled default; wire the real adapter. Add both public restart methods. Validate exact prior staged identity before invoking native work, reuse joined revision/health checks, and cancel invalid or late returned handles. Validate fresh response: changed UUID, same publication, stage 1, nil reason/lastAcceptedAt, zero local and total counters, new campaign origin equal to startedAt, start after prior start and within the request/observation interval, finite positive lease at most 300 ms. Do not reuse old campaign accounting.
- [x] Run focused adapter RED/GREEN and full streaming regressions sequentially with SDK jobs. Compile native app integration.

## Verification and follow-up

- [x] Independent spec review, then quality review; resolve findings and rerun affected checks.
- [x] Freeze runtime sources and verify unchanged legacy measured recovery integration, or explicitly retain native qualification as pending if its prerequisites fail. Preserve all earlier evidence. Rehash the frozen baseline, record exact test/source hashes and commit.
- [ ] Next wire fresh candidate and probe campaign scheduling after proven recovery, extend evidence formats/verifiers for multiple independent campaigns, and verify repeated native ramps before production activation.

## Receiver compatibility finding

The current v2 relay parser treats stage numbers as monotonically increasing
within a publication; `WorkerReceiverProbeTracker` preserves that same history.
A stage-1 restart after stage 3 is therefore rejected as stale traffic. The new
restart operation is an ownership primitive and remains unused by the native
scheduler. It is **not a compatible end-to-end repeated campaign route yet**.
Do not enable it against the existing v2 relay.

The next required implementation is a versioned campaign ordinal carried on the
wire and through receiver evidence, followed by tracker handling that discards
coverage at campaign boundaries without allowing old packets or clock regressions.
Campaign traffic/time limits reset only under that explicit new identity; receiver
publication accounting must remain monotonic. Keep existing v1/v2 behavior and
fixtures unchanged. Then wire fresh candidate ownership and proven recovery into
the repeated native scheduler. This dependency is now explicit before any caller
can claim repeated ramp-up qualification.

## Test checkpoint

SDK RED failed on the missing restart API; GREEN passed all 27 probe tests and
full SDK regressions passed 280 tests in 36 suites. Adapter RED failed on its
missing API, then a separate assertion run caught three out-of-range requested
rates accepted by a matching injected response. The added rate bound makes all
seven restart tests pass. Full streaming regressions pass 150 tests.

Independent spec review approved the implementation. Its two test improvements
were applied: a returned timestamp between the old start and actual request must
reject independently of the prior-start check, and malformed same-ID results must
show an additional cancellation after the restart attempt. Focused tests pass.
The maintained patch still verifies all 162 upstream hashes and exact round trip.

Native regression `native-app-hJ84vZ` uses frozen runtime sources and the existing
v2 measured-recovery route. It checks integration without claiming to exercise
restart against a receiver that does not yet understand it. The joined harness exited 0; both MP4s fully decode, native scoring and archive
export pass, and the measured increase/stall/reset/recovery gate passes.

## Verified integration

The unchanged frozen-source native run passes with a 1,998 ms owned decoder stall
and 10.0001 seconds of healthy recovery. The independent local archive contains
3646 consecutive 1080p frames at 30 fps with 60 audio markers and no
source loss. The streamed recording contains 3269 consecutive frames with no
source loss. The maximum usable report gap is 139 ms; minimum monitored disk
headroom is 5443317760 bytes. These are regression results for the existing v2 route,
not qualification of the new restart against a receiver.

Spec and quality reviews approved. Prior evidence remains frozen; the final
source/test/raw-artifact inventory is
`artifacts/qa/probe-campaign-restart-final-verification.json`.
The next required implementation is campaign-aware wire and receiver support.

## Campaign wire follow-up

The [campaign-aware wire checkpoint](2026-09-17-probe-campaign-wire.md) now adds
v3 from explicit repeatable begin, requires it for restart, and carries campaign
identity through relay/API/native accounting. V2 restart is rejected. Its new
relay image passes a finite three-campaign SRT/media loopback. Fresh candidate
ownership, recovery scheduling and repeated native ramp qualification remain next.

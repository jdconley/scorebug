# Native bandwidth probe fixture implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline in the existing isolated worktree; autonomous execution is authorized.

**Goal:** Run the default-disabled probe through the actual DEBUG simulator publishing path alongside independent archive/live media, with bounded renewal and joined terminal evidence.

**Architecture:** A DEBUG-only `NativeBandwidthProbePublisher` wraps the real SRT adapter without changing the media protocol. It owns one cancellable task, starts one 1 Mbps probe after 20 seconds and a valid native transport clock, and evaluates a 50-second observation schedule on polling boundaries, capped at 600 iterations. Mode `renew` renews every 100 ms; mode `expire` only observes the native lease expire. Stop closes the publisher, joins the fixture task and atomically exports bounded scalar evidence. The first experiment fixes live video at 540p, excluding profile/quality changes so their traffic does not confound this primitive test. Production factories remain disabled.

**Tech stack:** Swift 6/XCTest, existing Xcode project generation, Node test runner and native local streaming harness.

## Tasks

- [x] Add failing Swift tests for absent/malformed fixture flags, exclusive fixed540p routing, stop during pending admission, no late renewal, bounded scheduling, expiry without renewal, scalar event bounds and terminal export ownership. Add `NativeBandwidthProbeFixture.swift` with operation-injected tests and real adapter binding. Every owned task must be joined and clocks/counters must be validated before JSON serialization.
- [x] Wrap the fixed-profile DEBUG factory only for explicit `SCOREBUG_TEST_BANDWIDTH_PROBE=renew|expire`. Forward the flag through Project.yml and NativeStreamingTests. Add Node option/evidence tests before implementation and wire `scripts/test-native-app.mjs` to preserve and validate the closed evidence against the actual recording/match/publishing attempt. Require the existing full processing/publication/direct-recorder/motion checks and 90–600 second hold.
- [x] Run focused and full app-model/tooling tests, streaming package regression tests and unsigned combined iPhone/Watch Release build sequentially in existing build directories. Review ownership, flag isolation and evidence claims. Record source/evidence hashes and commit the fixture integration.

## Qualification boundary

The fixture result can establish local acceptance, lease expiry or withdrawal and joined cleanup. It cannot establish receiver capacity or authorize an upgrade. Execute actual simulator simultaneous archive/live runs next, retain all existing picture/24-fps/A/V gates, and add authenticated pre-demux receiver accounting before admission. Then evaluate measured candidate cost, pressure/recovery/feedback loss, phone/Watch, portable hosts and soaks. The fixed540p experiment is an intermediate isolation test, not the highest-sustainable-quality end state.

## First actual simulator command

Use the existing owned fixture and Xcode 26.2. Start with `expire`, then repeat with
`renew`; neither result alone admits a video upgrade. A passthrough proxy retains
packet timeline evidence without introducing a changing link rate in this first run.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
SCOREBUG_TEST_BANDWIDTH_PROBE=expire SCOREBUG_TEST_LIVE_PROFILE=540p30 \
SCOREBUG_TEST_UPLINK_PROFILE=passthrough SCOREBUG_TEST_PUBLISH_PACING=relative \
SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS=400 SCOREBUG_TEST_DECODER_THREADING=slice \
SCOREBUG_TEST_RELAY_PUBLICATION=1 SCOREBUG_TEST_WORKER_PROCESSING=1 \
SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_MOTION_FIXTURE=blocks16 \
SCOREBUG_TEST_STREAM_HOLD_SECONDS=90 pnpm test:native-streaming
```

The app emits `native-bandwidth-probe.json` only after joined stop. It contains
bounded scalar events and exact decimal-string counters, no credentials or media.
The harness matches its scope and native generation to independently qualified
capture/clock evidence, checks accepted packet/accounted-rate bounds, sticky
terminal state, native lease causality and closed export, and explicitly reports
`receiverCapacityQualified: false`. Existing media gates remain unchanged. All
QA artifacts are also covered by the existing failure snapshot mechanism.

Review reproduced a verifier defect: an advanced lease deadline could claim a
future renewal or revive an expired lease. The verifier now derives the native
renewal instant as `leaseDeadline - 0.3`, checks it against adjacent observation
and expiry times, and permits deadline advances only in renewal events. Causal
regressions cover future renewal, expired revival and a final snapshot silently
advancing a lease. The Swift export closure is explicitly Sendable; the newly
introduced conversion warning was removed.

## Fixture implementation verification

The final fixture integration passes all 219 app-model, 70 streaming-package and
1111 tooling tests (1400 total). The ARM64 DEBUG simulator build-for-testing passes,
including the simulator-only factory and UI test launch path. The unsigned combined
iPhone/Watch Release build also passes. Six new Swift tests cover bounded scheduling,
expiry, stop during admission, invalid clocks/counters and the 602-event maximum;
26 Node tests cover flags and evidence validation. Generated project/scheme output
includes the opt-in flag; generated project files remain untracked as before.

These checks qualify fixture ownership, integration and evidence validation only.
The first actual expired-lease execution is recorded below; sustained renewal remains next. Test/build logs use
`artifacts/qa/probe-fixture-*`; retained causal failures are separate from final
passing outputs. Production quality admission remains disabled.

## Actual expired-lease simulator result

Run `native-app-f8Su6q` completed on iOS 17.5 using the command above. The native
UI workflow, full MP4 decoding, native scoring/overlay, archive and existing media
gates pass. The probe accepts nine messages (11,844 payload bytes), with its last
native completion 14.774 ms before the fixed 300 ms deadline. Expiry is observed
12.177 ms after that deadline; accepted bytes remain unchanged through joined
stop. Capture/live publishing continue another 90.282 seconds after expiry.

The independent archive contains all 3,658 consecutive 1080p30 frames over 121.933
seconds, all 60 audio markers, and a 6.667 ms end-coverage offset. The 540p live
file contains 3,282 consecutive identities (192–3473), with the separately
accounted 35-frame startup acquisition interval and no missing/repeated pictures
inside the retained range. All 54 expected matched audio markers are present,
end coverage is +24.392 ms, and the minimum of 20 reported five-second receiver
windows is 29.8 fps. Both full decode logs are empty. The passthrough proxy closes
with no drops/errors/foreign peers/pending data; recorder and worker exits are zero.
The native owner and all test/build command sessions terminate and are joined.

An independent Python check re-decodes saved barcode artifacts, checks raw receiver
windows, matches probe/capture/clock scope, verifies unchanged terminal counters
and media continuation, and reconciles terminal proxy/owner evidence. Its report
is `native-app-f8Su6q/probe-independent-verification.json`. Code hashes captured
during the run match the validated runtime sources; final source and terminal
artifact hashes are in `probe-fixture-final-verification.json`.

This finite run demonstrates default-isolated native probe expiry alongside a
clean local archive and healthy fixed540p live media. The opportunity-limited
probe does not deliver the requested full 1 Mbps and cannot admit an upgrade.
Next run `renew`, then pressure/feedback-loss cases and authenticated receiver
accounting before testing higher-quality admission. The previously failing
adaptive runs remain unresolved; physical devices, Watch routes, other hosts
and long soaks remain unqualified.


The subsequent [renewal and pressure qualification](2026-09-16-native-probe-renewal.md)
passes both actual iOS 17.5 media scenarios. Renewal remains healthy for roughly
50 seconds; the constrained run reports pressure withdrawal while archive/live
media continue. Both measure only ~0.316 Mbps extra payload against a requested
1 Mbps, confirming the scheduler opportunity limit. That measured underdelivery
must be resolved before capacity admission; requested rate is never headroom.

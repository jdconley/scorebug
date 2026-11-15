# Ordinary native recovery integration plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans. Review implementation against this contract and review code quality before committing.

**Goal:** Run the actual native publisher through confirmed increase, constrained upload, minimum fallback and confirmed recovery while recording and scoring through the complete local vertical.

**Architecture:** The existing device lab owns a manual UDP bottleneck on the publisher route. An authenticated loopback controller lets XCTest apply its two transitions after observing native state. The app uses its normal production publishing controller with only the existing finite file-capture input selected.

**Tech stack:** Node HTTP/UDP, existing relay/worker/RTMP recorder, Swift XCTest, current DEBUG quality diagnostics, independent transport and media checkers.

## Current status

The lab/controller, native lane, diagnostics and independent checkers are implemented and reviewed. Two consecutive instrumented ordinary recovery runs pass confirmed increase, constrained fallback and confirmed recovery at unchanged policy settings. Actual capped transport, all three recorded outputs and media coverage of the six accepted native phase windows pass. Earlier failed recovery remains preserved and unexplained; repeatability and exact network-boundary media attribution remain open. The verified input is `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`: 600 seconds, 18000 consecutive source frames, SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.

## 1. Lab and controller

Files: `scripts/device-lab.mjs`, `scripts/scoring-test-server.mjs`, new `scripts/ordinary-recovery-control.mjs`, and corresponding `scripts/test/` tests.

- [x] Clear ambient `INGEST_PUBLISH_HOST/PORT` before explicit scoring-test environment overrides. Verify a default server cannot inherit a publisher route, and an explicit pair is retained.
- [x] Add an opt-in `publisherRecovery: true` API option to `startDeviceLab`; do not add it to the general lab CLI or default/paired runs. Create the proxy after relay readiness:

```js
const uplink = await createUDPImpairmentProxy({
    receiverHost: options.host,
    receiverPort: ingestPort,
    forward: { recordTimeline: true, recordRateLedger: true },
    reverse: { recordTimeline: true },
    forwardRateControl: { rateBitsPerSecond: 750000 },
});
```

Only `INGEST_PUBLISH_HOST: '127.0.0.1'` and `INGEST_PUBLISH_PORT: String(uplink.port)` use this frontend. Worker `INGEST_HOST/PORT` remains the direct relay endpoint.

- [x] Start a private HTTP controller on `127.0.0.1:0`, with a fresh random bearer token and run ID. Expose only POST `/constrain` and `/restore`, in that order, with sequence 1 and 2. Body contains run ID, sequence, and a bounded current diagnostic. Reject malformed, oversized, unauthenticated, duplicate, concurrent and out-of-order requests before mutation. Bound request bodies and timeouts; do not retry uncertain mutations. No arbitrary rates or destinations.
- [x] Each accepted request records Node `performance.now()` receipt time, the exact synchronous proxy phase receipt, and response-preparation time. Preserve at most two records in a private audit. Close/join the controller and use `createUplinkEvidenceStopper` with `rate-ledger-v1`; aggregate cleanup failures without skipping worker/recorder/API/relay cleanup. Incomplete transitions remain incomplete evidence.
- [x] Test the real loopback HTTP server with a UDP peer, including authorization, limits, ordering, actual phase changes, detached receipts and joined/idempotent cleanup. Run `node --test scripts/test/ordinary-recovery-control.test.mjs scripts/test/device-lab-options.test.mjs scripts/test/udp-impairment-control.test.mjs`.

## 2. Native recovery lane

Files: `scripts/test-ordinary-native-app.mjs`, `scripts/test/ordinary-native-app.test.mjs`, `ios/AppUITests/PhysicalStreamingTests.swift`.

- [x] Add explicit `--lane recovery`, selecting a dedicated XCTest method. Put the private controller URL/token/run ID only into that test runner's private xctestrun environment. App launch environment remains only `SCOREBUG_TEST_FILE_CAPTURE=1`. Default phone/paired selectors and allowances remain unchanged.
- [x] Reuse the actual setup, native HOME point, clean local recording, publishing, stop-stream/archive-continuation/stop/export flow. Preserve a recovery failure through cleanup/export, as existing `adaptiveFailure` does.
- [x] Sample bounded diagnostics every two seconds. Record XCTest `ProcessInfo.processInfo.systemUptime` immediately before and after AX reads and each controller request. Reject stale diagnostics and nonfinite/backward timestamps. The app and XCTest share simulator boot uptime in seconds; Node phase times are milliseconds with a different origin. Do not directly subtract Node and native times.
- [x] Require initial acknowledged `240p30:350000`, then retain the existing 150-second acknowledgment gate for `360p30:600000`. Confirmation requires observing active probation and then no trial under the **same trial owner key and revision**, with advancing accepted source sequence and no pending recommendation/application/minimum reset/rollback. A lone absent trial or historical event string is insufficient. Bound confirmation separately at 30 seconds; do not change production timing.
- [x] POST constrain only after that confirmation. Require a newer native revision acknowledged at `240p30:350000` strictly **after the XCTest response upper bound** for constrain. Give fallback 60 seconds. A fallback that occurred earlier but was noticed later must fail this gate.
- [x] POST restore only after qualified fallback. Require a fresh acknowledged increase within 150 seconds and a second probation-to-confirmation transition, whose acknowledgment follows the restore response upper bound. Preserve session attempt identity throughout.

The trial owner digest includes settings, revision and receipt: it **must change between initial increase, fallback and recovery**. Require owner stability within each trial's confirmation interval, never equality across changed revisions. Do not accept a restarted publishing attempt as recovery.

- [x] Enforce a 540-second recording deadline, leaving headroom before the finite 600-second source ends; keep the 12-second live hold and at least three seconds of independent archive continuation. An outer runner allowance may cover setup/export but cannot extend phase gates or input playback.
- [x] Preserve native phase samples and clock brackets as XCTest attachments. Build the Debug arm64 UI target and run targeted runner tests before the live attempt.

## 3. Independent qualification and actual execution

Files: new `scripts/ordinary-recovery-evidence.mjs` and tests; existing archive/export, source-ID and waveform helpers.

- [x] Validate complete baseline→750000 constrained→restored phases, one peer, no socket errors, joined closure, conserved queues and complete timelines. Call `qualifyRateLedger` with exact transition snapshots mapped as `{appliedAt: phase.appliedAt, queue: phase.forward.queue}`. Require actual offered traffic and token denial/queue pressure; configured rate alone is insufficient.
- [x] Independently replay native ownership, probation/confirmation transitions, acknowledgment ordering, controller request/response brackets and all finite gates. Negative fixtures must reject pre-cap fallback, stale/changed trial owner, restart, missing probation, missing response bracket and evidence overflow.
- [x] Preserve a source-PTS-to-native-uptime correspondence for media phase attribution. Existing `PublishingSourceInterval` provides source start/end and capture boundary uptime. Current mapping is tied to the accepted source sequence/window; absent accepted source remains absent. Do not infer a capture clock from MP4 duration or XCTest wall time. Keep the 4096-byte diagnostic limit.
- [x] Execute the recovery lane on the owned iPhone14 simulator with the verified 600-second input. Keep failed artifacts and all original media. Join all capture/lab processes before heavy decoding.
- [x] Collect the native export; fully decode archive, RTMP MP4 and proxy MP4. Verify consecutive source identity, A/V continuity and sampled waveform alignment, native score/overlay transition, clean archive and archive continuation. Report adaptive, transport and media results separately. Media coverage of all six accepted native phase windows passes.
- [ ] Finish exact network-boundary media attribution and recovery repeatability; accepted source-window coverage is not a continuous network-phase latency measurement.
- [ ] Review changes, fix evidence-backed failures, update the main plan's current status/todos and a separate session log. Physical paired Watch acceptance, full-match duration, wider quality profiles and remote workers remain separate gates.

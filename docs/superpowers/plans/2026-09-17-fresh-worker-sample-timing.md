# Fresh worker sample timing implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded implementation and independent spec/quality reviews.

**Goal:** Remove the avoidable prior-report wait from conservative worker sample age while preserving authenticated timing provenance and the 250 ms consumer freshness bound.

**Architecture:** Negotiate an additive fresh-sample timing capability in worker registration. A worker supporting it obtains a new session-bound token immediately before sampling. The control plane stores one bounded independent challenge slot with its actual monotonic issuance time. Existing current/previous legacy tokens retain their original issuance and rotation semantics. The reporter samples only after the timing response, with the same total deadline, sequential/coalesced reporting, and bounded unknown-session recovery. A failed or missing timing proof cannot fall back to a cached token and masquerade as fresh.

**Tech stack:** TypeScript protocol package, Hono control plane, Node worker reporter; unchanged Swift consumers and native media stack.

## Evidence and alternatives

Previous turn is progress: commit `6a9a160` brought median phone report spacing from 133.2 to 100.0 ms, passed 390 model tests and Apple builds, and produced `native-app-quXkEA`. Delivery row 57 and cadence row 513 share receipt `fec68192-589d-4da1-937d-74e3e408968f`. The healthy 30/30-frame result was classified at uptime 1332019.7602223335 with sample age 249.559 ms. The rejection was logged 21.136 ms later; the next response arrived afterward. The server upper bound was already 161 ms, and the phone request added 8.763 ms. Current report age includes the previous token issuance and the worker's completion-plus-100-ms wait. Existing audit materialization and actor admission need normal nonzero execution time, so a nearly exhausted bound cannot reliably support a sustained trial.

Increasing freshness limits changes the reliability contract. Polling both sides more frequently adds load and still retains an avoidable prior-report age floor. A fresh challenge adds one authenticated round trip per negotiated report, but directly bounds the current sample without trusting a client-reported elapsed time or changing the media policy. Choose the fresh challenge, measure actual overhead and age distributions, and retain conservative rejection on slow networks. Exact synchronous audit versus actor queue delay remains a separate diagnostic question.

## Tasks

- [x] Add protocol capability and request/response types, an authenticated strict-schema timing route, and one bounded session challenge slot. Do not mutate stored report ages, worker epoch, delivery history, or legacy token issuance. Consume the challenge only after a successful new report; duplicate accepted reports stay idempotent. Unknown/retired sessions and invalid monotonic time fail conservatively.
- [x] Add reporter negotiation and challenge-before-sample ordering. Keep a single deadline across registration/challenge/report/recovery; coalesce concurrent calls; omit unproven timing when the server cannot issue a token. Never reuse a previous token after a negotiated challenge fails. Preserve legacy behavior when capability is absent or unknown.
- [x] Prove behavior with failing tests before implementation: long idle before challenge yields bounded current age; delayed challenge defers sampling; old snapshots cannot be redated by a new challenge; token cross-session/eviction/replay and clock failures remain conservative; report duplicates and delivery deltas stay intact; failed challenges and bounded session recovery preserve ordering and deadline semantics.
- [x] Run affected server/worker suites, builds/typechecks, and independent spec then quality review. Preserve previous evidence and record source hashes.
- [x] Run one controlled native comparison after sources are stable. Replay native phases, lifecycle receipts, candidate source correspondence and archive/live media. Analyze current receipt-age distribution and trial outcome. Keep the whole-run gate failed until the independent combined measured-trial gate is implemented; do not enable production increases based on diagnostics alone.
- [x] Update the main plan and evidence manifest, verify immutable prior evidence, and commit the tested checkpoint. Continue toward the complete measured gate, controlled recovery, long sessions and physical/remote validation.

## Implementation verification

The additive capability is `worker-sample-timing-v1`; its strict authenticated route is `POST /v1/worker/sample-timing`. The pending challenge is separate from the legacy current/previous pair and is consumed only after an accepted new report. Failed reports preserve it; duplicate reports do not consume another challenge. Unknown/retired sessions and failed monotonic clocks remain conservative.

The reporter samples after the fresh response and shares its original total deadline and two-attempt recovery budget across registration, challenge and observation. Missing proof is omitted; failed challenges cannot fall back to a cached token. Registration after a lost session clears the delivery cursor. Legacy/unknown capabilities retain the previous request flow.

Cadence snapshots have no explicit sampledAt field, so completed-window sequence plus age establishes the sample coordinate. Equal coordinates retain their previous age; regressed or overflowing coordinates are rejected. Before a completed window exists, fresh-PTS/age progress distinguishes samples. Omission removes timing proof while retaining history, so replay cannot restore it. This conservative cadence hardening also applies to legacy reports. Existing unchanged delivery sample age and merged delta history remain intact.

Behavioral RED reproduced missing challenge behavior and cadence redating before implementation. Final suites passed 500 server tests across 20 files and 392 worker tests across 23 files. Protocol, control-plane and worker builds/typechecks passed. Spec and quality reviews approved the six-file source/test diff. Evidence includes exact commands, exit codes and hashes in `artifacts/qa/fresh-worker-timing-impl-20260917-01/check-inventory.json`. All implementation jobs joined before native verification. Apple source is unchanged from `6a9a160`.

The evidence scope freezes 8,463 prior registered QA files in `fresh-worker-timing-scoped-baseline.json`; a separate broad inventory also records generated build artifacts. Approximately 4.6 GB of ignored iOS build/module/index caches were removed to make room for the next run. Logs, test results, recordings and source packages were preserved. Native diagnostic A exercises the stable reviewed source; its result is recorded below when joined.

## Native comparison

Diagnostic `native-app-15qSdC` ran the reviewed source through the native iOS 17.5 simulator, SRT relay and local worker. Median current report spacing remained 100.0 ms. Median audited cadence/delivery age dropped from the preceding run's 178.2 ms to 73.4 ms; p95 cadence age was 119.7 ms and maximum 136.1 ms. All 1,037 current rows have valid ordered stage timings. This is a one-run local comparison, not a guarantee for remote round-trip latency. There were no logged cadence/delivery rejections.

The runtime applied 240p→360p, logged `trialConfirmed` 19.414 seconds after acknowledgment, and remained at 360p until stop approximately 69.415 seconds after acknowledgment. This is observed controller behavior. Full independent replay of admission, native probe retirement and contiguous policy probation remains pending, so `independentCombinedTrialQualified` is false and production automatic upgrades remain disabled.

Independent existing validators verified the actual 1,257-frame baseline and 2,072-frame 360p phase, exact native lifecycle/bitrate receipts and application deadlines, and all 121 candidate frames within the actual baseline and decoded output. Initial live acquisition omitted 35 baseline frames; every later frame arrived, including the first and final trial frames. Native compressed output paused approximately 440 ms at the encoder transition without losing fixture frames.

Deadline replay reconstructed all 147 rows from raw source/report evidence: all were healthy, none unknown, with 5,880 on-time classified frame instances across overlapping one-/two-second lanes. Each higher-profile lane independently covered 66 seconds; lane totals must not be added as probation credit. The 1080p local recording contained 3,669 frames and live output 3,294, both approximately 30 fps with no lost fixture frames after initial acquisition. All 61 archive and 54 live audio markers matched; archive continued after live stop.

The whole harness still exits 1 at the unchanged fixed-format validator because the native stream actually changes dimensions. The standalone transition, lifecycle, candidate, deadline and media replays all passed. Evidence is indexed by `artifacts/qa/fresh-worker-timing-final-verification.json`. Next implement the combined measured gate against this successful diagnostic, preserving legacy validators and raw failed campaign evidence, then controlled withdrawal/recovery and longer/physical/remote sessions. No further timing-budget change is justified by this run.

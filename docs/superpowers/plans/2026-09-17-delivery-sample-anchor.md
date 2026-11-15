# Fixed delivery sample timing implementation plan

> **For agentic workers:** Use one bounded Core implementation agent, parent native/audit integration, then independent specification and quality reviews. Parent serializes all heavy tests/builds. Preserve all prior raw evidence in the local-validation worktree.

**Goal:** Classify frame deadlines using a fixed conservative sample-time interval, so local scheduling delay does not discard already known arrival timing.

**Architecture:** Optional same-clock request timing establishes a worker sample interval at receipt. Carry it with the authenticated delivery proof; preserve it for a frozen worker sample. Use that interval consistently for arrival, history coverage and maturity, while independently enforcing current freshness and TTL. Legacy unanchored callers retain their current arithmetic.

**Tech stack:** Swift Core tracker/classifier, native capture delivery adapter and DEBUG audit, JavaScript independent replay, native simulator.

## Evidence and decision

`native-app-GfdMuX` row 125 has one uncertain frame. Native encoding took about
437 ms. Classification occurred 81.892 ms after the response-receipt uptime.
Existing arithmetic takes the classification time as the latest possible worker
sample, widening the interval even though the response was already received.
For source PTS 13467/60, the actual request/response bracket gives arrival bounds
1347251.651159–1347251.745396, before deadline 1347251.824094. This is a diagnostic
calculation, not a relabeling of the original failed native result.

Changing deadline thresholds would not fix this information loss. Subtracting a
guessed scheduling delay or mixing clock epochs would be unsafe. Instead capture
the request start and response receipt in the same monotonic uptime domain as
capture. If the server reports sample age at most A at response construction,
sample time S satisfies `requestStart - A <= S <= responseReceived`.

## Contract

- `DeliveryRequestTiming` carries finite nonnegative `startedAt`, `receivedAt`
  in capture's monotonic clock, ordered and bounded by 1e12. Its initializer is
  failable. `DeliverySampleTimeBounds` similarly validates `lower <= upper`.
- `WorkerDecoderDeliveryTracker.observe(..., requestTiming: ... = nil)` adds
  optional timing. Fresh samples use `[max(0, startedAt - serverAge/1000), receivedAt]`.
  Server age validation and all existing authenticated owner/history checks stay
  mandatory. Timing must not reverse across accepted responses, including across
  frozen samples. The uptime bracket must enclose the independently measured
  request duration, allowing only floating-point subtraction roundoff. An omitted
  timing clears timing availability for new samples.
- Repeated identical `sampledAtMs` preserves the previous proof's exact optional
  bounds; later receipt cannot freshen or add bounds to a formerly unanchored sample.
  Existing max-aged freshness and status TTL remain independent and unchanged.
- `DeliveryDeadlineClassifier.classify(..., sampleTimeBounds: ... = nil)` uses
  fixed lower/upper when supplied; otherwise retains `[evaluatedAt-age, evaluatedAt]`.
  Reject a future upper bound or lower older than maximum sample age. Arrival is
  `[lower-arrivalAge, upper-arrivalAge]`, history starts before first capture only
  when `upper-coverageAge < firstCapture`, and maturity requires
  `lower > lastCapture+latencyBudget`. No threshold changes.
- Capture records start before the request and receipt after response completion,
  already present for its control timing audit. Pass those exact values to the
  tracker. Native classification passes the proof's bounds. Audit exports the
  bound (or null when unavailable) in report and classification rows under the
  explicit `deliveryTiming: request-uptime-v1` discriminator. Legacy mode cannot
  silently export anchored arithmetic.
- JavaScript replay reconstructs bounds from the raw report's existing timing,
  original server age and frozen-sample history. Require exported equality and
  correct receipt binding. Legacy audits without fields retain their old results;
  no old raw file is rewritten to gain an anchor. Verify all three interval uses.

## Steps

- [x] Core agent: tests first for stable classification across local delay, expiry,
      future/malformed bounds, maturity/coverage, frozen sample preservation, legacy
      omission, and request-clock reversal. Parent runs focused RED, agent implements,
      parent runs focused GREEN and Core regression. Agent owns only Core source/tests.
- [x] Parent native tests: tracker timing passed by capture; classifier receives exact
      bound; report/audit export carries it with the receipt; stale proof still rejects.
      Implement in CaptureStreamingModel, PublishingDeliveryObservation,
      PublishingDeliveryMonitor and WorkerCadenceReportAudit with their FilmModel tests.
- [x] Parent replay tests: reconstruct exact anchors, reject changed/forged/future/
      expired bounds, preserve frozen identities and legacy fixtures. Update
      scripts/native-delivery-deadlines.mjs and scripts/test/native-delivery-deadlines.test.mjs.
      Verify independent arrival, coverage and maturity arithmetic and failure signals.
- [x] Independent spec/quality review, affected Core/Film/tool regressions, unsigned
      phone/Watch build and fresh native media recovery run. Preserve original failures,
      rehash frozen evidence and commit the tested result with remaining limits stated.
- [ ] Continue recovery-driven fresh candidate scheduling and repeated native cycles;
      then physical phone/Watch and portable-host qualification. Goal remains active.

## Verification commands

Use licensed Xcode 26.2 via `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
Prefix immutable logs with `artifacts/qa/delivery-sample-anchor-`.

```sh
swift test --package-path ios/Packages/ScorebugCore
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination platform=macOS -derivedDataPath ios/DerivedData -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
pnpm test:tools
```

The existing autonomous authorization covers this implementation and local
verification. No deployment, broadcast, license acceptance or physical-device
qualification is implied.

## Verification checkpoint

The regression initially reproduced information loss during local classification
residence. The Core tracker and classifier now carry a fixed request/response
interval; the native capture path supplies its existing exact uptime endpoints.
Both audit envelopes explicitly identify the new semantics. Independent replay
reconstructs the interval from raw request timing and server age, including frozen
sample handling, before trusting classification rows or downstream failure signals.

Review found an additional contradiction: a supplied uptime bracket shorter than
the separately measured request duration could narrow uncertainty. Core and replay
now reject it, permitting only floating-point subtraction roundoff. Regression
failures and their subsequent passing runs are preserved. Review closed with no
remaining findings.

Final regression results: 449 Core tests, 407 FilmModel tests and 2,303 tooling tests
passed, as did the combined unsigned iPhone/Watch Release build. The original raw
legacy recovery replay retains its prior outcomes. All 13,046 frozen evidence files
match the baseline hashes. Fresh media qualification is recorded below; its owned native process and
teardown completed successfully.

Production automatic upgrades remain disabled. Repeated campaign scheduling,
two complete native ramp/reset/recovery cycles, physical phone/Watch verification
and additional proxy-host qualification remain subsequent work.

## Fresh native pass

`native-app-3VrjVR` completed with exit 0 on the iPhone 14 / iOS 17.5 simulator.
The harness independently qualified the measured upgrade, intentionally induced
decoder stall, fallback and 10.0009 seconds of shared healthy recovery. All 140
deadline windows were classifiable with the new anchored format; none contained
uncertain frames. Post-reset delivery lanes had no late or missing frames.
The original 1.5-second deadline and 250 ms freshness limit remain unchanged.

Both MP4s fully decoded. The clean 1920×1080 archive contained 3,671 consecutive
frames at 30 fps, zero source loss and all 61 audio markers; durable recording
finished without an archive failure. Live output contained 3,294 consecutive
frames at 30 fps with zero recorded source loss and approximately 65 ms A/V offset.
These saved-media checks are separate from receiver timing checks, whose windows
overlap and must not be summed as unique delivered frames.

Evidence is preserved in `artifacts/qa/delivery-sample-anchor-*` and the original
native folder. Runtime source hashes remained unchanged throughout the native run.
Prior failed recordings retain their original exits and contents. This closes the
sample-timing qualification issue; it does not qualify repeated ramp-up, network
loss recovery, physical devices or other proxy hosts. Continue at the scheduler
boundary documented in `2026-09-17-candidate-campaign-ownership.md`.

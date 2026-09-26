# Continuous delivery control implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for implementation followed by specification and quality reviews. The user's standing instruction authorizes autonomous implementation of the agreed full-match streaming plan.

**Goal:** Keep delivery-based control running for a full match without depending on finite laboratory audit storage.

**Architecture:** Extract shared synchronous ownership/window classification from `PublishingDeliveryMonitor.Audit`. A continuous classifier retains only the current ownership key and two scheduling cursors. The audit uses the same classifier but continues to grant observations only when its complete evidence row is retained within existing limits. The driver explicitly selects one feedback consumer; existing fixture construction remains audited.

**Tech stack:** Swift, CoreMedia, existing ScorebugCore/Media delivery types and macOS FilmModel XCTest target.

## Design and constraints

The continuous consumer is preferable to increasing the audit limits, which only postpones failure, or silently rotating a qualification log, which loses required evidence. It does not change thresholds or enable production adaptation by itself. The remaining candidate, network-cost and real-camera construction work remains in the delivery plan.

- Share ownership identity and the actual classification operation; do not create a second interpretation of delivery health.
- Preserve source/clock/receipt/worker/authority identity, request-time mode, freshness, missing input, suspension, invalid time, negative/mixed batches, and terminal close behavior.
- Continuous operation has no lifetime row or phase count. Retain at most current identity and two lane cursors; each poll produces at most two transient observations. Do not accumulate histories, JSON rows, results or ownership identities.
- Audit limits stay256ordinary rows/256phases,512extended rows and32MiB. Audit overflow and serialization failure remain terminal and invalidate recovery. Existing format versions and exports remain unchanged.
- Driver selection is explicit and exclusive: continuous feedback must not bypass a requested audit. Preserve all fixture/default behavior and delivery export wiring. Stop/cancel must close continuous feedback and invalidate recovery.
- Every scheduled window in a mixed batch is assessed before a positive observation can grant recovery. Actual missing, stale, uncertain or failed evidence still invalidates immediately.

## Implementation

Files: `ios/Sources/Scorebug/Capture/PublishingDeliveryMonitor.swift`, `PublishingQualityDriver.swift`, and focused tests in `ios/FilmModelTests/PublishingDeliveryMonitorTests.swift`, `PublishingDeliverySourceWindowTests.swift`, plus existing driver test fixtures as needed.

- [ ] Add failing continuous-consumer tests using real `PublishingDeliveryObservation.classify` inputs. Advance history, clock and delivery evidence with time; stale repeated fixtures cannot prove a soak. Require positive classifications beyond512windows and after more than256ownership changes.
- [ ] Cover missing input, suspension, clock reversal, closed consumer, changed authority, request-time mismatch and mixed healthy/unhealthy batches. Compare continuous and audit outputs before audit exhaustion; verify audit stops while continuous feedback remains live.
- [ ] Extract the common classifier and bounded ownership schedule. Keep audit formatting and retention gates separate; preserve every existing audit assertion.
- [ ] Wire explicit continuous mode into the driver without changing simulator fixture selection. Add a driver integration regression showing fresh feedback continues beyond audit limits and stop prevents later control. Avoid a new fallback that silently changes requested mode.
- [ ] Run focused tests, then the FilmModel suite once; fix failures based on evidence. Build the simulator app if changed driver construction is not covered by the model target.
- [ ] Commit implementation and complete independent specification then quality review. Fix/review findings before marking this slice complete.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:

```sh
xcodebuild test -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests \
  -destination 'platform=macOS' -derivedDataPath ios/DerivedData/FilmModel \
  -only-testing:ScorebugFilmModelTests/PublishingDeliveryMonitorTests \
  -only-testing:ScorebugFilmModelTests/PublishingDeliverySourceWindowTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

For the full model suite omit the two `-only-testing` arguments. Save red/green/full logs under a new `artifacts/qa` prefix, and explicitly join each process. Passing this slice proves bounded delivery-control operation only; it does not qualify residual audio loss, full recovery, production enablement or paired hardware.

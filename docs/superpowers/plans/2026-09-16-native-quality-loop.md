# Native quality loop implementation plan

> **For agentic workers:** Execute inline with red/green tests and bounded independent
> source review. Run native/media/build commands sequentially.

**Goal:** Exercise verified bitrate bootstrap, matched-window decisions and actual
native trial/rollback through the camera publishing owner while recording continues.

**Architecture:** A bounded MainActor driver coalesces existing local-health ticks into
one owned task. It bootstraps only after encoded frames exist, evaluates each source
window once, polls rollback deadlines even without reports, and serializes advice
application. Detach cancels scheduling and joins driver/owner/session stop before
closing diagnostics. Initially constructed only by exact DEBUG simulator fixture opt-in;
production remains disabled until real qualification passes.

## Requirements and execution

- [ ] Add `PublishingQualityDriver.swift` and focused lifecycle tests. One task maximum,
  no per-frame work, no independent polling loop. No write before encoder readiness.
  Stop prevents future scheduling and joins suspended writes and owner shutdown.
- [ ] Coalesce matched worker interval identity (epoch/attempt/publication/sequence).
  Wait briefly for pending processing while the original two-second source budget
  permits; consume unknown evidence conservatively when the budget is nearly spent.
  Skip expected initial/mixed/pre-acknowledgment configuration windows, never rewrite
  their counts/endpoints. Poll trial deadline on every admitted tick before evaluating.
  Only owner-accepted advice may dispatch; terminal driver failures retire live only.
- [ ] Bind driver to `CaptureStreamingModel` creation, health polling and joined detach.
  Fixture profile is existing 1080p30, initial verified 6Mbps, 1–12Mbps bounds. Explicit
  trial fixture limits: VideoToolbox filter maximum250ms/completion1000ms; transport
  buffer500ms/RTT500ms/retransmitted fraction1%. These are test parameters, not qualified
  physical or remote-host defaults. Archive settings are untouched.
- [ ] Export bounded scalar driver events/receipts/accepted windows into a separate
  `quality-control.json` after joined stop. Include exact source and configuration
  identities for cross-checking with independently qualified source/video evidence.
  Unknown/error states remain explicit; no URLs, credentials or free-form errors.
- [ ] Add exact `SCOREBUG_TEST_NATIVE_QUALITY=1` opt-in through script/Xcode/UI/app.
  Require streaming, publication+processing qualification, direct recorder, and a
  hold of at least90s. Initially require verified bootstrap, matched policy windows,
  actual trial application and joined stop; report confirmation/rollback outcome.
- [ ] Run full Film/Core/tool tests and Apple builds; run the actual simulator fixture,
  inspect failures without weakening source/recording/freshness gates. Add targeted
  regressions for issues found. Extend to structured-motion and network impairment
  when the initial real loop works. Document partial failures/limits honestly.

Tests use controlled native receipts to prove driver lifecycle; native evidence must
prove the actual SDK writes, source configuration boundaries and saved A/V continuity.
A low-payload barcode pass cannot establish achieved target bitrate or sports-motion
capacity. Keep physical phone/Watch and remote-host qualifications separate.

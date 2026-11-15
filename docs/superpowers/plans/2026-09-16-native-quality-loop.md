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

- [x] Add `PublishingQualityDriver.swift` and focused lifecycle tests. One task maximum,
      no per-frame work, no independent polling loop. No write before encoder readiness.
      Stop prevents future scheduling and joins suspended writes and owner shutdown.
- [x] Coalesce matched worker interval identity (epoch/attempt/publication/sequence).
      Wait briefly for pending processing while the original two-second source budget
      permits; consume unknown evidence conservatively when the budget is nearly spent.
      Skip expected initial/mixed/pre-acknowledgment configuration windows, never rewrite
      their counts/endpoints. Poll trial deadline on every admitted tick before evaluating.
      Only owner-accepted advice may dispatch; terminal driver failures retire live only.
- [x] Bind driver to `CaptureStreamingModel` creation, health polling and joined detach.
      Fixture profile is existing 1080p30, initial verified 6Mbps, 1–12Mbps bounds. Explicit
      trial fixture limits: VideoToolbox filter maximum250ms/completion1000ms; transport
      buffer500ms/RTT500ms/retransmitted fraction1%. These are test parameters, not qualified
      physical or remote-host defaults. Archive settings are untouched.
- [x] Export bounded scalar driver events/receipts/accepted windows into a separate
      `quality-control.json` after joined stop. Include exact source and configuration
      identities for cross-checking with independently qualified source/video evidence.
      Unknown/error states remain explicit; no URLs, credentials or free-form errors.
- [x] Add exact `SCOREBUG_TEST_NATIVE_QUALITY=1` opt-in through script/Xcode/UI/app.
      Require streaming, publication+processing qualification, direct recorder, and a
      hold of at least90s. Initially require verified bootstrap, matched policy windows,
      actual trial application and joined stop; report confirmation/rollback outcome.
- [x] Run full Film/Core/tool tests and Apple builds; run the actual simulator fixture,
      inspect failures without weakening source/recording/freshness gates. Add targeted
      regressions for issues found. Document partial failures/limits honestly.
- [ ] Resolve confirmation timing, then extend to structured-motion and network
      impairment with the same recording/freshness/source gates.

Tests use controlled native receipts to prove driver lifecycle; native evidence must
prove the actual SDK writes, source configuration boundaries and saved A/V continuity.
A low-payload barcode pass cannot establish achieved target bitrate or sports-motion
capacity. Keep physical phone/Watch and remote-host qualifications separate.

## Preserved diagnostic runs

- `native-app-uNUh5z`: the 90-second opt-in workflow completed, but all 19
  source intervals reached policy evaluation after the two-second capture-boundary
  budget (observed examples 2.07–3.30 seconds). No trial was applied; the qualification
  correctly failed. Model tests: 161; tool tests: 805.
- `native-app-4Fn7MA`: worker reporting and phone control polling at 250 ms brought
  19 evaluated source intervals inside the freshness budget. Eighteen still had
  pending encoder completions when the initial 1.5-second wait cutoff consumed them;
  only one was nominal, so the required native trial again correctly failed. Raw
  diagnostic replay passed before the missing-trial assertion. The completion
  measurements were about 401 ms mean, with the transport/decoder boundary about
  one second after capture. No pressure or freshness threshold was relaxed.

The driver now waits for pending completions through the original two-second budget
and coalesces a tick directly on newly received status, as well as the existing health
loop. `WORKER_REPORT_INTERVAL_MS` is configurable from 100 to 5000 ms, default 1000;
only this fixture selects 100 ms. Phone control polling remains two seconds unless
an explicitly constructed quality driver is active. The test uses the same source
windows, receipt boundaries, local recording, scoring and saved-video validators.

Review also found that advice expiry before dispatch must not stop publishing. The
new regression first failed with `staleAdvice`, then passed after the driver treated
it as skipped advice; later valid advice still writes. The independent verifier now
replays bounded thermal samples, transport counters, exact-interval queue states and
as-evaluated worker processing. It requires sticky trial rollback after invalid
probation, the exact source-derived trial advice expiry, and the 60-second rollback
cooldown. Unknown evidence cannot be upgraded using later processing completion.

- `native-app-0v3q80`: with immediate evaluation and the full pending-completion
  wait, nine windows were fully nominal and fresh (about 1.77–1.99 seconds), but ten
  arrived too late (about 2.01–2.12 seconds). No six consecutive windows qualified,
  so no native trial occurred. This demonstrated that the 250 ms report/poll cadence
  lacked reliable headroom for the unchanged two-second gate. The next run uses
  explicit 100 ms fixture reporting/polling; normal defaults remain unchanged.

## Actual native trial/rollback pass

`native-app-r29PCh` passes the complete 90-second hold on the iPhone 14 / iOS 17.5
simulator. Seventeen independently replayed policy windows yielded one verified
native 6 → 6.6 Mbps trial and one 6.6 → 6 Mbps rollback. Both writes produced new
configuration receipts and subsequent source intervals carried the matching native
configuration identity. Two mixed transition windows were explicitly skipped.

All 3647 clean local archive frames (0–3646) survive. The live recording contains
3236 consecutive frames (227–3462), through the final encoded frame, with the 60
acquisition frames explicitly excluded. Both outputs fully decode at 30 fps with
zero qualified source loss; native scoring/overlay, post-stream recording, export,
A/V markers, publication/age, processing and archive diagnostics pass. The final
quality trace is closed and the bitrate is 6 Mbps. This remains a low-payload barcode
workload: measured steady video payload is roughly 0.10 Mbps local / 0.07–0.08 Mbps
live. The receipts prove native target-setting changes, not achieved target payload.

### Confirmation timing remains open

The trial was **not confirmed**. Its first two uniform post-acknowledgment windows
cover 9.999979750 seconds, just short of the required ten seconds. The second was
evaluated about 33 ms before the fixed 15-second trial deadline. With no third full
window available, the deadline poll correctly rolled back. There was no observed
frame loss or elevated pressure in these windows. The recorded `telemetryGap` on
the first uniform window reflects the skipped mixed configuration window; probation
starts with that first uniform window rather than retroactively counting it.

Next work must replay this measured timing in deterministic tests and review a
bounded probation timing design that allows a mixed transition plus enough actual
source coverage and reporting latency. Do not round 9.999979750 up to ten or waive
freshness, weak-evidence rollback, or archive continuity to make confirmation pass.
Then require an actual confirmed native trial, structured-motion load, and network
impairment. Runtime remains DEBUG simulator opt-in only; physical phone/Watch,
resolution transitions, production activation and remote hosts remain open.

## Checkpoint verification

All 162 FilmModel, 333 worker, 831 tooling (including 38 native quality verifier),
and 279 Core tests pass. Worker typechecking, combined unsigned iPhone/Watch Release,
arm64_32 watchOS 10 Core compilation and changed-code formatting checks pass.
Independent source review approves this scoped checkpoint. The local manifest is
`artifacts/qa/native-quality-final-verification.json`, including source and retained
native/media/test evidence hashes. Failed diagnostic runs remain preserved.

The [subsequent confirmation checkpoint](2026-09-16-native-trial-confirmation.md)
resolves the measured deadline issue with a bounded 22.5-second budget and an
explicit initial-window-start limit, without rounding coverage or relaxing freshness.
Confirmation-required barcode and structured-motion simulator runs both pass.
Network impairment and production/physical qualification remain open.

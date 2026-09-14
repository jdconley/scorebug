# Native live tail diagnosis

> Use bounded subagent implementation tasks with specification and quality reviews.
> Keep native qualification isolated from builds and other media tests.

## Evidence

At `5f564db`, isolated native run `artifacts/qa/native-app-9V41qA` completed the
iPhone 14/iOS 17.5 UI workflow and clean archive export. The unchanged live A/V end
coverage gate failed: video ends at 29.451333 s, while decoded audio covers through
29.559002 s, a 107.669 ms difference against a 100 ms budget. Last audio PTS plus
packet duration differs from the sample-count endpoint by only 0.182 ms, so coverage
arithmetic does not explain the failure.

Native capture/encoder observations cover source frames 169–1098. The sink contains
867 consecutive frames 229–1095; three terminal encoded frames are missing. Their
100 ms nominal duration explains the gap except for 7.669 ms. Encoder completion
does not prove SRT receipt, downstream decoding, or output delivery. Earlier passing
run `native-app-PzWmTp` used the same 44.1 kHz live pipeline with only a 3.687 ms tail.

The native SDK finish path drains raw input, VideoToolbox completion, compressed
output, the muxer, and transport. SRT's bounded stop policy waits for local queue
drain and peer latency plus 500 ms within a three-second budget. Its stop outcome
is available on `SRTPublisher` but is not retained in the native artifact. Worker
stdout/stderr are discarded by the fixture, and collected decoder history excludes
terminal/stopping observations. These omissions limit localization.

## First discriminating check: control stop ordering

Code inspection identifies a possible race, not proof of this run's cause:

- `CaptureStreamingModel.stopStreaming()` sets `shouldStopOwnedBroadcast` before
  awaiting publisher teardown. Its explicit final `pollControl()` waits for teardown,
  but an independent periodic poll can enter while teardown is still pending.
- `pollControl()` can submit the owned stop command without a publisher-drain check.
  A poll already awaiting recovery may also resume after stop begins; an entry-only
  guard needs scrutiny under MainActor reentrancy.
- Removing assignment/source readiness makes the worker stop FFmpeg and relay
  reconciliation removes obsolete paths. Those operations can truncate downstream
  media if requested before the local sender completes its bounded finish.

First add a deterministic regression with a gated publisher finish and an observable
fake control server. Exercise a poll started during teardown and a poll already
awaiting recovery when stop begins. Establish whether either submits a local owned
stop before finish is released. Preserve stop ownership, stale-selection protection,
pending-command recovery, startup cancellation, and repeated-stop joining.

If that regression confirms an ordering defect, design the smallest ownership-safe
barrier and test that the stop proceeds after the existing bounded finish settles,
including failure. Do not add sleeps, extend transport budgets, or block clean local
recording on network work. Review and run full relevant model/core suites and the
combined Release build before an unchanged isolated native rerun. A passing rerun
would support the fix but would not by itself prove the race caused `9V41qA`.

### Deterministic reproduction and selected barrier

Both controlled schedules reproduced the ordering defect. While publisher finish
was still gated, the fake server had received `start, stop`, its desired state was
stopped, and the event trace was `publisher.finish.entered, server.stop`. Releasing
the gate appended `publisher.finish.completed`. The focused run failed eight
ordering assertions across two tests, with no unexpected failures. Evidence:
`artifacts/qa/native-stop-order-red.log`. Production code was unchanged for that run.

Keep early stop intent and coordinator startup invalidation. Defer `pollControl`
while `publisherStopping` is true, and recheck after report flushing and recovery
awaits before acting on stop intent. Retain the existing selection/ownership checks
and pending receipt/retry logic. `controlBusy` already prevents a replacement
publisher while polling is suspended. An established publisher is created only
after pending commands are resolved; no new coordinator API is needed to handle
an invented pending-stop/publishing combination. Check again after any relevant
pending-discard await before submission. Add coverage for capture-driven teardown
and eventual single stop after finish settles, then run full model/Core regressions.

This fixes a deterministically reproduced control-ordering defect. Attribution of
the native run's three missing terminal frames still requires the unchanged rerun
and, if necessary, the additional measurements below.

The barrier is implemented and independently approved by specification and quality
reviews. Three focused ordering tests, two relaunch tests, all 74 Film/model tests,
and all 119 Core tests pass. The unsigned combined iPhone/Watch Release build passes.
Two older relaunch fixtures now explicitly join shutdown before exercising their
unchanged acknowledgment/ownership assertions. The initial full-suite failure is
retained in `native-stop-order-film-before-fixture-join.log`; final evidence is in
`artifacts/qa/native-stop-order-{green,relaunch,film,core,release}.log`.

### Post-fix native result

At `9679081`, isolated run `artifacts/qa/native-app-yCntsf` passed the maintained
iPhone 14/iOS 17.5 workflow and all existing media/observation/report-age gates
(runner exit 0, owned cleanup complete). The archive contains 1,225 consecutive
frames 0–1224; live contains 799 consecutive acquired frames 229–1027 at 30 fps.
Archive queue rejections/drops remain zero. Native scoring changed 341 overlay
pixels. Live maximum marker offset is 65.25 ms and its end offset is −17.567 ms,
within the unchanged 100 ms budget. Both native age proofs match independent API
windows. Four steady observation windows match 600 decoded frames.

Complete terminal delivery is still unproven: native capture/encoder observations
cover frames 169–1040, leaving 13 terminal encoded frames (1028–1040) absent from
the sink, in addition to the separately reported 60-frame acquisition interval.
The A/V gate passes because both tracks end close together; it cannot detect equal
truncation of both tracks. This result validates the existing gates after the
control-race fix, not complete end delivery or attribution of the prior failure.
Continue the bounded terminal-delivery localization below, preserving this passing
run and the earlier failed runs. Do not erase the unresolved archive overflow.

## If tail localization remains unresolved

Retain small, bounded, sanitized evidence across the stop boundary: native transport
stop outcome, local broadcast-stop timing, worker stop reason/exit outcome, and a
terminal decoder observation with last PTS. Design exact identity/clock semantics
before instrumentation; do not compare unsynchronized host clocks or dump credentials
and raw worker configuration. Preserve existing source pacing and media policies.

If terminal decoder coverage reaches the final native frame but the sink does not,
investigate worker encoding/output drain. If decoder coverage ends early, distinguish
SRT delivery, relay revocation and control shutdown. Direct sink finalization remains
a possibility, although the runner already stops MediaMTX before copying its MP4.

Keep the 100 ms A/V tail gate and every frame/rate/archive gate unchanged. The earlier
archive overflow remains unresolved; retain its diagnostics for future recurrence.
No automatic quality adaptation or physical-device reliability claim follows from
these short local runs.


### Relay recording feasibility check

An input-recording experiment was considered to compare source barcodes at relay
receipt and worker output. MediaMTX supports inherited recording defaults, but
`IngestRelay.ensure` explicitly sets and verifies `record: false` for native paths.
Changing copied fixture path defaults would therefore produce no recording.
Do not change that production provisioning contract merely for this experiment.
Continue with the planned bounded transport-stop and worker-terminal evidence.

## Bounded worker terminal evidence

Implement as one bounded subagent task, followed by specification and quality
review. Keep production media arguments, stop budgets, protocol snapshots and
report freshness unchanged.

- [x] Add an optional terminal observer to `startPipeline` in `pipeline.ts`.
  When enabled, gather lifetime decoder scalar evidence independently from the
  existing five-second telemetry: accepted/fresh/duplicate/reordered counts,
  first/last/highest PTS at 1/90000, finite invalidity, and ended state. Retain no
  per-frame history. Freeze at parser EOF. Preserve partial-window terminal frames
  without changing `DecodedVideoTelemetry.snapshot()` semantics. A malformed,
  incomplete, nonfinite, or overflowed measurement must remain invalid.
- [x] Emit the terminal callback once after guardian close and telemetry drain,
  before resolving actual encoder exit. Include whether telemetry EOF was observed,
  actual encoder code/signal only when reported by guardian, and final validated
  output progress. Guardian loss is unknown encoder exit and must still retain
  terminal diagnostics without releasing the supervisor's existing fail-closed
  wait. Callback exceptions cannot alter shutdown. Handle pre-spawn errors too.
- [x] In the worker entry point, exact `SCOREBUG_TEST_WORKER_TERMINAL=1` enables
  the observer. Scope its structured event with input gameId, generation and an
  explicitly named worker-local pipeline ordinal (not supervisor attempt). Scope
  pipeline log events the same way through an adapter. No credential, raw error,
  URL or configuration fields. Ordinary worker behavior stays unchanged.
- [x] In the native fixture, always enable that exact test flag for its owned
  worker and drain stdout into a bounded strict JSON allowlist collector. Retain
  stop-state reasons, scoped pipeline lifecycle events and terminal evidence;
  discard other fields and raw lines. Bound pending line length and event count,
  expose truncation/invalid diagnostics explicitly. Keep worker stderr ignored.
  Write one manifest after worker close on success or cleanup failure, before
  container removal. Join collection with worker shutdown and preserve original
  runner errors. Use event order within the collector, never host-clock alignment.
- [x] Red/green tests: partial-window terminal retention, duplicate/reorder and
  invalid EOF, exact once callback including exceptions, actual exit vs guardian
  loss, late telemetry/progress drain; collector bounds and field filtering,
  scope and failure cleanup. Full worker/tool tests and typecheck, then reviews.
- [ ] Run one isolated unchanged native qualification and compare lifetime
  decoder counts/PTS span and output progress to offline source barcodes at sink.
  Count evidence can distinguish decoder-vs-output losses, but cannot establish
  an unqualified PTS mapping or prove upstream delivery. Add native transport
  outcome evidence next only if localization remains insufficient.


The worker-side implementation and fixture collector pass specification review.
Diagnostics use a separate optional lifetime parser, keeping the production
five-second snapshot unchanged. The fixture retains at most 256 events and one
4,096-byte pending line. It persists after actual worker close and on failure
cleanup; absent/truncated/invalid evidence remains explicit. Test-only warning
and error events route to stdout, while raw stderr remains discarded. Worker-local
pipeline ordinals do not claim to be supervisor attempt identifiers.

Validation: 153 worker tests, 163 tool tests, worker type checking and diff checks
pass. Evidence is under `artifacts/qa/worker-terminal-*`; final worker/typecheck
logs use the `-review` suffix. Two review regressions caught diagnostic stderr
routing and coercion of an array into a signal name; both have retained red/green
logs. Both specification and code quality reviews approve. A third regression
ensures the collector loads before the native runner builds protocol artifacts;
its finite private allowlists have no generated-file dependency. The isolated
native run is pending.

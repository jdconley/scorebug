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

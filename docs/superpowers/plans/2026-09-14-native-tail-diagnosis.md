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
- [x] Run one isolated unchanged native qualification and compare lifetime
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
native run is recorded below.

### Native terminal evidence at `4884734`

Isolated iPhone 14/iOS 17.5 run `artifacts/qa/native-app-VrXKA9` passed all maintained
UI, recording, streaming, native scoring/overlay, export, observation and report-age
gates; runner exited 0 and owned cleanup completed. The archive contains 1,252
consecutive frames 0–1251 at 30 fps. All 2,504 archive samples were accepted/written,
with zero queue rejection/drop, peak one 3,200-byte item, valid timing and complete
component coverage. Its A/V end offset is +14.667 ms. Live contains 856 consecutive
frames 198–1053 at 30 fps; maximum marker offset is 65.25 ms and end offset −15.751 ms.
Two native age proofs match independent API windows; five steady windows match 750
source frames. No media threshold changed.

Native capture and encoding cover 929 consecutive frames 138–1066. The separately
observed acquisition interval is 60 frames; 13 terminal native frames are absent
from the sink. The new worker evidence is complete: 143 retained events, zero
invalid/oversized/omitted events, full stdout EOF, actual worker exit 0. One scoped
pipeline reports 869 fresh decoder frames, no duplicates/reordering, valid terminal
EOF, and PTS 68640–2672641 at 90 kHz. FFmpeg reports 869 output frames and exits 0
with no signal; there was no pipeline SIGTERM or SIGKILL before that exit.

The 13-frame count deficit is after decoder ingress. This does not itself identify
encoding, muxing, RTMP receipt, or sink recording as the cause, and it does not
establish a production mapping between native source PTS and worker PTS. Version-
pinned FFmpeg source clarifies that progress `frame` counts packets entering the
mux submission path, incremented before `av_interleaved_write_frame`; it is not a
receipt acknowledgment. Evidence: `worker-terminal-evidence.json`, `results.json`,
and the scoped offline `terminal-comparison.json` in that run.

### Test-recorder shutdown investigation

MediaMTX 1.21.0 recorder shutdown removes its stream reader before closing the
format. Reader shutdown closes a gortsplib 5.6.5 ring buffer, which clears pending
callbacks. Separately, fMP4 keeps one pending sample for duration calculation;
format close does not flush that sample. Source references:

- https://github.com/bluenviron/mediamtx/blob/v1.21.0/internal/recorder/recorder_instance.go
- https://github.com/bluenviron/mediamtx/blob/v1.21.0/internal/stream/reader.go
- https://github.com/bluenviron/gortsplib/blob/v5.6.5/pkg/ringbuffer/ringbuffer.go
- https://github.com/bluenviron/mediamtx/blob/v1.21.0/internal/recorder/format_fmp4_track.go
- https://github.com/bluenviron/mediamtx/blob/v1.21.0/internal/recorder/format_fmp4.go
- https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/fftools/ffmpeg.c
- https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/fftools/ffmpeg_mux.c

A standalone local replay (`artifacts/qa/sink-eof-probe/probe.py`) sends archived
fixture frames through VideoToolbox/RTMP to fresh owned MediaMTX containers. A
transparent loopback relay changes only its deliberate post-client-EOF delay,
0 versus 1 second. FFmpeg's `stats_enc_post` and `stats_mux_pre` retain packet
boundaries; all resulting sink files pass full A/V decode and barcode analysis.
These are diagnostic experiments, not replacements for native qualification.

| Replay           | Video packets encoded / submitted | Saved frames, immediate EOF | Saved frames, delayed EOF |
| ---------------- | --------------------------------- | --------------------------- | ------------------------- |
| 10 seconds paced | 300 / 300                         | 299                         | 299                       |
| 10 seconds burst | 300 / 300                         | 163                         | 163                       |
| 4 seconds burst  | 120 / 120                         | 112                         | 119                       |

For the short burst, all four complete audio/video packet-stat files are byte-
identical across cases (SHA-256 comparison retained). Each run forwards 38,543
client bytes, has 174 audio packets and exits 0. Seven additional source frames
are saved when EOF is delayed; one final sample still remains absent. This supports
queued-recorder-work cancellation alongside the independently identified final-
sample issue. The larger-burst loss is not localized by this experiment.

Limitations: separate executions have unavoidable scheduling differences; forwarded
byte counts are not receipt acknowledgments. The prototype's `relayQueueErrorObserved`
filter did not cover all possible warnings and discarded stderr, so false does not
establish absence of reader overload. No queue occupancy/drop counters were measured.
Exact attribution of the native run's 13 missing frames remains unproved. The
one-second delay is a discriminator, not an application shutdown fix. Both the
positive and non-discriminating replay results remain preserved.

### Next bounded step

Qualify a terminal-complete independent RTMP test recorder, or a reviewed recorder
fix, before making app shutdown changes for this sink deficit. Establish packet and
source-frame preservation with paced and short-burst replay, then rerun the native
workflow against it. Keep the existing MediaMTX runs as comparative evidence. Do not
hide the deficit with sleeps or weaker gates. The earlier local archive overflow,
sustained physical iPhone/Watch runs, source-clock qualification, adaptive profile
transitions and additional worker-host qualification remain open.

## Independent RTMP recorder qualification

The standalone FFmpeg 8.1.2 listener prototype in
`artifacts/qa/direct-rtmp-recorder-probe/` receives RTMP directly and stream-copies
both tracks into fragmented MP4 (`+frag_keyframe+empty_moov`). It preserves every
submitted video packet/source frame in paced 300-frame, short-burst 120-frame and
burst 300-frame cases. Publisher and receiver exit 0 and all three recordings fully
decode. `packet-completeness.json` also verifies all video/audio packet counts:
300/432 paced, 120/174 short burst, and 300/432 burst. This establishes feasibility;
native A/V alignment still needs explicit qualification.

Implement one bounded helper with specification and quality review. No application,
worker media policy, production relay provisioning, or acceptance-gate changes.

- [x] Add `scripts/direct-rtmp-recorder.mjs`: own a single FFmpeg child listening
      on an OS-selected, supplied loopback port. Use `-listen 1`, explicit video/audio
      maps, stream copy, fragmented MP4, and non-overwrite output beneath the artifact
      directory. Ignore raw stderr. Readiness must observe the actual owned PID listening
      on exactly `127.0.0.1:port` with bounded `lsof`, without connecting a probe client
      (which would consume the single publisher slot). Bound startup to five seconds.
- [x] Expose a URL and joined lifecycle: successful `finish()` waits for natural
      EOF/child close after worker stop, bounded to five seconds, and requires exit 0,
      no signal and a nonempty output. Timeout is failed evidence, not successful drain.
      Cleanup `stop()` is idempotent and joins the owned process; TERM then bounded KILL
      after two seconds if necessary. Preserve a small sanitized manifest exactly once
      after close, including whether readiness was observed, actual code/signal and
      fixture termination request. Startup failure must clean its own child before
      rejecting. No detached tasks or ambient-process termination.
- [x] In `native-streaming-fixture.mjs`, exact
      `SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1` selects this receiver instead of the owned
      MediaMTX sink. Keep the same owned SRT ingest, worker, scoring and media gates.
      Await recorder readiness before worker startup; collect its MP4 only after worker
      stop and receiver natural exit. Failure cleanup joins both children before
      removing owned containers. With the flag absent, preserve the comparative
      MediaMTX fixture. This is a local test endpoint, not a public authenticated server.
- [x] Test readiness without network probing, early exit/spawn failure, startup
      timeout, close-before-finish, repeated joins, natural EOF, explicit failure on
      nonzero/signal/empty output, and TERM/KILL cleanup. Verify native selection through
      the maintained fixture boundary where practical; full tool suite and both reviews.
- [x] Recheck all three replay MP4s for both video and audio packet completeness
      against the publisher stats. Then one isolated native run with the flag enabled,
      retaining complete source-frame, A/V, scoring, archive and terminal comparisons.
      Preserve the previous sink's deficits and avoid claiming beyond this local scope.

Implementation verification: 26 focused recorder tests and all 189 tool tests pass.
Review caught and fixed a real Node execFile cancellation hang: AbortSignal can
send TERM and clear the probe timeout, so cancellation explicitly kills the owned
live probe and joins close. A real TERM-resistant child regression failed before
the fix and passes after it. The readiness timeout reason is captured before
cleanup; its exact-message regression also failed before the fix. Red/green logs:
`artifacts/qa/direct-rtmp-recorder-review-{red,green}.log`; full suite:
`artifacts/qa/direct-rtmp-recorder-tools-review.log`. Native qualification pending.

First native attempt `native-app-WPajX2` stopped at recorder readiness before app
launch. macOS lsof rendered `localhost` instead of numeric loopback. An isolated
owned-listener probe confirmed the cause; `-nP` now disables name and service
conversion. The exact-arguments regression failed before this fix; all 189 tools
pass after it (`direct-rtmp-recorder-numeric-{red,green}.log`). Real helper smoke
`direct-recorder-numeric-6I8KmL` observes readiness and joins cleanup. Review cleared
the fix. No native media result was produced by the failed startup attempt.

Second native attempt `native-app-mnP1kq` at d88f799 passed the UI/export flow
and full A/V decode, but FAILED the existing video timestamp cadence check. The
recorder exited naturally with code 0 and preserved all 893 decoded worker video
frames (source IDs 198..1090). Its first video timestamp was 0, followed by 1.139;
all later frame intervals matched source cadence. Archive terminal evidence shows
2554 accepted/written samples, no reject/drop, and finished state. This is not an
overall native qualification pass.

The controlled offset replay `direct-recorder-offset-N10U41/results.json` isolates
the recorder setting: `empty_moov` produces first video times 0/1.177/1.211, while
adding `delay_moov` produces 1.144/1.177/1.211. Both retain 117 video and 237 audio
frames and fully decode. FFmpeg documents delaying the initial moov until the first
fragment at https://ffmpeg.org/ffmpeg-formats.html#Options-9; this allows initial
track offset metadata. Only this test recorder gains `+delay_moov`; source and
worker media arguments and acceptance thresholds are unchanged. The argument
regression failed before the fix; all 189 tools pass after it (`offset-{red,green}`
logs). Review cleared the bounded fix; another isolated native run is pending.

### Passing independent-recorder native qualification

`native-app-lyB1el` at efcda56 passes the maintained iPhone 14 / iOS 17.5 native
streaming, scoring, archive/export, full A/V decode, cadence, sync, observation and
worker-report-age gates. Command log: `direct-rtmp-recorder-native-offset.log`.
`terminal-comparison.json` and its adjacent reproducible comparison script verify:

- Clean archive: 1308 consecutive frames 0..1307, 30 fps, no source loss; A/V end
  difference +4.000 ms. All 2616 samples accepted/written, zero rejected/dropped,
  peak queue one item/3200 bytes, finished with complete diagnostic coverage.
- Live: 894 consecutive frames 228..1121, about 30 fps, no interior source loss;
  all 894 worker decoded/output-progress frames retained. Native encoded range
  168..1121 contains 954 frames: the separately observed 60-frame acquisition
  interval is explicit, and no encoded tail remains absent from the saved stream.
- Live A/V marker maximum offset 65.25 ms; end difference +12.327 ms. The initial
  978 ms audio lead is within the existing keyframe-acquisition allowance. Native
  scoring changes 346 overlay pixels; both age proofs match independent API windows.
- Recorder readiness observed, natural exit 0, no termination requested. Worker
  pipeline DID receive SIGTERM and exited 255; telemetry ended with valid counts.
  This is complete observed frame delivery, not a claim of natural FFmpeg EOF.
  Worker wrapper exited 0; bounded terminal evidence has no invalid/oversized/omitted
  events or incomplete line. All owned resources were cleaned up.

This qualifies the opt-in recorder for this local short fixture. It does not resolve
the earlier archive overflow, prove exact causes of every prior MediaMTX deficit,
or establish sustained recording, real camera/Watch networking, higher profiles,
adaptive behavior or additional GPU/cloud hosts.

Next bounded work: use this qualified opt-in endpoint when investigating sustained
native archive recording. First make frame-tail comparison a maintained assertion
for that endpoint and add a bounded duration override to the native fixture without
relaxing current media gates; then collect an isolated longer run with archive
pressure diagnostics. Preserve failures and inspect pressure before changing queue
limits or capture pacing. Physical pairing still requires an available device;
continue simulator and portable-worker work while devices remain unavailable.

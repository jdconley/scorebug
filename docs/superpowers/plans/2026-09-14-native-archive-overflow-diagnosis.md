# Native archive overflow diagnosis

> Use superpowers:subagent-driven-development for bounded implementation tasks,
> with specification and quality reviews. Keep timing runs isolated.

## Evidence and limits

`artifacts/qa/native-app-mIqwM3` failed during the report-age qualification attempt.
App diagnostics and the failure screen show archive queue overflow at 34.90 seconds.
The ensuing capture shutdown removed Stop Streaming, which caused the UI failure.
Native scoring reached the worker. No successful stop/export/media or report-age
qualification followed. Existing records show accepted duration tracking real time
until shortly before failure; they do not establish the cause of the backlog.

The archive queue is bounded to 24 items/24 MiB, roughly a quarter-second of
1080p NV12 video. The simulator source schedules absolute frame deadlines and can
catch up after a scheduling delay. AVAssetWriter readiness and synchronous segment
storage can also delay the consumer. Neither mechanism is established by this run.
Do not widen the queue, drop archive frames, alter fixture cadence, or relax media
gates merely to obtain a pass. The already-reviewed report-age source is committed
separately; its native qualification gate remains open.

## Checkpoint 1: Preserve owned failure artifacts

- Add a small filesystem helper and focused tests, called by the native runner's
  failure path before deleting its owned simulator. Resolve only that simulator's
  app data container, using its recorded ID. Boot it only if needed to inspect its
  container; no global simulator reset or unrelated app/device access.
- Copy only `Library/Application Support/Scorebug/Recordings` and `QA` into a new
  failure-only artifact subdirectory. Do not copy setup, Keychain, preferences, or
  the full application container. Never modify source recording files.
- Reject symlinks/special files, cap total copied bytes (1 GiB), entry count (10,000)
  and traversal depth (32), and record incomplete/skipped/error outcomes explicitly.
  Tests may inject smaller limits. Missing QA or missing recordings is diagnostic
  information, not another reason to discard the original failure.
- Preserve the original test error and exit failure. Export/copy errors must be
  secondary evidence and cannot bypass existing owned-resource cleanup. Existing
  passing-run collection and every media acceptance gate stay unchanged.
- Test the whitelist, missing paths, symlinks, budgets, partial read/copy failure,
  and source preservation. Run tooling tests and review before committing.

Checkpoint 1 is implemented and approved by specification and quality review.
`scripts/native-failure-artifacts.mjs` copies into a fresh `failure-app-data-*`
directory and writes an explicit best-effort manifest. Limits include ancestor
inspections. The runner captures these files before owned simulator cleanup and
retains the original native failure even when diagnostic collection or cleanup
also fails. Fourteen focused tests and all 149 tooling tests pass, including a
regression executing the actual runner catch/finally path. Syntax and diff checks
pass. Logs: `artifacts/qa/native-failure-artifacts-{red,green,tools}.log`.

No native media rerun has occurred since the initial overflow; first add the cause
measurements below. These new preservation hooks cannot recover files already
removed by the earlier run's cleanup, and copied fragments still need recovery and
full decode before their media validity is established.

## Checkpoint 2: Capture bounded cause measurements

The [diagnostic specification](../specs/2026-09-14-archive-pressure-diagnostics.md)
now defines the implementation. Independent design review approved bounded completed
span rings with active operations, with explicit count-based retention, atomic
rejection occupancy, overlapping timing semantics, bounded persistence concurrency,
and partial delegate work after cancellation. Routine diagnostic design choices
remain within the user's authorized autonomous implementation scope.

Implementation order:

1. Add the DEBUG owner/snapshots and deterministic timing/bounds tests. Add atomic
   mailbox rejection statistics, prepared session/writer attachments, and consumer/
   persistence hooks with behavioral pressure regressions. Review this source boundary.
2. Attach the fixture source and Film owner; join the QA export and retain it in
   the native harness. Test scope, failure, disabled state and restart/export ordering.
3. Finish package/model/tooling checks, Release exclusion and source reviews, then
   run one isolated native reproduction with unchanged media gates. Continue to
   checkpoint 3 based on actual measurements, not a successful retry alone.

Step 1 implementation adds the bounded DEBUG owner, atomic mailbox rejection
statistics, and session/native persistence hooks. All 130 Media tests pass (101
XCTest and 29 Swift Testing), including 39 focused owner/session/writer tests.
Logs: `artifacts/qa/archive-pressure-core-{red,green,media}.log`. Independent
specification and quality reviews approve this source boundary. The Media Release
build also passes (`archive-pressure-core-release.log`). Fixture/Film ownership,
joined export and harness collection are next; native qualification is still open.

The actual storage gate exposed a runtime-specific test assumption: on this Mac,
native cancellation waited for the gated persistence callback. The partial-close
regression therefore uses a protocol-valid non-joining test sink around the actual
native writer/receiver/store, then releases and cleans up native work. It proves
diagnostics tolerate unfinished persistence without claiming that this Mac's native
cancellation returns early. Counter saturation is tested through the shared helper;
the owner's overflow-flag assignment is checked by source inspection.

Step 2 now attaches the same owner to Film's prepared session, simulator source and
native writer. Its closed snapshot exports atomically inside the joined stop task,
and the native runner retains and checks the actual recording identity, closure,
coverage and bounded shape. Existing cancellation before session creation still
creates no source or diagnostic owner. Partial timing remains explicit evidence.

All 71 Film/model tests and 155 tooling tests pass. A deterministic Swift encoding
matches the retained JSON fixture used by JavaScript tests. The unsigned combined
iPhone/Watch Release build passes; both binaries exclude the diagnostic symbols
and fixture markers checked. Logs are `artifacts/qa/archive-pressure-integration-*`,
including `release-exclusion.json`. Independent specification and quality reviews
approve step 2. The native reproduction and report-age gate remain open; no
overflow fix is claimed.

Define a small, explicit DEBUG qualification snapshot with recording identity and
monotonic timing. Retain existing queue peak/accepted/rejected/dropped counts, plus
enough producer scheduling and consumer readiness/append timing to distinguish a
source catch-up burst from an encoder/storage stall. Capture the first failure
before queue cancellation destroys current occupancy. No per-frame I/O/tasks,
unbounded samples, credentials, or changes to media admission and retry policy.

Design exact ownership, bounded aggregation, export timing and deterministic
failure tests before implementation. Reuse the newly preserved QA/recording paths.
Do not infer a cause from only a high-water mark or a successful later retry.

Source inspection identifies the measurements needed for that design:

- `FixtureCameraSource` waits for `began + frame/30` and generates the next immutable
  frame/audio pair even when that deadline is already past. Measure deadline
  lateness and generation time separately from callback/offer time. Preserve this
  pacing behavior while measuring it; skipping or slowing frames would change the
  experiment.
- `RecordingSession.offer` is the only place that latches `.overflow`. Capture its
  first rejected kind/retained bytes, admission reason and pre-cancellation queue
  occupancy, not only the emptied mailbox visible later. Existing peak/accepted/
  rejected/dropped statistics should accompany it.
- `RecordingCore.run` retries `sink.append` on false, with a two-second deadline.
  Measure time awaiting readiness separately from the duration of the synchronous
  append call. A full producer queue may fail much earlier than that deadline.
- `SegmentReceiver` synchronously hashes/persists/fsyncs segments. Measure segment
  persistence duration as a separate consumer-side contributor; a slow append call
  alone cannot establish whether disk or encoder readiness caused the stall.
- Use one recording-scoped monotonic owner, short non-reentrant diagnostic locks,
  bounded recent aggregation and an immutable first-failure snapshot. Never read
  writer/disk state while holding capture/diagnostic locks. Export once after joined
  recording shutdown under the explicit simulator qualification flag, into QA.

These measurement targets are now defined by the reviewed diagnostic specification
linked above. They do not establish which contributor caused the observed overflow.
Verify the schema, lock order and disabled path with deterministic producer/consumer
timing and controlled writer backpressure before the native reproduction.

## Checkpoint 3: Reproduce, fix from evidence, and requalify

Finish all builds/tests/reviews before a controlled native run. Preserve and inspect
failed artifacts if it recurs. Fully decode recoverable failed recording segments
to establish what survived. Use measured pressure to choose a narrowly justified
fix and a behavioral regression; obtain source reviews and run relevant checks.
Then repeat the unchanged recording/streaming/scoring/export/media gates and the
report-age comparison. A later pass does not erase this failure or establish
sustained recording reliability. Hardware, impairment and soak gates remain open.

### Instrumented native run: archive completed, live tail failed

The isolated run `artifacts/qa/native-app-9V41qA` at `5f564db` used iPhone 14/iOS
17.5 and the local Mac VideoToolbox worker. The native UI workflow passed, but the
runner exited 1 during live media analysis: audio/video end coverage differed by
107.669 ms, exceeding the unchanged 100 ms limit. This is not a native qualification
pass. Log: `artifacts/qa/archive-pressure-native.log`.

The archive overflow did not recur. Diagnostics are closed, valid and fully covered,
with 2,620 accepted/written samples, zero rejected/dropped samples, and peak queue
occupancy of one item/3,200 bytes. Archive decode contains 1,310 consecutive source
frames 0–1309 at 30 fps; its A/V end difference is 1.334 ms. The final bounded
producer/consumer histories contain only their retained tail, so their small delays
cannot explain the earlier failed run. All 23 persistence spans were retained; the
maximum measured persistence duration is 6.738 ms. No overflow fix is established.

Separate post-run checks against the saved files found:

- Live video has 867 consecutive source frames 229–1095 at approximately 30 fps,
  with no missing frames inside that acquired interval. Native capture and encoder
  observations both contain frames 169–1098; the final three encoded frames are
  absent from the sink. Three nominal frames account for 100 ms of the tail gap.
- Live steady marker offset is at most 65.25 ms. Five complete steady observation
  windows match 750 decoded frames; their encoder rates are 29.8–30.2 fps. The
  final partial window includes shutdown and is reported separately.
- Both worker-age helper proof windows match independently collected API windows.
  These historical helper checks pass independently; the complete native gate
  remains failed because of the live tail.
- Native scoring changed 341 thresholded overlay pixels. The failure preservation
  manifest is complete: all 52 copied files match the normal collection by SHA-256.

Evidence: `post-run-independent-checks.json`, `failure-copy-verification.json`,
`archive-diagnostics.json`, `video-observation.json`, and the media/probe files in
that run directory. Post-run checks do not replace the runner's failed result.

Continue with the [native tail diagnosis](2026-09-14-native-tail-diagnosis.md).

The subsequent `native-app-yCntsf` run at `9679081` passes all maintained native
gates after the independently reproduced control-stop race was fixed. It also has
zero archive rejections/drops, with 1,225 consecutive archive frames. The earlier
overflow is still unresolved; these short runs do not establish sustained recording
reliability. Thirteen terminal native encoded frames are absent from the live sink,
so complete end delivery remains a separate open diagnosis despite passing A/V
alignment. See the tail plan for the exact results and next measurements.

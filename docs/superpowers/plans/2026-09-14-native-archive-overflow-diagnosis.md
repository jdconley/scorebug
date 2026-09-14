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

These are measurement targets, not a completed implementation specification or
an assertion that any one contributor caused the observed overflow. Before coding,
review the minimum bounded schema, lock order and disabled-path behavior; test them
with deterministic producer/consumer timing and controlled writer backpressure.

## Checkpoint 3: Reproduce, fix from evidence, and requalify

Finish all builds/tests/reviews before a controlled native run. Preserve and inspect
failed artifacts if it recurs. Fully decode recoverable failed recording segments
to establish what survived. Use measured pressure to choose a narrowly justified
fix and a behavioral regression; obtain source reviews and run relevant checks.
Then repeat the unchanged recording/streaming/scoring/export/media gates and the
report-age comparison. A later pass does not erase this failure or establish
sustained recording reliability. Hardware, impairment and soak gates remain open.

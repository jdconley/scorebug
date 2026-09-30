# Native worker status

Broadcast intent and worker observations are separate. A requested broadcast can be
waiting for a camera, starting, encoding, retrying, or unavailable. The native
scorer displays these states without taking the scoring lock or blocking a point.
“Worker encoding video” means the worker has reported advancing encoder counters;
it does not certify viewer delivery, audio synchronization, or fresh-frame rate.

## API and worker

All routes use bearer authorization and no-store responses.

| Route                              | Authorization                         | Body/result                                                                     |
| ---------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------- |
| `POST /v1/worker/sessions`         | Worker installation token             | `{workerId, runId}` → `{sessionId, serverTime}`                                 |
| `POST /v1/worker/observations`     | Worker installation token             | `{workerId, sessionId, sequence, observation}` → `{accepted: true, serverTime}` |
| `GET /v1/matches/:id/media/status` | Match-scoped score/capture credential | `{status, serverTime}`                                                          |

An observation contains `gameId`, `generation`, `state`, nullable fixed `reason`,
`attempt`, nullable `frame`/`outTimeUs`, and nullable `scoreRevision`. There are no
stream URLs, tokens, or arbitrary encoder diagnostics. The score revision describes
the last completed overlay-file write. Actual burn-in is checked separately in the
media harness.

The API accepts reports only for the currently selected worker/game/generation.
One current reporting session exists per worker ID. Registration retries for that
run are idempotent; replacement retires the old run/session. Sequences and counters
cannot regress within an encoder attempt, including across intervening null reports.
A new attempt permits encoder counters to reset. Exact duplicate delivery returns
success but never refreshes freshness.

The worker reports approximately once a second on its own asynchronous loop, with
one 1.5-second deadline for each reporting cycle. It copies observations, coalesces
concurrent calls, and renegotiates an unknown session once after an API restart.
Reporting failures leave control polling and process supervision running. A normal
idle worker sends no stale assignment report.

## Expiry and native display

A report expires five seconds after receipt using a monotonic clock. Wall-clock
corrections cannot extend or revive it. API restart deliberately discards observations,
so status is unknown until the worker reports again; durable match and broadcast
state remains intact. Stop and generation replacement take precedence over old
reports immediately.

The native client converts `expiresAt − serverTime` to a local ContinuousClock
budget, caps it at five seconds, and subtracts the full request duration. The display
reevaluates every second independently of network completion; normal rendering may
lag the validity deadline by one display cadence. Status requests never acquire the
scoring busy flag or overwrite scoring errors. Changing server, token, credential,
match, or generation invalidates delayed replies, including changing settings and
then restoring them before a reply arrives.

Session retirement tombstones remain for the API process lifetime. This is transient
status bookkeeping, not a distributed encoder fencing mechanism. Continue to run
one worker process per worker ID. Output watchdogs and relay revocation remain
separate safeguards.

## Evidence

- Shared `worker-status-v1.json` is compared against real scoped HTTP responses and
  decoded/round-tripped by Swift with canonical nulls.
- Backend tests cover authentication, strict schema, current selection, sessions,
  ordering, counter reset, duplicate freshness, clock jumps, generation replacement,
  stop precedence, and restart-to-unknown.
- Worker tests cover copied observations, completed score writes, independent
  reporting, total deadlines, coalescing, ordered reports, and session recovery.
- Real software media through SRT and the local RTMP sink verifies API waiting,
  positive encoder counters, written score revision, expiry after worker SIGKILL,
  API/source recovery with the current score, and `not_requested` after match end.
- Swift tests hold status requests while scoring, change identity/generation during
  requests, and advance monotonic time past expiry.
- `pnpm test:apple --worker-status` creates its own API and simulator, drives the
  native app through waiting/encoding/expiry/recovery/stop, and scores while status
  is active. This UI fixture supplies worker reports directly; it does not simulate
  actual phone camera capture or establish Watch behavior.

The native status UI workflow passed on iPhone 14 simulators running iOS 17.5 and
18.5, and an iPhone 15 simulator running iOS 26.2. Shared Swift tests (50) and
scoring model tests (17) passed. Screenshots confirm encoding and expired status
remain readable alongside the point controls.

The rebuilt production API and Linux CPU worker containers passed their startup
and media checks. The shared protocol exports compiled JavaScript at runtime;
container builds include workspace dependencies, and test/development entry points
build that protocol first. A plain-Node import test guards against depending on a
TypeScript loader to resolve production modules. When editing shared protocol source
during a dev/watch session, rebuild the protocol or restart that command.

Current logs are under `artifacts/qa/worker-status-*` and
`artifacts/qa/native-worker-status-ios*.log`. The [ten-minute local 720p30 qualification](media-soak.md) now passes. Native
recording/publishing, sustained higher profiles, adaptive quality, Watch workflows,
and physical-device testing remain required.

## Optional source processing reports

Session registration advertises `workerProcessing: "source-processing-v1"`. A worker
sends the optional `observation.processing` only after negotiating that exact version,
the transport clock and private pipeline-read identity. Legacy and unsupported workers
continue without it. Decoder and processing fields come from one synchronous pipeline
sample, bound to the current publishing attempt.

Reports identify one immutable pipeline UUID/backend and an adjacent decoder interval.
They separate decoded, submitted, completed, pending and omitted counts, with nullable
reader-observed filter/completion durations. The API validates source bounds/counts,
permits pending-to-complete updates and freezes completed contents. Omissions retain
server progression guards while removing public metadata. A new assignment requires
a new attempt before processing can resume; neither pipeline UUIDs nor read IDs can
be reused across attempts. Rejected reports consume no token or identity state.

Swift tolerates malformed optional metadata, then validates usable processing against
the existing publication and decoder age proof. The film app attaches it only when
its reconstructed native source interval has the same exclusive anchor, first/end PTS,
sequences and frame count. Repeated reports can update completion without refreshing
the original source-age anchor; omission clears attached processing. No pressure or
capacity classification follows from completion counts alone.

The optional `workerFrameCapOmissions: "tokenbucket-90k-v1"` session capability
allows `interval.intentionalFrameCapOmissions`. Older peers keep the unchanged
v1 processing protocol and timing/count fields; a new worker strips cap attribution
unless that separate capability was negotiated. The API validates its count against
total omissions and freezes it with the source interval.

Cap attribution predicts the exact bounded-credit selection rule from pipeline
start at the shared90kHz timebase, then corroborates selected frames against actual
encoder submissions. Unknown policy or a contradictory submission omits attribution.
The native classifier excludes only this attributed count from resource-overload
classification; unexpected/legacy omissions and excessive filter/completion durations
still produce pressure. Counts remain visible, and capture/delivery/cadence safeguards
are unchanged. This is historical frame selection evidence, not proxy CPU utilization
or viewer receipt.

For the owned local simulator fixture, add `SCOREBUG_TEST_WORKER_PROCESSING=1` alongside
`SCOREBUG_TEST_RELAY_PUBLICATION=1` to `pnpm test:native-streaming`. The gate requires
two completed API/native processing intervals matching independently qualified source
intervals and saved frame identities. It validates historical correspondence, not
fresh health, raw timing arithmetic, sustained load or remote-host performance.
See the [processing report plan](superpowers/plans/2026-09-15-worker-processing-reports.md).

# Media control API: milestone 1 progress

Native matches now have persistent recording associations and separate broadcast
intent. Ending a match commits the score result and broadcast stop together, while
leaving recording metadata unchanged. This establishes the control contract for
independent local recording; it does not yet write or validate a video file.

## Routes and credentials

All routes below use Bearer authorization and return `Cache-Control: no-store`.
The installation credential is `PHONE_TOKEN`; the worker credential is `HOME_TOKEN`.
Scoped credentials come from the native match create/join routes.

| Method and path                                 | Authorization             | Response                                                    |
| ----------------------------------------------- | ------------------------- | ----------------------------------------------------------- |
| `GET /v1/matches/:id/media`                     | Scoped scoring or capture | `{snapshot, serverTime}`                                    |
| `POST /v1/matches/:id/media/recordings`         | Scoped capture            | `{recording, serverTime}`                                   |
| `POST /v1/matches/:id/media/commands`           | Installation              | `BroadcastOutcome`, HTTP 200 accepted or 409 rejected       |
| `GET /v1/matches/:id/media/commands/:commandId` | Installation              | Original outcome, or 404 `command_not_found`                |
| `GET /v1/worker/snapshot?workerId=mac`          | Worker                    | `{assignment, serverTime}`                                  |
| `POST /v1/matches/:id/media/publish`            | Selected scoped capture   | `{gameId, generation, recordingId, publishUrl, serverTime}` |
| `GET /v1/worker/connection?workerId=mac`        | Worker                    | `{connection, serverTime}`; null for an unselected worker   |

A recording report contains `recordingId`, `sequence`, `status`, and `startedAt`.
The API takes the reporting device identity from its capture credential. It rejects
another device claiming an existing recording, changed start times, older sequences,
and differing payloads at the same sequence. Identical retries preserve the original
server timestamp. `stopped` is terminal; an `interrupted` recording may resume with
a newer sequence. Reports do not change the match's scoring revision.

Reports are the capture client's last known state, not a server observation that
frames are still being written. Consumers must not present an old `recording` report
as proof of a healthy archive. Recording health and stale-status presentation remain
part of capture integration.

## Broadcast intent and recovery

A command contains `commandId`, `gameId`, `expectedGeneration`, `issuedAt`, and
`operation`. Start selects `{workerId, outputId, captureDeviceId, recordingId}`;
stop has no selection. These are identifiers, not URLs or stream secrets. Start
requires an active match and a recording last reported as active by the selected
capture device. A running broadcast must be explicitly stopped before moving to
another worker.

Every accepted new command advances the broadcast generation and match revision.
Recording telemetry does neither. Command receipts and state commit in one SQLite
transaction. Exact retries return the original outcome before checking age or
generation; changed content under the same ID is rejected. New commands expire
after ten seconds and reject timestamps more than five seconds ahead of server time.
Clients must reconcile an uncertain receipt before creating a replacement command.
The shared Swift client exposes these endpoints; a durable broadcast UI coordinator
is still to be added with capture integration.

The selected worker snapshot contains a consistent `{match, media}` assignment only
when that worker is selected for the active match's requested broadcast. Other
workers receive `null`. A late or restarted worker can fetch current score and intent.
`desired: running` is a request, not proof of an active stream. The native worker
consumes this endpoint and the connection route to launch media. Worker output
health is logged locally but is not yet reported to the API/native UI.

The publishing route takes `{recordingId, generation}` and returns only publishing
access for the selected capture device. The worker connection route returns only
reading access and a validated source observation (`ready`, `inboundBytes`, `tracks`).
Both routes recheck the current generation after asynchronous relay work; a changed
broadcast returns HTTP 409, an unselected capture returns 403, and unavailable or
unconfigured relay access returns 503. The existing public match/media snapshots
still contain no stream URLs or credentials. Source readiness is not worker output
health. See [relay reconciliation and limits](relay-conformance.md).

Schema version 2 adds recording, broadcast, and receipt tables to the existing
match database. Migration preserves scoring state, credentials, and receipts.
See the [native API runbook](native-scoring-api.md) for durable volume and secret
configuration. The legacy `/games` lifecycle remains separate and must not be mixed
with native matches.

## Local evidence

- 49 pure media state tests, 10 persistence tests, and 4 HTTP route tests pass.
  Coverage includes ownership, ordering, rejected operations, schema migration,
  independent SQLite connections, and rollback when receipt persistence fails.
- The complete workspace suite passes 169 API tests, 68 worker tests,
  and 12 tooling tests. Typecheck, production build, formatting, and the actual
  production server container startup check pass.
- Shared Swift passes 45 tests, including 11 media contract/client tests.
  TypeScript and Swift consume identical `media-v1.json` wire fixtures.
  The native scoring app also passes an unsigned generic iPhone build with an
  iOS 17 deployment target using Xcode 26.2; this is compilation, not a device run.
- `pnpm test:scoring` survives four forced API exits over real HTTP, preserving
  score, authority, receipts, recording association, worker/output selection, and
  broadcast stop after match end. Its owned processes and temporary files are removed.

These results do not qualify recording, SRT, FFmpeg output, watch networking, or
physical devices. Relay credential retrieval and short native worker media runs
now have [separate integration evidence](../apps/home-daemon/README.md).
Next work includes observed worker status, abrupt crash recovery, source-loss
injection, and the full local media qualification gate.

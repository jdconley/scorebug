# Native scoring API: milestone 1 progress

The `/v1/matches` API now stores native matches, scoring authority, command receipts,
and score history in SQLite. The native SwiftUI scorer creates/joins matches, scores,
undoes actions, ends sets/matches, and restores its session. The shared Swift outbox
persists uncertain commands and reconciles receipts. Full milestone 1 is still in
progress: recording associations and durable broadcast intent are implemented, but
relay credential routes and source observation now have real SRT validation.
Observed worker status and the actual worker consumer still need integration.
See the [media control API](media-control-api.md).

## Run locally

Use Node **22.13 or newer**, which exposes the built-in SQLite module without an
extra command-line flag. The implementation uses the same synchronous SQLite
transaction API on macOS and Linux; no platform-specific npm database addon is
required. See the [Node SQLite reference](https://nodejs.org/api/sqlite.html).

```sh
pnpm install --frozen-lockfile
pnpm dev:api
# In another terminal:
pnpm test:scoring
```

The development API binds `127.0.0.1:18787` and writes its native match database at
`artifacts/qa/development/scorebug.sqlite`. `DATABASE_PATH` overrides the path.
Container deployments must bind-mount the containing directory, including SQLite's
WAL/SHM sidecars; a container's writable layer is not durable deployment storage.
Back up the database with SQLite-aware tools or after stopping the API.

`pnpm test:scoring` instead owns a temporary database, private random port, and API
process. It creates/scores a match over real HTTP, force-kills and restarts the API,
checks the exact original receipt and score, transfers authority to a second
scoring device, force-kills/restarts again, and verifies that authority survived.
It then associates a recording, requests a broadcast, restarts a third time, and
verifies the selected worker can retrieve the assignment and original receipt.
After ending the match, a fourth restart verifies the broadcast stays stopped
while the recording association remains unchanged.
It removes only its process and temporary files. This tests server process recovery,
not a native UI or a video pipeline.

## Authentication and routes

Creating, discovering, and joining use the installation's existing `PHONE_TOKEN`.
After joining, each native client uses a token scoped to its match, device, and
role. A scoring token grants no access to the old `/games` publishing API. A capture
role can read its match but cannot submit scoring commands or take over scoring.
Watch pairing-code provisioning follows in milestone 5.

Keep `PHONE_TOKEN` stable and outside SQLite. Scoped tokens are derived with HMAC
using that installation secret and a domain-separated match/device/role identifier;
only their SHA-256 digests are stored in SQLite. Identical create/join retries return
the same credential, including after restart, so a lost response cannot revoke the
client's working credential. Explicit credential revocation/rotation tooling is
still to be added. Never use the public development tokens on an exposed host.

| Method and path                           | Authorization  | Response                                                                          |
| ----------------------------------------- | -------------- | --------------------------------------------------------------------------------- |
| `POST /v1/matches`                        | Installation   | `{snapshot, credential, serverTime}`; body `{id, deviceId, teams, rules}`         |
| `GET /v1/matches/active`                  | Installation   | `{snapshot, serverTime}`, with null snapshot when no active match exists          |
| `POST /v1/matches/:id/join`               | Installation   | `{snapshot, credential, serverTime}`; body `{deviceId, role}`                     |
| `GET /v1/matches/:id`                     | Scoped         | `{snapshot, serverTime}`                                                          |
| `POST /v1/matches/:id/commands`           | Scoped scoring | `CommandOutcome`; HTTP 200 for acceptance, 409 for a persisted rejection/conflict |
| `GET /v1/matches/:id/commands/:commandId` | Scoped scoring | That device's original `CommandOutcome`; 404 only when no receipt exists          |

Use newly generated UUIDs for match, device, and command identities. Identifiers
allow letters, digits, underscores, and hyphens, up to 128 characters; match ID
`active` is reserved for discovery. HTTP 401 means missing/invalid authorization;
403 means the authenticated role or device does not have the requested permission.
Validation failures are HTTP 400.

## Command and recovery contract

Commands include `commandId`, `gameId`, `deviceId`, `expectedRevision`, `scorerEpoch`,
`issuedAt`, and `operation`. The operation is one of `award_point`, `undo`, `end_set`,
`end_match`, or `take_over`. The canonical wire example is
[`packages/protocol/fixtures/match-v1.json`](../packages/protocol/fixtures/match-v1.json).
The Swift test bundle consumes the same fixture; CI verifies the copies agree.

State, revision, and receipt commit in one `BEGIN IMMEDIATE` transaction with WAL
and FULL synchronization. A retry of the same command returns its original receipt
before revision, age, or current-scorer checks, even after takeover or match end.
Reusing an ID for different content is rejected. Original receipt snapshots can be
older than the current match: the client must never roll back a newer view merely
because an old receipt arrived.

A new command older than ten seconds is rejected for reconciliation. A timestamp
more than five seconds in the future is rejected as clock skew. Native clients
must calculate server time from response envelopes, keep uncertain sent commands
in durable storage, and query receipts before deciding to retry or discard them.
The shared `MatchCommandCoordinator` implements these behaviors for native clients.
It stores the full command atomically before sending, blocks new actions while one
is unresolved, and checks receipts before any retry. It refuses automatic replay
when the age, revision, or scorer authority changed. Clearing an expired action is
an explicit reconciliation step with a second receipt check after server time has
proved the command too old. Failed file writes preserve the previous committed
pending record; recovery tests construct a new coordinator to verify this.

Only one scorer owns the match. Takeover requires the current revision and scorer
epoch, increments both, and leaves the match score unchanged. Delayed commands from
a previous scorer cannot apply. Rejected commands also have durable receipts.

Default rules are best of three, 25-point sets, a 15-point deciding set, win by two.
Best of five, target scores, win margin, and an optional cap are configurable.
Ending a set always rejects a tie. An override requires an explicit winner and
reason, which are retained in the set result and command history. Undo can restore
a completed set. After enough sets are won, further points are blocked until undo
or explicit match end. Match end requires a reason and is terminal.

## Current boundary

The legacy `/games` API remains an in-memory prototype for existing scaffolds.
It does not share the new native match lifecycle yet; do not mix both APIs in one
session. Native match creation needs no YouTube key and starts no recording or
broadcast. Recording associations, broadcast commands, and a selected-worker snapshot
endpoint now share the durable lifecycle. Relay credentials and reconciliation are
connected through separate native API routes; the actual worker consumer remains
an integration step. The native scoring app remains independent
of the unfinished camera/media project. Watch UI and route integration follow later.

## Native validation

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:apple
# Separate native scorer joins, takes over, scores, undoes, and ends the match:
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:apple --two-phones
```

The runner creates its own API process, SQLite database, and dedicated simulators.
The single-phone lifecycle has passed on iOS 26.2: create, point, terminate/relaunch,
restore score, undo, reject a tied set, and end the match without a camera prompt.
The two-phone run also passed on iOS 17.5 and 26.2: a second native app joins, takes over,
scores, undoes, and ends the match; the first app then restores the final state. Simulator apps use local ad hoc signing
so the tests exercise real Keychain persistence; no developer team is required.
The single-phone lifecycle also passed on an iPhone 14 simulator running iOS 18.5.
The generic physical-device compilation check remains unsigned. This is not a
recording, streaming, watch, or physical-device acceptance result.

The Apple runner also tests the production SwiftUI model through a hostless macOS
XCTest target with injected storage and HTTP transport. These tests cover uncertain
creation replies, credential repair, failed server/account changes, and action
confirmation during an in-flight refresh. Production storage remains Keychain-only.

## Evidence for this checkpoint

- TypeScript: 124 API/rules/store tests, 14 worker tests, and 9 local-tool tests pass;
  workspace typecheck and production build pass.
- Real API: `pnpm test:scoring` passes after four forced process exits, preserving
  score, exact receipts, scoped credentials, scorer takeover, recording association,
  broadcast selection, and the terminal broadcast stop after match end.
- Shared Swift: 45 tests pass, including failure-preserving atomic outbox writes,
  receipt-first replay, clock/context expiry, command serialization, and media client contracts.
- Scoring model: 13 hostless macOS tests pass, including secure-read failure,
  credential-scope changes, uncertain creation, and truthful recovery feedback.
- Native UI: three stages across two dedicated iPhone 15 simulators pass on iOS
  17.5 and 26.2. No browser or camera permission participates. Each runner cleans
  up its own API, database, and simulators. Logs are kept under ignored
  `artifacts/qa/apple-native-two-phones*.log`; screenshots/results under `ios/build`.
  The iPhone 14/iOS 18.5 single-phone lifecycle also passes, covering the middle
  supported OS generation and the minimum required phone screen size.

These tests do not yet simulate two people tapping simultaneously through two
real UI processes, actual watch connectivity, or camera/streaming performance.
The remaining milestone 1 integration connects durable match identity to actual
worker reconciliation/status; the legacy publishing
scaffold currently still has a separate in-memory lifecycle.

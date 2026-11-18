# Scorebug API

This is the HTTP API of the hosted Worker at `https://scorebug.live`
(`apps/control-plane/src/worker`).

Requests and responses are JSON. JSON responses carry `Cache-Control: no-store`.
Authenticated requests send `Authorization: Bearer <token>`. Most responses include
`serverTime`. Shared types live in `packages/protocol` (`matches.ts`, `media.ts`,
`setup.ts`, `worker-status.ts`).

## Conventions

Errors are `{ "error": "<code>" }` with a matching status. These can come from any
route:

| Status | Error                  | Meaning                                                                                   |
| ------ | ---------------------- | ----------------------------------------------------------------------------------------- |
| 400    | `invalid_request`      | The body or query failed validation                                                       |
| 401    | `unauthorized`         | Missing or invalid token                                                                  |
| 404    | `not_found`            | No such route                                                                             |
| 429    | `rate_limited`         | Rate limit hit; `Retry-After: 60`                                                         |
| 503    | `server_misconfigured` | `SERVER_SECRET` is missing or shorter than 32 characters (every `/v1` route and `/admin`) |
| 500    | `internal`             | Unhandled error                                                                           |

The match, scoring, media and worker routes validate bodies with
`@hono/zod-validator`, so their 400 body is the validator's own error object
rather than `invalid_request`.

Rate limits are per client IP: 20 requests a minute on `/v1/auth/*`, and 10 a
minute shared by `POST /v1/invites/redeem` and `POST /v1/team-invites/accept`.

`GET /healthz` returns `{ "ok": true }` with no auth.

## Credentials

| Credential                 | How a phone gets it                                                  | Used for                                                                    |
| -------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Session token              | `POST /v1/auth/session` after Google sign-in                         | `/v1/me`, `/v1/teams/...`, `/v1/youtube/...`, `/v1/team-invites/accept`     |
| Match `score` credential   | Creating a match, joining as `score`, or redeeming a match join code | Scoring commands for that match                                             |
| Match `capture` credential | Joining as `capture` (the filming phone)                             | Recording reports, the SRT publish URL, and match join codes for that match |

Session tokens are long-lived until revoked. D1 stores only their SHA-256 hashes.
Match credentials are scoped to one match and one device ID, and any match
credential can read that match.

## Sign-in

Sign-in is a server redirect with a ticket and a verifier. The app makes a random
`verifier` (43–128 characters of `A-Z a-z 0-9 . _ ~ -`) and sends
`challenge = base64url(SHA-256(verifier))`.

1. The app opens `GET /v1/auth/google/start?challenge=<challenge>` in
   `ASWebAuthenticationSession`. Optional `invite=<team invite code>` joins that
   team at sign-in. The response is a 302 to Google.
2. Google returns to `GET /v1/auth/google/callback`, which redirects to
   `scorebug://auth?status=<status>[&ticket=<ticket>]`. `status` is `ok`,
   `cancelled` or `error`. A ticket comes only with `ok`; it is
   single use and expires after 2 minutes. The signed state expires after 10
   minutes.
3. `POST /v1/auth/session`
   `{ "ticket": "…", "verifier": "…", "deviceName": "JD's iPhone" }` (`deviceName`
   optional) → `200 { token, person, serverTime }`. A wrong, used or expired ticket,
   or a verifier that does not match, gets `401 ticket_invalid`.

`person` is `{ id, email, name, picture }`.

`DELETE /v1/auth/session` revokes the bearer session → `204`.

Any Google account with a verified email signs in; an unverified one gets
`error`. At sign-in the person joins every team with a live invite bound to
their email, and the team of the `invite` passed at start when it is live and
not bound to another email.

`/admin` is a server-rendered page for the emails in `ADMIN_EMAILS`. It signs in
through the same callback (`purpose=admin`) with a cookie-held verifier, stores
nothing for an account that is not an admin, and lists every team.

## Me

`GET /v1/me` (session) →

```json
{
    "person": { "id": "…", "email": "…", "name": "…", "picture": "…" },
    "teams": [{ "id": "…", "name": "…", "shortName": "…", "color": "#2563EB", "role": "owner" }],
    "serverTime": "…"
}
```

## Teams

All team routes need a session token. Non-members get `404 team_not_found`;
members calling an owner route get `403 owner_required`.

| Method | Path                                  | Who            | Body                                | Response                                        |
| ------ | ------------------------------------- | -------------- | ----------------------------------- | ----------------------------------------------- |
| POST   | `/v1/teams`                           | anyone         | `{ name, shortName?, color? }`      | `201 { team, role: "owner" }`                   |
| GET    | `/v1/teams/:teamId`                   | member         |                                     | `{ team, role, members, youtube, invites? }`    |
| PATCH  | `/v1/teams/:teamId`                   | owner          | any of `name`, `shortName`, `color` | `{ team }`                                      |
| PUT    | `/v1/teams/:teamId/youtube`           | owner          | `{ connectionId: uuid \| null }`    | `{ youtube }`; `404 connection_not_found`       |
| DELETE | `/v1/teams/:teamId/members/:personId` | self, or owner |                                     | `204`; `404 member_not_found`; `409 last_owner` |

- `team` is `{ id, name, shortName, color, createdAt }`. `name` is 1–80 characters,
  `shortName` (the scorebug label) at most 8 characters and defaults from the name,
  `color` is `#RRGGBB` and defaults to `#2563EB`.
- `members` is `[{ personId, name, email, role }]`. `invites` is included for owners
  only.
- `youtube` is the team's channel or `null`:
  `{ connectionId, channelTitle, channelThumbnail, status, connectedBy }`.
  `connectedBy` is the person ID of the owner whose connection it is.
- `PUT /youtube` accepts only one of the caller's own connections.
- Removing a member also revokes their email-bound invites to that team, so their
  next sign-in does not add them back. A team never loses its last owner.

### Team invites

| Method | Path                                  | Who     | Body                         | Response                                                            |
| ------ | ------------------------------------- | ------- | ---------------------------- | ------------------------------------------------------------------- |
| POST   | `/v1/teams/:teamId/invites`           | owner   | `{ email?, expiresInDays? }` | `201 { invite, code, link }`; `409 invite_limit`                    |
| DELETE | `/v1/teams/:teamId/invites/:inviteId` | owner   |                              | `{ invite }`; `404 invite_not_found`                                |
| POST   | `/v1/team-invites/accept`             | session | `{ code }`                   | `{ team, role }`; `404 invite_invalid`; `403 invite_email_mismatch` |

- `invite` is `{ id, teamId, email, createdAt, expiresAt, revokedAt }`.
- `code` is 8 characters shown as `ABCD-EFGH`; `link` is
  `https://scorebug.live/invite/ABCDEFGH`. The code is shown only in the create
  response. D1 stores a keyed hash.
- `expiresInDays` is 1–30, default 14. A team has at most 50 live invites.
- With `email`, only that Google account can use the invite, and it is accepted
  automatically when that person signs in. Without it, anyone with the code can join
  until it expires or is revoked.
- Codes use `23456789ABCDEFGHJKMNPQRSTVWXYZ`. Accepting ignores case, spaces and
  dashes.

## YouTube channels

Connections belong to the person who made them. All routes need a session token.

1. `POST /v1/youtube/connect` → `{ url }`. The app opens `url` in
   `ASWebAuthenticationSession`. Google asks for the `youtube` scope with offline
   access.
2. Google returns to `/v1/auth/google/callback`, which redirects to
   `scorebug://auth?purpose=youtube&status=<status>[&ticket=<ticket>]`. `status` is
   `ok`, `cancelled`, `scope_denied` (the YouTube box was unticked) or `error`. The
   ticket expires after 10 minutes.
3. `POST /v1/youtube/connections` `{ ticket }` → `201 { connection }`. The server
   reads the channel, checks that live streaming is enabled, and creates (or keeps)
   the connection's reusable `liveStream`. A wrong or expired ticket gets
   `404 ticket_invalid`.

| Method | Path                                | Response                               |
| ------ | ----------------------------------- | -------------------------------------- |
| GET    | `/v1/youtube/connections`           | `{ connections }`                      |
| POST   | `/v1/youtube/connections/:id/check` | `{ connection }`, re-read from YouTube |
| DELETE | `/v1/youtube/connections/:id`       | `204`; `404 connection_not_found`      |

`connection` is
`{ id, channelId, channelTitle, channelThumbnail, status, createdAt, updatedAt }`.
`status` is `ready`, `live_disabled` (YouTube's live streaming is not enabled yet)
or `needs_reconnect` (the refresh token stopped working). Refresh tokens and the
stream key never leave the server.

YouTube failures map to `409 youtube_needs_reconnect`, `409 youtube_no_channel`,
`503 youtube_quota` or `503 youtube_unavailable`.

## Matches

Each team's matches live in its team object. There are two ways in:

- **Member routes**, `/v1/teams/:teamId/matches/...`, with a session token. The
  Worker checks membership and forwards to the team object as that member.
- **Match-token routes**, `/v1/matches/:id/...`, with a match credential. The Worker
  finds the team through `match_index`; an unknown match gets `404 match_not_found`.

| Method | Path                                  | Auth             | Response                                    |
| ------ | ------------------------------------- | ---------------- | ------------------------------------------- |
| POST   | `/v1/teams/:teamId/matches`           | member           | `201 { snapshot, credential, serverTime }`  |
| GET    | `/v1/teams/:teamId/matches/active`    | member           | `{ snapshot \| null }`                      |
| POST   | `/v1/teams/:teamId/matches/:id/join`  | member           | `{ credential, snapshot }`                  |
| GET    | `/v1/matches/:id`                     | match credential | `{ snapshot, youtube }`                     |
| POST   | `/v1/matches/:id/commands`            | `score`          | `CommandOutcome`, 200 if accepted, else 409 |
| GET    | `/v1/matches/:id/commands/:commandId` | `score`          | `CommandOutcome`; `404 command_not_found`   |

### Creating and joining

`POST /v1/teams/:teamId/matches`:

```json
{
    "id": "<client-chosen ID>",
    "deviceId": "<this phone>",
    "teams": {
        "home": { "name": "Team 1", "shortName": "T1", "color": "#2563EB" },
        "away": { "name": "Team 2", "color": "#DC2626" }
    },
    "rules": {
        "bestOf": 3,
        "pointsToWin": 25,
        "decidingPointsToWin": 15,
        "winBy": 2,
        "pointCap": null
    },
    "scorebugStyle": "bar",
    "recordOnly": false
}
```

- `id` and `deviceId` are 1–128 characters of `A-Z a-z 0-9 _ -`; `id` may not be
  `active`.
- `teams.home` is team 1 and `teams.away` is team 2. `shortName` is at most 8
  characters and defaults to the first 8 of the name.
- `bestOf` is 3 or 5. `pointCap` is `null` or at least both set targets.
- `scorebugStyle` is `bar` (default), `lowerThird` or `setCard`.
- `recordOnly: true` makes a match with no broadcast; a later start command is
  refused. Otherwise the match streams to the team's YouTube channel.
- Unknown fields get `400`.
- The response's `credential` is a `score` credential for `deviceId`.

Errors: `409 match_id_taken` (another team holds the ID), `409 match_in_flight`
(the team already has an active match), `409 match_id_reused`. Retrying a create
with the same ID from the same team is safe.

`POST /v1/teams/:teamId/matches/:id/join` `{ deviceId, role: "score" | "capture" }`
issues a match credential. Joining as `capture` also creates the match's Stream
input ahead of Go Live.

### Scoring commands

`POST /v1/matches/:id/commands`:

```json
{
    "commandId": "<unique per command>",
    "gameId": "<match ID>",
    "deviceId": "<credential's device>",
    "expectedRevision": 12,
    "scorerEpoch": 1,
    "issuedAt": "2026-11-15T20:00:00.000Z",
    "operation": { "type": "award_point", "side": "home" }
}
```

Operations:

| `type`               | Fields                                     |
| -------------------- | ------------------------------------------ |
| `award_point`        | `side`: `home` (team 1) or `away` (team 2) |
| `undo`               |                                            |
| `end_set`            | `winner?`, `overrideReason?`               |
| `end_match`          | `reason`                                   |
| `take_over`          | (become the scorer)                        |
| `set_scorebug_style` | `style`                                    |

The outcome is `{ commandId, accepted, error, snapshot }`. `gameId` and `deviceId`
must match the credential (else `403 forbidden`). A retry of the same `commandId`
replays its first outcome, and `GET /v1/matches/:id/commands/:commandId` looks it
up after a lost response. Only the current scorer can score; another device sends
`take_over` with the snapshot's `scorer.epoch` first.

### Snapshot

`MatchSnapshot` (`packages/protocol/src/matches.ts`) has `id`, `createdAt`,
`revision`, `teams`, `rules`, `score`, `completedSets`, `status` (`active` or
`ended`), `endReason`, `canUndo`, `scorer: { deviceId, epoch }`,
`broadcast: { desired, generation }`, `scorebugStyle`, `pendingSetEnd` and `output`.

- `pendingSetEnd: { winner } | null` is set when the current set is won under the
  rules. The apps prompt the scorer to confirm with `end_set`. Further points stay
  allowed and recompute it.
- `output: { recordOnly }`.

`GET /v1/matches/:id`, `GET /v1/matches/:id/media/status`
and media command responses add `youtube`: the match's broadcast,
`{ broadcastId, watchUrl, channelTitle, channelThumbnail, privacy: "unlisted" }`,
or `null` before the first Go Live. The link does not change for the life of the
match.

## Match join codes

A team member or the match's `capture` device mints a code so other phones can
score without an account.

| Method | Path                                    | Auth                | Response                                |
| ------ | --------------------------------------- | ------------------- | --------------------------------------- |
| POST   | `/v1/teams/:teamId/matches/:id/invites` | member              | `201 { invite, code, link, expiresAt }` |
| POST   | `/v1/matches/:id/invites`               | `capture`           | same                                    |
| GET    | `.../invites`                           | member or `capture` | `{ invites }` (no codes)                |
| DELETE | `.../invites/:inviteId`                 | member or `capture` | `{ invite }`; `404 invite_not_found`    |
| POST   | `/v1/invites/redeem`                    | none                | `{ credential, snapshot, serverTime }`  |

- Create body: optional `{ "expiresInMinutes": 1-1440 }`, default 6 hours. At most
  16 live codes per match; more gets `409 invite_limit`. An ended match gets
  `410 match_ended`.
- `invite` is `{ id, gameId, createdAt, expiresAt, revokedAt, redemptions }`.
- `code` is 6 characters shown as `K7P-4QX`; `link` is
  `https://scorebug.live/join/K7P4QX`. The code appears only in the create response.
- Codes are multi-use until they expire, are revoked, or the match ends. Revoking a
  code also removes the `score` credentials handed out through it.
- `POST /v1/invites/redeem` `{ "code": "k7p 4qx", "deviceId": "…" }` returns a
  `score` credential. Redeeming again from the same device returns the same
  credential. The new device is not the scorer until it sends `take_over`.
- Redeem errors: `404 invite_invalid` (no live code), `410 invite_expired`,
  `410 invite_revoked`, `410 match_ended`, `409 device_id_taken` (the device ID
  already holds another credential for this match).

## Media and broadcast

| Method | Path                                                      | Auth             | Response                                                               |
| ------ | --------------------------------------------------------- | ---------------- | ---------------------------------------------------------------------- |
| GET    | `/v1/matches/:id/media`                                   | match credential | `{ snapshot: MediaSnapshot }`                                          |
| GET    | `/v1/matches/:id/media/status`                            | match credential | `{ status, youtube }`                                                  |
| POST   | `/v1/matches/:id/media/recordings`                        | `capture`        | `{ recording }`                                                        |
| POST   | `/v1/matches/:id/media/publish`                           | `capture`        | `{ gameId, generation, recordingId, publishUrl, publishingAttemptId }` |
| POST   | `/v1/teams/:teamId/matches/:id/media/commands`            | member           | `BroadcastOutcome`, 200 if accepted, else 409                          |
| GET    | `/v1/teams/:teamId/matches/:id/media/commands/:commandId` | member           | `BroadcastOutcome`; `404 command_not_found`                            |

`MediaSnapshot` is `{ gameId, recordings, broadcast: { desired, generation, selection } }`.

**Recordings.** `POST .../media/recordings`
`{ recordingId, sequence, status: "recording" | "stopped" | "interrupted", startedAt }`
reports the phone's local recording. It never changes scoring.

**Go Live and stop.** `POST .../media/commands`:

```json
{
    "commandId": "…",
    "gameId": "…",
    "expectedGeneration": 0,
    "issuedAt": "…",
    "operation": {
        "type": "start",
        "selection": { "captureDeviceId": "…", "recordingId": "…" }
    }
}
```

or `"operation": { "type": "stop" }`. `selection` names only the capture device and
its recording; the server fills in the worker (`match`) and output (`youtube`), and
the snapshot's `selection` carries all four.
`expectedGeneration` must be the current `broadcast.generation`. A retry of the
same `commandId` replays its first outcome.

Before a start is accepted, the team object prepares YouTube, Stream and a
live slot. If it cannot, it answers `409` with
`{ commandId, accepted: false, error, snapshot, youtube }` and records nothing, so
a retry can succeed. `error` is one of:

| Error                     | Meaning                                                    |
| ------------------------- | ---------------------------------------------------------- |
| `youtube_not_set`         | The team has no YouTube channel                            |
| `youtube_needs_reconnect` | The channel's owner must connect it again                  |
| `youtube_live_disabled`   | Live streaming is not enabled on the channel               |
| `youtube_unavailable`     | A YouTube API call failed                                  |
| `stream_unavailable`      | The Stream input could not be created                      |
| `container_unavailable`   | The runtime has no container                               |
| `busy`                    | `LIVE_MATCH_CAP` matches are already live across all teams |
| `time_limit`              | The match passed its 4-hour live limit                     |

**Publish URL.** `POST .../media/publish`
`{ recordingId, generation, publishingAttemptId }` returns
`{ gameId, generation, recordingId, publishUrl, publishingAttemptId, serverTime }`.
`publishingAttemptId` is required: a lowercase UUID the phone makes for each publishing
attempt, echoed back so the phone can match the URL to its attempt. `publishUrl` is
the SRT URL of the match's Stream live input, with its stream ID and passphrase.
It answers `403 capture_not_selected` if this device and recording are not the
selected capture, `409 broadcast_changed` if the broadcast stopped or moved to
another generation, and `503 stream_unavailable` if the Stream input could not be
created.

**Status.** `GET .../media/status`:

```json
{
    "status": {
        "gameId": "…",
        "generation": 3,
        "workerId": "match",
        "phase": "live",
        "output": { "width": 1920, "height": 1080, "fps": 30, "bitrateKbps": 6000 },
        "state": "producing_output",
        "observation": {
            "gameId": "…",
            "generation": 3,
            "state": "producing_output",
            "reason": null,
            "attempt": 1,
            "frame": 1800,
            "outTimeUs": 60000000,
            "scoreRevision": 12
        },
        "observedAt": "2026-11-15T20:00:00.000Z",
        "expiresAt": "2026-11-15T20:00:05.000Z"
    },
    "youtube": null,
    "serverTime": "2026-11-15T20:00:00.400Z"
}
```

`phase` is what the app shows: `idle` (no broadcast requested), `starting`, `live`,
`reconnecting` (the worker is stopping or restarting FFmpeg, for example after the
phone's video dropped) or `error` (failed, or no report for five seconds). `state` and
`observation` are the worker's detailed state; `state` can also be
`not_requested`, `unknown` (no report yet) or `stale`. Status is held in memory,
so it reads `starting` after a restart until the next report.

## Worker endpoints

The broadcast worker uses these. They are not public: the
match container reaches them only at `http://api.internal/v1/worker/...`, an
outbound intercept that forwards to its own team object. The container's bearer is
a fixed placeholder; the intercept is the authentication. The worker ID is
`match` and the output ID is `youtube`.

| Method | Path                              | Body or query                                    | Response                         |
| ------ | --------------------------------- | ------------------------------------------------ | -------------------------------- |
| POST   | `/v1/worker/sessions`             | `{ workerId, runId }`                            | `{ sessionId, serverTime }`      |
| POST   | `/v1/worker/observations`         | `{ workerId, sessionId, sequence, observation }` | `{ accepted: true, serverTime }` |
| GET    | `/v1/worker/snapshot?workerId=`   |                                                  | `{ assignment }`                 |
| GET    | `/v1/worker/connection?workerId=` |                                                  | `{ connection }`                 |

- A new `runId` for the same worker retires the old session; its reports get
  `409 worker_session_retired`. `409 worker_session_unknown` means register again.
  Reports for another match or generation get `409 broadcast_changed`.
- `observation` is
  `{ gameId, generation, state, reason, attempt, frame, outTimeUs, scoreRevision, output? }`,
  with `output` as `{ width, height, fps, bitrateKbps }`.
- `assignment` is the match, its media state and `output: { publishUrl }`, or `null`.
  `publishUrl` is the YouTube RTMPS ingest with its stream key. There is an
  assignment only while this worker's broadcast runs and the match has its YouTube
  broadcast.
- `connection` is `{ gameId, generation, readUrl }` or `null`. `readUrl` is the
  Stream input's RTMPS playback URL.

# Hosted Go Live: YouTube channels, Stream, match container

Build-order steps 2 and 4 of `docs/superpowers/specs/2026-11-16-hosted-cloudflare-design.md`,
with the tuning from `2026-11-16-stream-container-spike-results.md`. Built and tested in one
pass; this file records the layout and the API contract the iPhone app uses.

## Layout

| Piece                                                                  | File (`apps/control-plane/src/worker/`)           |
| ---------------------------------------------------------------------- | ------------------------------------------------- |
| YouTube Data API adapter                                               | `youtube.ts`                                      |
| Stream live input adapter                                              | `stream.ts`                                       |
| Adapter factory, test hook, container interface                        | `media-adapters.ts`                               |
| Connections, grants, team channel, live slots (D1)                     | `channels.ts`, `migrations/0002_youtube_live.sql` |
| Refresh-token and ingest encryption (AES-GCM, HKDF of `SERVER_SECRET`) | `secret-box.ts`                                   |
| Connect routes and the callback leg                                    | `youtube-routes.ts`                               |
| Go Live lifecycle and guards, in the team object                       | `hosted-media.ts`                                 |
| Team object wiring, container, worker API over RPC                     | `team-object.ts`                                  |
| `http://api.internal/` intercept target                                | `worker-api.ts`                                   |
| Daily cron sweep                                                       | `sweep.ts`                                        |

The match container is the team object's own container (one active match per team, so at
most one container per team object). The worker image is `apps/home-daemon`, unchanged in
shape; the hosted tuning is env vars that default to the self-hosted behavior.

## API contract

All routes take the Scorebug session token (`Authorization: Bearer …`) unless noted.
Errors are `{ "error": "<code>" }`.

### Connect a channel

1. `POST /v1/youtube/connect` → `{ url, serverTime }`. Open `url` in
   `ASWebAuthenticationSession` (callback scheme `scorebug`). Google asks for the account,
   then the channel, then the `youtube` scope (offline, consent).
2. The session ends at `scorebug://auth?purpose=youtube&status=<status>[&ticket=<ticket>]`.
   `status` is `ok` (with `ticket`), `cancelled`, `scope_denied` (the YouTube box was
   unticked) or `error`.
3. `POST /v1/youtube/connections` `{ "ticket": "<ticket>" }` → `201 { connection }`.
   The ticket is single use, lasts 10 minutes and only the person who started step 1 can
   claim it (`404 ticket_invalid` otherwise). Other errors: `409 youtube_needs_reconnect`,
   `409 youtube_no_channel`, `503 youtube_unavailable` / `youtube_quota`.

`connection`:

```json
{
    "id": "uuid",
    "channelId": "UC…",
    "channelTitle": "Wildcats Volleyball",
    "channelThumbnail": "https://yt3…",
    "status": "ready | live_disabled | needs_reconnect",
    "createdAt": "…",
    "updatedAt": "…"
}
```

- `live_disabled`: the channel can't live stream yet (YouTube's 24-hour wait). Show that at
  setup. `POST /v1/youtube/connections/:id/check` re-checks → `{ connection }`.
- `GET /v1/youtube/connections` → `{ connections: [connection] }` (mine).
- `DELETE /v1/youtube/connections/:id` → 204. Teams that used it lose their channel.
- Reconnecting the same channel updates the existing connection (same `id`).

### Team channel

- `PUT /v1/teams/:teamId/youtube` `{ "connectionId": "<id>" | null }` (owner only, and only
  the owner's own connections) → `{ youtube }`. `403 owner_required`, `404 connection_not_found`.
- `GET /v1/teams/:teamId` now includes `youtube` for every member:

```json
{
    "connectionId": "uuid",
    "channelTitle": "Wildcats Volleyball",
    "channelThumbnail": "https://yt3…",
    "status": "ready | live_disabled | needs_reconnect",
    "connectedBy": "<personId>"
}
```

or `null` (no channel: Go Live disabled, filming and recording still work). With
`needs_reconnect`, owners see "YouTube needs reconnecting"; members see "Ask your team owner
to reconnect YouTube".

### Go Live and stop

Unchanged protocol, member-authenticated:
`POST /v1/teams/:teamId/matches/:id/media/commands` with the `BroadcastCommand`
(`operation: { type: "start", selection: { captureDeviceId, recordingId } }` or
`{ type: "stop" }`; `workerId`/`outputId` may be left out, the server fills them).

- Accepted: `200` `BroadcastOutcome` plus `youtube` (below). The first start creates the
  match's one broadcast; later starts reuse it.
- Refused before the store sees it: `409` with a `BroadcastOutcome` shape,
  `accepted: false`, and `error` one of `youtube_not_set`, `youtube_needs_reconnect`,
  `youtube_live_disabled`, `youtube_unavailable`, `stream_unavailable`, `busy` ("Scorebug is
  busy, try again shortly": the beta cap of 5 live matches), `time_limit` (the match hit the
  4-hour cap), `container_unavailable`. The generation does not change and nothing is
  recorded under the command ID, so the same command can be retried.
- Stop keeps the Stream input and the broadcast; the next start reuses both.
- Ending the match (scoring `end_match`, or the last set) tears everything down within
  seconds and ends the broadcast.

### Publish credential (the filming phone)

`POST /v1/matches/:id/media/publish` (match credential, role `capture`) — same request and
response as today:
`{ gameId, generation, recordingId, publishUrl, publishingAttemptId?, serverTime }`.
`publishUrl` is Stream's SRT URL:
`srt://live.cloudflare.com:778?passphrase=<…>&streamid=<…>`. **The stream ID is Stream's,
not `publish:scorebug-…:sbp1=…`**, so the app's `publishingAttemptId` stream-ID pattern
check must accept it (check the scheme, host and port only, and that
`publishingAttemptId` is echoed). Opening the film screen (`POST …/join` with role
`capture`) creates the Stream input in the background, so Go Live is quicker.

### Match broadcast fields

`GET /v1/matches/:id`, `GET /v1/teams/:teamId/matches/active`,
`GET /v1/matches/:id/media/status` and media command outcomes carry a top-level `youtube`:

```json
{
    "broadcastId": "abc123",
    "watchUrl": "https://www.youtube.com/watch?v=abc123",
    "channelTitle": "Wildcats Volleyball",
    "channelThumbnail": "https://yt3…",
    "privacy": "unlisted"
}
```

or `null` before the first Go Live. The link never changes within a match.

## Guards

- While live, every 30 s: renew the container's inactivity timeout (5 min) and the live slot.
- 4-hour cap from the first Go Live: stop, end the broadcast, delete the input; Go Live
  afterwards is refused with `time_limit`.
- Idle: no worker output for 10 minutes destroys the container and frees the slot. The
  alarm polls the Stream input every 30 s; when the phone's video is back (or the phone asks
  for its publish URL again) the container starts on its own.
- A crashed container restarts on the next alarm.
- Daily cron (`17 10 * * *`): every team with a slot, a recent match or a Stream input runs
  its guards and stops an orphaned container; Stream inputs named `scorebug:<team>:<match>`
  that no open match uses are deleted. Orphans are logged as errors.
- Beta cap: `LIVE_MATCH_CAP` (5) fresh rows in `live_slots`, claimed in one conditional
  insert.

## Worker (home-daemon) tuning, set by the team object

`SCORE_DELAY_MS=1100`, `INPUT_PROBE=fast` (`-probesize 2000000 -analyzeduration 2500000`),
`INPUT_READ_TIMEOUT_MS=4000` (`-rw_timeout`), `OUTPUT_TIMEOUT_MS=15000`,
`RETRY_MAX_ATTEMPTS=6`, `RETRY_FREE_AFTER_MS=3000` (an attempt that ran 3 s or more doesn't
use up the crash budget). Defaults keep the self-hosted worker as it was.

## Not verified here

Nothing was deployed. The real YouTube and Stream adapters and the container start are
covered by types and the spike's measurements, not by tests against the live services:
verify Go Live end to end on `scorebug.live` after the deploy.

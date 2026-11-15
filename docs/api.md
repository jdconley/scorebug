# Scorebug API (phone setup, invites, destinations, scoring)

The control plane is the HTTPS API behind Caddy. Every response is JSON with
`Cache-Control: no-store`. Authenticated requests send
`Authorization: Bearer <token>`. Types live in `packages/protocol`
(`setup.ts`, `matches.ts`).

This page covers phone setup, match invites, streaming destinations and the
scoring helpers. Media and worker endpoints are described in the code
(`apps/control-plane/src/routes/media.ts`).

## Credentials

| Credential           | How a phone gets it                       | Can                                                                                                          |
| -------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **Owner device**     | Redeem a one-time setup link              | Create matches, join them as `score`/`capture`, start/stop broadcasts, manage destinations, devices, invites |
| Legacy `PHONE_TOKEN` | Typed into older app versions             | Same as an owner device. Kept until the redesigned app ships; then retire it                                 |
| Match `capture`      | `POST /v1/matches/:id/join` (owner)       | Report recordings, publish SRT, mint/list/revoke invites for that match                                      |
| Match `score`        | Creating the match, joining, or an invite | Send scoring commands and take over scoring for that match only                                              |

Owner device tokens are long-lived and revocable. The server stores only
SHA-256 hashes of tokens and keyed hashes (HMAC) of setup and invite codes.

## Links

```
scorebug://connect?server=<https-url>&code=<setup-code>
scorebug://join?server=<https-url>&code=<invite-code>
```

Query values are percent-encoded (`server=https%3A%2F%2Fscorebug.example.com`).
`server` is the API base URL (`PUBLIC_URL`, set by `infra/install.sh`). Setup
codes are 24 URL-safe characters. Invite codes in links are six characters
without the dash.

## Phone setup

**Mint a link** (server admin, inside the API container):

```bash
docker compose -f infra/vps/docker-compose.yml exec control-plane \
  node apps/control-plane/dist/cli.js setup-link
```

It prints a QR code and the link. `infra/install.sh phone` does the same. Other
CLI commands: `devices`, `revoke-device ID`, `destinations`.

`POST /v1/setup/links` (owner) → `201 { code, link, expiresAt }`. Optional body
`{ "expiresInHours": 1-720 }`, default 24. Lets one owner phone add another.

**Redeem** — `POST /v1/setup/redeem` (no auth, rate-limited)

```json
{ "code": "…24 chars…", "deviceId": "<uuid>", "deviceName": "JD's iPhone" }
```

→ `200 { device, token, serverTime }`. `device` is
`{ id, name, role: "owner", createdAt, lastSeenAt, revokedAt }`. Codes are single
use. If the response is lost, repeating the same request with the same
`deviceId` within 10 minutes returns the same token.

Errors: `400 invalid_request`, `401 setup_code_invalid`, `409 setup_code_used`,
`409 device_id_taken`, `410 setup_code_expired`, `429 rate_limited` (with
`Retry-After`).

**Devices** (owner)

- `GET /v1/devices` → `{ devices: Device[] }`
- `GET /v1/devices/me` → `{ role: "owner", legacy, device }` (check a stored token)
- `DELETE /v1/devices/:id` → `{ device }` with `revokedAt` set. Takes effect on
  the next request.

## Match invites

An owner device (or the match's `capture` device, i.e. the filming phone) mints
an invite for other phones at the game.

`POST /v1/matches/:id/invites` → `201`

```json
{
    "invite": {
        "id": "…",
        "gameId": "…",
        "createdAt": "…",
        "expiresAt": "…",
        "revokedAt": null,
        "redemptions": 0
    },
    "code": "K7P-4QX",
    "link": "scorebug://join?server=https%3A%2F%2Fscorebug.example.com&code=K7P4QX",
    "expiresAt": "…"
}
```

Optional body `{ "expiresInMinutes": 1-1440 }`; default 6 hours. Invites are
multi-use and stop working when they expire, are revoked, or the match ends.
At most 16 live invites per match. The code is shown only in this response.

- `GET /v1/matches/:id/invites` → `{ invites: MatchInvite[] }` (no codes)
- `DELETE /v1/matches/:id/invites/:inviteId` → `{ invite }`. Also removes the
  `score` credentials handed out through that invite.

Codes use `23456789ABCDEFGHJKMNPQRSTVWXYZ` (no 0/O, 1/I/L, U). Redemption
ignores case, spaces and dashes.

**Redeem** — `POST /v1/invites/redeem` (no auth, rate-limited)

```json
{ "code": "k7p 4qx", "deviceId": "mom-iphone" }
```

→ `200 { credential, snapshot, serverTime }` where `credential.role` is
`score`. Redeeming again from the same device returns the same credential.
The new scorer is not the current scorer: send `take_over` (with the
snapshot's `scorer.epoch`) before scoring. The usual epoch rules apply to
several scorers.

Errors: `400 invalid_request`, `401 invite_invalid`, `409 device_id_taken` (the
device ID already holds a non-invite credential for this match), `410
invite_expired | invite_revoked | match_ended`, `429 rate_limited`. Error
bodies never include a snapshot.

Rate limits (both redeem endpoints, per API process): 10 attempts per client
address per minute, and 100 failed attempts per 10 minutes across all clients.

## Destinations

Named RTMP(S) targets such as a YouTube channel. Owner only. The stream key is
write-only: responses carry only its last four characters (none for keys
shorter than 8), and it is never logged.

```json
{
    "id": "…",
    "name": "YouTube",
    "rtmpUrl": "rtmps://a.rtmp.youtube.com/live2",
    "streamKeyLast4": "qrst",
    "isDefault": true,
    "createdAt": "…",
    "updatedAt": "…"
}
```

- `GET /v1/destinations` → `{ destinations }`
- `POST /v1/destinations` `{ name, rtmpUrl, streamKey, isDefault? }` → `201 { destination }`.
  The first destination becomes the default.
- `GET /v1/destinations/:id` → `{ destination }`
- `PATCH /v1/destinations/:id` with any of the create fields → `{ destination }`
- `DELETE /v1/destinations/:id` → `{ deleted: true }`; `409 destination_in_use`
  while the active match streams to it.

`rtmpUrl` must be `rtmp://` or `rtmps://` without credentials, query or
fragment. `streamKey` is printable ASCII without spaces, quotes or
backslashes (query strings such as Facebook's are fine). The worker publishes to
`<rtmpUrl>/<streamKey>`.

`infra/install.sh` saves the YouTube URL it asks for as the default destination
named "YouTube" on first install.

## Creating a match

`POST /v1/matches` (owner) accepts, in addition to `id`, `deviceId`, `teams`,
`rules` and `scorebugStyle`:

- `destinationId` — stream to this destination; or
- `recordOnly: true` — no broadcast; starting one is refused with
  `record_only_match`.

With neither, the match uses the default destination, or, if there is none, the
worker's own `OUTPUT_URL`. Both together → `400`; an unknown destination →
`409 destination_not_found`.

Team `shortName` (the scorebug label) is at most 8 characters and optional; it
defaults to the first 8 characters of the team name.

## Snapshot fields

`MatchSnapshot` adds:

- `pendingSetEnd: { winner: "home" | "away" } | null` — the current set is won
  under the rules (25 points, 15 in the deciding set, win by 2, optional point
  cap). Phone and Watch prompt the scorer to confirm; `end_set` confirms. Points
  after set point stay allowed and recompute it (25-24 clears it). Null when the
  match is decided or ended.
- `output: { destinationId: string | null, recordOnly: boolean }`.

## Worker

`GET /v1/worker/snapshot` (worker token) adds `assignment.output`:
`{ destinationId, publishUrl }`. `publishUrl` includes the stream key;
`null` tells the worker to use its `OUTPUT_URL`.

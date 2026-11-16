# Hosted Scorebug on Cloudflare

Status: draft for JD's approval, 2026-11-16.

## Why

Self-hosting is too much work to set up: you run an install script on a VPS,
print a QR code or link, and pair the phone with it. JD wants Scorebug to be a
hosted service instead. You sign in on the phone, and from then on you open
the app and go live. Nothing should run, or cost money, between matches.

JD wants to invite other volleyball teams soon. Scorebug opens as a free
private beta: JD adds each person by email before they can get in. Later,
teams can pay to stream so the service covers its own costs.

## Goals

- First run on a new phone: install, tap **Sign in with Google**, done. No
  server address, QR code, link or stream key, ever.
- Teams: a team has members who can see its active matches and score them
  from their own phones. A scorer can also join one match with a code and no
  account.
- Each team streams to the YouTube channel its owner picks: the owner's own
  channel or the team's channel. JD streams all his kids' teams to his own
  channel. Other teams have channels of their own.
- Every match: create it, film, tap **Go Live**. The backend is ready without
  the user doing anything.
- Pay only while a match is streaming, apart from small fixed platform plans.
- A verified Google app, so other teams see no "unverified app" warning and
  there's no 100-user cap.
- Keep what works today:
    - local recording on the phone, which never depends on the network;
    - scoring on the filming phone, the Watch or a second phone;
    - the score burned into the video;
    - YouTube as the destination.

## Non-goals (for now)

- Payments, plans and billing. The beta is free. The design must not block
  payments later: teams are the natural thing to bill.
- Public sign-up. Every person is added by JD (or, for members, invited by
  a team owner JD has added).
- Self-hosting. The install script, the VPS deployment and the home worker go
  away. The repo stays open source.
- Multiple cameras, sub-second latency, destinations other than YouTube, an
  in-app viewer.

## Anti-goals

- An onboarding step that needs a computer, a terminal, a copied value or a
  second device.
- Something left running after a match that keeps billing (a forgotten
  container or Stream input).
- A YouTube connection that silently expires and fails at the gym.
- Losing the local recording, or making it depend on the cloud.
- One team seeing or changing another team's matches.

## Constraints

- One person runs it. No servers to patch, no pager.
- Cloudflare Containers receive traffic only through a Worker and Durable
  Object, as HTTP or WebSocket. A phone cannot send SRT (UDP) or RTMP to a
  container. Containers can make outbound connections, including raw TLS
  (RTMPS) on any port.
- Containers top out at 4 vCPU and 12 GiB, with no GPU, so encoding is x264 on
  CPU.
- Google verification of the YouTube scope (a "sensitive" scope) needs a
  public home page, a privacy policy and terms on a verified domain, a demo
  video and a written justification. Review takes days to weeks.
- YouTube Data API default quota is 10,000 units a day. Each broadcast call
  costs about 50, so roughly 50 matches a day before we need YouTube's
  compliance audit for more.
- A YouTube channel that has never streamed must enable live streaming first,
  and YouTube makes it wait 24 hours.

## Approaches considered

Accounts, sign-in and the YouTube calls run on a Cloudflare Worker in every
option. The options differ in where each match's video work runs.

1. **Worker + a Hetzner VM per match.** The Worker boots a VM from a snapshot
   holding today's relay and worker, and the phone streams straight to it.
   This reuses the whole tested media path and is the cheapest per hour. It
   takes about a minute to boot, is billed hourly, and needs a reaper for
   orphaned VMs.
2. **All Cloudflare: Stream for intake, a Container per match for
   processing.** Stream is always ready to receive SRT. The container pulls
   the feed, burns in the score and pushes to YouTube. One vendor, nothing to
   patch, starts in seconds. Unknowns: the extra hop, 1080p x264 on 4 shared
   vCPU, and how Stream behaves when the phone drops.
3. **Worker + a Fly.io Machine per match.** Like option 1, with second-level
   boot and billing. Adds a vendor, needs a dedicated IP for UDP, and costs
   more per hour.

Within option 2 there are two ways to get video into the container:

- **Stream as intake:** the phone keeps sending SRT, only to a different
  address. The container pulls it back from Stream.
- **HTTPS chunk upload through the Worker:** no Stream, but the phone's
  streaming code has to be rewritten, and it adds a few seconds of latency.

**Chosen (JD):** option 2, with Stream as intake.

**Reference:** Cloudflare's open-source [Streamline](https://github.com/cloudflare/streamline)
(Apache-2.0, [post](https://blog.cloudflare.com/streamline/)) runs this exact
shape: a Durable Object owns a per-session FFmpeg container, which pulls RTMPS
from a Stream Live input and pushes RTMPS out. We borrow its patterns:

- session lifecycle;
- renewing the activity timeout while a session is live, with a hard maximum
  duration;
- secrets kept in the Worker and injected by an outbound handler;
- direct RTMPS egress, which outbound interception can't proxy.

We don't use its Go media engine. Its overlays are PNG snapshots. Our worker
already renders the scorebug as a second FFmpeg input with frame-accurate
timing, and that overlay is the part of the product that's tested.

## Design

```text
iPhone ──SRT──▶ Cloudflare Stream live input (one per match)
                         │ RTMPS playback (pull)
                         ▼
             Match container (FFmpeg + scorebug) ──RTMPS──▶ team's YouTube channel
                         ▲ score + control (HTTP via outbound handler)
Phones ──HTTPS──▶ Worker (Hono) ──▶ Team Durable Object
Watch ◀──WatchConnectivity──▶ iPhone          │ starts/stops the container,
                                              ▼ Stream inputs, YouTube broadcasts
                     D1: people, teams, members, YouTube connections, invites
```

### People, access and teams

- **Signing in:** Sign in with Google through `ASWebAuthenticationSession`
  (OAuth 2.0 authorization code with PKCE), with no Google SDK. Scopes are
  `openid email profile` only, so a scorer never sees a YouTube prompt. The
  Worker gives the app a long-lived, revocable Scorebug session token, stored
  in the Keychain.
- **Private beta access (JD):** JD adds a person by email before they can get
  in. Anyone else who signs in sees "Scorebug is in private beta" with a way
  to ask JD for access.
    - **How JD adds people (my call):** an admin page at
      `scorebug.live/admin`, visible only to JD's account, with an email list
      and a "can create teams" flag. A Wrangler/D1 command does the same thing
      as a fallback.
    - **Team invites let members in (my call):** a team owner can invite people
      to their team by email or link. Accepting a team invite grants access to
      that team without JD adding the person. It doesn't let them create teams.
      So JD adds team owners, and owners bring their own parents and scorers.
- **Teams:**
    - Anyone JD has flagged can create a team: a name, and optionally colors and
      a short name for the scorebug.
    - One person can be on several teams, like a parent with two kids playing.
    - **Roles (my call):**
        - **Owner:** manages members, picks the team's YouTube channel, and can
          do everything a member can.
        - **Member:** sees the team's matches, creates matches, films and goes
          live to the team's channel, and scores.
    - A team has at most one active match at a time, the same rule as today's
      one active match per installation.
- **Scoring a team's match:** members see the team's active match in the app
  and tap to score it, with the usual take-over rules.
- **Scoring without an account:** match join codes and links still work for
  one match, as today, with no account needed. Links no longer carry a server
  address because it's always `scorebug.live`.

### YouTube channels

- **Connecting a channel:** a separate one-time step, only for people who set
  up a team's streaming. The app asks Google for the `youtube` scope with
  incremental authorization. If the Google account has several channels
  (personal plus Brand Accounts), Google's own consent screen asks which one.
  Each grant is one channel connection.
- **Connections belong to the person who connected them.** JD connects his
  personal channel once and points all his kids' teams at it. A club owner
  connects the club's channel and points their team at it. A person can hold
  several connections.
- **Per team setting:** the team owner picks one of their connections as the
  team's channel, and can change it. The Worker shows the channel name and
  picture so it's clear where streams go.
- **At connect:** the Worker checks that live streaming is enabled on the
  channel. If it isn't, the app says so plainly, including the 24-hour wait,
  at setup rather than at the gym. It also creates one reusable YouTube
  `liveStream` per connection and stores its ingest URL and key. The key
  never leaves the server.
- **Going live:** any member can film a team match, and it goes to the team's
  channel using the owner's connection. The filmer needs no YouTube setup.
- **At the first Go Live of a match:** the Worker creates a `liveBroadcast`
  on the team's channel, bound to that connection's stream. The title is
  "Team A vs Team B · Nov 16". Auto-start is on and auto-stop is off. The app
  shows the watch link to share.
- **One link per match (my call):** stopping and going live again, an app
  crash, or a long network drop all reuse the same broadcast, so the link
  never changes mid-match. The team object ends the broadcast explicitly when
  the match ends, or when the 4-hour cap or the daily sweep fires.
- **Defaults (my call):**
    - **Privacy:** unlisted, because these are kids' matches, and the app shares
      the link. A per-team privacy setting can come later.
    - **Made for kids:** set to "no". The video shows kids but isn't aimed at
      them.
- **If a connection stops working** (revoked grant, channel removed): the
  team shows "YouTube needs reconnecting" to its owner, and members see
  "Ask your team owner to reconnect YouTube" before Go Live. It never fails
  silently at the gym.
- **No team channel set:** Go Live is disabled with a clear reason. Filming
  and local recording still work.

### Google app verification

Done in parallel with the build, starting as soon as sign-in and channel
connection work end to end, because Google's review is the long pole:

- `scorebug.live` home page: what Scorebug is, "Private beta", a contact
  link, and links to the privacy policy and terms.
- Privacy policy and terms of service pages, covering YouTube API use and
  linking Google's privacy policy, as YouTube's API terms require.
- Domain verified in Google Search Console, under the OAuth app's project.
- A demo video of signing in, connecting a channel and going live, and a
  justification for the `youtube` scope.
- The Google Cloud project and OAuth client are set up under Conley Chaos
  LLC.
- Until Google approves, JD's own testing uses the app in Testing mode with
  test users, and its 7-day token expiry is accepted for that period.

### Control plane on Workers

- **The port:** the Hono app moves to a Worker. Routes and the
  `packages/protocol` contracts stay the same where they still apply:
  matches, scoring commands with IDs and revisions, take-over, media state,
  and worker status.
- **Storage:** today it's `node:sqlite`. It becomes:
    - **One Durable Object per team,** holding that team's matches, scoring and
      media state, using the Durable Object's synchronous SQLite API. The
      existing stores port almost line for line.
    - **D1** for everything that crosses teams: people (by Google `sub`),
      session tokens, the beta allowlist, teams, memberships and roles, YouTube
      connections (refresh tokens encrypted), team invites and match join
      codes. The Worker checks membership in D1, then routes to the team
      object.
- **Removed:** setup links, owner-device enrollment, destinations configured
  by the install script, and the MediaMTX management calls.

### Match lifecycle and media

1. **Open the film screen.** The team object creates a Stream live input
   for the match, with Stream recording off, and returns its SRT publish URL
   and passphrase. Starting this before Go Live hides the API round trips.
2. **Go Live:**
    - the phone starts sending SRT to Stream, which is always ready to receive;
    - the team object creates the YouTube broadcast if the match has none yet;
    - it starts the match container with the YouTube ingest URL and key, the
      Stream input's RTMPS playback URL, and the match ID.
3. **The container:**
    - **Input:** it pulls RTMPS from Stream, retrying until the feed exists.
    - **Score:** it fetches the score from `http://api.internal/...`, which an
      outbound handler sends straight to the team object. No token sits in the
      container.
    - **Output:** it runs today's pipeline and pushes RTMPS to YouTube directly.
    - **Status:** it reports to the team object about once a second, the same
      way the worker does today, so the app shows `starting`, `live`,
      `reconnecting` and `error` with resolution and bitrate.
4. **Stop streaming mid-match:** the team object drains and destroys the
   container. The Stream input and the YouTube broadcast stay, so the next
   Go Live in the same match reuses both. YouTube shows the stream as
   offline in the meantime.
5. **End of match:** the team object destroys the container, deletes the
   Stream live input, and ends the YouTube broadcast.
6. **Phone drops:** the container keeps reading and holds YouTube on the last
   frame or a short slate, depending on what the spike shows works. It
   reconnects when Stream gets the feed back, exactly as it does with the
   relay today.

**Teardown guards.** Nothing should keep billing:

- **While live:** the container's activity timeout is renewed, Streamline
  style.
- **Hard cap:** 4 hours per match.
- **Idle:** if no video has reached Stream for 10 minutes, the team object
  destroys the container. The match, the Stream input and the YouTube
  broadcast stay. When video reaches Stream again (a Stream webhook, or the
  phone's own reconnect calling Go Live), the container starts again on its
  own, so a long gym network outage recovers without a tap.
- **Daily sweep:** a scheduled Worker deletes any Stream input or container
  older than its match, and alerts.
- **Beta cost guard (my call):** a cap on concurrent live matches across all
  teams (start at 5), so a busy weekend can't run up JD's bill. Over the cap,
  Go Live says "Scorebug is busy, try again shortly" and local recording
  carries on.

### The match container image

- The image is today's `apps/home-daemon` worker, in a container image built
  by Wrangler.
- **Input:** it takes the RTMPS playback URL from Stream instead of the SRT
  relay URL.
- **Startup:** its config comes from container env vars instead of the
  polled assignment.
- **Encoder:** x264 `veryfast` with `zerolatency`, on `standard-4`.
  1080p30 is the target and 720p30 the fallback. The spike decides the
  default.
- **Dropped:** the NVENC and VideoToolbox paths stay in code but aren't used
  in production.

### iPhone app

- **First screen:** `ConnectView`, with QR scanning, server address entry and
  code entry, is replaced by a **Sign in with Google** screen. If the person
  isn't in the beta, it says so. After sign-in the app opens on Home.
- **Home:** the person's teams, each with its active match (if any) to score
  or film, and **New match** for that team. A person with one team sees that
  team straight away. "Join with a code" stays for scoring without an
  account.
- **Team screen (owner):** members and invites, and the YouTube channel
  setting with **Connect a channel**.
- **Fixed address:** the API base URL is fixed (`https://scorebug.live`), with
  an override in the debug menu for local development.
- **Go Live:** the phone gets the Stream SRT URL from the API, the same
  `publish` credential shape it gets now.
- **Unchanged:**
    - HaishinKit SRT publishing (the SRT URL format needs a check against
      Stream's `streamid` and `passphrase`);
    - local recording, scoring and the Watch.
- **Sign out:** a Settings row, which also revokes the session token.

### Web pages on scorebug.live

Served by the same Worker:

- the home page ("Private beta"), the privacy policy and the terms, needed
  for Google verification;
- team invite links (`scorebug.live/invite/...`), which open the app if it's
  installed and otherwise point to TestFlight while in beta;
- JD's admin page for the beta list.

### What gets removed

- `infra/install.sh`, `infra/vps`, `infra/worker`, `docs/self-hosting.md`;
  setup-link and owner-device code and docs; the `scorebug://connect` link
  type.
- `vendor/MediaMTX` stays only as the local and CI stand-in for Stream. It
  takes SRT in and serves RTMP reads, which is the same shape as Stream.
- CI's "Real SRT relay" job becomes "SRT intake → RTMP pull → worker →
  sink" against MediaMTX. The Docker job builds the container image. A new
  job runs the Worker tests in `@cloudflare/vitest-pool-workers`.

### Local development

- **Runtime:** `wrangler dev` runs the Worker, the Durable Objects, D1 and the
  container in local Docker.
- **Stand-ins:** a fake Stream adapter points at local MediaMTX, and a fake
  YouTube adapter points at the existing mock RTMP sink.
- **Wrapped dependencies:** Google OAuth and the YouTube and Stream APIs sit
  behind small interfaces, so tests use fakes and need no network.

### Costs (estimates; the spike confirms them)

| Item                                         | Cost              |
| -------------------------------------------- | ----------------- |
| Workers Paid plan (Containers, DOs, D1)      | $5/month          |
| Stream plan                                  | ~$5/month minimum |
| Container, standard-4, busy at 1080p         | ~$0.40/hour       |
| Stream delivery (the container's RTMPS pull) | ~$0.06/hour       |
| Container egress to YouTube (~3 GB/hour)     | cents             |
| **Typical 2-hour match**                     | **~$1**           |

That's about $10 a month fixed, plus about $1 per match for every team in
the beta, all on JD's bill while the beta is free. These numbers feed
pricing later.

## Phase 0: spike before building

The spike is throwaway. Its point is to prove the unknowns in option 2 before
anything is ported. The setup:

- send a real phone, or FFmpeg as a stand-in, over SRT to a Stream live input;
- the container pulls RTMPS from Stream, draws the score at 1080p30 with x264
  on `standard-4`, and pushes to an unlisted YouTube broadcast.

Measure:

1. **CPU headroom at 1080p30.** Pass if sustained below 80% with no dropped
   frames for 30 minutes. If not, check whether 720p30 passes.
2. **End-to-end latency** from phone to YouTube. A pass is under 30 seconds
   glass to glass, given YouTube's own buffering.
3. **Score lead.** How far the burned-in score runs ahead of the play on
   screen, now that Stream adds intake delay. A pass is within 1 second. If
   it runs further ahead, the worker delays score changes by the measured
   intake delay. The phone doesn't change for this.
4. **Phone drop behavior.** Kill the phone's feed for 10 seconds, 60 seconds
   and 5 minutes. Check that the container recovers and the YouTube broadcast
   (and its link) survives, or record exactly what breaks.
5. **Cold start,** from Go Live to the first frame on YouTube. A pass is
   under 30 seconds. Between 30 and 90 seconds, start the container when the
   film screen opens instead, capped at 15 minutes if Go Live never comes.
   Over 90 seconds counts as a failure.
6. **Actual costs** from the Cloudflare billing pages.

If 1, 4 or 5 fails, or latency is over 30 seconds, come back to JD with
option 1 or 3 before building.

## Build order after the spike

1. **Worker control plane:** people, Google sign-in, the beta allowlist and
   admin page, teams, memberships, invites, and the team Durable Object with
   ported matches and scoring, plus tests.
2. **YouTube channel connections,** Stream adapter, and the match lifecycle
   with teardown guards and the beta cost guard.
3. **Web pages and Google verification:** home, privacy, terms, domain
   verification, demo video, submit for review. Review runs in parallel with
   the steps below.
4. **Match container image** and the Durable Object container lifecycle.
5. **iPhone app:** sign in, teams on Home, the team screen, connecting a
   channel, the fixed server, and deleting the QR and setup flows.
6. **Remove self-hosting:** the infra, docs and CI changes. Deploy to
   `scorebug.live` and rewrite `docs/field-test.md` for the hosted service.

**Cutover (my call):** nothing self-hosted is deployed or in use, so there's
no feature flag. Old code is deleted as each step lands. The TestFlight build
already uploaded keeps working on its own until the hosted build replaces it.

**Deploys (my call):** GitHub Actions deploys the Worker and container image
to production on every merge to `main`, which matches the merge-on-green
rule. The Cloudflare API token and the Google, YouTube and Stream secrets
live as GitHub and Worker secrets. There's no staging environment until
there are other users, and Wrangler's version rollback is the undo.
`scorebug.live` serves nothing today, so the Worker takes the apex domain.

## Left to the builder

- Durable Object and D1 schemas, route shapes beyond what the protocol already
  defines, and token formats.
- Stream API details: per-match input creation, and RTMPS or SRT playback for
  the pull, whichever the spike finds more robust.
- How the container fetches the score: poll or WebSocket through the outbound
  handler.
- The slate or last-frame behavior during a phone drop.
- The look of the web pages and the admin page, following the app's style.
- Wrangler and project layout. The `apps/` directory names can change, for
  example `apps/home-daemon` to `apps/match-worker`.

## Calls I made (JD: check these)

- Team invites let people into the beta for that team only. JD adds team
  owners (people who can create teams) by email, on an admin page.
- Two roles: owner and member. Any member can film and go live to the team's
  channel.
- YouTube connections belong to the person who connected them. A team owner
  picks one of their own connections as the team's channel.
- Google sign-in asks only for identity. YouTube is a separate, later
  consent, so scorers never see it.
- YouTube broadcasts default to unlisted and not made for kids, titled with
  the team names and date. There's one broadcast and one link per match, with
  auto-stop off and an explicit end.
- A cap of 5 concurrent live matches across the beta, to bound JD's bill.
- One Stream live input per match, deleted afterward.
- An idle container is torn down after 10 minutes and restarts by itself when
  video comes back.
- MediaMTX stays only as the local and CI stand-in for Stream.
- 1080p30 is the target and 720p30 the fallback. The spike decides the
  default.
- Spike pass bars: latency under 30 seconds, score lead within 1 second, cold
  start under 30 seconds (or an early start up to 90).
- No cutover flag. Auto-deploy to production on merge, with no staging yet.

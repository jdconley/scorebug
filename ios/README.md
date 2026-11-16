# Scorebug iOS

One iPhone app (with an embedded Apple Watch app) for a parent who films and
scores alone. `Project.yml` (XcodeGen) builds:

- **Scorebug** — iPhone app. Dark, camera-first, no tabs.
- **ScorebugWatch** — Watch app. Mirrors the paired iPhone's open match.
- **ScorebugModelTests** — macOS unit tests for the view models, capture,
  streaming and recording (no simulator needed).
- **ScorebugAppUITests** — a screenshot tour of every screen (manual, below).

Swift packages: `ScorebugCore` (HTTP client, sign-in (PKCE, callback), teams, invite links, scoring outbox,
short names, court sides, set point, Watch protocol, quality ladder),
`ScorebugMedia` (capture, segmented archive, MP4 export), `ScorebugStreaming`
(SRT publisher). The iPhone baseline is iOS 17, the Watch watchOS 10.

## Flow

The app talks to the hosted service at `https://scorebug.live` (the Worker in
`apps/control-plane/src/worker`). Debug builds can point at another server from the
sign-in screen or Settings → Developer, or with `SCOREBUG_TEST_API_URL`.

1. **Sign in (first launch).** **Sign in with Google** opens
   `/v1/auth/google/start?challenge=…` in `ASWebAuthenticationSession` (PKCE: only the
   S256 challenge goes through the browser). The Worker sends the browser back to
   `scorebug://auth?status=ok&ticket=…`; the app trades the ticket and its verifier at
   `POST /v1/auth/session` for a session token kept in the Keychain. `not_in_beta` shows
   "Scorebug is in private beta". **Join with a code** works without an account.
2. **Home.** The person's teams from `/v1/me`, each with its open match (Film or Score)
   and **New match**. One team shows directly; several stack. **Join with a code**
   (K7P-4QX scores one match, ABCD-EFGH joins a team), the last match, Recordings.
   People JD lets create teams see **Create team**.
3. **Team.** The team's YouTube channel, members and invites. Owners **Connect a YouTube
   channel** (`POST /v1/youtube/connect` in `ASWebAuthenticationSession`, landing on
   `scorebug://auth?purpose=youtube&status=…&ticket=…`, claimed at
   `POST /v1/youtube/connections`), pick one of their connections (`PUT /v1/teams/:id/youtube`),
   **Reconnect** one that needs it, or **Check again** after YouTube's 24-hour wait. Members
   see the channel, or "Ask your team owner to reconnect YouTube". Owners also rename, invite
   by email or with a link (share sheet), revoke invites and remove members. Anyone can leave.
4. **Links.** Universal links `https://scorebug.live/invite/<code>` (team invite: signs in
   with the invite if needed) and `https://scorebug.live/join/<code>` (score one match),
   always confirmed with a tap. The app has the `applinks:scorebug.live` entitlement; the
   Worker serves `/.well-known/apple-app-site-association`.
5. **New match.** Team 1 starts as the team (names, short names ≤ 8 characters
   prefilled from the name, colors), format, scorebug style, the team's YouTube channel
   or record only, Record in 4K. **Go live** starts recording and the stream together; it's
   off, with the reason, when the team has no channel or the channel needs attention.
   The sheet remembers the last opponent. The app never says home or away: Team 1 is the
   API's `home`, Team 2 `away`. Member routes go through `/v1/teams/:teamId/matches`
   with the session token; match-token routes stay `/v1/matches/:id`.
6. **Live (landscape).** Tap the left or right half of the picture to give the
   team on that side a point; Undo; **Swap sides**. LIVE, elapsed time,
   `REC 1080p · 720p out · good`. **Watch link** shares the match's YouTube link (one per
   match, from the Go Live reply or `GET /v1/matches/:id`). **Invite scorer** shows a QR
   (for the Camera app), a 6-character code and a share link. Stream problems, including a
   refused Go Live (`busy`, `time_limit`, no channel…), are a small banner with **Go live
   again**; the recording never stops because of the stream.
7. **Set point.** When the server reports `pendingSetEnd` the scorer confirms
   ("Cascade wins set 3?"): End set / End match, Undo last point, or Keep playing.
   After a set ends: "Teams switching sides?".
8. **Recordings.** Thumbnail, teams and result, date, duration, resolution, size;
   Play, Save to Photos, Share (each checks an MP4 export first).
9. **Second phone as scorer.** A team member taps **Score** on Home; anyone else joins
   with the code or link. Portrait, two big team-colored halves, undo, swap sides, the
   same set-point sheet.
10. **Settings.** Name and email, **Sign out** (revokes the session token), and the
    Debug server.

### Watch

No Watch setup. When its paired iPhone has a match open (filming or scoring), the
Watch shows two team-colored halves ordered by court side: tap to score,
long-press or the undo button to undo, swap sides, the set-point confirm and a
LIVE indicator. Taps go to the iPhone over WatchConnectivity and run through the
iPhone's own scoring outbox, so the Watch never holds a server credential. The
iPhone keeps the latest state in the application context, so the Watch shows the
match as soon as it opens. The iPhone must be in Bluetooth/Wi-Fi range.

## Build and test

```sh
brew install xcodegen
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer   # match CI
xcodegen generate --spec ios/Project.yml
swift test --package-path ios/Packages/ScorebugCore --scratch-path ios/.build/core
swift test --package-path ios/Packages/ScorebugMedia --scratch-path ios/.build/media
swift test --package-path ios/Packages/ScorebugStreaming --scratch-path ios/.build/streaming
xcodebuild test -project ios/Scorebug.xcodeproj -scheme ScorebugModelTests \
  -destination 'platform=macOS' -derivedDataPath ios/DerivedData/Model \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project ios/Scorebug.xcodeproj -scheme Scorebug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData/NativeCI \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

Simulator builds that touch the Keychain need ad hoc signing
(`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`); unsigned builds fail with -34018.
Debug Simulator builds record a generated test picture and tone through the same
recorder as the camera, and show a drawn court in place of the camera preview.

### Screenshot tour against a local server

`ios/AppUITests/ScreenTourTests.swift` signs in, hits the private beta screen, creates a
team, invites, joins a second team by code and scores its match. It runs against the
real Worker app in `ios/AppUITests/LocalWorker`, with a stand-in Google that signs in as
whoever `POST /dev/identity` (`{"email": …, "name": …}`) names, and the Worker tests'
in-memory YouTube, Stream and match container (so Go Live returns a watch link, while the
SRT publish goes nowhere). Use `127.0.0.1`, not
`localhost`: the web sign-in sheet tries IPv6 first and the Worker listens on IPv4.

```sh
pnpm --filter @scorebug/protocol build
cd ios/AppUITests/LocalWorker
W=../../../apps/control-plane/node_modules/.bin/wrangler
rm -rf .state   # each tour starts from an empty database
$W d1 migrations apply scorebug-dev --local --persist-to .state
$W d1 execute scorebug-dev --local --persist-to .state --file seed.sql
$W dev --ip 127.0.0.1 --port 8787 --persist-to .state
```

Then, from the repository root:

```sh
xcodebuild test -project ios/Scorebug.xcodeproj -scheme Scorebug \
  -destination 'platform=iOS Simulator,name=<phone>' -derivedDataPath ios/DerivedData/Sim \
  -only-testing:ScorebugAppUITests/ScreenTourTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  SCOREBUG_TEST_TOUR=/tmp/scorebug-shots SCOREBUG_TEST_API_URL=http://127.0.0.1:8787
```

Debug Simulator builds honor `SCOREBUG_TEST_RESET=1` (signed out, no open match),
`SCOREBUG_TEST_API_URL` (server) and `SCOREBUG_TEST_LINK` (open a link on launch);
Release builds ignore all three.

To try the Watch on simulators, run the **Scorebug** scheme on an iPhone simulator
that has a paired Watch, then run the **ScorebugWatch** scheme on that Watch from
Xcode, and start a match on the phone. What was seen while building this with
`simctl` only (no Xcode Run): one simctl-created pair's phone had a broken IDS
service (`WCSession` never finished activating); on a fresh pair activation
worked, but a Watch app installed with `simctl install` is "not installed" to the
phone and neither side reports the other reachable, and installing the phone app
did not push the embedded Watch app through pairing. The Watch then shows "Keep
your iPhone nearby with Scorebug open." The mirror itself (state, intents,
court-side order, set point) is covered by unit tests in ScorebugCore and the
model tests.

### Needs a real device

- Camera capture and preview orientation in landscape, thermal behavior in 4K.
- Universal links from Messages or Safari (needs the AASA file live on scorebug.live).
- SRT streaming over a real network, and the stream banner on weak networks.
- WatchConnectivity between a physical iPhone and Watch: open Scorebug on the
  iPhone, start a match, raise the Watch and open Scorebug. Check that taps score
  within a second, the haptic plays, long-press undoes, and the set-point screen
  appears. Then walk away until the Watch says "iPhone out of reach" and come back.
- Save to Photos (permission prompt) and the share sheet.

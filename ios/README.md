# Scorebug iOS

The iPhone app films a volleyball match, keeps score and streams it live to YouTube with the score
burned onto the video. It embeds an Apple Watch app for scoring from the wrist. `Project.yml`
(XcodeGen) defines these targets:

- **Scorebug**: the iPhone app, bundle `live.scorebug.app`. iOS 17 or later.
- **ScorebugWatch**: the Watch app, embedded in the iPhone app. watchOS 10 or later.
- **ScorebugModelTests**: macOS unit tests for the app's view models, capture, streaming and
  recording (`AppModelTests` and `FilmModelTests`). No simulator needed.
- **ScorebugAppUITests**: a screenshot tour of the screens against a local Worker (see below).

Swift packages in `Packages/`:

- `ScorebugCore`: the API client (Google sign-in, teams, invites, matches, YouTube), links and
  codes, the scoring outbox, team names and colors, court sides, set point, the Watch protocol and
  the stream quality ladder.
- `ScorebugMedia`: camera capture, the segmented local recording, MP4 export and the publishing
  session that feeds the stream.
- `ScorebugStreaming`: the SRT publisher ([README](Packages/ScorebugStreaming/README.md)).

## What the app does

The app talks to the hosted service at `https://scorebug.live`, the Worker in
`apps/control-plane/src/worker`. The app never says home or away: the New match sheet and the
scoring screens use Team 1, Team 2 and the team names.

1. **Sign in.** **Sign in with Google** opens Google in a system sign-in sheet. Any Google account
   can sign in. **Join with a code** scores one match without an account.
2. **Home.** Each of your teams, with its open match (**Film** or **Score**) and **New match**. Below
   them: **Join with a code**, the last match and **Recordings**. With no team yet, Home shows
   **Create team**; once you have one, **New team** is at the bottom. The gear opens Settings.
3. **Team.** Tap a team on Home. The owner connects the team's YouTube channel once with **Connect a
   YouTube channel**, and can switch channels, **Reconnect YouTube**, or **Check again** while a new
   channel waits out YouTube's 24 hours before it can stream. Members go live on that channel with no
   YouTube setup of their own. The owner also renames the team, invites people (**Invite people**, by
   email or with a link and an eight-character code), revokes invites and removes members. Anyone can
   **Leave team**.
4. **Links.** `https://scorebug.live/invite/<code>` opens a team invite and
   `https://scorebug.live/join/<code>` joins one match as a scorer. The app always asks before it
   joins. The Worker serves the `apple-app-site-association` file for these universal links.
5. **New match.** Team 1 starts as your team. Set each team's name, short name (up to 8 characters,
   filled in from the name) and color, the format (best of 3 or best of 5), the scorebug style on the
   stream (Bar, Lower third or Set card), **Stream to** (the team's channel or Record only) and
   **Record in 4K**. The sheet remembers the last opponent. **Go live** starts recording and the
   stream together. **Record only, don't stream** records without a stream. Go live is off, with the
   reason, when the team has no channel or the channel needs attention.
6. **Live (landscape).** The phone records 1080p, or 4K when Record in 4K is on. When live, it also
   publishes SRT to the match's own Cloudflare Stream input; the server burns in the score and sends
   it to YouTube. Tap the left or right half of the picture to give the team on that side a point.
   **Undo**, **Swap sides**, **Invite scorer** (a QR code, a six-character code and a share link),
   **Watch link** (the match's YouTube link) and **End**. The status line reads like
   `REC 1080p · 720p out · good`. A stream problem shows as a banner, sometimes with **Go live
   again**. The recording never stops because of the stream.
7. **Set point.** The scorer confirms the set ("Cascade wins set 3?"): **End set** or **End match**,
   **Undo last point**, or **Keep playing**. After a set ends: "Teams switching sides?" with **Yes,
   switch** or **Keep sides**.
8. **Second phone.** A team member taps **Score** on Home. Anyone else joins with the code or the
   link. The scorer screen is portrait, with two large team-colored halves, **Undo**, **Swap sides**
   and the same set-point prompts. Scoring moves to the phone that last took it; the other phone
   shows **Take over**.
9. **Recordings.** Each recording with its teams and result, date, length, resolution and size.
   **Play**, **Save to Photos** and **Share**. Recordings stay on the phone.
10. **Settings.** Name and email, **Sign out**, and **Delete account**, which asks first, deletes
    the account on the server (`DELETE /v1/me`) and then signs out. Recordings stay on the phone.

Debug builds can use another server: the **Server** button on the sign-in screen, Settings →
Developer, or the `SCOREBUG_TEST_API_URL` environment variable. Changing the server signs you out.

### Watch

The Watch needs no setup. While the paired iPhone has a match open, filming or scoring, the Watch
shows two team-colored halves in court-side order: tap to score, long-press or the undo button to
undo, swap sides, the set-point prompt and a LIVE indicator. Taps go to the iPhone over
WatchConnectivity and run through the iPhone's own scoring outbox, so the Watch holds no server
credential. With no match open the Watch shows "No match yet". It needs the iPhone in range.

## Build and test

Install XcodeGen and use Xcode 26.2, the version CI uses. If you have several Xcodes, point
`DEVELOPER_DIR` at 26.2. Run these from the repository root; they are the steps in
`.github/workflows/native.yml`.

```sh
brew install xcodegen
xcodegen generate --spec ios/Project.yml

swift test --package-path ios/Packages/ScorebugCore --scratch-path ios/.build/core
swift test --package-path ios/Packages/ScorebugMedia --scratch-path ios/.build/media
swift test --package-path ios/Packages/ScorebugStreaming --scratch-path ios/.build/streaming

xcodebuild test -project ios/Scorebug.xcodeproj -scheme ScorebugModelTests \
  -destination 'platform=macOS' -derivedDataPath ios/DerivedData/Model \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

xcodebuild build -project ios/Scorebug.xcodeproj -scheme Scorebug \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/DerivedData/NativeCI \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

The last command builds the iPhone app with the embedded Watch app. To run it, open
`ios/Scorebug.xcodeproj` and run the **Scorebug** scheme. Simulator builds that use the Keychain
need ad hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`).

Debug Simulator builds record a generated test picture and tone through the same recorder as the
camera, and show a drawn court in place of the camera preview.

Debug builds read these environment variables. Release builds ignore them.

| Variable                | What it does                                      | Where                  |
| ----------------------- | ------------------------------------------------- | ---------------------- |
| `SCOREBUG_TEST_API_URL` | The server to use                                 | Debug builds           |
| `SCOREBUG_TEST_LINK`    | A team invite or match join link to open on start | Debug builds           |
| `SCOREBUG_TEST_RESET`   | `1` starts signed out, with no open match         | Debug Simulator builds |

To try the Watch on simulators, run the **Scorebug** scheme on an iPhone simulator that has a paired
Watch simulator, then run the **ScorebugWatch** scheme on that Watch from Xcode, and open a match on
the phone.

### Screenshot tour against a local Worker

`AppUITests/ScreenTourTests.swift` signs in with a new account, creates a team, connects
YouTube, invites a member, joins a second team by code, scores its match and goes live. It saves a
screenshot of each screen. It runs against `AppUITests/LocalWorker`: the real Worker app with a
stand-in Google that signs in as whoever `POST /dev/identity` (`{"email": …, "name": …}`) names, and
the Worker tests' in-memory YouTube, Stream and match container. Go live returns a watch link, but
the SRT stream goes nowhere. Use `127.0.0.1`, not `localhost`.

Start the local Worker:

```sh
pnpm --filter @scorebug/protocol build
cd ios/AppUITests/LocalWorker
W=../../../apps/control-plane/node_modules/.bin/wrangler
rm -rf .state   # each tour starts from an empty database
$W d1 migrations apply scorebug-dev --local --persist-to .state
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

`SCOREBUG_TEST_TOUR` is the folder for the PNGs. Without it the test is skipped.

## Release

Every push to `main` that changes `ios/**`, `vendor/HaishinKit/**` or `native.yml` runs the
**TestFlight upload** job in `.github/workflows/native.yml` after the tests and build pass. It runs
`release/testflight.sh` with an App Store Connect API key from the `ASC_KEY_ID`, `ASC_ISSUER_ID` and
`ASC_KEY_P8` secrets; without them the upload is skipped with a notice. Afterwards it revokes the
development certificate the archive created on the runner (`release/certs.swift`). The internal
TestFlight group gets every build once Apple has processed it, and any build can be submitted for
App Store review from App Store Connect.

`release/testflight.sh` does the same by hand. It needs an Admin App Store Connect API key at
`~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8` (or `ASC_KEY_PATH`):

```sh
TEAM_ID=… ASC_KEY_ID=… ASC_ISSUER_ID=… ios/release/testflight.sh
```

The build number is the UTC time (`YYYYMMDDHHMM`) unless `BUILD_NUMBER` is set. The version users
see is `MARKETING_VERSION` in `Project.yml`.

The App Store page itself (listing copy, screenshots, the preview video and the scripts that make
and upload them) lives in [`AppStore/`](AppStore/README.md).

## Needs a real device

- Camera capture, the landscape preview and heat over a full match in 4K.
- Universal links from Messages or Safari.
- SRT streaming over a real network, and the stream banner on a weak network.
- WatchConnectivity between a physical iPhone and Watch: taps score within a second, the haptic
  plays, long-press undoes and the set-point prompt appears. Walk away until the Watch says "iPhone
  out of reach", then come back.
- Save to Photos (the permission prompt) and the share sheet.

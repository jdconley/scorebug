# Scorebug iOS

One iPhone app (with an embedded Apple Watch app) for a parent who films and
scores alone. `Project.yml` (XcodeGen) builds:

- **Scorebug** — iPhone app. Dark, camera-first, no tabs.
- **ScorebugWatch** — Watch app. Mirrors the paired iPhone's open match.
- **ScorebugModelTests** — macOS unit tests for the view models, capture,
  streaming and recording (no simulator needed).
- **ScorebugAppUITests** — a screenshot tour of every screen (manual, below).

Swift packages: `ScorebugCore` (HTTP client, scoring outbox, setup/invite links,
short names, court sides, set point, Watch protocol, quality ladder),
`ScorebugMedia` (capture, segmented archive, MP4 export), `ScorebugStreaming`
(SRT publisher). The iPhone baseline is iOS 17, the Watch watchOS 10.

## Flow

1. **Connect (first launch).** On the server run `./infra/install.sh phone`
   (or `node apps/control-plane/dist/cli.js setup-link` in the API container).
   Scan its QR code, open the `scorebug://connect` link, or enter the address and
   code by hand. The app always asks before connecting. It redeems the one-time
   code for an owner credential kept in the Keychain. One server for the whole app.
2. **Home.** Server status (connected · YouTube ready), **New match**, **Join a
   match**, the last match, Recordings.
3. **New match.** Team 1 / Team 2 (names, short names ≤ 8 characters prefilled
   from the name, colors), format, scorebug style, stream destination (from the
   server) or record only, Record in 4K. **Go live** starts recording and the
   stream together. The sheet remembers the last teams, colors and destination.
   The app never says home or away: Team 1 is the API's `home`, Team 2 `away`.
4. **Live (landscape).** Tap the left or right half of the picture to give the
   team on that side a point; Undo; **Swap sides**. LIVE, elapsed time,
   `REC 1080p · 720p out · good`. **Invite scorer** shows a QR, a 6-character code
   and a share link. Stream problems are a small banner; the recording never
   stops because of the stream.
5. **Set point.** When the server reports `pendingSetEnd` the scorer confirms
   ("Cascade wins set 3?"): End set / End match, Undo last point, or Keep playing.
   After a set ends: "Teams switching sides?".
6. **Recordings.** Thumbnail, teams and result, date, duration, resolution, size;
   Play, Save to Photos, Share (each checks an MP4 export first).
7. **Second phone as scorer.** Join with the invite QR, link or code. Portrait,
   two big team-colored halves, undo, swap sides, the same set-point sheet. No
   camera and no setup link needed.

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

```sh
pnpm dev:api        # 127.0.0.1:18787, PUBLIC_URL=http://127.0.0.1:18787
curl -s -X POST http://127.0.0.1:18787/v1/setup/links \
  -H "Authorization: Bearer qa-phone-token-not-production" -H "Content-Type: application/json" -d '{}'
xcodebuild test -project ios/Scorebug.xcodeproj -scheme Scorebug \
  -destination 'platform=iOS Simulator,name=<phone>' -derivedDataPath ios/DerivedData/Sim \
  -only-testing:ScorebugAppUITests/ScreenTourTests/testFilmingTourStart \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  SCOREBUG_TEST_TOUR=/tmp/scorebug-shots 'SCOREBUG_TEST_LINK=<the scorebug://connect link>'
```

Then mint an invite for the open match (`POST /v1/matches/<id>/invites` with the
same token), run `testScorerTour` on a second simulator with that
`scorebug://join` link, and `testFilmingTourFinish` on the first. Debug Simulator
builds honor `SCOREBUG_TEST_RESET=1` (fresh install state) and
`SCOREBUG_TEST_LINK` (open a link on launch); Release builds ignore both.

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
- Scanning QR codes (the Simulator has no camera; paste the link instead).
- SRT streaming over a real network, and the stream banner on weak networks.
- WatchConnectivity between a physical iPhone and Watch: open Scorebug on the
  iPhone, start a match, raise the Watch and open Scorebug. Check that taps score
  within a second, the haptic plays, long-press undoes, and the set-point screen
  appears. Then walk away until the Watch says "iPhone out of reach" and come back.
- Save to Photos (permission prompt) and the share sheet.

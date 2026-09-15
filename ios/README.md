# Scorebug iOS

## Native scorer (milestone 1 in progress)

`Scoring.yml` generates a separate **ScorebugScoring** app and XCUITest target.
It builds only `Sources/ScorebugScoring` and the local `Packages/ScorebugCore`
Swift package. It does not resolve or link the camera app, HaishinKit, or SRT.
The iPhone deployment baseline is iOS 17.0; the shared package also declares
watchOS 10.0 for the native Watch app.

The SwiftUI screen connects to the durable match API, creates or joins the active
match, scores, undoes actions, ends sets/matches, and takes over scoring explicitly.
Keychain stores setup and credentials. A durable command outbox checks server
receipts after network failure or relaunch before retrying the original action.
Pending actions and conflicts require resolution before another point is sent.

HTTPS is accepted for public servers; HTTP is accepted only for localhost, loopback,
private IPv4 LAN addresses, and `.local` hostnames. Debug builds enable local-network
ATS access. Base paths are preserved; credentials in URLs, query strings, fragments,
and invalid ports are rejected. The default simulator address is
`http://localhost:18787`. See [the API and recovery contract](../docs/native-scoring-api.md).

Install full Xcode with an iOS SDK and simulator runtime, plus XcodeGen:

```sh
brew install xcodegen
# From the repository root; defaults to the installed iOS 26.2 simulator runtime.
pnpm test:apple
# Create on phone A, join/take over/end on phone B, observe on phone A:
pnpm test:apple --two-phones
# Choose another installed runtime, including an older supported iOS version.
SCOREBUG_IOS_RUNTIME=17.5 pnpm test:apple
# Exercise the required iPhone 14 screen size with an installed runtime:
SCOREBUG_IOS_RUNTIME=18.5 SCOREBUG_IOS_DEVICE_TYPE=iPhone-14 pnpm test:apple
```

The runner first runs shared Swift tests and the production scoring-model tests
on macOS 14+, then builds the iPhone app and exercises its UI.

The runner creates dedicated iPhone 15 simulators with unique **Scorebug Scoring**
names, runs the native workflow, then shuts down and deletes only those devices.
It also owns a temporary SQLite database and real API bound to a random loopback port.
It does not use or reset existing simulators. Each build/test command has a ten
minute timeout. Results remain under `ios/build/*.xcresult` and generated projects,
Swift build products, and DerivedData are ignored.

On the development Mac, the default Xcode 26.6 reported “iOS 26.5 is not installed”
when resolving destinations. The complete installed Xcode 26.2 is selected for
this command only:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:apple
```

To run each step manually from the repository root (set `DEVELOPER_DIR` as needed):

```sh
xcodegen generate --spec ios/Scoring.yml
swift test --package-path ios/Packages/ScorebugCore --scratch-path ios/.build/core
xcodebuild -project ios/ScorebugScoring.xcodeproj -scheme ScorebugScoring \
  -configuration Debug -derivedDataPath ios/DerivedData/Scoring \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.0
# Run UI tests through pnpm test:apple; it supplies the owned API URL and token.
```

The UI test resets camera/microphone authorization and exercises native scoring
without any permission dialog. No camera or microphone usage descriptions are
present in this app. Simulator UI builds use local ad hoc signing because Keychain
access fails with error -34018 when signing is disabled. No signing team is needed.
The unsigned generic build checks iOS 17 compilation, not physical-device behavior.
To inspect interactively, start `pnpm dev:api`, open
`ios/ScorebugScoring.xcodeproj`, and choose a dedicated Scorebug simulator.
Use the development token from `infra/local/.env.example` only for local tests.

## Native filming and scoring app

`Project.yml` now builds **Scorebug**, with Film, Score, Watch, and Recordings tabs. The
obsolete camera prototype has been replaced by the shared capture/recording path.
Filming requires no match, server connection, or streaming key. Switching to the
native scorer keeps local recording running. No browser scorer is used.

Record explicitly starts camera/microphone permission and capture on a phone.
The initial clean archive is 1080p/30 SDR H.264 with audio. Leaving the app requests
recording stop; camera interruptions and failures preserve recoverable segments.
Recordings distinguishes completed, recoverable, and unavailable media. Export
retains the original and verifies the full MP4 before offering playback/sharing.

Debug Simulator builds generate timed video/audio through the same recording
owner. This is labeled in Film and does not use a physical camera. Release and
physical-device builds choose the iPhone camera adapter. Native SRT publishing is
connected; adaptive quality remains pending.

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
pnpm test:native-app
SCOREBUG_IOS_RUNTIME=18.5 pnpm test:native-app
SCOREBUG_IOS_RUNTIME=26.2 SCOREBUG_IOS_DEVICE_TYPE=iPhone-15 pnpm test:native-app
xcodegen generate --spec ios/Project.yml
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests \
  -destination 'platform=macOS' -derivedDataPath ios/DerivedData/FilmModel \
  test CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

The native-app runner owns a fresh Simulator and local scoring server. It tests
recording without setup, a real scoring command during recording, stop/relaunch,
forced-termination recovery, export, and advancing video playback. It copies the
recordings into `artifacts/qa/native-app-*`, fully decodes exports, checks sequential
source frame identities, and applies the 100 ms audio/video coverage gate. Only
the runner's device and processes are cleaned up. It never shares the video.

See [native app integration](../docs/native-film-app.md), the
[architecture](../docs/architecture.md), and the
[delivery plan](../docs/superpowers/plans/2026-09-13-portable-streaming-and-watch.md).
Physical-phone camera and Watch networking qualification remain ahead.

## Native Watch scorer

`Project.yml` also generates **ScorebugWatch**, a watchOS 10 application embedded
in the phone app. It uses ScorebugCore and Apple frameworks, without media packages.
The phone's Watch tab sends an expiring setup offer using a saved Film or Score
connection. Accept it on the Watch, then take over scoring explicitly. Watch commands
use its own credential, Keychain setup, and durable scoring outbox. Configured Watch
scoring can use direct HTTP or the paired phone's app-scoped relay, with receipt-first
recovery after uncertain sends. Initial setup redemption still requires direct HTTP;
physical network switching and background delivery remain unqualified.

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
pnpm test:native-watch
SCOREBUG_WATCH_RUNTIME=26.2 SCOREBUG_WATCH_DEVICE_TYPE=Apple-Watch-Ultra-2-49mm pnpm test:native-watch
SCOREBUG_WATCH_RUNTIME=10.0 SCOREBUG_WATCH_DEVICE_TYPE=Apple-Watch-SE-40mm-2nd-generation pnpm test:native-watch
```

The runner owns a fresh simulator and real local API. It injects only initial setup
into a Debug simulator build; redemption, Keychain, commands, and relaunch recovery
use production paths. This does not qualify WatchConnectivity or physical radio
selection. See [native Watch implementation and evidence](../docs/native-watch-app.md).

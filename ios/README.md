# Scorebug iOS

## Native scorer (milestone 1 in progress)

`Scoring.yml` generates a separate **ScorebugScoring** app and XCUITest target.
It builds only `Sources/ScorebugScoring` and the local `Packages/ScorebugCore`
Swift package. It does not resolve or link the camera app, HaishinKit, or SRT.
The iPhone deployment baseline is iOS 17.0; the shared package also declares
watchOS 10.0 for later native Watch work.

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

## Camera app scaffold (media integration pending)

`Project.yml` and `Sources/Scorebug` retain the original filming prototype. They
are excluded from the scoring harness and have not passed the new media gates.
The sample forwarding into SRT is incomplete, and the archive writer's raw-buffer
passthrough assumptions do not establish a reliable recording. The previous
crash-safety and simultaneous streaming claims are unverified.

Milestone 3 will validate the HaishinKit version and replace the recording path
with encoded, recoverable local segments. Milestone 5 adds the native watch app.
See the [architecture](../docs/architecture.md) and
[delivery plan](../docs/superpowers/plans/2026-09-13-portable-streaming-and-watch.md).

To inspect the legacy camera project, run `xcodegen generate --spec ios/Project.yml`.
Do not interpret a scoring-harness build as a camera-project or device-media pass.

# Scorebug iOS

## Native scorer foundation (milestone 0)

`Scoring.yml` generates a separate **ScorebugScoring** app and XCUITest target.
It builds only `Sources/ScorebugScoring` and the local `Packages/ScorebugCore`
Swift package. It does not resolve or link the camera app, HaishinKit, or SRT.
The iPhone deployment baseline is iOS 17.0; the shared package also declares
watchOS 10.0 for later native Watch work.

The SwiftUI screen validates the syntax of a control-plane address. HTTPS is
accepted for public servers; HTTP is accepted only for localhost, loopback,
private IPv4 LAN addresses, and `.local` hostnames. Base paths are preserved;
credentials, query strings, fragments, and invalid ports are rejected. This is
address validation only: no requests, persistence, authentication, match creation,
joining, scoring, or Watch app are implemented by this harness. Those follow in
milestones 1 and 5. The default simulator address is `http://localhost:18787`.

Install full Xcode with an iOS SDK and simulator runtime, plus XcodeGen:

```sh
brew install xcodegen
# From the repository root; defaults to the installed iOS 26.2 simulator runtime.
pnpm test:apple
# Choose another installed runtime, including an older supported iOS version.
SCOREBUG_IOS_RUNTIME=17.5 pnpm test:apple
```

The runner creates an iPhone 15 simulator named **Scorebug Scoring Smoke** with a
unique suffix, runs the smoke test, then shuts down and deletes only that device.
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
SCORING_SIMULATOR_ID=$(xcrun simctl create 'Scorebug Scoring Manual' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-15 \
  com.apple.CoreSimulator.SimRuntime.iOS-26-2)
xcodebuild -project ios/ScorebugScoring.xcodeproj -scheme ScorebugScoring \
  -configuration Debug -derivedDataPath ios/DerivedData/Scoring \
  -destination "platform=iOS Simulator,id=$SCORING_SIMULATOR_ID" \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 test CODE_SIGNING_ALLOWED=NO
xcrun simctl shutdown "$SCORING_SIMULATOR_ID"
xcrun simctl delete "$SCORING_SIMULATOR_ID"
```

The UI test resets camera/microphone authorization, launches the native scorer,
and validates the address without any permission dialog. No camera or microphone
usage descriptions are present in the scorer app. An unsigned generic device
build checks compilation at the iOS 17 baseline; it is not physical-device testing
or an SRT/capture pass. To inspect the app interactively, open
`ios/ScorebugScoring.xcodeproj` and choose a dedicated Scorebug simulator.

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

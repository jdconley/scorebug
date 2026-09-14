# HaishinKit compatibility probes

These isolated probes establish SDK compatibility before camera integration.
`SDKSmoke` checks method signatures without capture or networking.
`DualOutputSmoke` feeds decoded fixture samples to the shared archive and a real
SRT publisher through independent bounded queues. Its destination is restricted
to an owned loopback receiver. Neither executable is the production camera app.
The `record-only` destination skips publisher creation entirely; the conformance
runner exercises this offline mode as well as three network scenarios.

The package pins HaishinKit 2.2.5 and checks in its resolution, including Logboard
2.6.0. HaishinKit supplies libsrt 1.5.4 with iPhone, Simulator, and Mac slices.

From the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
swift run --package-path tools/media-sdk-probe SDKSmoke
pnpm test:dual-output
cd tools/media-sdk-probe
xcodebuild -scheme DualOutputSmoke -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/qa/dual-output-simulator ARCHS=arm64 \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DualOutputSmoke -destination 'generic/platform=iOS' \
  -derivedDataPath ../../artifacts/qa/dual-output-device \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO build
```

The exact source passed macOS Swift 6 compilation and linked execution, generic
iOS Simulator arm64/x86_64 compilation, and unsigned iPhone arm64 compilation
with deployment target 17.0 using Xcode 26.2. Logs are retained under
`artifacts/qa/media-sdk-probe/`. The final PCM helper also passed the simulator
rebuild. The repository copy compiled and ran with a fresh, dedicated scratch
directory. Reusing the original temporary package's scratch directory from the
new package location failed in imported SDK modules; the precise cache cause is
unproven. Keep each package's default `.build` directory or use a dedicated scratch.
This does not establish runtime behavior on iOS 17.

Full executable linking additionally requires `libc++`, now declared in the
package. The resolved libsrt 1.5.4 archive advertises an Intel simulator slice but
has no SRT function symbols in that slice; its full x86_64 link fails. The ARM64
simulator destination above matches this Mac. The previous x86_64 library compile
did not establish executable link compatibility.

See [the dual-output results](../../docs/native-dual-output.md) and
[compatibility findings](../../docs/capture-sdk-compatibility.md) for the audio
conversion requirement, buffer ownership, and remaining runtime checks.

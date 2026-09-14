# HaishinKit compatibility probe

This isolated compile probe establishes method signatures and linking before the
camera integration is rebuilt. It is not the production publisher or archive.
It neither captures media nor connects to a network.

The package pins HaishinKit 2.2.5 and checks in its resolution, including Logboard
2.6.0. HaishinKit supplies libsrt 1.5.4 with iPhone, Simulator, and Mac slices.

From the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
swift run --package-path tools/media-sdk-probe SDKSmoke
cd tools/media-sdk-probe
xcodebuild -scheme SDKProbe -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/qa/media-sdk-probe/DerivedData \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SDKProbe -destination 'generic/platform=iOS' \
  -derivedDataPath ../../artifacts/qa/media-sdk-probe/DerivedData \
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

See [the compatibility findings](../../docs/capture-sdk-compatibility.md) for the
audio conversion requirement, actor/buffer ownership, and remaining runtime checks.

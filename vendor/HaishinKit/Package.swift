// swift-tools-version: 6.0
import PackageDescription

// Source subset of upstream 2.2.5. See README.md and upstream-files.json.
let package = Package(
    name: "HaishinKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
        .library(name: "SRTHaishinKit", targets: ["SRTHaishinKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/shogo4405/Logboard.git", exact: "2.6.0")
    ],
    targets: [
        .binaryTarget(name: "libsrt",
            url: "https://github.com/HaishinKit/libsrt-xcframework/releases/download/v1.5.4/libsrt.xcframework.zip",
            checksum: "76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a"),
        .target(name: "HaishinKit", dependencies: ["Logboard"], path: "HaishinKit/Sources"),
        .target(name: "SRTHaishinKit", dependencies: ["libsrt", "HaishinKit"],
            path: "SRTHaishinKit/Sources", linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "SRTHaishinKitTests", dependencies: ["SRTHaishinKit"],
            path: "SRTHaishinKit/Tests"),
        .testTarget(name: "HaishinKitPatchTests", dependencies: ["HaishinKit"],
            path: "ScorebugPatchTests")
    ],
    swiftLanguageModes: [.v6]
)

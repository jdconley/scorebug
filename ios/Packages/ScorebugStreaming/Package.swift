// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScorebugStreaming",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ScorebugStreaming", targets: ["ScorebugStreaming"])],
    dependencies: [.package(path: "../../../vendor/HaishinKit"), .package(path: "../ScorebugMedia")],
    targets: [
        .target(name: "ScorebugStreaming", dependencies: [
            .product(name: "HaishinKit", package: "HaishinKit"),
            .product(name: "SRTHaishinKit", package: "HaishinKit"),
            .product(name: "ScorebugMedia", package: "ScorebugMedia")
        ], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "ScorebugStreamingTests", dependencies: ["ScorebugStreaming"])
    ]
)

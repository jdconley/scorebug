// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SDKProbe", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .executable(name: "SDKSmoke", targets: ["SDKSmoke"]),
        .executable(name: "DualOutputSmoke", targets: ["DualOutputSmoke"]),
        .library(name: "SDKProbe", targets: ["SDKProbe"])
    ],
    dependencies: [
        .package(path: "../../ios/Packages/ScorebugStreaming"),
        .package(path: "../../ios/Packages/ScorebugMedia")
    ],
    targets: [
        .executableTarget(name: "SDKSmoke", dependencies: ["SDKProbe"]),
        .executableTarget(name: "DualOutputSmoke", dependencies: [
            "SDKProbe", .product(name: "ScorebugMedia", package: "ScorebugMedia")
        ]),
        .target(name: "SDKProbe", dependencies: [
            .product(name: "ScorebugStreaming", package: "ScorebugStreaming"),
            .product(name: "ScorebugMedia", package: "ScorebugMedia")
        ], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "SDKProbeTests", dependencies: ["SDKProbe"])
    ]
)

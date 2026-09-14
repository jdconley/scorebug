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
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift.git", exact: "2.2.5"),
        .package(path: "../../ios/Packages/ScorebugMedia")
    ],
    targets: [
        .executableTarget(name: "SDKSmoke", dependencies: ["SDKProbe"]),
        .executableTarget(name: "DualOutputSmoke", dependencies: [
            "SDKProbe", .product(name: "ScorebugMedia", package: "ScorebugMedia")
        ]),
        .target(name: "SDKProbe", dependencies: [
            .product(name: "HaishinKit", package: "HaishinKit.swift"),
            .product(name: "SRTHaishinKit", package: "HaishinKit.swift")
        ], linkerSettings: [.linkedLibrary("c++")])
    ]
)

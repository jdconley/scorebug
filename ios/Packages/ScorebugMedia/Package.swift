// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScorebugMedia",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ScorebugMedia", targets: ["ScorebugMedia"])],
    targets: [
        .target(name: "ScorebugMedia"),
        .testTarget(name: "ScorebugMediaTests", dependencies: ["ScorebugMedia"]),
    ]
)

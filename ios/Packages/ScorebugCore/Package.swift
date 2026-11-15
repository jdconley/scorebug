// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScorebugCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [.library(name: "ScorebugCore", targets: ["ScorebugCore"])],
    targets: [
        .target(name: "ScorebugCore"),
        .testTarget(name: "ScorebugCoreTests", dependencies: ["ScorebugCore"], resources: [.copy("Fixtures")]),
    ]
)

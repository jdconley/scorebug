// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScorebugStreaming",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ScorebugStreaming", targets: ["ScorebugStreaming"])],
    dependencies: [.package(path: "../../../vendor/HaishinKit")],
    targets: [
        .target(name: "ScorebugStreaming", dependencies: [
            .product(name: "HaishinKit", package: "HaishinKit"),
            .product(name: "SRTHaishinKit", package: "HaishinKit")
        ], linkerSettings: [.linkedLibrary("c++")])
    ]
)

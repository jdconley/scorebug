// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScorebugMediaHarness",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ArchiveHarness", targets: ["ArchiveHarness"])],
    dependencies: [.package(path: "../../ios/Packages/ScorebugMedia")],
    targets: [.executableTarget(name: "ArchiveHarness", dependencies: [
        .product(name: "ScorebugMedia", package: "ScorebugMedia")
    ])]
)

// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SDKProbe", platforms: [.iOS(.v17), .macOS(.v13)], products: [.executable(name: "SDKSmoke", targets: ["SDKSmoke"]), .library(name: "SDKProbe", targets: ["SDKProbe"])], dependencies: [.package(url: "https://github.com/HaishinKit/HaishinKit.swift.git", exact: "2.2.5")], targets: [.executableTarget(name: "SDKSmoke", dependencies: ["SDKProbe"]), .target(name: "SDKProbe", dependencies: [.product(name: "HaishinKit", package: "HaishinKit.swift"), .product(name: "SRTHaishinKit", package: "HaishinKit.swift")])])

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TestSupport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        .target(
            name: "TestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

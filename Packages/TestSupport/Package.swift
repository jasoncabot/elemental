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
            // Read from the checkout via #filePath (see TextFixtures), not bundled as resources.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

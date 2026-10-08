// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Presenters",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Presenters", targets: ["Presenters"]),
    ],
    dependencies: [
        .package(path: "../GitData"),
        .package(path: "../TestSupport"),
    ],
    targets: [
        .target(
            name: "Presenters",
            dependencies: ["GitData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PresentersTests",
            dependencies: ["Presenters", "GitData", "TestSupport"],
            // Golden snapshots are read and recorded in the checkout via #filePath.
            exclude: ["Goldens"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

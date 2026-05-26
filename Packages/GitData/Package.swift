// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitData",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GitData", targets: ["GitData"]),
    ],
    dependencies: [
        .package(path: "../TestSupport"),
    ],
    targets: [
        .target(
            name: "GitData",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GitDataTests",
            dependencies: ["GitData", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

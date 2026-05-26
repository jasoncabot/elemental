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
    ],
    targets: [
        .target(
            name: "Presenters",
            dependencies: ["GitData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PresentersTests",
            dependencies: ["Presenters", "GitData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

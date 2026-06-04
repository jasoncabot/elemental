// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppRouting",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppRouting", targets: ["AppRouting"]),
    ],
    targets: [
        .target(
            name: "AppRouting",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AppRoutingTests",
            dependencies: ["AppRouting"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

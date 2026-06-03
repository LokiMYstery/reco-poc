// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecoPOC",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RecoPOC", targets: ["RecoPOC"])
    ],
    targets: [
        .target(
            name: "RecoPOC",
            path: "Sources/RecoPOC",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "RecoPOCTests",
            dependencies: ["RecoPOC"],
            path: "Tests/RecoPOCTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)

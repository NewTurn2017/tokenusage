// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenUsage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenUsageCore", targets: ["TokenUsageCore"]),
        .executable(name: "TokenUsageApp", targets: ["TokenUsageApp"])
    ],
    targets: [
        .target(name: "TokenUsageCore"),
        .executableTarget(
            name: "TokenUsageApp",
            dependencies: ["TokenUsageCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TokenUsageCoreTests",
            dependencies: ["TokenUsageCore"]
        ),
        .testTarget(
            name: "TokenUsageAppTests",
            dependencies: ["TokenUsageApp", "TokenUsageCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)

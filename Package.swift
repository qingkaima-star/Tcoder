// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TcoderMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TcoderMonitor",
            path: "Sources/TcoderMonitor",
            swiftSettings: [
                // Swift 6 strict concurrency would stall a multi-agent merge with
                // Sendable churn; revisit after the feature set ships.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "TcoderMonitorTests",
            dependencies: ["TcoderMonitor"],
            path: "Tests/TcoderMonitorTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)

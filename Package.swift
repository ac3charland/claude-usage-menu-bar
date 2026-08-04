// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
        .executable(name: "ClaudeUsageDaemon", targets: ["ClaudeUsageDaemon"]),
        .executable(name: "ClaudeUsageApp", targets: ["ClaudeUsageApp"]),
    ],
    targets: [
        .target(name: "ClaudeUsageCore", path: "Sources/ClaudeUsageCore"),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            path: "Tests/ClaudeUsageCoreTests"
        ),
        .executableTarget(
            name: "ClaudeUsageDaemon",
            dependencies: ["ClaudeUsageCore"],
            path: "Sources/ClaudeUsageDaemon"
        ),
        .executableTarget(
            name: "ClaudeUsageApp",
            dependencies: ["ClaudeUsageCore"],
            path: "Sources/ClaudeUsageApp"
        ),
        // Phase 0 feasibility spikes — throwaway, kept for reference under spikes/.
        .executableTarget(name: "Spike0aKeychain", path: "spikes/Spike0aKeychain"),
        .executableTarget(name: "Spike0bUsage", path: "spikes/Spike0bUsage"),
        .executableTarget(name: "Spike0cRefresh", path: "spikes/Spike0cRefresh"),
        .executableTarget(name: "Spike0cForceRefresh", path: "spikes/Spike0cForceRefresh"),
    ]
)

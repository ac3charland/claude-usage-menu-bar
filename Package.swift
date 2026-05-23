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
        .executableTarget(name: "Spike0aKeychain", path: "Sources/Spike0aKeychain"),
        .executableTarget(name: "Spike0bUsage", path: "Sources/Spike0bUsage"),
        .executableTarget(name: "Spike0cRefresh", path: "Sources/Spike0cRefresh"),
        .executableTarget(name: "Spike0cForceRefresh", path: "Sources/Spike0cForceRefresh"),
    ]
)
